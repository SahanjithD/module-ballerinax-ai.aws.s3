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
import ballerinax/aws;
import ballerinax/aws.auth;

# Connection settings for Amazon S3 Vectors.
public type VectorStoreConnectionConfig record {|
    # AWS credentials. Use `auth:DEFAULT_CREDENTIALS` for the standard AWS credential chain
    auth:AuthConfig auth;

    # AWS region that hosts the vector bucket
    aws:Region|string region;

    # Overrides the endpoint derived from the region, e.g. for testing. FIPS is not supported
    aws:EndpointConfig endpoint?;

    # Timeout, proxy, TLS and other HTTP client settings
    HttpConfig httpConfig = {};
|};

# HTTP client settings for calls to S3 Vectors.
public type HttpConfig record {|
    # Seconds to wait for a response before the request times out
    decimal timeout = 30;

    # Proxy server to send requests through
    http:ProxyConfig proxy?;

    # TLS settings, such as a custom trust store
    http:ClientSecureSocket secureSocket?;

    # Limits on pooled connections
    http:PoolConfiguration poolConfig?;

    # Stops sending requests for a while after repeated failures
    http:CircuitBreakerConfig circuitBreaker?;

    # Low-level socket options
    http:ClientSocketConfig socketConfig = {};

    # Size limits for response status lines, headers and bodies
    http:ResponseLimitConfigs responseLimits = {};
|};

# The vector index to use. Give either `vectorBucketName` and `indexName` together, or `indexArn`.
public type VectorIndex record {|
    # Vector bucket that holds the index
    string vectorBucketName?;

    # Index name within the vector bucket
    string indexName?;

    # Full index ARN. Needed to reach an index owned by another AWS account
    string indexArn?;
|};

# How S3 Vectors applies metadata filters in a query with an embedding.
public enum QueryMode {
    # Filters during the search. A filtered query can return fewer than `topK` matches
    CLASSIC,
    # Filters before the search, so a filtered query returns every match it can, up to `topK`
    ENHANCED
}

# Vector store behaviour.
public type VectorStoreConfig record {|
    # Metadata key that holds the chunk text. Must be declared non-filterable on the index
    string contentKey = "content";

    # Filters applied to every query, in addition to the query's own filters
    ai:MetadataFilters filters?;

    # How filters are applied when querying by embedding. Unset uses the index's own mode
    QueryMode queryMode?;

    # Whether query results include embeddings. Costs an extra `GetVectors` call per query
    boolean returnVectorData = false;

    # Most vectors a query without an embedding may scan before it fails
    int maxListScan = 100000;

    # Whether to check the index's dimension, metric and content key when the store is created
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
