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
import ballerina/log;
import ballerinax/aws;
import ballerinax/aws.auth;

# A vector store backed by Amazon S3 Vectors (`s3vectors`), implementing `ai:VectorStore`.
#
# S3 Vectors is a distinct AWS service from S3 object storage — its own endpoint, its own
# `s3vectors` IAM namespace, its own API — and has no Ballerina connector, so this store talks to
# it directly over `ballerina/http` with hand-signed AWS Signature Version 4 requests, using the
# signing primitives from `ballerinax/aws.auth`.
#
# **Dense vectors only.** S3 Vectors has no sparse or hybrid index type, so `add` and `query`
# reject anything other than `ai:Vector` embeddings — there is no `ai:VectorStoreQueryMode` to
# configure, unlike the Pinecone and Milvus stores.
#
# **Text chunks only.** A vector's content is stored as S3 Vectors metadata (there is nowhere
# else to put it), which must be JSON — so `add` requires `chunk.content` to be a `string`.
#
# **The content key must be non-filterable.** S3 Vectors caps filterable metadata at 2 KB per
# vector, far below what chunk text routinely needs, so the metadata key holding the chunk's
# text (`Configuration.contentKey`, `"content"` by default) must be declared in the index's
# `nonFilterableMetadataKeys` when the index is created — and that setting is immutable
# afterwards. By default, `init` reads the index configuration back with `GetIndex` and fails
# fast with an actionable message if this was not done; see `Configuration.validateIndexOnInit`.
#
# **Regional availability.** S3 Vectors is not offered in every AWS region; the vector bucket
# must live in the region configured on `VectorStoreConnectionConfig`.
#
# **`similarityScore` is a converted value, not a raw distance.** S3 Vectors returns a distance
# (lower is more similar); `ai:VectorMatch.similarityScore` must be higher-is-better, so `query`
# converts it — see `distanceToScore` in `vector_utils.bal` for the exact formulas and a note on
# where this deliberately diverges from `ai:InMemoryVectorStore`'s Euclidean handling.
#
# **`query` with no embedding scans the index.** `QueryVectors` requires a query vector; it
# cannot filter without one. So a query carrying only metadata filters (or neither — the shape
# `ai:VectorKnowledgeBase.deleteByFilter` issues) pages through `ListVectors` and evaluates the
# filters in Ballerina, bounded by `Configuration.maxListScan`. This is the only way
# `deleteByFilter` can function against this store at all, but it is an O(index size) operation.
#
# **`delete` is idempotent.** Deleting a key that does not exist is not an error, unlike
# `ai:InMemoryVectorStore`, which raises one for a missing id.
public isolated class VectorStore {
    *ai:VectorStore;

    // Every field below is either `final` and itself an isolated object (`http:Client`,
    // `auth:CredentialProvider` — safe to reference from any isolated method without a `lock`,
    // since the object manages its own internal concurrency) or `final` and a value/`readonly &`
    // type (also lock-free by construction). Nothing here is ever mutated after `init`, so — as
    // with `ai.pinecone`'s store — no `lock` blocks are needed anywhere in this class.
    private final http:Client httpClient;
    private final auth:CredentialProvider credentialProvider;
    private final string host;
    private final aws:Region|string region;
    private final readonly & IndexIdentifier index;
    private final string contentKey;
    private final (readonly & ai:MetadataFilters)? filters;
    private final boolean returnVectorData;
    private final int maxListScan;
    // () when `validateIndexOnInit` is `false` — dimension checks on `add` are then skipped
    // rather than guessed at, since S3 Vectors is the only source of truth for it.
    private final int? dimension;
    // () when `validateIndexOnInit` is `false`, for the same reason as `dimension`: this value
    // also feeds `add`'s all-zero-vector rejection (`mapEntryToWireVector` in `vector_utils.bal`,
    // which only rejects when the metric is known to be "cosine"), so guessing "cosine" here
    // would wrongly reject a legitimate all-zero embedding against a real euclidean index.
    // `query`'s score conversion falls back to "cosine" only if a response were to omit its own
    // `distanceMetric` field, which QueryVectors does not do in practice.
    private final string? distanceMetric;

    # Initializes the S3 Vectors vector store.
    #
    # + connectionConfig - How to reach the S3 Vectors service: credentials, region, and an
    # optional endpoint override
    # + index - The target vector index, by ARN or by bucket and index name
    # + config - Store behaviour: the content metadata key, default filters, whether to hydrate
    # embeddings on query, the filter-only scan cap, and whether to validate the index at startup
    # + httpConfig - HTTP client configuration for the underlying connection to S3 Vectors.
    # The HTTP version and chunking settings are always forced to HTTP/1.1 and
    # `CHUNKING_NEVER`, since S3 Vectors rejects HTTP/2 and chunked request bodies, and
    # `retryConfig` is always cleared, since this store retries S3 Vectors calls itself with a
    # fresh SigV4 signature on each attempt
    # + return - An `ai:Error` if the index identifier is invalid, credentials cannot be
    # resolved, the HTTP client cannot be created, or (when `config.validateIndexOnInit` is
    # `true`) the index cannot be read or is misconfigured for this store
    public isolated function init(
            @display {label: "Connection Config"} VectorStoreConnectionConfig connectionConfig,
            @display {label: "Index"} IndexIdentifier index,
            @display {label: "S3 Vectors Configuration"} Configuration config = {},
            @display {label: "HTTP Configuration"} http:ClientConfiguration httpConfig = {}) returns ai:Error? {
        string? indexArn = index.indexArn;
        string? vectorBucketName = index.vectorBucketName;
        string? indexName = index.indexName;
        if indexArn is string {  
            if vectorBucketName is string || indexName is string {
                return error ai:Error(
                    "The S3 Vectors index must be identified by either 'indexArn' alone, or by " +
                    "'vectorBucketName' and 'indexName' together — not both forms at once");
            }
        } else if vectorBucketName is () || indexName is () {
            return error ai:Error(
                "The S3 Vectors index must be identified by either 'indexArn', or by both " +
                "'vectorBucketName' and 'indexName'");
        }
        self.index = index.cloneReadOnly();

        [string, string]|ai:Error endpointResult = resolveServiceEndpoint(connectionConfig);
        if endpointResult is ai:Error {
            return error ai:Error("Failed to initialize the S3 Vectors vector store", endpointResult);
        }
        [string, string] [endpointUrl, host] = endpointResult;
        self.host = host;
        self.region = connectionConfig.region;

        auth:CredentialProvider|auth:CredentialResolutionError provider = new (connectionConfig.auth);
        if provider is auth:CredentialResolutionError {
            return error ai:Error(
                "Failed to initialize the S3 Vectors vector store: could not resolve AWS credentials",
                provider);
        }
        self.credentialProvider = provider;

        // S3 Vectors rejects both HTTP/2 and chunked request bodies, so the two Ballerina
        // defaults that produce them are overridden here on top of whatever the caller supplied.
        //
        // HTTP/2: identical, byte-for-byte identically signed GetIndex requests multiplexed as
        // successive streams on one connection come back 200 and 400 ("Invalid request",
        // x-amzn-errortype: ValidationException) at random, failing roughly a fifth of calls. The
        // cause on the service side is unknown; HTTP/1.1 avoids it entirely.
        //
        // Chunking: a SigV4 `rest-json` request is signed over its whole body and needs a
        // Content-Length to be verified. A chunked body carries neither, so every payload large
        // enough to trip Ballerina's `CHUNKING_AUTO` threshold (e.g. a 4096-dimension vector) is
        // rejected with the same 400, deterministically.
        //
        // Both AWS SDKs default to HTTP/1.1 with an explicit Content-Length for the same reason:
        // the Java SDK v2 pins `Protocol.HTTP1_1`, and botocore sets Content-Length whenever the
        // body length is known while its urllib3 transport offers only "http/1.1" over ALPN.
        //
        // `http:ClientConfiguration` is a closed record that is neither `anydata` nor cloneable, so
        // the two fields are set on the caller's record rather than on a copy.
        httpConfig.httpVersion = http:HTTP_1_1;
        httpConfig.http1Settings.chunking = http:CHUNKING_NEVER;
        // Retries are driven by `invoke`, which re-signs on every attempt. Leaving a caller's
        // `retryConfig` in place would nest the two schedules — `MAX_ATTEMPTS` requests per
        // HTTP-level retry — so the transport's own retries are cleared here.
        httpConfig.retryConfig = ();
        http:Client|http:ClientError httpClient = new (endpointUrl, httpConfig);
        if httpClient is http:ClientError {
            return error ai:Error(
                "Failed to initialize the S3 Vectors vector store: could not create the HTTP client",
                httpClient);
        }
        self.httpClient = httpClient;

        self.contentKey = config.contentKey;
        ai:MetadataFilters? configFilters = config.filters;
        self.filters = configFilters is ai:MetadataFilters ? configFilters.cloneReadOnly() : ();
        self.returnVectorData = config.returnVectorData;
        self.maxListScan = config.maxListScan;

        if !config.validateIndexOnInit {
            self.dimension = ();
            self.distanceMetric = ();
            return;
        }

        IndexAttributes|ai:Error indexAttributes =
            getIndex(self.httpClient, self.credentialProvider, self.host, self.region, self.index);
        if indexAttributes is ai:Error {
            return error ai:Error(
                "Failed to initialize the S3 Vectors vector store: could not read the index " +
                "configuration with GetIndex", indexAttributes);
        }
        self.dimension = indexAttributes.dimension;
        self.distanceMetric = indexAttributes.distanceMetric;

        string[] nonFilterableKeys = indexAttributes.metadataConfiguration?.nonFilterableMetadataKeys ?: [];
        if nonFilterableKeys.indexOf(self.contentKey) is () {
            return error ai:Error(
                string `The S3 Vectors index's content key '${self.contentKey}' is not declared in the ` +
                "index's nonFilterableMetadataKeys. Chunk text routinely exceeds the 2 KB " +
                "filterable-metadata limit, and this setting is immutable after index creation, so the " +
                string `index must be recreated with '${self.contentKey}' included in ` +
                "metadataConfiguration.nonFilterableMetadataKeys — or set a different 'contentKey' in " +
                "this store's Configuration that IS declared non-filterable on the existing index. To " +
                "skip this check (not recommended), set Configuration.validateIndexOnInit to false");
        }
    }

    # Adds vector entries to the index.
    #
    # `PutVectors` is an upsert: an entry whose id matches one already in the index replaces it,
    # the same behaviour `ai:InMemoryVectorStore` documents. Entries without an `id` are assigned
    # a random UUID, and `entry.id` is mutated in place so the caller can see the assigned id
    # afterwards.
    #
    # Batches are sized to stay within both the 500-vector and 20 MiB `PutVectors` request
    # limits. There is no cross-batch transaction: if a batch fails partway through a large
    # `add`, earlier batches have already been committed.
    #
    # + entries - The vector entries to add. An empty array is a no-op — no request is sent
    # + return - An `ai:Error` if any entry is invalid (wrong dimension, non-dense embedding,
    # non-string chunk content, a metadata limit exceeded) or if a batch request fails
    public isolated function add(ai:VectorEntry[] entries) returns ai:Error? {
        if entries.length() == 0 {
            return;
        }

        map<json>[] wireVectors = [];
        foreach ai:VectorEntry entry in entries {
            map<json> wireVector = check mapEntryToWireVector(entry, self.contentKey, self.dimension,
                    self.distanceMetric);
            wireVectors.push(wireVector);
        }

        map<json>[][] batches = batchBySize(wireVectors, MAX_PUT_BATCH_COUNT, MAX_REQUEST_BYTES);
        int completedBatches = 0;
        int completedVectors = 0;
        foreach map<json>[] batch in batches {
            ai:Error? result = putVectors(self.httpClient, self.credentialProvider, self.host, self.region,
                    self.index, batch);
            if result is ai:Error {
                return wrapServiceError(
                    string `Failed to add vectors to S3 Vectors: ${completedBatches} of ${batches.length()} ` +
                    string `batches (${completedVectors} of ${wireVectors.length()} vectors) succeeded before ` +
                    string `this batch failed: ${result.message()}`, result);
            }
            completedBatches += 1;
            completedVectors += batch.length();
        }
    }

    # Searches the index for vectors matching a query.
    #
    # When `query.embedding` is set, this runs an approximate nearest-neighbour search via
    # `QueryVectors`, paginating internally until `topK` results are collected or the index is
    # exhausted. When it is unset — with or without `query.filters` — there is no vector to
    # search with, so `QueryVectors` cannot be used at all; this pages through every vector with
    # `ListVectors` instead and evaluates any filters in Ballerina, bounded by
    # `Configuration.maxListScan`. Matches from this path get `similarityScore: 0.0`, the same
    # convention `ai:InMemoryVectorStore` uses for its own filter-only branches.
    #
    # `Configuration.filters` (if set) is combined with `query.filters` under `AND`.
    #
    # `QueryVectors` is an approximate search, and asking it for very few results makes it
    # explore correspondingly little of the index — a `topK` of 1 was measured returning an
    # empty result for a vector that was certainly stored, on more than half of attempts.
    # Retrying does not help, so this always asks the service for at least 10 results and
    # truncates to `query.topK` locally; callers get the `topK` they asked for.
    #
    # `Embedding` values are `[]` unless `Configuration.returnVectorData` is enabled — S3
    # Vectors' `QueryVectors` never returns vector data, and hydrating it costs an additional
    # batched `GetVectors` call per query.
    #
    # + query - The query: an embedding, metadata filters, both, or neither, plus `topK`
    # (`-1` for all matches — uncapped on the filter-only path, capped at 10,000 when an
    # embedding is given, since that is `QueryVectors`' own ceiling)
    # + return - The matching vectors, most similar first when an embedding was given, or an
    # `ai:Error` if the query is invalid or the underlying request fails
    public isolated function query(ai:VectorStoreQuery query) returns ai:VectorMatch[]|ai:Error {
        int topK = query.topK;
        if topK == 0 {
            return error ai:Error(
                string `Invalid value for topK: ${topK}. It must be a positive integer, or -1 to ` +
                "retrieve all matches");
        }
        if topK > MAX_TOP_K {
            return error ai:Error(
                string `Invalid value for topK: ${topK}. S3 Vectors allows at most ${MAX_TOP_K} results ` +
                "per query");
        }

        ai:MetadataFilters? filters = mergeFilters(self.filters, query.filters);
        ai:Embedding? embedding = query.embedding;

        ai:VectorMatch[]|ai:Error result;
        if embedding is () {
            // -1 means "all" here too, but unlike the QueryVectors path there is no fixed
            // ceiling to cap it at — only `maxListScan` bounds how far this scans.
            result = self.queryByFilterOnly(filters, topK);
        } else if embedding !is ai:Vector {
            return error ai:Error("S3 Vectors supports dense vectors exclusively");
        } else {
            int effectiveTopK = topK < 0 ? MAX_TOP_K : topK;
            result = self.queryByEmbedding(embedding, filters, effectiveTopK);
        }
        if result is ai:Error {
            return result;
        }
        if self.returnVectorData {
            check self.hydrateEmbeddings(result);
        }
        return result;
    }

    // Runs an approximate nearest-neighbour search, paginating on `nextToken` until `topK`
    // results are collected or the response reports no further page. Every page re-sends the
    // same query vector, requested `topK`, and filter, per S3 Vectors' pagination contract for
    // this operation.
    //
    // The value sent to the service is floored at `MIN_QUERY_TOP_K` because QueryVectors' recall
    // degrades sharply at very small `topK` (see the constant); the caller's own `topK` still
    // bounds what this returns, so the surplus is discarded locally.
    private isolated function queryByEmbedding(ai:Vector embedding, ai:MetadataFilters? filters, int topK)
            returns ai:VectorMatch[]|ai:Error {
        json filterJson = ();
        if filters is ai:MetadataFilters {
            map<json> translated = check translateFilters(filters, self.contentKey);
            if translated.length() > 0 {
                filterJson = translated;
            }
        }
        json queryVectorJson = {"float32": embedding};
        int requestedTopK = topK < MIN_QUERY_TOP_K ? MIN_QUERY_TOP_K : topK;

        ai:VectorMatch[] matches = [];
        string? nextToken = ();
        // Ballerina has no post-condition loop, so this pages via an unconditional `while true`
        // that breaks once a response reports no further `nextToken`.
        while true {
            QueryVectorsResponse page = check queryVectors(self.httpClient, self.credentialProvider, self.host,
                    self.region, self.index, queryVectorJson, requestedTopK, filterJson, nextToken);
            string metric = page.distanceMetric ?: (self.distanceMetric ?: "cosine");
            foreach QueryOutputVector item in page.vectors {
                ai:Chunk|ai:Error chunk = metadataToChunk(item.metadata ?: {}, self.contentKey);
                if chunk is ai:Error {
                    // A vector with unreadable content metadata (e.g. written by something
                    // other than this store's `add`) must not sink the whole query for every
                    // other, well-formed match — skip it and keep going.
                    log:printWarn(string `S3 Vectors: skipping vector '${item.key}' in query results: ` +
                            chunk.message());
                    continue;
                }
                ai:Vector emptyEmbedding = [];
                matches.push({
                    id: item.key,
                    embedding: emptyEmbedding,
                    chunk,
                    similarityScore: distanceToScore(item.distance, metric)
                });
                if matches.length() >= topK {
                    return matches;
                }
            }
            nextToken = page.nextToken;
            if nextToken is () {
                break;
            }
        }
        return matches;
    }

    // Pages through the whole index with `ListVectors`, evaluating `filters` locally against
    // each vector's metadata since S3 Vectors cannot filter server-side without a query vector.
    // `topK < 0` collects every match up to `maxListScan`; `topK > 0` stops as soon as that many
    // matches are found (but still counts every vector *scanned*, matched or not, against
    // `maxListScan`).
    private isolated function queryByFilterOnly(ai:MetadataFilters? filters, int topK)
            returns ai:VectorMatch[]|ai:Error {
        log:printWarn(
            "S3 Vectors: running a filter-only query (no embedding). ListVectors has no server-side " +
            "filtering, so this scans the index and evaluates filters locally; it is an O(index size) " +
            "operation bounded by Configuration.maxListScan.");

        ai:VectorMatch[] matches = [];
        int scanned = 0;
        string? nextToken = ();
        while true {
            ListVectorsResponse page = check listVectors(self.httpClient, self.credentialProvider, self.host,
                    self.region, self.index, MAX_LIST_PAGE_SIZE, nextToken);
            foreach ListOutputVector item in page.vectors {
                scanned += 1;
                if scanned > self.maxListScan {
                    return error ai:Error(
                        string `S3 Vectors filter-only query scanned past Configuration.maxListScan ` +
                        string `(${self.maxListScan}) vectors without finishing. Raise maxListScan if ` +
                        "this index is genuinely this large, or add an embedding to the query so " +
                        "QueryVectors can be used instead of scanning with ListVectors");
                }
                map<json> metadata = item.metadata ?: {};
                boolean included = true;
                if filters is ai:MetadataFilters {
                    included = check matchesFilters(metadata, filters);
                }
                if included {
                    ai:Chunk|ai:Error chunk = metadataToChunk(metadata, self.contentKey);
                    if chunk is ai:Error {
                        log:printWarn(string `S3 Vectors: skipping vector '${item.key}' in query results: ` +
                                chunk.message());
                        continue;
                    }
                    ai:Vector emptyEmbedding = [];
                    matches.push({id: item.key, embedding: emptyEmbedding, chunk, similarityScore: 0.0});
                    if topK > 0 && matches.length() >= topK {
                        return matches;
                    }
                }
            }
            nextToken = page.nextToken;
            if nextToken is () {
                break;
            }
        }
        return matches;
    }

    // Hydrates `ai:VectorMatch.embedding` via batched `GetVectors` calls (100 keys/call), only
    // called when `Configuration.returnVectorData` is enabled. Mutates the matches in place
    // rather than rebuilding them, since they are freshly constructed (not readonly) here.
    private isolated function hydrateEmbeddings(ai:VectorMatch[] matches) returns ai:Error? {
        if matches.length() == 0 {
            return;
        }
        // Index matches by id once (O(matches)) rather than rescanning the whole `matches` array
        // for every 100-key GetVectors batch — at topK near S3 Vectors' 10,000 ceiling that
        // rescan would be ~100 batches x 10,000 matches, a million comparisons for one query.
        map<int> matchIndexById = {};
        string[] keys = [];
        foreach int i in 0 ..< matches.length() {
            string? id = matches[i].id;
            if id is string {
                matchIndexById[id] = i;
                keys.push(id);
            }
        }

        foreach string[] batch in chunkStrings(keys, MAX_GET_BATCH_COUNT) {
            GetVectorsResponse response = check getVectors(self.httpClient, self.credentialProvider, self.host,
                    self.region, self.index, batch);
            foreach GetOutputVector item in response.vectors {
                float[]? values = item.data?.float32;
                int? matchIndex = matchIndexById[item.key];
                if values is float[] && matchIndex is int {
                    matches[matchIndex].embedding = values;
                }
            }
        }
    }

    # Deletes vector entries from the index by key.
    #
    # `DeleteVectors` is idempotent: a key that does not exist in the index is not an error. This
    # differs from `ai:InMemoryVectorStore`, which raises one for a missing id.
    #
    # Batches are sized to stay within the 500-key `DeleteVectors` request limit. There is no
    # cross-batch transaction: if a batch fails partway through a large `delete`, earlier batches
    # have already been committed.
    #
    # + ids - The vector key or keys to delete. An empty array is a no-op — no request is sent
    # + return - An `ai:Error` naming how many batches/keys succeeded before a batch failed
    public isolated function delete(string|string[] ids) returns ai:Error? {
        string[] keys = (ids is string) ? [ids] : ids;
        if keys.length() == 0 {
            return;
        }
        string[][] batches = chunkStrings(keys, MAX_DELETE_BATCH_COUNT);
        int completedBatches = 0;
        int completedKeys = 0;
        foreach string[] batch in batches {
            ai:Error? result = deleteVectors(self.httpClient, self.credentialProvider, self.host, self.region,
                    self.index, batch);
            if result is ai:Error {
                return wrapServiceError(
                    string `Failed to delete vectors from S3 Vectors: ${completedBatches} of ` +
                    string `${batches.length()} batches (${completedKeys} of ${keys.length()} keys) succeeded ` +
                    string `before this batch failed: ${result.message()}`, result);
            }
            completedBatches += 1;
            completedKeys += batch.length();
        }
    }
}
