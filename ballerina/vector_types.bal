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
    http:ClientConfiguration httpConfig = {};
|};

# The vector index to use, by its bucket and index name or by its ARN.
public type VectorIndex VectorBucketIndex|IndexArn;

# A vector index identified by its bucket and index name.
public type VectorBucketIndex record {|
    # Vector bucket that holds the index
    string vectorBucketName;

    # Index name within the vector bucket
    string indexName;
|};

# Full ARN of a vector index. Needed to reach an index owned by another AWS account.
public type IndexArn string;

# Vector store behaviour.
public type VectorStoreConfig record {|
    # Metadata key that holds the chunk text. Must be declared non-filterable on the index
    string contentKey = "content";

    # Filters applied to every query, in addition to the query's own filters
    ai:MetadataFilters filters?;

    # Whether query results include embeddings. Costs an extra `GetVectors` call per query
    boolean returnVectorData = false;

    # Most vectors a query without an embedding may scan before it fails
    int maxListScan = 100000;

    # Whether to check the index's dimension, metric and content key when the store is created
    boolean validateIndexOnInit = true;
|};

// Wire records, narrowed to the fields the store reads. Open records, so fields AWS adds later
// don't break `cloneWithType`.

type GetIndexResponse record {
    IndexAttributes index;
};

type IndexAttributes record {
    string vectorBucketName;
    string indexName;
    string indexArn;
    int dimension;
    // A string rather than an enum, so a new metric isn't a conversion failure.
    string distanceMetric;
    MetadataConfiguration metadataConfiguration?;
};

// Absent when the index has no non-filterable keys.
type MetadataConfiguration record {
    string[] nonFilterableMetadataKeys;
};

// Values are 32-bit floats, so a Ballerina `float` doesn't round-trip exactly.
type VectorData record {
    float[] float32?;
};

type QueryVectorsResponse record {
    QueryOutputVector[] vectors;
    string distanceMetric?;
    string nextToken?;
};

// `QueryVectors` never returns vector data.
type QueryOutputVector record {
    string key;
    float distance?;
    map<json> metadata?;
};

type ListVectorsResponse record {
    ListOutputVector[] vectors;
    string nextToken?;
};

type ListOutputVector record {
    string key;
    VectorData data?;
    map<json> metadata?;
};

type GetVectorsResponse record {
    GetOutputVector[] vectors;
};

type GetOutputVector record {
    string key;
    VectorData data?;
    map<json> metadata?;
};

type ValidationExceptionField record {
    string path;
    string message;
};

// The error type comes in the `x-amzn-errortype` header and/or `__type`.
type ErrorResponse record {
    string message?;
    string __type?;
    ValidationExceptionField[] fieldList?;
};
