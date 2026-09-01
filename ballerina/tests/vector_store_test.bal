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
import ballerina/test;
import ballerinax/aws.auth;

// End-to-end `VectorStore` tests, driven against the in-process mock service in
// `vector_mock_service.bal` rather than a live S3 Vectors endpoint (none exists to test
// against — see that file's header comment). These exercise the store's actual request
// building, batching, pagination, and response/error mapping; `vector_mapping_test.bal` and
// `vector_filter_test.bal` cover the pure logic beneath them in isolation.

const string MOCK_SERVICE_URL = "http://localhost:20990";
const string TEST_VECTOR_BUCKET = "test-vector-bucket";
const string TEST_INDEX = "test-index";

function newTestStore(Configuration config = {validateIndexOnInit: false}) returns VectorStore|ai:Error {
    mockS3VectorsControl.reset();
    return new (
        {
            auth: {accessKeyId: "AKIAEXAMPLE", secretAccessKey: "secret"},
            region: "us-east-1",
            serviceUrl: MOCK_SERVICE_URL
        },
        {vectorBucketName: TEST_VECTOR_BUCKET, indexName: TEST_INDEX},
        config
    );
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

@test:Config {}
function testInitRejectsBothIndexArnAndBucketName() {
    VectorStore|ai:Error store = new (
        {auth: {accessKeyId: "AKIAEXAMPLE", secretAccessKey: "secret"}, region: "us-east-1"},
        {vectorBucketName: TEST_VECTOR_BUCKET, indexName: TEST_INDEX, indexArn: "arn:aws:s3vectors:us-east-1:123456789012:bucket/b/index/i"});
    test:assertTrue(store is ai:Error, "Supplying both indexArn and the bucket/index name pair must be rejected");
}

@test:Config {}
function testInitRejectsNeitherIndexArnNorBucketName() {
    VectorStore|ai:Error store = new (
        {auth: {accessKeyId: "AKIAEXAMPLE", secretAccessKey: "secret"}, region: "us-east-1"}, {});
    test:assertTrue(store is ai:Error, "The index must be identified one way or the other");
}

@test:Config {}
function testInitSkipsGetIndexWhenValidationDisabled() returns error? {
    VectorStore|ai:Error store = newTestStore();
    test:assertFalse(store is ai:Error, "init must succeed without calling GetIndex when validation is disabled");
    test:assertEquals(mockS3VectorsControl.callCount("GetIndex"), 0,
            "GetIndex must not be called when validateIndexOnInit is false");
}

@test:Config {}
function testInitValidatesContentKeyIsNonFilterable() returns error? {
    mockS3VectorsControl.reset();
    mockS3VectorsControl.queueResponse("GetIndex", {
        body: {
            index: {
                vectorBucketName: TEST_VECTOR_BUCKET,
                indexName: TEST_INDEX,
                indexArn: "arn:aws:s3vectors:us-east-1:123456789012:bucket/b/index/i",
                creationTime: "2026-01-01T00:00:00Z",
                dataType: "float32",
                dimension: 3,
                distanceMetric: "cosine",
                metadataConfiguration: {nonFilterableMetadataKeys: ["content"]}
            }
        }
    });
    VectorStore|ai:Error store = new (
        {
            auth: {accessKeyId: "AKIAEXAMPLE", secretAccessKey: "secret"},
            region: "us-east-1",
            serviceUrl: MOCK_SERVICE_URL
        },
        {vectorBucketName: TEST_VECTOR_BUCKET, indexName: TEST_INDEX});
    test:assertFalse(store is ai:Error,
            "init must succeed when the content key is declared non-filterable on the index");
}

@test:Config {}
function testInitFailsWhenContentKeyIsFilterable() returns error? {
    mockS3VectorsControl.reset();
    mockS3VectorsControl.queueResponse("GetIndex", {
        body: {
            index: {
                vectorBucketName: TEST_VECTOR_BUCKET,
                indexName: TEST_INDEX,
                indexArn: "arn:aws:s3vectors:us-east-1:123456789012:bucket/b/index/i",
                creationTime: "2026-01-01T00:00:00Z",
                dataType: "float32",
                dimension: 3,
                distanceMetric: "cosine",
                metadataConfiguration: {nonFilterableMetadataKeys: ["someOtherKey"]}
            }
        }
    });
    VectorStore|ai:Error store = new (
        {
            auth: {accessKeyId: "AKIAEXAMPLE", secretAccessKey: "secret"},
            region: "us-east-1",
            serviceUrl: MOCK_SERVICE_URL
        },
        {vectorBucketName: TEST_VECTOR_BUCKET, indexName: TEST_INDEX});
    test:assertTrue(store is ai:Error,
            "init must fail with an actionable message when the content key is NOT declared non-filterable");
    if store is ai:Error {
        test:assertTrue(store.message().includes("nonFilterableMetadataKeys"),
                "The error must name the fix (declaring the content key non-filterable), got: " + store.message());
    }
}

@test:Config {}
isolated function testVectorStoreInitAcceptsDefaultCredentialsConfigShape() {
    // The default AWS credential chain must be accepted as a configuration shape without
    // panicking, matching the loader's own test for this — actual resolution only happens on
    // the first signed request, not at construction time.
    VectorStore|ai:Error store = new (
        {auth: auth:DEFAULT_CREDENTIALS, region: "us-east-1", serviceUrl: MOCK_SERVICE_URL},
        {vectorBucketName: TEST_VECTOR_BUCKET, indexName: TEST_INDEX},
        {validateIndexOnInit: false});
    test:assertFalse(store is ai:Error, "The DEFAULT_CREDENTIALS config shape must be accepted at construction");
}

// ---------------------------------------------------------------------------
// add
// ---------------------------------------------------------------------------

@test:Config {}
function testAddOnEmptyArrayIsANoOp() returns error? {
    VectorStore store = check newTestStore();
    check store.add([]);
    test:assertEquals(mockS3VectorsControl.callCount("PutVectors"), 0, "An empty add must not send any request");
}

@test:Config {}
function testAddSendsExpectedPutVectorsBody() returns error? {
    VectorStore store = check newTestStore();
    ai:VectorEntry entry = textEntry([0.1, 0.2, 0.3], "hello world", "vec-1");
    check store.add([entry]);

    json[] requests = mockS3VectorsControl.requestsFor("PutVectors");
    test:assertEquals(requests.length(), 1);
    json request = requests[0];
    test:assertEquals(request.vectorBucketName, TEST_VECTOR_BUCKET);
    test:assertEquals(request.indexName, TEST_INDEX);
    json[] vectors = <json[]>check request.vectors;
    test:assertEquals(vectors.length(), 1);
    map<json> vector = <map<json>>vectors[0];
    test:assertEquals(vector["key"], "vec-1");
    map<json> metadata = <map<json>>check vector.metadata;
    test:assertEquals(metadata["content"], "hello world");
}

@test:Config {}
function testAddAllowsAllZeroVectorWhenValidationDisabled() returns error? {
    // With `validateIndexOnInit: false` (`newTestStore`'s default), the store never learns the
    // index's real distance metric, so it must not guess "cosine" and wrongly reject a
    // legitimate all-zero embedding against what might actually be a euclidean index.
    VectorStore store = check newTestStore();
    ai:VectorEntry entry = textEntry([0.0, 0.0, 0.0], "hello world", "zero-vec");
    check store.add([entry]);
    test:assertEquals(mockS3VectorsControl.callCount("PutVectors"), 1);
}

@test:Config {}
function testAddAssignsIdWhenAbsent() returns error? {
    VectorStore store = check newTestStore();
    ai:VectorEntry entry = textEntry([0.1, 0.2, 0.3]);
    check store.add([entry]);
    test:assertTrue(entry.id is string, "add must mutate entry.id in place when the caller left it unset");
}

@test:Config {}
function testAddBatchesAt500VectorCount() returns error? {
    VectorStore store = check newTestStore();
    ai:VectorEntry[] entries = [];
    foreach int i in 0 ..< 501 {
        entries.push(textEntry([0.1, 0.2], "chunk " + i.toString(), "vec-" + i.toString()));
    }
    check store.add(entries);

    json[] requests = mockS3VectorsControl.requestsFor("PutVectors");
    test:assertEquals(requests.length(), 2, "501 vectors must split into two PutVectors requests at the 500 limit");
    json[] firstBatch = <json[]>check requests[0].vectors;
    json[] secondBatch = <json[]>check requests[1].vectors;
    test:assertEquals(firstBatch.length(), 500);
    test:assertEquals(secondBatch.length(), 1);
}

@test:Config {}
function testAddSurfacesAPutVectorsFailure() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("PutVectors",
            {statusCode: 403, headers: {"x-amzn-errortype": "AccessDeniedException"},
                body: {message: "not authorized"}});
    ai:VectorEntry entry = textEntry([0.1, 0.2], "hello", "vec-err");
    ai:Error? result = store.add([entry]);
    test:assertTrue(result is ai:Error, "A PutVectors failure must surface as an ai:Error");
    if result is ai:Error {
        test:assertTrue(result.message().includes("s3vectors:GetVectors") || result.message().includes("Access denied"),
                "A 403 must be mapped to an actionable permissions message, got: " + result.message());
    }
}

// ---------------------------------------------------------------------------
// query — QueryVectors (embedding present)
// ---------------------------------------------------------------------------

@test:Config {}
function testQueryByEmbeddingReturnsMappedMatches() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("QueryVectors", {
        body: {
            distanceMetric: "cosine",
            vectors: [
                {key: "vec-1", distance: 0.1, metadata: {content: "first chunk"}},
                {key: "vec-2", distance: 0.4, metadata: {content: "second chunk"}}
            ]
        }
    });

    ai:VectorMatch[] matches = check store.query({embedding: [0.1, 0.2, 0.3], topK: 5});
    test:assertEquals(matches.length(), 2);
    test:assertEquals(matches[0].id, "vec-1");
    test:assertEquals(matches[0].chunk.content, "first chunk");
    test:assertEquals(matches[0].similarityScore, 0.9, "cosine score must be 1 - distance");
    test:assertEquals(matches[0].embedding, [], "embedding must be empty unless returnVectorData is enabled");

    json[] requests = mockS3VectorsControl.requestsFor("QueryVectors");
    test:assertEquals(requests.length(), 1);
    test:assertEquals(requests[0].returnMetadata, true);
    test:assertEquals(requests[0].returnDistance, true);
}

@test:Config {}
function testQueryByEmbeddingSkipsAMalformedVectorRatherThanFailingEntirely() returns error? {
    // A vector whose content-key metadata isn't a string (e.g. written by something other than
    // this store's add) must not sink the whole query for every other well-formed match.
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("QueryVectors", {
        body: {
            distanceMetric: "cosine",
            vectors: [
                {key: "vec-bad", distance: 0.0, metadata: {content: 12345}},
                {key: "vec-good", distance: 0.1, metadata: {content: "a well-formed chunk"}}
            ]
        }
    });
    ai:VectorMatch[] matches = check store.query({embedding: [0.1, 0.2, 0.3], topK: 5});
    test:assertEquals(matches.length(), 1, "The malformed vector must be skipped, not fail the whole query");
    test:assertEquals(matches[0].id, "vec-good");
}

@test:Config {}
function testQueryByEmbeddingFollowsNextTokenAcrossPages() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("QueryVectors", {
        body: {
            distanceMetric: "cosine",
            nextToken: "page-2-token",
            vectors: [{key: "vec-1", distance: 0.0, metadata: {content: "a"}}]
        }
    });
    mockS3VectorsControl.queueResponse("QueryVectors", {
        body: {
            distanceMetric: "cosine",
            vectors: [{key: "vec-2", distance: 0.0, metadata: {content: "b"}}]
        }
    });

    ai:VectorMatch[] matches = check store.query({embedding: [0.1, 0.2], topK: 10});
    test:assertEquals(matches.length(), 2, "Results across both pages must be aggregated");
    test:assertEquals(mockS3VectorsControl.callCount("QueryVectors"), 2, "A present nextToken must trigger a second page fetch");

    json[] requests = mockS3VectorsControl.requestsFor("QueryVectors");
    test:assertEquals(requests[0].topK, check requests[1].topK, "Every page must resend the same topK");
    test:assertFalse((<map<json>>requests[0]).hasKey("nextToken"), "The first page must not send a nextToken");
    test:assertEquals(requests[1].nextToken, "page-2-token", "The second page must send back the token from page 1");
}

@test:Config {}
function testQueryByEmbeddingStopsEarlyOnceTopKIsReached() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("QueryVectors", {
        body: {
            distanceMetric: "cosine",
            nextToken: "would-fetch-more",
            vectors: [
                {key: "vec-1", distance: 0.0, metadata: {content: "a"}},
                {key: "vec-2", distance: 0.1, metadata: {content: "b"}}
            ]
        }
    });

    ai:VectorMatch[] matches = check store.query({embedding: [0.1, 0.2], topK: 1});
    test:assertEquals(matches.length(), 1, "Only topK results must be returned even if the page had more");
    test:assertEquals(mockS3VectorsControl.callCount("QueryVectors"), 1,
            "No further page should be fetched once topK is already satisfied");
}

@test:Config {}
function testQueryRejectsTopKZero() returns error? {
    VectorStore store = check newTestStore();
    ai:VectorMatch[]|ai:Error result = store.query({embedding: [0.1, 0.2], topK: 0});
    test:assertTrue(result is ai:Error, "topK: 0 is meaningless and must be rejected");
}

@test:Config {}
function testQueryRejectsTopKAboveTenThousand() returns error? {
    VectorStore store = check newTestStore();
    ai:VectorMatch[]|ai:Error result = store.query({embedding: [0.1, 0.2], topK: 10001});
    test:assertTrue(result is ai:Error, "topK above S3 Vectors' 10,000 ceiling must be rejected");
}

@test:Config {}
function testQueryNegativeTopKSendsTenThousandToQueryVectors() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("QueryVectors", {body: {distanceMetric: "cosine", vectors: []}});
    ai:VectorMatch[] _ = check store.query({embedding: [0.1, 0.2], topK: -1});
    json[] requests = mockS3VectorsControl.requestsFor("QueryVectors");
    test:assertEquals(requests[0].topK, 10000, "topK: -1 must be sent as the 10,000 QueryVectors ceiling");
}

@test:Config {}
function testQuerySmallTopKIsFlooredOnTheWireButNotInTheResult() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("QueryVectors", {
        body: {
            distanceMetric: "cosine",
            vectors: [
                {key: "vec-1", distance: 0.0, metadata: {content: "a"}},
                {key: "vec-2", distance: 0.1, metadata: {content: "b"}}
            ]
        }
    });
    ai:VectorMatch[] matches = check store.query({embedding: [0.1, 0.2], topK: 1});
    json[] requests = mockS3VectorsControl.requestsFor("QueryVectors");
    test:assertEquals(requests[0].topK, MIN_QUERY_TOP_K,
            "A topK below the floor must be widened on the wire, since QueryVectors' recall " +
            "collapses at very small topK");
    test:assertEquals(matches.length(), 1, "The caller must still get exactly the topK it asked for");
    test:assertEquals(matches[0].id, "vec-1", "Truncation must keep the closest matches");
}

@test:Config {}
function testQueryTopKAboveTheFloorIsSentUnchanged() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("QueryVectors", {body: {distanceMetric: "cosine", vectors: []}});
    ai:VectorMatch[] _ = check store.query({embedding: [0.1, 0.2], topK: 25});
    json[] requests = mockS3VectorsControl.requestsFor("QueryVectors");
    test:assertEquals(requests[0].topK, 25, "A topK above the floor must be sent as-is");
}

@test:Config {}
function testQueryRejectsSparseEmbedding() returns error? {
    VectorStore store = check newTestStore();
    ai:VectorMatch[]|ai:Error result =
        store.query({embedding: {indices: [0, 1], values: [1.0, 2.0]}, topK: 5});
    test:assertTrue(result is ai:Error, "S3 Vectors supports dense vectors exclusively");
}

@test:Config {}
function testQueryWithEmbeddingAndFiltersSendsTranslatedFilter() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("QueryVectors", {body: {distanceMetric: "cosine", vectors: []}});
    ai:VectorMatch[] _ = check store.query({
        embedding: [0.1, 0.2],
        topK: 5,
        filters: {filters: [{key: "genre", operator: ai:EQUAL, value: "drama"}]}
    });
    json[] requests = mockS3VectorsControl.requestsFor("QueryVectors");
    test:assertEquals(requests[0].filter, {"genre": "drama"});
}

// ---------------------------------------------------------------------------
// query — ListVectors (filter-only / no embedding)
// ---------------------------------------------------------------------------

@test:Config {}
function testFilterOnlyQueryScansAndFiltersLocally() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("ListVectors", {
        body: {
            vectors: [
                {key: "vec-1", metadata: {content: "a", genre: "drama"}},
                {key: "vec-2", metadata: {content: "b", genre: "comedy"}}
            ]
        }
    });

    ai:VectorMatch[] matches = check store.query({
        filters: {filters: [{key: "genre", operator: ai:EQUAL, value: "drama"}]},
        topK: -1
    });
    test:assertEquals(matches.length(), 1, "Only the vector matching the local filter must be returned");
    test:assertEquals(matches[0].id, "vec-1");
    test:assertEquals(matches[0].similarityScore, 0.0, "Filter-only matches must score 0.0 (no distance exists)");

    json[] requests = mockS3VectorsControl.requestsFor("ListVectors");
    test:assertEquals(requests.length(), 1);
    test:assertEquals(requests[0].returnMetadata, true);
}

@test:Config {}
function testQueryWithNoEmbeddingAndNoFiltersReturnsEverything() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("ListVectors", {
        body: {vectors: [{key: "vec-1", metadata: {content: "a"}}, {key: "vec-2", metadata: {content: "b"}}]}
    });
    ai:VectorMatch[] matches = check store.query({topK: -1});
    test:assertEquals(matches.length(), 2, "No embedding and no filters must return every vector (deleteByFilter's shape)");
}

@test:Config {}
function testFilterOnlyQueryPaginatesOverListVectors() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("ListVectors",
            {body: {nextToken: "next-page", vectors: [{key: "vec-1", metadata: {content: "a"}}]}});
    mockS3VectorsControl.queueResponse("ListVectors", {body: {vectors: [{key: "vec-2", metadata: {content: "b"}}]}});

    ai:VectorMatch[] matches = check store.query({topK: -1});
    test:assertEquals(matches.length(), 2);
    test:assertEquals(mockS3VectorsControl.callCount("ListVectors"), 2);
}

@test:Config {}
function testFilterOnlyQueryErrorsPastMaxListScan() returns error? {
    VectorStore store = check newTestStore({validateIndexOnInit: false, maxListScan: 1});
    mockS3VectorsControl.queueResponse("ListVectors", {
        body: {
            vectors: [{key: "vec-1", metadata: {content: "a"}}, {key: "vec-2", metadata: {content: "b"}}]
        }
    });
    ai:VectorMatch[]|ai:Error result = store.query({topK: -1});
    test:assertTrue(result is ai:Error, "Scanning past maxListScan must fail rather than silently truncate");
    if result is ai:Error {
        test:assertTrue(result.message().includes("maxListScan"),
                "The error must name maxListScan as the actionable knob, got: " + result.message());
    }
}

@test:Config {}
function testFilterOnlyQueryRespectsTopKEarlyExit() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("ListVectors", {
        body: {
            vectors: [{key: "vec-1", metadata: {content: "a"}}, {key: "vec-2", metadata: {content: "b"}}]
        }
    });
    ai:VectorMatch[] matches = check store.query({topK: 1});
    test:assertEquals(matches.length(), 1, "A positive topK on the filter-only path must still cap the result count");
}

// ---------------------------------------------------------------------------
// query — returnVectorData hydration
// ---------------------------------------------------------------------------

@test:Config {}
function testReturnVectorDataHydratesEmbeddingViaGetVectors() returns error? {
    VectorStore store = check newTestStore({validateIndexOnInit: false, returnVectorData: true});
    mockS3VectorsControl.queueResponse("QueryVectors", {
        body: {
            distanceMetric: "cosine",
            vectors: [{key: "vec-1", distance: 0.0, metadata: {content: "a"}}]
        }
    });
    mockS3VectorsControl.queueResponse("GetVectors", {
        body: {vectors: [{key: "vec-1", data: {float32: [0.1, 0.2, 0.3]}}]}
    });

    ai:VectorMatch[] matches = check store.query({embedding: [0.1, 0.2, 0.3], topK: 5});
    test:assertEquals(matches.length(), 1);
    test:assertEquals(matches[0].embedding, [0.1, 0.2, 0.3],
            "The embedding must be hydrated from GetVectors when returnVectorData is enabled");
    test:assertEquals(mockS3VectorsControl.callCount("GetVectors"), 1);
}

@test:Config {}
function testReturnVectorDataBatchesGetVectorsAt100Keys() returns error? {
    VectorStore store = check newTestStore({validateIndexOnInit: false, returnVectorData: true});

    json[] queryMatches = [];
    foreach int i in 0 ..< 150 {
        queryMatches.push({key: "vec-" + i.toString(), distance: 0.0, metadata: {content: "c"}});
    }
    mockS3VectorsControl.queueResponse("QueryVectors", {body: {distanceMetric: "cosine", vectors: queryMatches}});
    mockS3VectorsControl.queueResponse("GetVectors", {body: {vectors: []}});
    mockS3VectorsControl.queueResponse("GetVectors", {body: {vectors: []}});

    ai:VectorMatch[] matches = check store.query({embedding: [0.1, 0.2, 0.3], topK: 150});
    test:assertEquals(matches.length(), 150);
    test:assertEquals(mockS3VectorsControl.callCount("GetVectors"), 2,
            "150 keys must split into two GetVectors requests at the 100-key limit");
    json[] requests = mockS3VectorsControl.requestsFor("GetVectors");
    json[] firstBatchKeys = <json[]>check requests[0].keys;
    json[] secondBatchKeys = <json[]>check requests[1].keys;
    test:assertEquals(firstBatchKeys.length(), 100);
    test:assertEquals(secondBatchKeys.length(), 50);
}

@test:Config {}
function testReturnVectorDataDisabledLeavesEmbeddingEmpty() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("QueryVectors", {
        body: {distanceMetric: "cosine", vectors: [{key: "vec-1", distance: 0.0, metadata: {content: "a"}}]}
    });
    ai:VectorMatch[] matches = check store.query({embedding: [0.1, 0.2, 0.3], topK: 5});
    test:assertEquals(matches[0].embedding, []);
    test:assertEquals(mockS3VectorsControl.callCount("GetVectors"), 0,
            "GetVectors must never be called when returnVectorData is disabled (the default)");
}

// ---------------------------------------------------------------------------
// delete
// ---------------------------------------------------------------------------

@test:Config {}
function testDeleteOnEmptyArrayIsANoOp() returns error? {
    VectorStore store = check newTestStore();
    check store.delete([]);
    test:assertEquals(mockS3VectorsControl.callCount("DeleteVectors"), 0);
}

@test:Config {}
function testDeleteAcceptsASingleId() returns error? {
    VectorStore store = check newTestStore();
    check store.delete("vec-1");
    json[] requests = mockS3VectorsControl.requestsFor("DeleteVectors");
    test:assertEquals(requests.length(), 1);
    test:assertEquals(requests[0].keys, ["vec-1"]);
}

@test:Config {}
function testDeleteBatchesAt500Keys() returns error? {
    VectorStore store = check newTestStore();
    string[] ids = [];
    foreach int i in 0 ..< 750 {
        ids.push("vec-" + i.toString());
    }
    check store.delete(ids);
    json[] requests = mockS3VectorsControl.requestsFor("DeleteVectors");
    test:assertEquals(requests.length(), 2, "750 keys must split into two DeleteVectors requests at the 500 limit");
    json[] firstBatchKeys = <json[]>check requests[0].keys;
    json[] secondBatchKeys = <json[]>check requests[1].keys;
    test:assertEquals(firstBatchKeys.length(), 500);
    test:assertEquals(secondBatchKeys.length(), 250);
}

@test:Config {}
function testDeleteSurfacesBatchProgressOnFailure() returns error? {
    VectorStore store = check newTestStore();
    string[] ids = [];
    foreach int i in 0 ..< 750 {
        ids.push("vec-" + i.toString());
    }
    // First batch (500 keys) succeeds with the mock's default 200 {}; the second fails with a
    // non-retryable status, so it fails on the first attempt rather than falling through to the
    // mock's default 200 {} on a later retry attempt.
    mockS3VectorsControl.queueResponse("DeleteVectors", {statusCode: 200, body: {}});
    mockS3VectorsControl.queueResponse("DeleteVectors",
            {statusCode: 403, headers: {"x-amzn-errortype": "AccessDeniedException"},
                body: {message: "not authorized"}});
    ai:Error? result = store.delete(ids);
    test:assertTrue(result is ai:Error, "A DeleteVectors failure must surface as an ai:Error");
    if result is ai:Error {
        test:assertTrue(result.message().includes("1 of 2 batches") && result.message().includes("500 of 750 keys"),
                "The error must report how many batches/keys succeeded before the failure, got: " +
                        result.message());
    }
}

@test:Config {}
function testDeleteOfNonexistentKeyIsNotAnError() returns error? {
    // S3 Vectors' DeleteVectors is idempotent; the mock's default 200 {} response models that,
    // so a plain successful call here IS the assertion.
    VectorStore store = check newTestStore();
    check store.delete("does-not-exist");
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

@test:Config {}
function testNotFoundErrorMapping() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("DeleteVectors",
            {statusCode: 404, headers: {"x-amzn-errortype": "NotFoundException"}, body: {message: "no such index"}});
    ai:Error? result = store.delete("vec-1");
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("not found") || result.message().includes("NotFound"),
                "A 404 must be mapped to a not-found message, got: " + result.message());
        test:assertTrue(result.message().includes(TEST_VECTOR_BUCKET) && result.message().includes(TEST_INDEX),
                "The error must echo the targeted bucket/index rather than a generic message, got: " +
                        result.message());
    }
}

@test:Config {}
function testValidationExceptionSurfacesFieldList() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("PutVectors", {
        statusCode: 400,
        headers: {"x-amzn-errortype": "ValidationException"},
        body: {
            message: "Validation failed",
            fieldList: [{path: "vectors.0.data", message: "dimension mismatch"}]
        }
    });
    ai:Error? result = store.add([textEntry([0.1, 0.2], "x", "vec-1")]);
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("dimension mismatch"),
                "The individual fieldList entry must be surfaced verbatim, got: " + result.message());
        test:assertTrue(result.message().includes("vectors.0.data"),
                "The field path must be surfaced too, got: " + result.message());
    }
}

@test:Config {}
function testServiceQuotaExceededErrorMapping() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("PutVectors", {
        statusCode: 402,
        headers: {"x-amzn-errortype": "ServiceQuotaExceededException"},
        body: {message: "quota exceeded"}
    });
    ai:Error? result = store.add([textEntry([0.1, 0.2], "x", "vec-1")]);
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("quota"), "A 402 must mention the quota, got: " + result.message());
    }
}

@test:Config {}
function testKmsErrorMapping() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("PutVectors", {
        statusCode: 400,
        headers: {"x-amzn-errortype": "KmsDisabledException"},
        body: {message: "the KMS key is disabled"}
    });
    ai:Error? result = store.add([textEntry([0.1, 0.2], "x", "vec-1")]);
    test:assertTrue(result is ai:Error);
    if result is ai:Error {
        test:assertTrue(result.message().includes("encryption") || result.message().includes("KMS"),
                "A KMS error must be identified as an encryption-configuration problem, got: " + result.message());
    }
}

@test:Config {}
function testRetryableStatusIsRetriedAndSucceeds() returns error? {
    VectorStore store = check newTestStore();
    mockS3VectorsControl.queueResponse("PutVectors",
            {statusCode: 503, headers: {"x-amzn-errortype": "ServiceUnavailableException"}, body: {message: "busy"}});
    mockS3VectorsControl.queueResponse("PutVectors", {statusCode: 200, body: {}});

    ai:Error? result = store.add([textEntry([0.1, 0.2], "x", "vec-1")]);
    test:assertFalse(result is ai:Error, "A 503 followed by a 200 must succeed after an internal retry");
    test:assertEquals(mockS3VectorsControl.callCount("PutVectors"), 2, "Exactly one retry attempt must have occurred");
}
