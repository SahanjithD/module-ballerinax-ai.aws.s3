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
const int MAX_METADATA_KEY_NAME_LENGTH = 63;
const int MAX_METADATA_BYTES = 40 * 1024;
const int MAX_FILTERABLE_METADATA_BYTES = 2 * 1024;
const int MAX_PUT_BATCH_COUNT = 500;
const int MAX_DELETE_BATCH_COUNT = 500;
const int MAX_GET_BATCH_COUNT = 100;
const int MAX_REQUEST_BYTES = 20 * 1024 * 1024;
const int MAX_TOP_K = 10000;
// The smallest `topK` `queryByEmbedding` will ask S3 Vectors for, regardless of how few results
// the caller wants. QueryVectors is an approximate search, and a small `topK` narrows how much of
// the index it explores: measured against an index holding a single vector, queried with that
// vector's own embedding, `topK: 1` came back empty on 6 of 10 attempts while `topK: 10` returned
// it on 10 of 10 in the same period. Over-asking and truncating locally costs one response worth
// of extra metadata and removes the misses.
const int MIN_QUERY_TOP_K = 10;
const int MAX_LIST_PAGE_SIZE = 1000;

// The metadata key `add` writes the chunk's type under. Not user-configurable (only the content
// key is): it exists purely so `query` can reconstruct a `Chunk` with something other than the
// hardcoded default, and its value is a plain string with no size concerns of its own.
const string CHUNK_TYPE_METADATA_KEY = "type";

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
    metadata[contentKey] = content;
    metadata[CHUNK_TYPE_METADATA_KEY] = entry.chunk.'type;

    if metadata.length() > MAX_METADATA_KEYS {
        return error ai:Error(
            string `Vector '${key}' has ${metadata.length()} metadata keys, exceeding the limit of ` +
            string `${MAX_METADATA_KEYS}`);
    }
    foreach string metadataKey in metadata.keys() {
        if metadataKey.length() > MAX_METADATA_KEY_NAME_LENGTH {
            return error ai:Error(
                string `Vector '${key}' has a metadata key '${metadataKey}' longer than ` +
                string `${MAX_METADATA_KEY_NAME_LENGTH} characters`);
        }
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
// or type keys first.
isolated function metadataToChunk(map<json> metadata, string contentKey) returns ai:Chunk|ai:Error {
    map<json> remaining = metadata.clone();
    json contentValue = remaining.removeIfHasKey(contentKey) ?: "";
    json typeValue = remaining.removeIfHasKey(CHUNK_TYPE_METADATA_KEY) ?: "text-chunk";

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

// Merges the store-level `Configuration.filters` with a per-query filter under `AND`. Either
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
    if filter.key == contentKey {
        return error ai:Error(
            string `Cannot filter on '${contentKey}': it is declared non-filterable metadata precisely so ` +
            "that chunk text is exempt from the 2 KB filterable-metadata limit");
    }

    json value = filter.value;
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
    }
    if operator == ai:GREATER_THAN || operator == ai:LESS_THAN ||
            operator == ai:GREATER_THAN_OR_EQUAL || operator == ai:LESS_THAN_OR_EQUAL {
        if value !is int && value !is float && value !is decimal {
            return error ai:Error(
                string `Metadata filter on '${filter.key}': '${operator}' requires a numeric value — S3 ` +
                "Vectors range operators do not accept strings. Store timestamps as epoch-seconds numbers " +
                "(as this store's 'add' does for createdAt/modifiedAt) rather than date strings if you need " +
                "range filtering on them");
        }
    }

    if operator == ai:EQUAL {
        // S3 Vectors treats a bare `{key: value}` as an implicit `$eq`.
        return {[filter.key]: value};
    }
    string s3Operator = check mapOperator(operator);
    return {[filter.key]: {[s3Operator]: value}};
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
// Mirrors `ballerina/ai`'s own `entryMatchesFilters`/`evaluateFilterNode`/`compareValues`
// (`_ref/ai/ballerina/utils.bal`) as closely as the different metadata representation allows —
// missing key is a non-match, `AND` requires no false result, `OR` requires at least one true
// result, and range operators coerce both sides through `decimal`. One deliberate departure:
// `ballerina/ai`'s own `compareValues` silently returns `false` for `IN`/`NOT_IN` when the
// right-hand side isn't an array; this module errors instead, to agree with
// `translateSingleFilter` below, which already rejects the same malformed input on the
// QueryVectors path — otherwise a caller's mistake would make a filter-only query or
// `deleteByFilter` quietly match nothing instead of failing loudly. Semantics must otherwise
// agree with `translateSingleFilter`, or a filter-only `query` would return a different set of
// vectors than the equivalent server-side-filtered `QueryVectors` call would for the same
// filter, and `deleteByFilter` would delete the wrong entries.
// ---------------------------------------------------------------------------------------------

isolated function matchesFilters(map<json> metadata, ai:MetadataFilters filters) returns boolean|ai:Error {
    boolean[] results = from ai:MetadataFilters|ai:MetadataFilter node in filters.filters
        select check evaluateFilterNode(metadata, node);
    return evaluateCondition(filters.condition, results);
}

isolated function evaluateFilterNode(map<json> metadata, ai:MetadataFilters|ai:MetadataFilter node)
        returns boolean|ai:Error {
    if node is ai:MetadataFilter {
        if !metadata.hasKey(node.key) {
            return false;
        }
        return compareMetadataValues(metadata.get(node.key), node.operator, node.value);
    }
    boolean[] results = from ai:MetadataFilters|ai:MetadataFilter child in node.filters
        select check evaluateFilterNode(metadata, child);
    return evaluateCondition(node.condition, results);
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
            // One known, documented divergence from server-side QueryVectors filtering: S3
            // Vectors' `$eq` matches an array-valued metadata field if ANY element equals the
            // right-hand side, but this local evaluator (like `ai`'s own `compareValues`) only
            // ever sees `left` as the whole stored value and does plain `==`. A filter-only
            // query or `deleteByFilter` against array-valued custom metadata can therefore
            // disagree with what an equivalent embedding query would match. See the README's
            // Limitations section.
            return left == right;
        }
        ai:NOT_EQUAL => {
            return left != right;
        }
        ai:IN => {
            // Mismatched with what translateSingleFilter accepts (a non-empty array) is an error
            // here too, not a silent non-match — otherwise a caller's malformed filter value
            // would make a filter-only query or deleteByFilter quietly match nothing, while the
            // equivalent QueryVectors path rejects the same input loudly.
            if right !is json[] || right.length() == 0 {
                return error ai:Error(
                    string `Metadata filter operator '${operator}' requires a non-empty array value, got: ` +
                    right.toJsonString());
            }
            foreach json value in right {
                if left == value {
                    return true;
                }
            }
            return false;
        }
        ai:NOT_IN => {
            if right !is json[] || right.length() == 0 {
                return error ai:Error(
                    string `Metadata filter operator '${operator}' requires a non-empty array value, got: ` +
                    right.toJsonString());
            }
            foreach json value in right {
                if left == value {
                    return false;
                }
            }
            return true;
        }
        ai:GREATER_THAN => {
            return check toComparableDecimal(left) > check toComparableDecimal(right);
        }
        ai:LESS_THAN => {
            return check toComparableDecimal(left) < check toComparableDecimal(right);
        }
        ai:GREATER_THAN_OR_EQUAL => {
            return check toComparableDecimal(left) >= check toComparableDecimal(right);
        }
        ai:LESS_THAN_OR_EQUAL => {
            return check toComparableDecimal(left) <= check toComparableDecimal(right);
        }
        _ => {
            return error ai:Error(string `Unsupported metadata filter operator: ${operator}`);
        }
    }
}

isolated function toComparableDecimal(json value) returns decimal|ai:Error {
    decimal|error result = value.cloneWithType(decimal);
    if result is error {
        return error ai:Error(
            string `Cannot evaluate a numeric metadata filter: '${value.toJsonString()}' is not numeric`, result);
    }
    return result;
}
