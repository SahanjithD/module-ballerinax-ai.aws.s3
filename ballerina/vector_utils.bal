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

// Limits from AWS's published S3 Vectors limitations.
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
// Room under `MAX_REQUEST_BYTES` for the request envelope (index identifier, brackets, commas).
const int REQUEST_ENVELOPE_HEADROOM_BYTES = 64 * 1024;
const int MAX_PUT_PAYLOAD_BYTES = MAX_REQUEST_BYTES - REQUEST_ENVELOPE_HEADROOM_BYTES;
const int MAX_TOP_K = 10000;
// Small `topK` values reduce recall in QueryVectors' approximate search, so at least this many
// results are requested and the surplus is dropped.
const int MIN_QUERY_TOP_K = 10;
const int MAX_LIST_PAGE_SIZE = 1000;

// Underscore-prefixed to stay clear of callers' own metadata; `add` rejects a clash anyway.
const string CHUNK_TYPE_METADATA_KEY = "_chunkType";

// Media chunks may carry a URL string, which would otherwise pass the string-content check.
final readonly & string[] MEDIA_CHUNK_TYPES = ["image", "audio", "file", "binary"];

// The `ai:Metadata` fields typed `string`; assigning anything else to them panics.
final readonly & string[] STRING_METADATA_KEYS = ["mimeType", "fileName", "header", "language",
    "header1", "header2", "header3", "header4", "header5", "header6"];


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

// Includes the store-level filters, so a bad one fails at `init`.
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


// Converts an entry to a `PutInputVector`, checking up front what S3 Vectors would reject with
// an opaque error. Sets `entry.id` to a UUID when empty, as other `ai:VectorStore`s do.
isolated function mapEntryToWireVector(ai:VectorEntry entry, string contentKey, int? expectedDimension,
        string? distanceMetric) returns map<json>|ai:Error {
    ai:Embedding embedding = entry.embedding;
    if embedding !is ai:Vector {
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

// Everything but the content key counts toward the 2 KB filterable limit.
isolated function filterableMetadata(map<json> metadata, string contentKey) returns map<json> {
    map<json> result = metadata.clone();
    _ = result.removeIfHasKey(contentKey);
    return result;
}

isolated function jsonByteSize(json value) returns int {
    return value.toJsonString().toBytes().length();
}

// Batches by both count and size, since 500 large vectors can exceed 20 MiB.
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


// Timestamps are stored as epoch seconds, unlike `ai.pinecone`'s ISO strings, because S3
// Vectors' range operators only accept numbers.
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

// The caller removes the content and chunk-type keys first (`metadataToChunk` does).
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
            // Declared `int` in `ai:Metadata`; a JSON round trip can turn 5 into 5.0.
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

// A vector with no content is an error, which `query` turns into a skip.
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


// Higher must mean more similar. Cosine: `1 - distance`, the cosine similarity. Euclidean:
// `1 / (1 + distance)`, which keeps rank order (unlike `ai:InMemoryVectorStore`, which returns
// the raw distance).
isolated function distanceToScore(float? distance, string distanceMetric) returns float {
    float d = distance ?: 0.0;
    if distanceMetric == "euclidean" {
        return 1.0 / (1.0 + d);
    }
    return 1.0 - d;
}


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

// An empty filter becomes `{}` (omitted from the request), and a single filter isn't wrapped in
// `$and`.
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
        // A bare `{key: value}` is an implicit `$eq`; map values are rejected by `validateFilter`.
        return {[filter.key]: value};
    }
    string s3Operator = check mapOperator(filter.operator);
    return {[filter.key]: {[s3Operator]: value}};
}

// Validates a filter and returns its value in wire form (`time:Utc` becomes epoch seconds, as
// stored). Both query paths go through here, so they accept the same filters.
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

isolated function toFilterOperand(json value) returns json {
    return value is time:Utc ? utcToEpochSeconds(value) : value;
}

isolated function isScalar(json value) returns boolean {
    return value is string|boolean || toNumber(value) is float;
}

// Numbers change type on the JSON round trip (0.5 comes back as 0.5d) and `==` is
// type-sensitive, so numbers are compared as floats.
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

// Local filter evaluation for queries without an embedding (including `deleteByFilter`), since
// `ListVectors` can't filter. It must match what `QueryVectors` would, so: a missing key never
// matches, numbers compare by value, a range filter never matches a non-numeric value, empty groups
// are dropped, and `EQUAL` matches any element of an array value, as AWS documents for `$eq`.

isolated function matchesFilters(map<json> metadata, ai:MetadataFilters filters) returns boolean|ai:Error {
    boolean? result = check evaluateFilterGroup(metadata, filters);
    return result ?: true;
}

// `()` for a group left with no conditions.
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

// A malformed list is an error, as in `validateFilter`.
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
