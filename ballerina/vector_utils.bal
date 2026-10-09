// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/lang.'decimal;
import ballerina/time;
import ballerina/uuid;

// Metadata and vector limits from AWS's published S3 Vectors limitations. Kept as named
// constants so every check that enforces one names it, rather than a magic number.
const int MAX_VECTOR_KEY_LENGTH = 1024;
const int MAX_METADATA_KEYS = 50;
// Applies to the names in an index's `nonFilterableMetadataKeys`, so it bounds `contentKey`.
const int MAX_NON_FILTERABLE_KEY_LENGTH = 63;
const int MAX_METADATA_BYTES = 40 * 1024;
const int MAX_FILTERABLE_METADATA_BYTES = 2 * 1024;
const int MAX_PUT_BATCH_COUNT = 500;
const int MAX_DELETE_BATCH_COUNT = 500;
const int MAX_GET_BATCH_COUNT = 100;
const int MAX_REQUEST_BYTES = 20 * 1024 * 1024;
// Room left under `MAX_REQUEST_BYTES` for the request envelope around the vectors: the index
// identifier, the array brackets and one comma per vector. 64 KiB covers a 500-vector batch with
// a 2,048-character index ARN many times over.
const int REQUEST_ENVELOPE_HEADROOM_BYTES = 64 * 1024;
const int MAX_PUT_PAYLOAD_BYTES = MAX_REQUEST_BYTES - REQUEST_ENVELOPE_HEADROOM_BYTES;
const int MAX_TOP_K = 10000;
// The smallest `topK` `queryByEmbedding` will ask S3 Vectors for, regardless of how few results
// the caller wants. QueryVectors is an approximate search, and a small `topK` narrows how much of
// the index it explores: measured against an index holding a single vector, queried with that
// vector's own embedding, `topK: 1` came back empty on 6 of 10 attempts while `topK: 10` returned
// it on 10 of 10 in the same period. Over-asking and truncating locally costs one response worth
// of extra metadata and removes the misses.
const int MIN_QUERY_TOP_K = 10;
const int MAX_LIST_PAGE_SIZE = 1000;

// The metadata key `add` writes the chunk's type under, so `query` can rebuild the `Chunk` with
// its original type. Underscore-prefixed so it is unlikely to clash with a caller's own metadata;
// `add` rejects a chunk whose metadata uses it (or the content key) rather than overwrite it.
const string CHUNK_TYPE_METADATA_KEY = "_chunkType";

// Chunk types whose content is media, not text. Such a chunk can still carry a string (a URL),
// which would otherwise pass the string-content check and be stored as if it were text.
final readonly & string[] MEDIA_CHUNK_TYPES = ["image", "audio", "file", "binary"];

// The `ai:Metadata` fields declared as `string`. Assigning a non-string to one of them panics, so
// `createAiMetadata` checks these before copying a stored value across.
final readonly & string[] STRING_METADATA_KEYS = ["mimeType", "fileName", "header", "language",
    "header1", "header2", "header3", "header4", "header5", "header6"];

// ---------------------------------------------------------------------------------------------
// Init-time validation
// ---------------------------------------------------------------------------------------------

// Checks that the index is named one way or the other, never both, and that no name is empty.
isolated function validateVectorIndex(VectorIndex index) returns ai:Error? {
    string? indexArn = index.indexArn;
    string? vectorBucketName = index.vectorBucketName;
    string? indexName = index.indexName;
    if indexArn is string {
        if vectorBucketName is string || indexName is string {
            return error ai:Error(
                "The S3 Vectors index must be identified by either 'indexArn' alone, or by " +
                "'vectorBucketName' and 'indexName' together — not both forms at once");
        }
        if indexArn.trim() == "" {
            return error ai:Error("The S3 Vectors 'indexArn' must not be empty");
        }
        return;
    }
    if vectorBucketName is () || indexName is () {
        return error ai:Error(
            "The S3 Vectors index must be identified by either 'indexArn', or by both " +
            "'vectorBucketName' and 'indexName'");
    }
    if vectorBucketName.trim() == "" || indexName.trim() == "" {
        return error ai:Error("The S3 Vectors 'vectorBucketName' and 'indexName' must not be empty");
    }
}

// Checks the store configuration, including the store-level filters, so a mistake surfaces at
// `init` instead of on the first query.
isolated function validateStoreConfig(VectorStoreConfig config) returns ai:Error? {
    string contentKey = config.contentKey;
    if contentKey.trim() == "" {
        return error ai:Error("VectorStoreConfig.contentKey must not be empty");
    }
    if contentKey.length() > MAX_NON_FILTERABLE_KEY_LENGTH {
        return error ai:Error(
            string `VectorStoreConfig.contentKey '${contentKey}' is longer than the ` +
            string `${MAX_NON_FILTERABLE_KEY_LENGTH} characters S3 Vectors allows for a non-filterable key`);
    }
    if contentKey == CHUNK_TYPE_METADATA_KEY {
        return error ai:Error(
            string `VectorStoreConfig.contentKey cannot be '${CHUNK_TYPE_METADATA_KEY}': the store uses that ` +
            "key for the chunk type");
    }
    if config.maxListScan < 1 {
        return error ai:Error("VectorStoreConfig.maxListScan must be at least 1");
    }
    ai:MetadataFilters? filters = config.filters;
    if filters is ai:MetadataFilters {
        _ = check translateFilters(filters, contentKey);
    }
}

// ---------------------------------------------------------------------------------------------
// Entry -> wire mapping (`add`)
// ---------------------------------------------------------------------------------------------

// Converts one `ai:VectorEntry` into the JSON shape of a `PutInputVector`, validating everything
// S3 Vectors would otherwise reject with an opaque error: dimension, key length, NaN/Infinity,
// an all-zero vector under cosine, and every metadata limit. Every failure names the vector's
// key so a caller adding a batch can tell which entry was the problem.
//
// `distanceMetric` is `()` when the store was initialized with `validateIndexOnInit: false` — the
// all-zero-vector check below only fires when the metric is known to be "cosine", so an unknown
// metric is treated as "don't guess" rather than assumed to be cosine.
//
// Assigns a UUID and mutates `entry.id` in place when the caller left it unset, so the caller
// can see the generated id afterwards — the same contract `ai:InMemoryVectorStore` and the
// Pinecone/Milvus stores follow.
isolated function mapEntryToWireVector(ai:VectorEntry entry, string contentKey, int? expectedDimension,
        string? distanceMetric) returns map<json>|ai:Error {
    ai:Embedding embedding = entry.embedding;
    if embedding !is ai:Vector {
        // S3 Vectors has no sparse or hybrid index type; only dense float vectors are stored.
        return error ai:Error("S3 Vectors supports dense vectors exclusively");
    }

    if entry.id is () {
        entry.id = uuid:createRandomUuid();
    }
    string key = <string>entry.id;
    if key.length() == 0 || key.length() > MAX_VECTOR_KEY_LENGTH {
        return error ai:Error(
            string `Vector key '${key}' must be between 1 and ${MAX_VECTOR_KEY_LENGTH} characters long`);
    }

    if expectedDimension is int && embedding.length() != expectedDimension {
        return error ai:Error(
            string `Vector '${key}' has ${embedding.length()} dimensions, but the index requires ` +
            string `${expectedDimension}`);
    }
    boolean allZero = true;
    foreach float component in embedding {
        if component.isNaN() || component.isInfinite() {
            return error ai:Error(
                string `Vector '${key}' contains a NaN or Infinity value, which S3 Vectors does not accept`);
        }
        if component != 0.0 {
            allZero = false;
        }
    }
    if allZero && distanceMetric == "cosine" {
        return error ai:Error(
            string `Vector '${key}' is an all-zero vector, which is not allowed under the cosine distance ` +
            "metric this index was created with");
    }

    string chunkType = entry.chunk.'type;
    if MEDIA_CHUNK_TYPES.indexOf(chunkType) is int {
        return error ai:Error(
            string `Vector '${key}': S3 Vectors vector store only supports text chunks, not '${chunkType}' chunks`);
    }
    anydata content = entry.chunk.content;
    if content !is string {
        // Every chunk kind other than text (image/audio/binary/file) carries non-string content,
        // which has nowhere sensible to go in a JSON metadata map. This store is built around
        // the `s3:TextDataLoader` -> chunker -> embedder -> vector store pipeline, so requiring
        // string content is a deliberate scope limit, not an oversight.
        return error ai:Error(
            string `Vector '${key}': S3 Vectors vector store only supports chunks with string content`);
    }

    map<json> metadata = transformMetadata(entry.chunk.metadata);
    foreach string reservedKey in [contentKey, CHUNK_TYPE_METADATA_KEY] {
        if metadata.hasKey(reservedKey) {
            return error ai:Error(
                string `Vector '${key}' has a metadata field named '${reservedKey}', which the store uses ` +
                "for the chunk's own content or type. Rename the field, or set a different " +
                "VectorStoreConfig.contentKey");
        }
    }
    metadata[contentKey] = content;
    metadata[CHUNK_TYPE_METADATA_KEY] = chunkType;

    if metadata.length() > MAX_METADATA_KEYS {
        return error ai:Error(
            string `Vector '${key}' has ${metadata.length()} metadata keys, exceeding the limit of ` +
            string `${MAX_METADATA_KEYS}`);
    }
    int metadataBytes = jsonByteSize(metadata);
    if metadataBytes > MAX_METADATA_BYTES {
        return error ai:Error(
            string `Vector '${key}' has ${metadataBytes} bytes of metadata, exceeding the ` +
            string `${MAX_METADATA_BYTES}-byte total limit`);
    }
    int filterableBytes = jsonByteSize(filterableMetadata(metadata, contentKey));
    if filterableBytes > MAX_FILTERABLE_METADATA_BYTES {
        return error ai:Error(
            string `Vector '${key}' has ${filterableBytes} bytes of filterable metadata (everything ` +
            string `except '${contentKey}'), exceeding the ${MAX_FILTERABLE_METADATA_BYTES}-byte limit. ` +
            "Move more fields into non-filterable metadata, or shorten them");
    }

    return {key, "data": {"float32": embedding}, metadata};
}

// The metadata map with the content key removed — the subset S3 Vectors treats as filterable
// and checks against the 2 KB limit, given this store declares only `contentKey` non-filterable.
isolated function filterableMetadata(map<json> metadata, string contentKey) returns map<json> {
    map<json> result = metadata.clone();
    _ = result.removeIfHasKey(contentKey);
    return result;
}

isolated function jsonByteSize(json value) returns int {
    return value.toJsonString().toBytes().length();
}

// Splits vectors into batches obeying both the 500-vector `PutVectors`/`DeleteVectors` count
// limit and the 20 MiB request payload limit, whichever is hit first. A naive `chunk(500)` is
// not enough: 500 high-dimensional vectors with near-maximal metadata can exceed 20 MiB well
// before reaching the count limit.
isolated function batchBySize(map<json>[] vectors, int maxCount, int maxBytes) returns map<json>[][] {
    map<json>[][] batches = [];
    map<json>[] current = [];
    int currentBytes = 0;
    foreach map<json> vector in vectors {
        int vectorBytes = jsonByteSize(vector);
        if current.length() > 0 && (current.length() >= maxCount || currentBytes + vectorBytes > maxBytes) {
            batches.push(current);
            current = [];
            currentBytes = 0;
        }
        current.push(vector);
        currentBytes += vectorBytes;
    }
    if current.length() > 0 {
        batches.push(current);
    }
    return batches;
}

// Splits a flat list of vector keys into fixed-size batches, for `DeleteVectors` (500/call) and
// `GetVectors` (100/call) — both are pure key lists with no accompanying payload large enough to
// need `batchBySize`'s byte-aware accounting.
isolated function chunkStrings(string[] items, int size) returns string[][] {
    string[][] chunks = [];
    int i = 0;
    while i < items.length() {
        int end = i + size < items.length() ? i + size : items.length();
        chunks.push(items.slice(i, end));
        i = end;
    }
    return chunks;
}

// ---------------------------------------------------------------------------------------------
// Metadata <-> `ai:Metadata`, including the epoch-seconds timestamp encoding
// ---------------------------------------------------------------------------------------------

// Flattens `ai:Metadata` into the wire's `map<json>`, encoding `createdAt`/`modifiedAt` as
// epoch-seconds numbers rather than ISO-8601 strings.
//
// This is a deliberate divergence from `ai.pinecone`, which stores them as ISO-8601 strings.
// S3 Vectors' `$gt`/`$gte`/`$lt`/`$lte` range operators only accept Number values (confirmed
// against AWS's metadata-filtering documentation) — a string-encoded date would make equality
// filters work but silently leave range filters non-functional. `createAiMetadata` below must
// decode with the exact same encoding, or a filter built from a `time:Utc` value would never
// match what was written.
isolated function transformMetadata(ai:Metadata? metadata) returns map<json> {
    map<json> properties = {};
    if metadata is () {
        return properties;
    }
    foreach string item in metadata.keys() {
        anydata value = metadata.get(item);
        if value is time:Utc {
            properties[item] = utcToEpochSeconds(value);
        } else if value is json {
            properties[item] = value;
        }
    }
    return properties;
}

// The inverse of `transformMetadata`. `metadata` must already have the content and chunk-type
// keys removed by the caller (`metadataToChunk` does this) — otherwise they would be duplicated
// into `ai:Metadata`'s open fields alongside `Chunk.content`/`Chunk.'type`.
isolated function createAiMetadata(map<json> metadata) returns ai:Metadata|ai:Error {
    ai:Metadata result = {};
    foreach [string, json] [key, value] in metadata.entries() {
        if key == "createdAt" || key == "modifiedAt" {
            decimal|error epochSeconds = value.cloneWithType(decimal);
            if epochSeconds is error {
                return error ai:Error(
                    string `Vector metadata key '${key}' is not a numeric epoch-seconds value: ` +
                    epochSeconds.message(), epochSeconds);
            }
            result[key] = epochSecondsToUtc(epochSeconds);
        } else if key == "fileSize" {
            decimal|error fileSize = value.cloneWithType(decimal);
            if fileSize is error {
                return error ai:Error(
                    string `Vector metadata key 'fileSize' is not numeric: ${fileSize.message()}`, fileSize);
            }
            result[key] = fileSize;
        } else if STRING_METADATA_KEYS.indexOf(key) is int {
            if value !is string {
                return error ai:Error(
                    string `Vector metadata key '${key}' is not a string: ${value.toJsonString()}`);
            }
            result[key] = value;
        } else if key == "index" || key == "id" || key == "prev" {
            // These three ai:Metadata fields are declared `int`. A plain `result[key] = value`
            // would panic with an uncaught InherentTypeViolation if the round-tripped JSON
            // number decoded as a float (e.g. "5.0") rather than an int — coerce explicitly so
            // a mismatch surfaces as this function's documented ai:Error instead of a panic.
            int|error intValue = value.cloneWithType(int);
            if intValue is error {
                return error ai:Error(
                    string `Vector metadata key '${key}' is not an integer: ${intValue.message()}`, intValue);
            }
            result[key] = intValue;
        } else {
            result[key] = value;
        }
    }
    return result;
}

isolated function utcToEpochSeconds(time:Utc utc) returns decimal {
    return <decimal>utc[0] + utc[1];
}

isolated function epochSecondsToUtc(decimal epochSeconds) returns time:Utc {
    decimal wholeSeconds = 'decimal:floor(epochSeconds);
    decimal fraction = epochSeconds - wholeSeconds;
    return [<int>wholeSeconds, fraction];
}

// Reconstructs a `Chunk` from a vector's wire metadata: `contentKey` becomes `content`, the
// chunk-type key becomes `'type` (defaulting to `"text-chunk"` when absent — vectors written by
// something other than this store's `add` may not carry it), and everything else becomes
// `ai:Metadata`. `metadata` is consumed by value; the caller does not need to strip the content
// or type keys first. A vector with no content is an error, which `query` turns into a skip.
isolated function metadataToChunk(map<json> metadata, string contentKey) returns ai:Chunk|ai:Error {
    map<json> remaining = metadata.clone();
    json contentValue = remaining.removeIfHasKey(contentKey);
    json typeValue = remaining.removeIfHasKey(CHUNK_TYPE_METADATA_KEY) ?: "text-chunk";

    if contentValue is () {
        return error ai:Error(
            string `Vector metadata has no '${contentKey}' key; this vector may have been written ` +
            "by something other than this vector store's 'add'");
    }
    if contentValue !is string {
        return error ai:Error(
            string `Vector metadata key '${contentKey}' is not a string; this vector may have been written ` +
            "by something other than this vector store's 'add'");
    }
    string chunkType = typeValue is string ? typeValue : "text-chunk";

    ai:Metadata chunkMetadata = check createAiMetadata(remaining);
    return {'type: chunkType, content: contentValue, metadata: chunkMetadata};
}

// ---------------------------------------------------------------------------------------------
// Distance -> similarity score
// ---------------------------------------------------------------------------------------------

// Converts an S3 Vectors distance into an `ai:VectorMatch.similarityScore`, where — unlike a raw
// distance — higher must mean more similar.
//
// * cosine: S3 returns cosine *distance*, which equals `1 - cosine similarity`. `1.0 - distance`
//   recovers the true cosine similarity in `[-1, 1]`, matching the convention
//   `ai:InMemoryVectorStore` uses via `vector:cosineSimilarity`.
// * euclidean: `1.0 / (1.0 + distance)` maps `[0, infinity)` to `(0, 1]`, preserving rank order
//   (smaller distance -> larger score). This deliberately does NOT match
//   `ai:InMemoryVectorStore`, which returns the raw Euclidean distance as its "similarity" score
//   for this metric — an inversion that makes its own ordering backwards. Rank-order correctness
//   is treated as more important here than bit-for-bit consistency with that inversion.
//
// `distanceMetric` should be the metric reported by the response (`QueryVectorsResponse.
// distanceMetric`) so a per-call value always wins over whatever was cached at `init`.
isolated function distanceToScore(float? distance, string distanceMetric) returns float {
    float d = distance ?: 0.0;
    if distanceMetric == "euclidean" {
        return 1.0 / (1.0 + d);
    }
    return 1.0 - d;
}

// ---------------------------------------------------------------------------------------------
// Metadata filter translation (`ai:MetadataFilters` -> S3 Vectors' Mongo-like filter JSON)
// ---------------------------------------------------------------------------------------------

// Merges the store-level `VectorStoreConfig.filters` with a per-query filter under `AND`. Either
// side may be absent; `()` is returned only when both are.
isolated function mergeFilters(ai:MetadataFilters? configFilters, ai:MetadataFilters? queryFilters)
        returns ai:MetadataFilters? {
    if configFilters is () {
        return queryFilters;
    }
    if queryFilters is () {
        return configFilters;
    }
    return {condition: ai:AND, filters: [configFilters, queryFilters]};
}

// Translates `ai:MetadataFilters` into the JSON body S3 Vectors' `filter` parameter expects.
// An empty filter list collapses to `{}` (the caller omits the field from the request entirely
// rather than sending it), and a single filter is emitted bare, without a wrapping `$and` —
// both to keep requests minimal and because a bare single-field object is exactly what S3
// Vectors' own filter examples show for one condition.
isolated function translateFilters(ai:MetadataFilters filters, string contentKey) returns map<json>|ai:Error {
    (ai:MetadataFilters|ai:MetadataFilter)[] rawFilters = filters.filters;
    if rawFilters.length() == 0 {
        return {};
    }

    map<json>[] filterList = [];
    foreach ai:MetadataFilters|ai:MetadataFilter filterEntry in rawFilters {
        if filterEntry is ai:MetadataFilter {
            filterList.push(check translateSingleFilter(filterEntry, contentKey));
            continue;
        }
        map<json> nested = check translateFilters(filterEntry, contentKey);
        if nested.length() > 0 {
            filterList.push(nested);
        }
    }

    if filterList.length() == 0 {
        return {};
    }
    if filterList.length() == 1 {
        return filterList[0];
    }
    string s3Condition = filters.condition == ai:OR ? "$or" : "$and";
    return {[s3Condition]: filterList};
}

isolated function translateSingleFilter(ai:MetadataFilter filter, string contentKey) returns map<json>|ai:Error {
    json value = check validateFilter(filter, contentKey);
    if filter.operator == ai:EQUAL {
        // S3 Vectors treats a bare `{key: value}` as an implicit `$eq`. `validateFilter` has already
        // ruled out a map value, which would otherwise be read as an operator object.
        return {[filter.key]: value};
    }
    string s3Operator = check mapOperator(filter.operator);
    return {[filter.key]: {[s3Operator]: value}};
}

// Checks one filter against what S3 Vectors accepts and returns its value in wire form. A
// `time:Utc` becomes epoch seconds, the encoding `add` uses for `createdAt`/`modifiedAt`, so a
// date filter matches what was stored. The filter-only path runs every filter through here (via
// `translateFilters`) before scanning, so both paths accept and reject exactly the same filters.
isolated function validateFilter(ai:MetadataFilter filter, string contentKey) returns json|ai:Error {
    if filter.key == contentKey {
        return error ai:Error(
            string `Cannot filter on '${contentKey}': it is declared non-filterable metadata precisely so ` +
            "that chunk text is exempt from the 2 KB filterable-metadata limit");
    }

    json value = toFilterOperand(filter.value);
    ai:MetadataFilterOperator operator = filter.operator;

    if value is () {
        return error ai:Error(
            string `Metadata filter on '${filter.key}': S3 Vectors does not support filtering for a null ` +
            "value");
    }
    if operator == ai:IN || operator == ai:NOT_IN {
        if value !is json[] || value.length() == 0 {
            return error ai:Error(
                string `Metadata filter on '${filter.key}': '${operator}' requires a non-empty array value`);
        }
        json[] items = from json item in value select toFilterOperand(item);
        foreach json item in items {
            if !isScalar(item) {
                return error ai:Error(
                    string `Metadata filter on '${filter.key}': '${operator}' values must be strings, ` +
                    string `numbers or booleans, got: ${item.toJsonString()}`);
            }
        }
        return items;
    }
    if operator == ai:GREATER_THAN || operator == ai:LESS_THAN ||
            operator == ai:GREATER_THAN_OR_EQUAL || operator == ai:LESS_THAN_OR_EQUAL {
        if toNumber(value) is () {
            return error ai:Error(
                string `Metadata filter on '${filter.key}': '${operator}' requires a numeric or time:Utc ` +
                "value — S3 Vectors range operators do not accept strings. Store timestamps as " +
                "epoch-seconds numbers (as this store's 'add' does for createdAt/modifiedAt) rather than " +
                "date strings if you need range filtering on them");
        }
        return value;
    }
    if !isScalar(value) {
        return error ai:Error(
            string `Metadata filter on '${filter.key}': '${operator}' requires a string, number or boolean ` +
            string `value, got: ${value.toJsonString()}`);
    }
    return value;
}

// Converts a `time:Utc` filter value to epoch seconds; any other value is returned unchanged.
isolated function toFilterOperand(json value) returns json {
    return value is time:Utc ? utcToEpochSeconds(value) : value;
}

isolated function isScalar(json value) returns boolean {
    return value is string|boolean || toNumber(value) is float;
}

// Reads a JSON number as a `float`, or `()` for anything else. Numbers change type on the JSON
// round trip (a Ballerina `0.5` float is read back as `0.5d`, a `2048d` as the int `2048`), and
// Ballerina's `==` is type-sensitive, so numbers are always compared as floats.
isolated function toNumber(json value) returns float? {
    if value is int {
        return <float>value;
    }
    if value is float {
        return value;
    }
    if value is decimal {
        return <float>value;
    }
    return ();
}

isolated function mapOperator(ai:MetadataFilterOperator operator) returns string|ai:Error {
    match operator {
        ai:EQUAL => {
            return "$eq";
        }
        ai:NOT_EQUAL => {
            return "$ne";
        }
        ai:GREATER_THAN => {
            return "$gt";
        }
        ai:LESS_THAN => {
            return "$lt";
        }
        ai:GREATER_THAN_OR_EQUAL => {
            return "$gte";
        }
        ai:LESS_THAN_OR_EQUAL => {
            return "$lte";
        }
        ai:IN => {
            return "$in";
        }
        ai:NOT_IN => {
            return "$nin";
        }
        _ => {
            return error ai:Error(string `Unsupported metadata filter operator: ${operator}`);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Local filter evaluation — needed because `ListVectors` supports no server-side filtering
// (a still-open gap in the S3 Vectors API), so the filter-only `query` path and
// `ai:VectorKnowledgeBase.deleteByFilter` must evaluate `ai:MetadataFilters` in Ballerina against
// each vector's metadata after paging it in with `ListVectors`.
//
// The result must agree with what `QueryVectors` would match for the same filter, or
// `deleteByFilter` deletes the wrong entries. So, as on the server: a missing key never matches,
// numbers compare by value regardless of their Ballerina type, a range filter never matches a
// non-numeric stored value, and a group with no conditions is dropped (as `translateFilters`
// drops it from the request) rather than counted as a match. The filters themselves are validated
// by `translateFilters` before the scan starts. `EQUAL` against an array-valued field matches if
// any element is equal, as AWS documents for `$eq`; AWS documents no array semantics for the
// other operators, so they compare the whole value.
// ---------------------------------------------------------------------------------------------

isolated function matchesFilters(map<json> metadata, ai:MetadataFilters filters) returns boolean|ai:Error {
    boolean? result = check evaluateFilterGroup(metadata, filters);
    // No conditions at all: nothing is sent to the server, so everything matches.
    return result ?: true;
}

// Returns `()` for a group with no conditions left once its own empty sub-groups are dropped.
isolated function evaluateFilterGroup(map<json> metadata, ai:MetadataFilters group) returns boolean?|ai:Error {
    boolean[] results = [];
    foreach ai:MetadataFilters|ai:MetadataFilter node in group.filters {
        if node is ai:MetadataFilter {
            results.push(check evaluateFilter(metadata, node));
            continue;
        }
        boolean? nested = check evaluateFilterGroup(metadata, node);
        if nested is boolean {
            results.push(nested);
        }
    }
    if results.length() == 0 {
        return ();
    }
    return evaluateCondition(group.condition, results);
}

isolated function evaluateFilter(map<json> metadata, ai:MetadataFilter filter) returns boolean|ai:Error {
    if !metadata.hasKey(filter.key) {
        return false;
    }
    return compareMetadataValues(metadata.get(filter.key), filter.operator, toFilterOperand(filter.value));
}

isolated function evaluateCondition(ai:MetadataFilterCondition condition, boolean[] results) returns boolean {
    if condition == ai:AND {
        return !results.some(result => result == false);
    }
    return results.some(result => result == true);
}

isolated function compareMetadataValues(json left, ai:MetadataFilterOperator operator, json right)
        returns boolean|ai:Error {
    match operator {
        ai:EQUAL => {
            // As on the server, `$eq` against an array-valued field matches if any element is equal.
            if left is json[] {
                foreach json element in left {
                    if valuesEqual(element, right) {
                        return true;
                    }
                }
                return false;
            }
            return valuesEqual(left, right);
        }
        ai:NOT_EQUAL => {
            return !valuesEqual(left, right);
        }
        ai:IN => {
            return check containsValue(operator, right, left);
        }
        ai:NOT_IN => {
            return !check containsValue(operator, right, left);
        }
        ai:GREATER_THAN|ai:LESS_THAN|ai:GREATER_THAN_OR_EQUAL|ai:LESS_THAN_OR_EQUAL => {
            float? rightNumber = toNumber(right);
            if rightNumber is () {
                return error ai:Error(
                    string `Cannot evaluate a numeric metadata filter: '${right.toJsonString()}' is not numeric`);
            }
            float? leftNumber = toNumber(left);
            if leftNumber is () {
                // The server never matches a range filter against a non-numeric stored value.
                return false;
            }
            match operator {
                ai:GREATER_THAN => {
                    return leftNumber > rightNumber;
                }
                ai:LESS_THAN => {
                    return leftNumber < rightNumber;
                }
                ai:GREATER_THAN_OR_EQUAL => {
                    return leftNumber >= rightNumber;
                }
                _ => {
                    return leftNumber <= rightNumber;
                }
            }
        }
        _ => {
            return error ai:Error(string `Unsupported metadata filter operator: ${operator}`);
        }
    }
}

isolated function valuesEqual(json left, json right) returns boolean {
    float? leftNumber = toNumber(left);
    float? rightNumber = toNumber(right);
    if leftNumber is float && rightNumber is float {
        return leftNumber == rightNumber;
    }
    return left == right;
}

// Whether `candidates` (an `IN`/`NOT_IN` filter value) holds `value`. A malformed list is an
// error, matching `validateFilter`, rather than a silent non-match.
isolated function containsValue(ai:MetadataFilterOperator operator, json candidates, json value)
        returns boolean|ai:Error {
    if candidates !is json[] || candidates.length() == 0 {
        return error ai:Error(
            string `Metadata filter operator '${operator}' requires a non-empty array value, got: ` +
            candidates.toJsonString());
    }
    foreach json candidate in candidates {
        if valuesEqual(value, toFilterOperand(candidate)) {
            return true;
        }
    }
    return false;
}
