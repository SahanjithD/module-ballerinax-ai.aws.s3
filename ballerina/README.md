## Overview

This package provides two building blocks for RAG pipelines on AWS: a data loader for
[AWS S3](https://aws.amazon.com/s3/) and a vector store for
[Amazon S3 Vectors](https://aws.amazon.com/s3/features/vectors/) — AWS's own vector storage and
similarity-search service. Together they let a whole pipeline (load, chunk, embed, store, query)
come from this one import.

`s3:TextDataLoader` reads objects from S3 buckets and returns them as `ai:TextDocument` values,
ready to be chunked, embedded, and indexed. It implements the `ai:DataLoader` abstraction, so it
can be used anywhere an `ai:DataLoader` is expected and its output feeds directly into
`ai:KnowledgeBase.ingest`. Natively-textual objects are decoded directly; PDF, Word (`.docx`),
PowerPoint (`.pptx`) and Excel (`.xlsx`) documents have their text extracted **in memory** —
object content is never written to disk.

`s3:VectorStore` implements `ai:VectorStore`, storing and querying vector embeddings in an
Amazon S3 Vectors index. See [Vector store](#vector-store) below.

## Prerequisites

### 1. Create an S3 bucket

Create a bucket and upload the documents you want to index, following the
[AWS S3 getting-started guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/GetStartedWithS3.html).

### 2. Obtain credentials

The loader authenticates in one of two ways:

- **Static credentials** — an access key pair for an IAM user or role, optionally with a session
  token for temporary (STS) credentials. See
  [Managing access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html).
- **EC2/ECS IAM role** — no keys at all; credentials are resolved from the AWS infrastructure the
  code runs on. An ECS task role is resolved through the ECS container credential endpoint, while an
  EC2 instance profile is resolved through the EC2 Instance Metadata Service (IMDS). This works only
  when running on AWS infrastructure with an attached instance or task role.

### 3. Grant the required IAM permissions

The loader only ever reads. It needs exactly two actions:

| Action | Applied to | Why |
|---|---|---|
| `s3:ListBucket` | the **bucket** ARN | to enumerate keys under a prefix |
| `s3:GetObject` | the **object** ARN (`/*`) | to download object content |

A minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucketContents",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::my-corpus-bucket"
    },
    {
      "Sid": "ReadObjects",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::my-corpus-bucket/*"
    }
  ]
}
```

To restrict access to a single prefix, narrow the `GetObject` resource to
`arn:aws:s3:::my-corpus-bucket/reports/*` and add an `s3:prefix` condition to the `ListBucket`
statement.

## Quickstart

### Step 1: Import the module

```ballerina
import ballerinax/ai.aws.s3;
```

### Step 2: Create a loader

```ballerina
s3:TextDataLoader loader = check new (
    {
        auth: {
            accessKeyId: "<ACCESS_KEY_ID>",
            secretAccessKey: "<SECRET_ACCESS_KEY>"
        },
        region: "us-east-1"
    },
    [
        {
            bucket: "my-corpus-bucket",
            paths: ["reports/"],
            recursive: true
        }
    ]
);
```

### Step 3: Load the documents

```ballerina
import ballerina/ai;

ai:Document[]|ai:Document documents = check loader.load();
```

`load()` returns a **bare `ai:Document`** when exactly one object is resolved and an
`ai:Document[]` otherwise — the same contract as `ai`'s built-in `TextDataLoader`. Both shapes are
accepted directly by `ingest`:

```ballerina
check knowledgeBase.ingest(documents);
```

## Configuration

### Connection

The loader's first argument is either an
[`s3:ConnectionConfig`](https://central.ballerina.io/ballerinax/aws.s3/latest#ConnectionConfig)
— the `ballerinax/aws.s3` connector's own configuration, from which the loader builds a client —
or an already-configured `s3:Client` you want it to reuse.

`ConnectionConfig` has two fields: `auth` and `region`.

| Field | Type | Default | Description |
|---|---|---|---|
| `auth` | `auth:AuthConfig` — e.g. `auth:StaticAuthConfig \| auth:ProfileAuthConfig \| auth:DEFAULT_CREDENTIALS` (from `ballerinax/aws.auth`) | — | How to authenticate (see below) |
| `region` | `Region` | `US_EAST_1` (`"us-east-1"`) | **Must match the region each bucket was created in** — a mismatch fails with an opaque `PermanentRedirect` error. The bucket's region is shown in the S3 console's Buckets list |

```ballerina
import ballerinax/aws.auth as awsAuth;
import ballerinax/aws.s3 as awsS3;

// Static credentials (an access key pair)
awsS3:ConnectionConfig config = {
    auth: {accessKeyId: "AKIA...", secretAccessKey: "..."},
    region: "us-east-1"
};

// Temporary (STS) credentials add a session token
awsS3:ConnectionConfig config = {
    auth: {accessKeyId: "ASIA...", secretAccessKey: "...", sessionToken: "..."},
    region: "us-east-1"
};

// AWS default credential chain — environment variables, ECS container credentials,
// and EC2/ECS instance-profile (IAM role) credentials, resolved automatically
awsS3:ConnectionConfig config = {auth: awsAuth:DEFAULT_CREDENTIALS, region: "us-east-1"};

// A named profile from the shared AWS credentials file
awsS3:ConnectionConfig config = {auth: {profileName: "prod"}, region: "us-east-1"};
```

**Prefer `DEFAULT_CREDENTIALS` in production** when running on AWS: it resolves the instance or
task role automatically and needs no long-lived keys in configuration. The examples use static
credentials only because they must run anywhere.

#### Reusing an existing client

Passing a ready `s3:Client` lets you share one client across several loaders, or configure the
connector in ways the loader's config does not surface:

```ballerina
awsS3:Client s3Client = check new ({
    auth: {accessKeyId: "AKIA...", secretAccessKey: "..."},
    region: "us-east-1"
});

s3:TextDataLoader loader = check new (s3Client, [{bucket: "my-corpus-bucket"}]);
```

### Sources and paths

A `Source` names a bucket and the paths to read from it. Several sources may be configured in
one loader; their documents are aggregated in the order given.

| `Source` field | Type | Default | Description |
|---|---|---|---|
| `bucket` | `string` | — | The bucket name; must live in the connection's region |
| `paths` | `string[]?` | `()` (omit → whole bucket) | One or more object keys or key prefixes. Omit it to load the whole bucket. See "How paths are resolved" below |
| `recursive` | `boolean` | `false` | Whether to descend into nested prefixes. Applies to every prefix in `paths` |
| `includeExtensions` | `string[]?` | `()` (all types) | Case-insensitive extension allowlist; a leading dot is optional. Applies to every prefix in `paths` |

```ballerina
{
    bucket: "my-corpus-bucket",
    paths: ["reports/2026/", "policies/handbook.md"],
    recursive: true,
    includeExtensions: [".pdf", "docx"]
}
```

`recursive` and `includeExtensions` are set once per source and apply to all of its `paths`. If
different prefixes in the same bucket need different recursion or extension filters, configure them
as separate sources.

### How paths are resolved

S3 has no folders — only keys that happen to contain `/`. So:

- Omitting `paths` (or an empty-string element `""`) loads the **whole bucket** — the listing runs
  with the S3 prefix left off.
- A value ending in `/` is treated as a **prefix**.
- Anything else is tried as an **exact key** first and, if no such key exists, treated as a prefix.
- Keys ending in `/` (the zero-byte "folder" objects the S3 console creates) are always skipped.
- With `recursive: false`, only keys directly under the prefix are loaded — a key whose remainder
  after the prefix contains another `/` is skipped.

An unsupported file type named **explicitly** as an exact key is an error. An unsupported file
found while **walking a prefix** is skipped with a logged warning, so one stray image cannot fail
an entire corpus load.

> **Collision to be aware of:** if a bucket holds *both* an object at key `reports` and objects
> under `reports/`, then the path `"reports"` resolves the single object and ignores the folder
> entirely — the exact-key match wins and there is no error. Use `"reports/"` when you
> mean the prefix.

### Loader options (`LoaderOptions`)

| Field | Type | Default | Description |
|---|---|---|---|
| `maxObjectSize` | `int` | `104857600` (100 MiB) | Largest single object read into memory; a bigger object fails with a clear error rather than risking an out-of-memory condition |

```ballerina
s3:TextDataLoader loader = check new (connectionConfig, sources,
        {maxObjectSize: 20 * 1024 * 1024});
```

Like the SharePoint data loader, there is **no document-count cap** — `load()` returns every
matching object. See Limitations for the memory implication.

## Supported file types

The supported set matches `ballerina/ai`'s built-in `TextDataLoader` exactly, plus the
natively-textual formats S3 buckets commonly hold.

| Type | Extensions | How the text is obtained |
|---|---|---|
| Markup | `md`, `markdown`, `html`, `htm` | Decoded verbatim (tags and all); stripping is the chunker's job |
| Plain text | `txt`, `text`, `csv`, `tsv`, `json`, `xml`, `yaml`, `yml`, `log`, `ini`, `conf`, `properties`, `css`, `js`, `ts` | Decoded directly as UTF-8 |
| PDF | `pdf` | Apache Tika `PDFParser` + PDFBox, in memory |
| Word | `docx` | Apache POI `XWPFWordExtractor`, in memory |
| PowerPoint | `pptx` | Apache POI `SlideShowExtractor`, in memory |
| Excel | `xlsx` | Apache POI `XSSFExcelExtractor`, in memory — tab-separated cells, one row per line, each sheet prefixed with its name |
| **Legacy binary Office** | `doc`, `ppt`, `xls` | **Not supported** — convert to the OOXML `.docx` / `.pptx` / `.xlsx` or PDF |
| Anything else | images, audio, unknown binary | Skipped (an error if named explicitly) |

Object metadata is attached to every document: `fileName` (the key), `mimeType`, `fileSize`,
`modifiedAt`, plus the open fields `bucket`, `key`, and `eTag`.

## Limitations

Please read these before indexing a large or busy bucket.

- **The whole matching corpus is read into memory.** There is no document-count cap (matching the
  SharePoint data loader); the loader paginates across every listing page and materializes every
  document, because `ai:DataLoader.load()` returns a `Document[]` — there is no streaming or cursor
  in the interface. A very large prefix therefore produces a correspondingly large in-memory
  result. Narrow the `path`, or split the work across several loads, if that is a concern.
- **A prefix walk is bounded at 10,000 listing pages.** That ceiling is a safety net, not a document
  cap: it guarantees the walk terminates whatever the listing returns, and reaching it is an error
  rather than a partial corpus. Ten thousand pages covers ten million listed entries — counting both
  objects and, for a non-recursive walk, the sub-folders S3 rolls into CommonPrefixes — so no
  listing this loader could return in memory comes close. A walk that hits it needs a narrower
  `path`.
- **Skipped objects are reported only to the log.** Archived, over-sized, undecodable and
  unsupported objects are skipped with a warning so that one bad object cannot fail a whole corpus,
  but `load()` returns a shorter array with no programmatic signal. A caller cannot distinguish
  "nothing matched" from "several objects were skipped" without reading the logs.
- **`load()` has no overall time limit.** The paging loop always terminates, but `ballerinax/aws.s3`
  4.0.0 exposes no timeout, retry or HTTP configuration on `ConnectionConfig`, so a stalled
  connection blocks the call indefinitely. Apply a deadline on the calling side if you need one.
- **S3 Express One Zone (directory) buckets are not usable.** Every object in one reports the
  `EXPRESS_ONEZONE` storage class, which is absent from the connector's `StorageClass` enum, so
  listing and metadata calls fail to deserialize. The exact-key path is designed to work on them —
  HEAD is order-independent, which unordered directory-bucket listings require — and needs no change
  here once the connector is fixed.
- **A listing is not a consistent snapshot.** S3 read and list operations are strongly consistent,
  but a paginated load is not an atomic snapshot: the loader pages through a listing, and concurrent
  writes across page requests can cause objects to be missed or double-counted — inherent to
  paginated listing.
- **Each object is read entirely into memory.** Extraction reads from an in-memory buffer so that
  no temporary file is ever written, but each object must therefore fit in the heap. `maxObjectSize`
  (default 100 MiB) bounds each individual object read; an object larger than that is a clear error
  rather than an attempted load.
- **Non-recursive filtering.** The loader lists with delimiter `/`, so S3 returns only same-level
  keys (descendants roll into `CommonPrefixes`, which the connector drops); a client-side filter
  stays as a backstop.
- **No `versionId` selection.** The loader always reads the current version of each object. The
  underlying connector *can* fetch a specific version, but the loader does not expose it, so a
  corpus cannot be pinned to specific object versions.
- **An exact key is resolved by listing its prefix**, not with a `HEAD`, to avoid a download just
  to test existence. Functionally transparent; noted for cost accounting on very large prefixes.
- **Legacy binary Office formats are unsupported.** `.doc`, `.ppt` and `.xls` are recognised only
  so they can be rejected with a format-specific message or skipped. Convert them to their OOXML
  successors (`.docx`/`.pptx`/`.xlsx`) or PDF. The OOXML `.xlsx` is extracted via POI's
  `XSSFExcelExtractor`: cells are rendered tab-separated, one row per line, each sheet prefixed with
  its name, and formula cells contribute their last cached result.
- **One unreadable object fails the whole load.** If an object is deleted between being listed
  and being downloaded, or its content cannot be decoded or parsed, the entire `load()` returns an
  error rather than skipping it. This is deliberate — a silently incomplete RAG index is worse
  than a failed one — but it means a corpus in flux may need a retry. (Objects of *unsupported
  types* are skipped, not failed; this applies to genuine read/parse failures.)
- **No requester-pays support.** The connector's configuration exposes no requester-pays option,
  so cross-account requester-pays buckets cannot be read.
- **AWS endpoints only.** The connector's `ConnectionConfig` takes a `region` but no endpoint
  override, so S3-compatible services (MinIO, LocalStack, Cloudflare R2) cannot be targeted.
- **All buckets in one loader share one region**, since the region is set on the connection. A
  bucket in a different region fails with an opaque AWS redirect error; use one loader per region.

## Vector store

`s3:VectorStore` implements `ai:VectorStore`, backed by
[Amazon S3 Vectors](https://aws.amazon.com/s3/features/vectors/) — AWS's own vector storage and
similarity-search service, in the same `s3vectors` namespace family as S3 itself but a distinct
service with its own endpoint and IAM actions. It exists alongside the data loader so a full RAG
pipeline can come from this one import: load documents from S3, chunk and embed them, and store
the vectors back in S3 Vectors.

There is no Ballerina connector for `s3vectors` (`ballerinax/aws.s3` is object storage only), so
`VectorStore` talks to the service directly over `ballerina/http`, signing every request with AWS
Signature Version 4 via `ballerinax/aws.auth`.

### Before you start: create a vector index

Unlike the loader, the vector store does not create its target for you — a vector bucket and
index must already exist, and **two of the index's settings are immutable once created**:

- **Dimension** and **distance metric** (`cosine` or `euclidean`) are fixed for the life of the
  index and must match your embedding model's output.
- **The chunk's text content must be stored as a non-filterable metadata key.** S3 Vectors caps
  *filterable* metadata at 2 KB per vector — far below what chunk text routinely needs — while
  *non-filterable* metadata has a much larger 40 KB budget. `VectorStore` stores chunk text under
  the metadata key named by `Configuration.contentKey` (`"content"` by default), and **that key
  must be declared in the index's `nonFilterableMetadataKeys` at creation time**. Getting this
  wrong means deleting and recreating the index — it cannot be changed afterwards.

Create the vector bucket and index with the AWS CLI:

```bash
aws s3vectors create-vector-bucket --vector-bucket-name my-vector-bucket

aws s3vectors create-index \
    --vector-bucket-name my-vector-bucket \
    --index-name my-index \
    --data-type float32 \
    --dimension 1024 \
    --distance-metric cosine \
    --metadata-configuration '{"nonFilterableMetadataKeys": ["content"]}'
```

By default, `VectorStore.init` calls `GetIndex` once at startup and fails with an actionable
message if the content key was left filterable — see `Configuration.validateIndexOnInit` below.

### Grant the required IAM permissions

| Action | Needed for |
|---|---|
| `s3vectors:PutVectors` | `add` |
| `s3vectors:QueryVectors` | `query` with an embedding |
| `s3vectors:GetVectors` | **Also required** whenever a query requests metadata or applies a filter — which this store always does, since the chunk lives in metadata. Its absence is the most common cause of a 403 here |
| `s3vectors:DeleteVectors` | `delete` |
| `s3vectors:ListVectors` | `query` with no embedding (the filter-only / `deleteByFilter` path) |
| `s3vectors:GetIndex` | `init`, when `validateIndexOnInit` is `true` (the default) |

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3VectorsAccess",
      "Effect": "Allow",
      "Action": [
        "s3vectors:PutVectors",
        "s3vectors:QueryVectors",
        "s3vectors:GetVectors",
        "s3vectors:DeleteVectors",
        "s3vectors:ListVectors",
        "s3vectors:GetIndex"
      ],
      "Resource": "arn:aws:s3vectors:us-east-1:123456789012:bucket/my-vector-bucket/index/my-index"
    }
  ]
}
```

### Quickstart

#### Step 1: Import the module

```ballerina
import ballerinax/ai.aws.s3;
```

#### Step 2: Create the store

```ballerina
s3:VectorStore vectorStore = check new (
    {
        auth: {
            accessKeyId: "<ACCESS_KEY_ID>",
            secretAccessKey: "<SECRET_ACCESS_KEY>"
        },
        region: "us-east-1"
    },
    {vectorBucketName: "my-vector-bucket", indexName: "my-index"}
);
```

#### Step 3: Use it as an `ai:VectorStore`

```ballerina
import ballerina/ai;

check vectorStore.add([
    {embedding: [0.12, 0.98, /* ... */], chunk: {'type: "text-chunk", content: "..."}}
]);

ai:VectorMatch[] matches = check vectorStore.query({embedding: queryEmbedding, topK: 5});

check vectorStore.delete(["vector-id-1"]);
```

Or hand it to `ai:VectorKnowledgeBase` and let `ballerina/ai` drive chunking, embedding, and
retrieval:

```ballerina
ai:VectorKnowledgeBase knowledgeBase = new (vectorStore, embeddingModel);
check knowledgeBase.ingest(documents);
```

### Configuration

#### Connection (`VectorStoreConnectionConfig`)

| Field | Type | Default | Description |
|---|---|---|---|
| `auth` | `auth:AuthConfig` | `auth:DEFAULT_CREDENTIALS` | Same credential shapes as the loader's `ConnectionConfig` — see Prerequisites above |
| `region` | `aws:Region \| string` | `US_EAST_1` | Must match the region the vector bucket was created in. **S3 Vectors is not available in every AWS region** — check current availability before choosing one |
| `serviceUrl` | `string?` | resolved from `region` | Overrides the resolved endpoint (scheme included). For testing against a local or proxied endpoint only |
| `fips` | `boolean` | `false` | Must stay `false`. AWS publishes no FIPS endpoint for S3 Vectors in any region (unlike S3 proper), so setting it is rejected at initialization. If a FIPS-validated path is required, put a FIPS-terminating endpoint in front of the service and set `serviceUrl` to it |

#### Index (`IndexIdentifier`)

Identify the target index one of two ways — not both:

| Field | Type | Description |
|---|---|---|
| `vectorBucketName` + `indexName` | `string?` | The bucket and index name, together |
| `indexArn` | `string?` | The index ARN, on its own |

#### Store behaviour (`Configuration`)

| Field | Type | Default | Description |
|---|---|---|---|
| `contentKey` | `string` | `"content"` | The metadata key chunk text is stored under. Must be declared non-filterable on the index — see above |
| `filters` | `ai:MetadataFilters?` | `()` | Applied to every query, combined with any per-query filters under `AND` |
| `returnVectorData` | `boolean` | `false` | Whether `query` issues a follow-up `GetVectors` call to populate `ai:VectorMatch.embedding`. `QueryVectors` never returns vector data on its own; enabling this roughly doubles request volume and cost |
| `maxListScan` | `int` | `100000` | Cap on how many vectors a filter-only query (no embedding — the shape `deleteByFilter` issues) will scan via `ListVectors` before failing, since S3 Vectors cannot filter server-side without a query vector |
| `validateIndexOnInit` | `boolean` | `true` | Whether `init` reads the index configuration back with `GetIndex` and validates the content key up front |

### Limitations

- **Dense vectors only.** S3 Vectors has no sparse or hybrid index type. `add` and `query` reject
  anything other than a plain `ai:Vector` (`float[]`) embedding.
- **Text chunks only.** A vector's content is stored as metadata, which must be JSON — so
  `chunk.content` must be a `string`. Image, audio, file and binary chunks are rejected.
- **A query with no embedding scans the index.** `QueryVectors` requires a query vector and
  cannot filter without one, so a query carrying only metadata filters — or neither, the shape
  `ai:VectorKnowledgeBase.deleteByFilter` issues — pages through every vector with `ListVectors`
  and evaluates filters in Ballerina, bounded by `Configuration.maxListScan`. This is the only way
  `deleteByFilter` can work against this store at all, but it is an O(index size) operation on a
  large index.
- **`EQUAL` against array-valued metadata can disagree between the two filter paths.** Server-side,
  S3 Vectors' `$eq` matches an array-valued metadata field if *any* element equals the filter
  value. The local filter evaluator used by the no-embedding path above (and so `deleteByFilter`)
  instead does a plain `==` against the whole stored value. A filter on a custom `ai:Metadata`
  field that holds a JSON array can therefore match different vectors depending on whether the
  query carried an embedding or not.
- **`similarityScore` is a converted value, not the raw S3 Vectors distance.** S3 Vectors returns
  a distance (lower is more similar); `ai:VectorMatch.similarityScore` must be higher-is-better.
  For `cosine`, `1.0 - distance` recovers the true cosine similarity. For `euclidean`,
  `1.0 / (1.0 + distance)` preserves rank order but is **not** numerically the same convention
  `ai:InMemoryVectorStore` uses for that metric (it returns the raw Euclidean distance, which
  inverts the ordering) — rank-order correctness was chosen over bit-for-bit consistency with
  that inversion.
- **Timestamps are stored as epoch-seconds numbers, not ISO-8601 strings.** `ai:Metadata`'s
  `createdAt`/`modifiedAt` are `time:Utc` values; S3 Vectors' `$gt`/`$gte`/`$lt`/`$lte` range
  operators only accept numbers, so encoding them as date strings (as the Pinecone vector store
  does) would leave range filters on dates silently non-functional. A filter written against
  either key must use an epoch-seconds number to match what was stored.
- **`embedding` is empty unless `returnVectorData` is enabled.** `QueryVectors` never returns
  vector data; see Configuration above.
- **`delete` is idempotent.** Deleting a key that does not exist in the index is not an error,
  unlike `ai:InMemoryVectorStore`, which raises one for a missing id.
- **No index management.** Creating, deleting or listing vector buckets and indexes is out of
  scope for this store — see "Before you start" above for creating one with the AWS CLI.
- **Metadata limits are AWS's, enforced client-side where practical.** Up to 40 KB total metadata
  per vector, 2 KB filterable, 50 keys, key names up to 63 characters, vector keys up to 1,024
  characters. `add` validates these before sending and names the offending vector's key in the
  error, rather than surfacing an opaque `ValidationException`.
- **No S3 Vectors emulator exists**, so this store's transport layer is tested against an
  in-process mock HTTP service rather than a live endpoint or LocalStack. Verify against a real
  vector bucket before relying on it in production.

## Examples

The `ai.aws.s3` connector provides practical examples illustrating usage in various scenarios.

1. [Minimal load](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/tree/main/examples/minimal-load)
   — load documents from a bucket and inspect what came back.
2. [RAG pipeline](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/tree/main/examples/rag-pipeline)
   — load a corpus, ingest it into a knowledge base, and answer questions over it.
3. [Vector store RAG](https://github.com/ballerina-platform/module-ballerinax-ai.aws.s3/tree/main/examples/vector-store-rag)
   — load a corpus with `s3:TextDataLoader` and store its embeddings in `s3:VectorStore`,
   loader and store from a single import.
