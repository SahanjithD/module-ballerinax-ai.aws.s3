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
import ballerinax/aws;
import ballerinax/aws.auth;

# Describes how to reach the Amazon S3 Vectors service. S3 Vectors is a distinct service from
# S3 object storage: it has its own endpoint, its own `s3vectors` IAM namespace, and its own
# API, so it is configured separately from the `s3:ConnectionConfig` the data loader takes.
public type VectorStoreConnectionConfig record {|
    # Where credentials come from. Defaults to the standard AWS provider chain (environment
    # variables, web identity token, IAM Identity Center, shared config/credentials files,
    # external process, container credentials, and EC2 instance profile — first one that answers)
    auth:AuthConfig auth = auth:DEFAULT_CREDENTIALS;

    # The region hosting the vector bucket. S3 Vectors is not available in every region, and the
    # bucket must live in the region set here
    aws:Region|string region = aws:US_EAST_1;

    # Overrides the resolved service endpoint, scheme included (e.g. `http://localhost:9090`).
    # Intended for testing against a local or proxied endpoint; leave unset for normal use, in
    # which case the endpoint is derived from `region`
    string serviceUrl?;

    # Whether to target the FIPS 140-validated endpoint variant
    # (`s3vectors-fips.{region}.api.aws`). Ignored when `serviceUrl` is set
    boolean fips = false;
|};

# Identifies the target vector index. S3 Vectors accepts either the bucket and index names
# together, or the index ARN on its own — supply one form or the other, not both.
public type IndexIdentifier record {|
    # The name of the vector bucket holding the index. Required unless `indexArn` is given, and
    # must be paired with `indexName`
    string vectorBucketName?;

    # The name of the vector index. Required unless `indexArn` is given, and must be paired with
    # `vectorBucketName`
    string indexName?;

    # The full ARN of the vector index, as an alternative to the bucket and index name pair
    string indexArn?;
|};

# Configuration options for the Amazon S3 Vectors vector store.
public type Configuration record {|
    # The metadata key the chunk's text content is stored under.
    #
    # This key **must** be declared in the index's `nonFilterableMetadataKeys` when the index is
    # created. Filterable metadata is capped at 2 KB per vector while chunk text routinely
    # exceeds that, and the setting is immutable — an index created without it has to be deleted
    # and rebuilt. When `validateIndexOnInit` is set, initialization checks this and fails with
    # an actionable message rather than letting writes fail later
    string contentKey = "content";

    # Metadata filters applied to every search, combined with any per-query filters under `AND`
    ai:MetadataFilters filters?;

    # Whether `query` issues follow-up `GetVectors` calls to populate `ai:VectorMatch.embedding`.
    #
    # The S3 Vectors `QueryVectors` operation never returns vector data, so when this is `false`
    # the field is an empty array. Enabling it roughly doubles the request count and incurs
    # additional `GetVectors` charges. No caller within `ballerina/ai` reads the field
    boolean returnVectorData = false;

    # The maximum number of vectors scanned by a filter-only query — one carrying filters but no
    # embedding, as issued by `ai:VectorKnowledgeBase.deleteByFilter`.
    #
    # S3 Vectors cannot filter server-side while listing, so such a query pages through the index
    # with `ListVectors` and evaluates the filters locally. Exceeding this bound fails with an
    # error rather than scanning further
    int maxListScan = 100000;

    # Whether to read the index configuration with a `GetIndex` call during initialization.
    #
    # One extra request at startup, in exchange for catching a filterable content key, an
    # embedding-dimension mismatch, and a missing or misnamed index up front instead of on the
    # first write
    boolean validateIndexOnInit = true;
|};

// ---------------------------------------------------------------------------------------------
// Wire records. These mirror the S3 Vectors API shapes narrowed to the fields the store reads.
// All are open (`record {`, not `record {|`) so that fields this store ignores — creationTime,
// encryptionConfiguration, and anything AWS adds later — do not break `cloneWithType`.
// ---------------------------------------------------------------------------------------------

// The `GetIndex` response.
type GetIndexResponse record {
    IndexAttributes index;
};

// The attributes of a vector index, as returned by `GetIndex`. `dimension` and `distanceMetric`
// are fixed at creation time, which is what makes them worth caching for the life of the store.
type IndexAttributes record {
    string vectorBucketName;
    string indexName;
    string indexArn;
    int dimension;
    // Either "cosine" or "euclidean"; kept as a string rather than an enum so that a metric
    // added by AWS later surfaces as a value to handle rather than a conversion failure.
    string distanceMetric;
    MetadataConfiguration metadataConfiguration?;
};

// The metadata configuration of a vector index. Absent entirely when the index was created
// without any non-filterable keys.
type MetadataConfiguration record {
    string[] nonFilterableMetadataKeys;
};

// Vector data. A union in the API with a single member today; values are stored as 32-bit
// floats, so a Ballerina `float` (IEEE-754 binary64) does not round-trip exactly.
type VectorData record {
    float[] float32?;
};

// The `QueryVectors` response. `distanceMetric` echoes the metric the index was created with,
// and `nextToken` is present while further pages remain.
type QueryVectorsResponse record {
    QueryOutputVector[] vectors;
    string distanceMetric?;
    string nextToken?;
};

// One approximate-nearest-neighbour hit. Note there is no vector data here: `QueryVectors` has
// no `returnData` parameter and never returns embeddings.
type QueryOutputVector record {
    string key;
    float distance?;
    map<json> metadata?;
};

// The `ListVectors` response.
type ListVectorsResponse record {
    ListOutputVector[] vectors;
    string nextToken?;
};

// One entry of a `ListVectors` page.
type ListOutputVector record {
    string key;
    VectorData data?;
    map<json> metadata?;
};

// The `GetVectors` response, used only to hydrate embeddings when `returnVectorData` is set.
type GetVectorsResponse record {
    GetOutputVector[] vectors;
};

// One entry of a `GetVectors` response.
type GetOutputVector record {
    string key;
    VectorData data?;
    map<json> metadata?;
};

// A single failure within a `ValidationException`. AWS reports each offending field separately,
// and the pair is far more actionable than the exception's summary message on its own.
type ValidationExceptionField record {
    string path;
    string message;
};

// The body of an S3 Vectors error response. `rest-json` carries the error type in the
// `x-amzn-errortype` header and/or a `__type` field, and the human-readable text in `message`;
// only `ValidationException` adds `fieldList`.
type ErrorResponse record {
    string message?;
    string __type?;
    ValidationExceptionField[] fieldList?;
};
