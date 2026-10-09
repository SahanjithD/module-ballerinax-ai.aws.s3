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

// S3 Vectors has no Ballerina connector, so this store calls the service directly over
// `ballerina/http`, signing each request with SigV4 through `ballerinax/aws.auth`. Behaviour that
// differs from other `ai:VectorStore` implementations (dense text chunks only, converted
// similarity scores, filter-only queries scanning the index, idempotent delete) is documented in
// the package README.

# A vector store backed by an Amazon S3 Vectors index.
@display {
    label: "Amazon S3 Vectors Vector Store"
}
public isolated class VectorStore {
    *ai:VectorStore;

    // Every field is `final` and either an isolated object (`http:Client`,
    // `auth:CredentialProvider`) or a readonly value, and nothing is mutated after `init`, so no
    // `lock` blocks are needed anywhere in this class.
    private final http:Client httpClient;
    private final auth:CredentialProvider credentialProvider;
    private final string host;
    private final aws:Region|string region;
    private final readonly & VectorIndex index;
    private final string contentKey;
    private final (readonly & ai:MetadataFilters)? filters;
    private final QueryMode? queryMode;
    private final boolean returnVectorData;
    private final int maxListScan;
    // `()` when `validateIndexOnInit` is `false`. The dimension check on `add` is then skipped
    // rather than guessed at, and the all-zero-vector check (cosine only) is skipped too, since
    // assuming "cosine" would wrongly reject a legitimate all-zero vector on a euclidean index.
    private final int? dimension;
    private final string? distanceMetric;

    # Initializes the S3 Vectors vector store.
    #
    # + connectionConfig - Credentials, region and HTTP settings for reaching S3 Vectors
    # + index - The vector index to store and query vectors in
    # + config - Content key, default filters and other store behaviour
    # + return - An `ai:Error` if the configuration is invalid or the index check fails
    public isolated function init(
            @display {label: "Connection Config"} VectorStoreConnectionConfig connectionConfig,
            @display {label: "Vector Index"} VectorIndex index,
            @display {label: "Vector Store Config"} VectorStoreConfig config = {}) returns ai:Error? {
        check validateVectorIndex(index);
        check validateStoreConfig(config);
        self.index = index.cloneReadOnly();

        [string, string]|ai:Error endpointResult = resolveServiceEndpoint(connectionConfig);
        if endpointResult is ai:Error {
            return error ai:Error("Failed to initialize the S3 Vectors vector store", endpointResult);
        }
        [string, string] [endpointUrl, host] = endpointResult;
        self.host = host;
        self.region = connectionConfig.region;

        http:Client|http:ClientError httpClient = new (endpointUrl, toClientConfiguration(connectionConfig.httpConfig));
        if httpClient is http:ClientError {
            return error ai:Error(
                "Failed to initialize the S3 Vectors vector store: could not create the HTTP client",
                httpClient);
        }
        self.httpClient = httpClient;

        auth:CredentialProvider|auth:CredentialResolutionError provider = new (connectionConfig.auth);
        if provider is auth:CredentialResolutionError {
            return error ai:Error(
                "Failed to initialize the S3 Vectors vector store: could not resolve AWS credentials",
                provider);
        }
        self.credentialProvider = provider;

        self.contentKey = config.contentKey;
        ai:MetadataFilters? configFilters = config.filters;
        self.filters = configFilters is ai:MetadataFilters ? configFilters.cloneReadOnly() : ();
        self.queryMode = config?.queryMode;
        self.returnVectorData = config.returnVectorData;
        self.maxListScan = config.maxListScan;

        if !config.validateIndexOnInit {
            self.dimension = ();
            self.distanceMetric = ();
            return;
        }

        IndexAttributes|ai:Error indexAttributes =
            getIndex(httpClient, provider, host, connectionConfig.region, self.index);
        if indexAttributes is ai:Error {
            closeCredentialProvider(provider);
            return error ai:Error(
                "Failed to initialize the S3 Vectors vector store: could not read the index " +
                "configuration with GetIndex", indexAttributes);
        }
        self.dimension = indexAttributes.dimension;
        self.distanceMetric = indexAttributes.distanceMetric;

        string[] nonFilterableKeys = indexAttributes.metadataConfiguration?.nonFilterableMetadataKeys ?: [];
        if nonFilterableKeys.indexOf(config.contentKey) is () {
            closeCredentialProvider(provider);
            return error ai:Error(
                string `The S3 Vectors index's content key '${config.contentKey}' is not declared in the ` +
                "index's nonFilterableMetadataKeys. Chunk text routinely exceeds the 2 KB " +
                "filterable-metadata limit, and this setting is immutable after index creation, so the " +
                string `index must be recreated with '${config.contentKey}' included in ` +
                "metadataConfiguration.nonFilterableMetadataKeys — or set a different 'contentKey' in " +
                "VectorStoreConfig that IS declared non-filterable on the existing index. To skip this " +
                "check (not recommended), set VectorStoreConfig.validateIndexOnInit to false");
        }
    }

    # Adds vectors to the index. An entry whose id already exists replaces the stored vector, and
    # an entry without an id is given a generated UUID.
    #
    # + entries - The vectors to add, each carrying a text chunk
    # + return - An `ai:Error` if an entry is invalid or a request fails
    public isolated function add(ai:VectorEntry[] entries) returns ai:Error? {
        // `PutVectors` is an upsert. Batches stay within its 500-vector and 20 MiB limits, and there
        // is no cross-batch transaction: if a later batch fails, earlier ones are already committed.
        // `entry.id` is set in place when it was empty, so the caller can see the generated id.
        if entries.length() == 0 {
            return;
        }

        map<json>[] wireVectors = [];
        foreach ai:VectorEntry entry in entries {
            map<json> wireVector = check mapEntryToWireVector(entry, self.contentKey, self.dimension,
                    self.distanceMetric);
            wireVectors.push(wireVector);
        }

        map<json>[][] batches = batchBySize(wireVectors, MAX_PUT_BATCH_COUNT, MAX_PUT_PAYLOAD_BYTES);
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

    # Searches the index by embedding, by metadata filters, or both.
    #
    # + query - The embedding, filters and number of results to return
    # + return - The matches, most similar first, or an `ai:Error` if the query is invalid or fails
    public isolated function query(ai:VectorStoreQuery query) returns ai:VectorMatch[]|ai:Error {
        // With an embedding, this runs `QueryVectors`. Without one (a filter-only query, or the
        // shape `deleteByFilter` issues) `QueryVectors` cannot be used, so the index is paged with
        // `ListVectors` and filters are evaluated locally, bounded by `maxListScan`; those matches
        // get `similarityScore: 0.0`, as in `ai:InMemoryVectorStore`. Store-level filters are
        // combined with the query's under `AND`. `topK: -1` means all matches (capped at
        // `MAX_TOP_K` with an embedding). Embeddings are `[]` unless `returnVectorData` is set.
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
        // The filter-only path already asked `ListVectors` for vector data.
        if self.returnVectorData && embedding !is () {
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
                    self.region, self.index, queryVectorJson, requestedTopK, filterJson, self.queryMode, nextToken);
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
        if filters is ai:MetadataFilters {
            // Validate once up front with the same rules the `QueryVectors` path applies, so a bad
            // filter fails the same way on both paths, even against an empty index.
            _ = check translateFilters(filters, self.contentKey);
        }
        log:printDebug("S3 Vectors: running a filter-only query; scanning the index with ListVectors",
                maxListScan = self.maxListScan);

        ai:VectorMatch[] matches = [];
        int scanned = 0;
        string? nextToken = ();
        while true {
            ListVectorsResponse page = check listVectors(self.httpClient, self.credentialProvider, self.host,
                    self.region, self.index, MAX_LIST_PAGE_SIZE, self.returnVectorData, nextToken);
            foreach ListOutputVector item in page.vectors {
                scanned += 1;
                if scanned > self.maxListScan {
                    return error ai:Error(
                        string `S3 Vectors filter-only query scanned past VectorStoreConfig.maxListScan ` +
                        string `(${self.maxListScan}) vectors without finishing. Raise maxListScan if ` +
                        "this index is genuinely this large, or add an embedding to the query so " +
                        "QueryVectors can be used instead of scanning with ListVectors");
                }
                map<json> metadata = item.metadata ?: {};
                if filters is ai:MetadataFilters && !check matchesFilters(metadata, filters) {
                    continue;
                }
                ai:Chunk|ai:Error chunk = metadataToChunk(metadata, self.contentKey);
                if chunk is ai:Error {
                    log:printWarn(string `S3 Vectors: skipping vector '${item.key}' in query results: ` +
                            chunk.message());
                    continue;
                }
                ai:Vector embedding = item.data?.float32 ?: [];
                matches.push({id: item.key, embedding, chunk, similarityScore: 0.0});
                if topK > 0 && matches.length() >= topK {
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

    // Hydrates `ai:VectorMatch.embedding` via batched `GetVectors` calls (100 keys/call), only
    // called when `VectorStoreConfig.returnVectorData` is enabled. Mutates the matches in place
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

    # Releases the AWS credential provider, stopping any background credential refresh. Call it
    # when the store is no longer needed.
    #
    # + return - An `ai:Error` if the provider could not be released
    public isolated function close() returns ai:Error? {
        error? result = self.credentialProvider.close();
        if result is error {
            return error ai:Error("Failed to close the S3 Vectors vector store", result);
        }
    }

    # Deletes vectors by id. Ids that are not in the index are ignored.
    #
    # + ids - The id, or ids, of the vectors to delete
    # + return - An `ai:Error` if a request fails
    public isolated function delete(string|string[] ids) returns ai:Error? {
        // `DeleteVectors` is idempotent, unlike `ai:InMemoryVectorStore`, which errors on a missing
        // id. Batches hold at most 500 keys, with no cross-batch transaction.
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
