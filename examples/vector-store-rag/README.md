# Vector store RAG

Loads a document corpus out of S3 with `s3:TextDataLoader`, chunks and embeds it, stores the
embeddings in an Amazon S3 Vectors index with `s3:VectorStore`, and answers a question over
it — loader and store from a single `ballerinax/ai.aws.s3` import.

This is the same pipeline as [rag-pipeline](../rag-pipeline), with one line changed: swap
`ai:InMemoryVectorStore` for `s3:VectorStore`. The embeddings now persist in S3 Vectors across
runs instead of being rebuilt in memory every time.

```ballerina
s3:VectorStore vectorStore = check new (
    {auth: {accessKeyId, secretAccessKey}, region},
    {vectorBucketName, indexName: vectorIndexName}
);
ai:VectorKnowledgeBase knowledgeBase = new (vectorStore, embeddingProvider, ai:AUTO);
```

Everything else — `load()` piping straight into `ingest()`, `ai:AUTO` chunking picking a
chunker from the loader's clean MIME types, `retrieve()` returning `ai:QueryMatch[]` — is
identical to `rag-pipeline`, because both loader and store sit behind the same `ballerina/ai`
abstractions.

## Prerequisites

1. An S3 bucket holding the documents to index, and credentials whose IAM policy allows
   `s3:ListBucket` on the bucket and `s3:GetObject` on its objects. See the
   [package README](../../ballerina/README.md#3-grant-the-required-iam-permissions) for a minimal
   policy.
2. **A vector bucket and index already created in Amazon S3 Vectors**, with the `content`
   metadata key declared non-filterable — this cannot be changed after the index is created. See
   the package README's
   [Before you start: create a vector index](../../ballerina/README.md#before-you-start-create-a-vector-index)
   section for the exact AWS CLI commands, and
   [Grant the required IAM permissions](../../ballerina/README.md#grant-the-required-iam-permissions)
   for the `s3vectors:*` policy the credentials above also need.
3. An embedding provider. This example uses `ai:getDefaultEmbeddingProvider()`, the WSO2-hosted
   default, which requires the Ballerina AI runtime configuration described in the
   [`ballerina/ai` documentation](https://central.ballerina.io/ballerina/ai). To use a different
   provider, replace that one line with your own `ai:EmbeddingProvider` — its output dimension
   must match the dimension the vector index was created with.

## Configuration

Create a `Config.toml` in this directory:

```toml
accessKeyId = "<ACCESS_KEY_ID>"
secretAccessKey = "<SECRET_ACCESS_KEY>"
region = "us-east-1"
bucket = "my-corpus-bucket"

# Optional: restrict to a prefix. Defaults to "", the whole bucket.
prefix = "handbook/"

# The S3 Vectors index the embeddings are stored in. Must already exist — see Prerequisites.
vectorBucketName = "my-vector-bucket"
vectorIndexName = "my-index"

# The question asked once the corpus is indexed.
question = "What is the policy on remote work?"

# Required by ai:getDefaultEmbeddingProvider(). Without this the run fails at the
# embedding step. This table must come AFTER the plain keys above — in TOML, every
# key following a table header belongs to that table.
[ballerina.ai.wso2ProviderConfig]
serviceUrl = "<SERVICE_URL>"
accessToken = "<ACCESS_TOKEN>"
```

> `Config.toml` holds live credentials — it is gitignored by this repository. Do not commit it.

## Run the example

```bash
cd examples/vector-store-rag
bal run
```

## Expected output

```text
Loaded documents from S3.
Ingested the corpus into the S3 Vectors index.

Question: What is the policy on remote work?

Top 2 matching passage(s):

  from  : handbook/policies.md
  score : 0.8814
  text  : ## Remote work  Employees may work remotely up to three days per week...

  from  : handbook/onboarding.pdf
  score : 0.7421
  text  : New joiners should agree a working pattern with their manager during...
```

## Notes

- **Re-running this example adds a second copy of every chunk.** `VectorKnowledgeBase.ingest`
  never sets an explicit chunk id, so each run's `add` assigns fresh random ids — nothing is
  deduplicated or replaced. Delete the vectors (or the whole index) between runs if that matters.
- **The dimension must match.** `s3:VectorStore.init` reads the index's configured dimension back
  with `GetIndex` by default and rejects any embedding of the wrong size — including the very
  first `add` during ingest — with a clear error rather than a generic AWS validation failure.
- **`similarityScore` here is a converted value**, not S3 Vectors' raw returned distance — see
  the package README's
  [Limitations](../../ballerina/README.md#limitations-1) section for the exact conversion and
  why it differs from `ai:InMemoryVectorStore`'s own Euclidean handling.
- Chunks stay traceable to their object the same way as in `rag-pipeline`: the loader records
  `bucket`, `key` and `eTag` as open metadata fields, which the vector store round-trips through
  S3 Vectors' metadata alongside the chunk text.
- Deleting by metadata filter (`ai:VectorKnowledgeBase.deleteByFilter`) works against this store,
  but unlike a normal similarity query it has to scan the whole index with `ListVectors` — see
  the package README for the `maxListScan` safety cap on that path.
