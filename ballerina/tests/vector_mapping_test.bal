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
import ballerina/http;
import ballerina/lang.'float as floats;
import ballerina/test;
import ballerina/time;
import ballerinax/aws;
import ballerinax/aws.auth;

// Tests for `vector_utils.bal` and endpoint resolution; filters are in `vector_filter_test.bal`.

// Endpoint resolution ignores credentials entirely, but `auth` is a required field on
// `VectorStoreConnectionConfig`, so these tests supply a placeholder that is never used to sign.
final readonly & auth:StaticAuthConfig TEST_AUTH = {accessKeyId: "AKIAEXAMPLE", secretAccessKey: "secret"};

// ---------------------------------------------------------------------------
// Endpoint resolution: `s3vectors` isn't in the SDK's endpoint metadata, so an unqualified lookup
// would resolve to a host that doesn't exist.
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testAwsResolveEndpointHostUsesApiAwsSuffix() {
    string host = aws:resolveEndpointHost("s3vectors", aws:US_EAST_1, {dualstack: true});
    test:assertEquals(host, "s3vectors.us-east-1.api.aws",
            "S3 Vectors endpoint host must use the .api.aws (dualstack) suffix, not .amazonaws.com");
}

@test:Config {}
isolated function testResolveServiceEndpointRejectsFips() {
    [string, string]|ai:Error result = resolveServiceEndpoint({auth: TEST_AUTH, region: aws:US_EAST_1, endpoint: {fips: true}});
    test:assertTrue(result is ai:Error,
            "AWS deploys no FIPS endpoint for S3 Vectors, so 'fips' must be rejected rather than " +
            "resolved to a host that does not exist");
    if result is ai:Error {
        test:assertTrue(result.message().includes("no FIPS endpoint"),
                "The error must say why FIPS is unavailable, not just that the value is invalid");
    }
}

@test:Config {}
isolated function testResolveServiceEndpointRejectsFipsEvenWithServiceUrl() {
    [string, string]|ai:Error result =
        resolveServiceEndpoint({auth: TEST_AUTH, region: aws:US_EAST_1,
                endpoint: {fips: true, customEndpoint: "https://proxy.example"}});
    test:assertTrue(result is ai:Error,
            "'fips' must not be silently ignored alongside a customEndpoint — that would leave the " +
            "caller believing they are on a validated path");
}

@test:Config {}
isolated function testResolveServiceEndpointDerivesHostAndUrl() {
    [string, string]|ai:Error result = resolveServiceEndpoint({auth: TEST_AUTH, region: aws:US_WEST_2});
    test:assertFalse(result is ai:Error, "Endpoint resolution must succeed for a plain region config");
    if result is [string, string] {
        var [url, host] = result;
        test:assertEquals(host, "s3vectors.us-west-2.api.aws", "Unexpected resolved host");
        test:assertEquals(url, "https://s3vectors.us-west-2.api.aws", "Unexpected resolved URL");
    }
}

@test:Config {}
isolated function testResolveServiceEndpointHonoursServiceUrlOverride() {
    [string, string]|ai:Error result =
        resolveServiceEndpoint({auth: TEST_AUTH, region: aws:US_EAST_1, endpoint: {customEndpoint: "http://localhost:9090"}});
    test:assertFalse(result is ai:Error, "An explicit customEndpoint override must resolve without error");
    if result is [string, string] {
        var [url, host] = result;
        test:assertEquals(url, "http://localhost:9090", "The override URL must be passed through as-is");
        test:assertEquals(host, "localhost:9090",
                "The bare host must retain the port but drop the scheme, for the SigV4 host header");
    }
}

// ---------------------------------------------------------------------------
// SigV4 header shape. The mock service doesn't verify signatures, so this checks `invoke`'s call
// to `auth:getSignedHeaders` against a fixed request.
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testSignedHeadersIncludeTheExpectedSigV4Set() {
    auth:Credentials credentials = {accessKeyId: "AKIAEXAMPLE", secretAccessKey: "secret"};
    map<string>|auth:SigningError signed = auth:getSignedHeaders({
        method: "POST",
        host: "s3vectors.us-east-1.api.aws",
        path: "/QueryVectors",
        headers: {"content-type": "application/json"},
        payload: "{}".toBytes()
    }, credentials, aws:US_EAST_1, "s3vectors");

    test:assertFalse(signed is auth:SigningError, "Signing a well-formed request must not fail");
    if signed is map<string> {
        test:assertTrue(signed.hasKey("authorization"), "The signed header set must include 'authorization'");
        test:assertTrue(signed.hasKey("x-amz-date"), "The signed header set must include 'x-amz-date'");
        test:assertTrue(signed.get("authorization").includes("s3vectors"),
                "The authorization header's credential scope must name the 's3vectors' signing service");
    }
}

@test:Config {}
isolated function testSignedHeadersIncludeSessionTokenForTemporaryCredentials() {
    auth:Credentials credentials = {
        accessKeyId: "ASIAEXAMPLE",
        secretAccessKey: "secret",
        sessionToken: "token-value"
    };
    map<string>|auth:SigningError signed = auth:getSignedHeaders({
        method: "POST",
        host: "s3vectors.us-east-1.api.aws",
        path: "/QueryVectors",
        headers: {"content-type": "application/json"},
        payload: "{}".toBytes()
    }, credentials, aws:US_EAST_1, "s3vectors");

    test:assertFalse(signed is auth:SigningError, "Signing with temporary credentials must not fail");
    if signed is map<string> {
        test:assertTrue(signed.hasKey("x-amz-security-token"),
                "Temporary credentials must add an 'x-amz-security-token' header");
        test:assertEquals(signed.get("x-amz-security-token"), "token-value");
    }
}

// ---------------------------------------------------------------------------
// Distance -> similarity score
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testDistanceToScoreCosineRecoversSimilarity() {
    test:assertEquals(distanceToScore(0.0, "cosine"), 1.0, "Zero cosine distance must be maximal similarity");
    test:assertEquals(distanceToScore(1.0, "cosine"), 0.0, "A cosine distance of 1 must be zero similarity");
    test:assertEquals(distanceToScore(2.0, "cosine"), -1.0,
            "The maximum cosine distance (2) must recover -1 similarity");
}

@test:Config {}
isolated function testDistanceToScoreEuclideanIsRankPreserving() {
    test:assertEquals(distanceToScore(0.0, "euclidean"), 1.0, "Zero Euclidean distance must score 1.0");
    float nearScore = distanceToScore(1.0, "euclidean");
    float farScore = distanceToScore(9.0, "euclidean");
    test:assertTrue(nearScore > farScore,
            "A smaller Euclidean distance must produce a larger score (rank-preserving inversion)");
    test:assertTrue(farScore > 0.0, "Euclidean score must stay strictly positive for a finite distance");
}

@test:Config {}
isolated function testDistanceToScoreDefaultsToCosineForUnknownMetric() {
    test:assertEquals(distanceToScore(0.5, "some-future-metric"), 0.5,
            "An unrecognized distanceMetric must fall back to the cosine conversion");
}

@test:Config {}
isolated function testDistanceToScoreDefaultsDistanceWhenAbsent() {
    test:assertEquals(distanceToScore((), "cosine"), 1.0,
            "A missing distance (returnDistance not requested) must not crash the conversion");
}

// ---------------------------------------------------------------------------
// Metadata <-> ai:Metadata, including the epoch-seconds timestamp encoding
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testTransformMetadataEncodesTimestampAsEpochSeconds() {
    time:Utc createdAt = [1755561600, 0.25d];
    map<json> wire = transformMetadata({createdAt, header: "Introduction"});
    test:assertEquals(wire["createdAt"], 1755561600.25d,
            "createdAt must be encoded as a single epoch-seconds decimal, not an ISO-8601 string");
    test:assertEquals(wire["header"], "Introduction");
}

@test:Config {}
isolated function testCreateAiMetadataDecodesEpochSecondsBackToUtc() returns ai:Error? {
    ai:Metadata metadata = check createAiMetadata({createdAt: 1755561600.25d, header: "Introduction"});
    time:Utc? createdAt = metadata?.createdAt;
    test:assertTrue(createdAt is time:Utc, "createdAt must decode back to a time:Utc value");
    if createdAt is time:Utc {
        test:assertEquals(createdAt[0], 1755561600, "Whole-seconds component mismatch");
        test:assertEquals(createdAt[1], 0.25d, "Fractional-seconds component mismatch");
    }
    test:assertEquals(metadata["header"], "Introduction");
}

@test:Config {}
isolated function testTimestampEncodingRoundTripsThroughBothDirections() returns ai:Error? {
    // The write path (transformMetadata) and the read path (createAiMetadata) must agree, or a
    // filter built from a `time:Utc` value would never match what was actually written.
    time:Utc original = time:utcNow();
    map<json> wire = transformMetadata({modifiedAt: original});
    ai:Metadata roundTripped = check createAiMetadata(wire);
    time:Utc? decoded = roundTripped?.modifiedAt;
    test:assertTrue(decoded is time:Utc, "modifiedAt must round-trip as a time:Utc value");
    if decoded is time:Utc {
        test:assertEquals(decoded[0], original[0], "Whole-seconds must round-trip exactly");
    }
}

@test:Config {}
isolated function testCreateAiMetadataCoercesFileSizeToDecimal() returns ai:Error? {
    ai:Metadata metadata = check createAiMetadata({fileSize: 2048});
    decimal? fileSize = metadata?.fileSize;
    test:assertEquals(fileSize, 2048d, "fileSize must be coerced to decimal per ai:Metadata's field type");
}

@test:Config {}
isolated function testCreateAiMetadataCoercesIntTypedFields() returns ai:Error? {
    // Declared `int` on ai:Metadata; a float from the JSON round trip must not panic.
    ai:Metadata metadata = check createAiMetadata({index: 5, id: 7, prev: 3});
    test:assertEquals(metadata["index"], 5);
    test:assertEquals(metadata["id"], 7);
    test:assertEquals(metadata["prev"], 3);
}

@test:Config {}
isolated function testCreateAiMetadataRejectsNonIntegerForIntField() {
    ai:Metadata|ai:Error result = createAiMetadata({index: "not-a-number"});
    test:assertTrue(result is ai:Error,
            "A non-numeric value for an int-typed ai:Metadata field must be a clean ai:Error, not a panic");
}

@test:Config {}
isolated function testCreateAiMetadataPassesThroughOpenJsonFields() returns ai:Error? {
    ai:Metadata metadata = check createAiMetadata({customTag: "abc", score: 3});
    test:assertEquals(metadata["customTag"], "abc", "Fields outside the declared schema must pass through as-is");
    test:assertEquals(metadata["score"], 3);
}

@test:Config {}
isolated function testCreateAiMetadataRejectsNonNumericTimestamp() {
    ai:Metadata|ai:Error result = createAiMetadata({createdAt: "2026-08-19T00:00:00Z"});
    test:assertTrue(result is ai:Error,
            "A string createdAt must be rejected: it means the vector was written by something other " +
            "than this store's epoch-seconds encoding");
}

@test:Config {}
isolated function testMetadataToChunkStripsContentAndTypeKeys() returns ai:Error? {
    ai:Chunk chunk = check metadataToChunk({content: "hello world", [CHUNK_TYPE_METADATA_KEY]: "text-chunk",
        header: "H1"}, "content");
    test:assertEquals(chunk.content, "hello world");
    test:assertEquals(chunk.'type, "text-chunk");
    ai:Metadata? metadata = chunk.metadata;
    test:assertTrue(metadata is ai:Metadata, "Chunk metadata must be present");
    if metadata is ai:Metadata {
        test:assertEquals(metadata.hasKey("content"), false,
                "The content key must not be duplicated into ai:Metadata's open fields");
        test:assertEquals(metadata.hasKey(CHUNK_TYPE_METADATA_KEY), false,
                "The chunk-type key must not be duplicated into ai:Metadata's open fields");
        test:assertEquals(metadata["header"], "H1");
    }
}

@test:Config {}
isolated function testMetadataToChunkDefaultsTypeWhenAbsent() returns ai:Error? {
    ai:Chunk chunk = check metadataToChunk({content: "hello"}, "content");
    test:assertEquals(chunk.'type, "text-chunk", "A vector written without a type key must default to text-chunk");
}

@test:Config {}
isolated function testMetadataToChunkRejectsMissingContent() {
    // `query` turns this error into a logged skip, so one foreign vector cannot fail the query.
    ai:Chunk|ai:Error result = metadataToChunk({header: "H1"}, "content");
    test:assertTrue(result is ai:Error, "A vector with no content key must not become an empty chunk");
}

@test:Config {}
isolated function testMetadataToChunkHonoursACustomContentKey() returns ai:Error? {
    ai:Chunk chunk = check metadataToChunk({body: "custom key content"}, "body");
    test:assertEquals(chunk.content, "custom key content");
}

// ---------------------------------------------------------------------------
// Entry -> wire vector mapping and validation
// ---------------------------------------------------------------------------

isolated function textEntry(ai:Vector embedding, string content = "hello world", string? id = ()) returns ai:VectorEntry => {
    id,
    embedding,
    chunk: {'type: "text-chunk", content}
};

@test:Config {}
isolated function testMapEntryToWireVectorAssignsUuidWhenIdAbsent() returns ai:Error? {
    ai:VectorEntry entry = textEntry([0.1, 0.2, 0.3]);
    map<json> wire = check mapEntryToWireVector(entry, "content", 3, "cosine");
    test:assertTrue(entry.id is string, "add must assign a generated id back onto the caller's entry");
    test:assertEquals(wire["key"], entry.id, "The wire vector's key must match the assigned id");
}

@test:Config {}
isolated function testMapEntryToWireVectorPreservesSuppliedId() returns ai:Error? {
    ai:VectorEntry entry = textEntry([0.1, 0.2, 0.3], id = "my-id");
    map<json> wire = check mapEntryToWireVector(entry, "content", 3, "cosine");
    test:assertEquals(wire["key"], "my-id");
}

@test:Config {}
isolated function testMapEntryToWireVectorEncodesFloat32Data() returns ai:Error? {
    ai:VectorEntry entry = textEntry([0.1, 0.2, 0.3], id = "my-id");
    map<json> wire = check mapEntryToWireVector(entry, "content", 3, "cosine");
    json data = wire["data"];
    test:assertTrue(data is map<json>);
    if data is map<json> {
        test:assertEquals(data["float32"], [0.1, 0.2, 0.3]);
    }
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsSparseVector() {
    ai:VectorEntry entry = {
        id: "sparse-1",
        embedding: {indices: [0, 2], values: [1.0, 2.0]},
        chunk: {'type: "text-chunk", content: "hello"}
    };
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", (), "cosine");
    test:assertTrue(result is ai:Error, "S3 Vectors has no sparse index type; a sparse embedding must be rejected");
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsNonStringContent() {
    ai:VectorEntry entry = {
        id: "img-1",
        embedding: [0.1, 0.2],
        chunk: {'type: "image", content: [1, 2, 3]}
    };
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", (), "cosine");
    test:assertTrue(result is ai:Error, "Non-string chunk content (e.g. an image chunk) must be rejected");
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsDimensionMismatch() {
    ai:VectorEntry entry = textEntry([0.1, 0.2, 0.3], id = "dim-1");
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", 4, "cosine");
    test:assertTrue(result is ai:Error, "A vector whose length disagrees with the index dimension must be rejected");
    if result is ai:Error {
        test:assertTrue(result.message().includes("dim-1"), "The error must name the offending vector's key");
    }
}

@test:Config {}
isolated function testMapEntryToWireVectorSkipsDimensionCheckWhenUnknown() returns ai:Error? {
    // validateIndexOnInit = false leaves the dimension unknown; the check must be skipped
    // rather than guessed at.
    ai:VectorEntry entry = textEntry([0.1, 0.2, 0.3], id = "dim-2");
    map<json> _ = check mapEntryToWireVector(entry, "content", (), "cosine");
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsNaN() {
    ai:VectorEntry entry = textEntry([0.1, floats:NaN, 0.3], id = "nan-1");
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", 3, "cosine");
    test:assertTrue(result is ai:Error, "A NaN component must be rejected before the request is even sent");
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsInfinity() {
    ai:VectorEntry entry = textEntry([0.1, floats:Infinity, 0.3], id = "inf-1");
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", 3, "cosine");
    test:assertTrue(result is ai:Error, "An Infinity component must be rejected before the request is sent");
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsAllZeroUnderCosine() {
    ai:VectorEntry entry = textEntry([0.0, 0.0, 0.0], id = "zero-1");
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", 3, "cosine");
    test:assertTrue(result is ai:Error, "An all-zero vector is invalid under the cosine metric");
}

@test:Config {}
isolated function testMapEntryToWireVectorAllowsAllZeroUnderEuclidean() returns ai:Error? {
    ai:VectorEntry entry = textEntry([0.0, 0.0, 0.0], id = "zero-2");
    map<json> _ = check mapEntryToWireVector(entry, "content", 3, "euclidean");
}

@test:Config {}
isolated function testMapEntryToWireVectorAllowsAllZeroWhenDistanceMetricIsUnknown() returns ai:Error? {
    // With the metric unknown, a legitimate all-zero embedding must not be rejected as cosine.
    ai:VectorEntry entry = textEntry([0.0, 0.0, 0.0], id = "zero-3");
    map<json> _ = check mapEntryToWireVector(entry, "content", 3, ());
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsTooManyMetadataKeys() {
    ai:Metadata hugeMetadata = {};
    foreach int i in 0 ..< 60 {
        hugeMetadata["key" + i.toString()] = i;
    }
    ai:VectorEntry entry = {
        id: "many-keys",
        embedding: [0.1, 0.2],
        chunk: {'type: "text-chunk", content: "hello", metadata: hugeMetadata}
    };
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", (), "cosine");
    test:assertTrue(result is ai:Error, "More than 50 metadata keys must be rejected client-side");
}

isolated function repeatChar(string ch, int count) returns string {
    string result = "";
    foreach int i in 0 ..< count {
        result += ch;
    }
    return result;
}

@test:Config {}
isolated function testMapEntryToWireVectorAcceptsLongFilterableMetadataKeyName() {
    // The 63-character limit applies to non-filterable key names (so to `contentKey`), not to
    // ordinary filterable metadata keys.
    string longKey = repeatChar("k", 70);
    ai:VectorEntry entry = {
        id: "long-key",
        embedding: [0.1, 0.2],
        chunk: {'type: "text-chunk", content: "hello", metadata: {[longKey]: "value"}}
    };
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", (), "cosine");
    test:assertFalse(result is ai:Error, "A long filterable metadata key name must not be rejected client-side");
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsReservedMetadataKeys() {
    foreach string reservedKey in ["content", CHUNK_TYPE_METADATA_KEY] {
        ai:VectorEntry entry = {
            id: "reserved",
            embedding: [0.1, 0.2],
            chunk: {'type: "text-chunk", content: "hello", metadata: {[reservedKey]: "user value"}}
        };
        map<json>|ai:Error result = mapEntryToWireVector(entry, "content", (), "cosine");
        test:assertTrue(result is ai:Error,
                string `User metadata named '${reservedKey}' must be rejected, not overwritten`);
    }
}

@test:Config {}
isolated function testUserTypeMetadataSurvivesRoundTrip() returns ai:Error? {
    ai:VectorEntry entry = {
        id: "typed",
        embedding: [0.1, 0.2],
        chunk: {'type: "text-chunk", content: "summary", metadata: {"type": "invoice"}}
    };
    map<json> wireVector = check mapEntryToWireVector(entry, "content", (), "cosine");
    map<json> metadata = <map<json>>wireVector["metadata"];
    ai:Chunk chunk = check metadataToChunk(metadata, "content");
    test:assertEquals(chunk.content, "summary");
    test:assertEquals(chunk.'type, "text-chunk");
    test:assertEquals((chunk.metadata ?: {})["type"], "invoice",
            "A user metadata field named 'type' must round-trip unchanged");
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsMediaChunkWithUrlContent() {
    ai:VectorEntry entry = {
        id: "image-url",
        embedding: [0.1, 0.2],
        chunk: {'type: "image", content: "https://example.com/cat.png"}
    };
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", (), "cosine");
    test:assertTrue(result is ai:Error, "A media chunk must be rejected even when its content is a URL string");
}

@test:Config {}
isolated function testMetadataToChunkRejectsNonStringTypedField() {
    ai:Chunk|ai:Error result = metadataToChunk({content: "hello", mimeType: 42}, "content");
    test:assertTrue(result is ai:Error,
            "A non-string value under a string-typed ai:Metadata field must be an error, not a panic");
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsOversizedFilterableMetadata() {
    string bigValue = repeatChar("x", 3000);
    ai:VectorEntry entry = {
        id: "big-filterable",
        embedding: [0.1, 0.2],
        chunk: {'type: "text-chunk", content: "hello", metadata: {"tag": bigValue}}
    };
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", (), "cosine");
    test:assertTrue(result is ai:Error,
            "Filterable metadata (everything but the content key) over 2 KB must be rejected client-side");
}

@test:Config {}
isolated function testMapEntryToWireVectorRejectsVectorKeyTooLong() {
    string longId = repeatChar("k", 1100);
    ai:VectorEntry entry = textEntry([0.1, 0.2], id = longId);
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", (), "cosine");
    test:assertTrue(result is ai:Error, "A vector key over 1024 characters must be rejected client-side");
}

// ---------------------------------------------------------------------------
// Batching: the 500-vector count boundary and the 20 MiB byte boundary
// ---------------------------------------------------------------------------

isolated function tinyVector(string key) returns map<json> => {key, "data": {"float32": [0.1, 0.2, 0.3]}};

@test:Config {}
isolated function testBatchBySizeHandlesEmptyInput() {
    map<json>[][] batches = batchBySize([], 500, 1000);
    test:assertEquals(batches.length(), 0, "Batching an empty input must produce zero batches");
}

@test:Config {}
isolated function testBatchBySizeRespectsCountBoundary() {
    map<json>[] vectors = [];
    foreach int i in 0 ..< 501 {
        vectors.push(tinyVector("k" + i.toString()));
    }
    map<json>[][] batches = batchBySize(vectors, 500, 20 * 1024 * 1024);
    test:assertEquals(batches.length(), 2, "501 small vectors at a 500-count limit must split into 2 batches");
    test:assertEquals(batches[0].length(), 500);
    test:assertEquals(batches[1].length(), 1);
}

@test:Config {}
isolated function testBatchBySizeRespectsByteBoundary() {
    // Each vector serializes to roughly 40 bytes; a 100-byte cap forces a split well before the
    // count limit would ever trigger, proving the byte accounting is independent of it.
    map<json>[] vectors = [tinyVector("a"), tinyVector("b"), tinyVector("c")];
    map<json>[][] batches = batchBySize(vectors, 500, 100);
    test:assertTrue(batches.length() > 1, "A tight byte budget must split the batch even under the count limit");
}

@test:Config {}
isolated function testBatchBySizeSingleOversizedVectorGetsOwnBatch() {
    // An oversized vector gets its own batch; the request limit then reports it.
    map<json>[] vectors = [tinyVector("solo")];
    map<json>[][] batches = batchBySize(vectors, 500, 1);
    test:assertEquals(batches.length(), 1);
    test:assertEquals(batches[0].length(), 1);
}

// ---------------------------------------------------------------------------
// Init-time validation and HTTP client configuration
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testValidateStoreConfigRejectsBadValues() {
    VectorStoreConfig[] badConfigs = [
        {contentKey: ""},
        {contentKey: CHUNK_TYPE_METADATA_KEY},
        {contentKey: repeatChar("c", 64)},
        {maxListScan: 0},
        {filters: {filters: [{key: "content", operator: ai:EQUAL, value: "x"}]}}
    ];
    foreach VectorStoreConfig config in badConfigs {
        test:assertTrue(validateStoreConfig(config) is ai:Error,
                string `Invalid store configuration must be rejected: ${config.toString()}`);
    }
    test:assertEquals(validateStoreConfig({}), (), "The default configuration must be valid");
}

@test:Config {}
isolated function testValidateVectorIndexRejectsEmptyNames() {
    VectorIndex[] badIndexes = [
        {vectorBucketName: "", indexName: "idx"},
        {vectorBucketName: "bucket", indexName: " "},
        {indexArn: ""},
        {},
        {indexArn: "arn:aws:s3vectors:us-east-1:123456789012:bucket/b/index/i", indexName: "i"}
    ];
    foreach VectorIndex index in badIndexes {
        test:assertTrue(validateVectorIndex(index) is ai:Error,
                string `Invalid index identifier must be rejected: ${index.toString()}`);
    }
}

@test:Config {}
isolated function testClientConfigurationPinsTransportSettings() {
    http:ClientConfiguration config = toClientConfiguration({timeout: 12});
    test:assertEquals(config.httpVersion, http:HTTP_1_1);
    test:assertEquals(config.http1Settings.chunking, http:CHUNKING_NEVER);
    test:assertEquals(config.retryConfig, ());
    test:assertEquals(config.timeout, 12d);
}

@test:Config {}
isolated function testBackoffDelayIsJitteredWithinBounds() {
    foreach int attempt in 1 ... 5 {
        decimal ceiling = backoffCeiling(attempt);
        decimal delay = backoffDelay(attempt);
        test:assertTrue(delay >= ceiling / 2d && delay <= ceiling,
                string `Attempt ${attempt}: delay ${delay} must lie within [${ceiling / 2d}, ${ceiling}]`);
    }
}

@test:Config {}
isolated function testMetadataToChunkReturnsATextChunkForTextChunks() returns ai:Error? {
    ai:Chunk chunk = check metadataToChunk({content: "hello", [CHUNK_TYPE_METADATA_KEY]: "text-chunk"}, "content");
    test:assertTrue(chunk is ai:TextChunk, "A text chunk must come back as an ai:TextChunk");
    ai:Chunk other = check metadataToChunk({content: "x", [CHUNK_TYPE_METADATA_KEY]: "custom"}, "content");
    test:assertEquals(other.'type, "custom");
}
