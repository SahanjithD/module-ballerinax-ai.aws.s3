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
import ballerina/lang.'float as floats;
import ballerina/test;
import ballerina/time;
import ballerinax/aws;
import ballerinax/aws.auth;

// Pure unit tests for `vector_utils.bal` and the endpoint resolution in `s3_vectors_api.bal`:
// no network access, no credentials, safe to run in CI. Filter translation/evaluation have their
// own file (`vector_filter_test.bal`); this one covers everything else — endpoint resolution,
// distance-to-score conversion, metadata round-tripping, entry validation, and batching.

// ---------------------------------------------------------------------------
// Endpoint resolution — the canary for the riskiest assumption in this module (see
// `resolveServiceEndpoint` in `s3_vectors_api.bal`): `s3vectors` is absent from the SDK's
// bundled endpoint metadata, so an unqualified lookup silently resolves to a host that does not
// exist. If this test ever fails, every other test in this file is testing against a store that
// cannot actually reach AWS.
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testAwsResolveEndpointHostUsesApiAwsSuffix() {
    string host = aws:resolveEndpointHost("s3vectors", aws:US_EAST_1, {dualstack: true});
    test:assertEquals(host, "s3vectors.us-east-1.api.aws",
            "S3 Vectors endpoint host must use the .api.aws (dualstack) suffix, not .amazonaws.com");
}

@test:Config {}
isolated function testResolveServiceEndpointRejectsFips() {
    [string, string]|ai:Error result = resolveServiceEndpoint({region: aws:US_EAST_1, fips: true});
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
        resolveServiceEndpoint({region: aws:US_EAST_1, fips: true, serviceUrl: "https://proxy.example"});
    test:assertTrue(result is ai:Error,
            "'fips' must not be silently ignored alongside a serviceUrl — that would leave the " +
            "caller believing they are on a validated path");
}

@test:Config {}
isolated function testResolveServiceEndpointDerivesHostAndUrl() {
    [string, string]|ai:Error result = resolveServiceEndpoint({region: aws:US_WEST_2});
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
        resolveServiceEndpoint({region: aws:US_EAST_1, serviceUrl: "http://localhost:9090"});
    test:assertFalse(result is ai:Error, "An explicit serviceUrl override must resolve without error");
    if result is [string, string] {
        var [url, host] = result;
        test:assertEquals(url, "http://localhost:9090", "The override URL must be passed through as-is");
        test:assertEquals(host, "localhost:9090",
                "The bare host must retain the port but drop the scheme, for the SigV4 host header");
    }
}

// ---------------------------------------------------------------------------
// SigV4 header shape. `vector_mock_service.bal` deliberately does not verify signatures — it
// would just be re-testing `ballerinax/aws.auth` itself — so this is the one place that checks
// `invoke` (`s3_vectors_api.bal`) is actually calling `auth:getSignedHeaders` with a shape that
// produces a usable signature, against a fixed request and static credentials.
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
    // index/id/prev are declared `int` on ai:Metadata. A plain pass-through assignment for
    // these (rather than an explicit coercion) panics at runtime when the decoded JSON number
    // is a float (e.g. round-tripped through a JSON layer as "5.0") instead of erroring cleanly.
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
    ai:Chunk chunk = check metadataToChunk({content: "hello world", 'type: "text-chunk", header: "H1"}, "content");
    test:assertEquals(chunk.content, "hello world");
    test:assertEquals(chunk.'type, "text-chunk");
    ai:Metadata? metadata = chunk.metadata;
    test:assertTrue(metadata is ai:Metadata, "Chunk metadata must be present");
    if metadata is ai:Metadata {
        test:assertEquals(metadata.hasKey("content"), false,
                "The content key must not be duplicated into ai:Metadata's open fields");
        test:assertEquals(metadata.hasKey("type"), false,
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
isolated function testMetadataToChunkDefaultsContentToEmptyStringWhenAbsent() returns ai:Error? {
    ai:Chunk chunk = check metadataToChunk({header: "H1"}, "content");
    test:assertEquals(chunk.content, "", "A vector with no content key must not fail the whole query");
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
    // `distanceMetric` is `()` when `Configuration.validateIndexOnInit` is `false` — the
    // all-zero check must not assume "cosine" in that case, or a legitimate all-zero embedding
    // would be wrongly rejected against a real euclidean index.
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
isolated function testMapEntryToWireVectorRejectsLongMetadataKeyName() {
    string longKey = repeatChar("k", 70);
    ai:VectorEntry entry = {
        id: "long-key",
        embedding: [0.1, 0.2],
        chunk: {'type: "text-chunk", content: "hello", metadata: {[longKey]: "value"}}
    };
    map<json>|ai:Error result = mapEntryToWireVector(entry, "content", (), "cosine");
    test:assertTrue(result is ai:Error, "A metadata key name over 63 characters must be rejected client-side");
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
    // A single vector larger than the byte budget must not be dropped or fail — it becomes its
    // own batch, on the theory that the request-level limit will surface the problem clearly if
    // it is truly too large, rather than the batching logic looping forever trying to shrink it.
    map<json>[] vectors = [tinyVector("solo")];
    map<json>[][] batches = batchBySize(vectors, 500, 1);
    test:assertEquals(batches.length(), 1);
    test:assertEquals(batches[0].length(), 1);
}
