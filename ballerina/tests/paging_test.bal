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
import ballerinax/aws.s3;

// The prefix-walk paging loop, driven offline against a mocked `s3:Client`.
//
// `TextDataLoader.init` accepts `ConnectionConfig|s3:Client`, and `s3:Client` is a public client
// class, so a default mock substitutes for it with no network. That matters: this loop is where
// both of the loader's serious defects have lived, and neither was reachable by any other test —
// a live walk of a small prefix completes in one page and never executes the paging branches at
// all. Everything here runs in milliseconds; the equivalent live test needs a 1001-key bucket and
// several minutes.
//
// What these tests cannot see: the connector's native layer is replaced wholesale, so they prove
// how the loader *reacts* to a response shape, never that S3 or the connector *produces* it.

const string PAGING_BUCKET = "paging-test-bucket";

// Builds one listing entry. Size defaults non-zero so entries look like real objects.
isolated function obj(string key, int size = 12) returns s3:S3Object =>
    {key, size, lastModified: "2026-01-01T00:00:00Z", eTag: "\"abc\"", storageClass: s3:STANDARD};

// Builds one normalized listing entry, for asserting `includeInPrefixWalk` directly.
isolated function itemOf(string key, int size) returns S3Item =>
    {key, size, eTag: "abc", lastModified: "2026-01-01T00:00:00Z", storageClass: s3:STANDARD};

// Builds one listing page.
isolated function pageOf(s3:S3Object[] objects, boolean truncated = false, string? token = ()) returns
        s3:ListObjectsResponse {
    s3:ListObjectsResponse page = {objects, count: objects.length(), isTruncated: truncated};
    if token is string {
        page.nextContinuationToken = token;
    }
    return page;
}

// A byte stream over fixed content, standing in for `getObject`'s stream return.
isolated function contentStream(string text) returns stream<byte[], error?> {
    ChunkIterator iterator = new ([text.toBytes()]);
    return new (iterator);
}

isolated class ChunkIterator {
    private final byte[][] chunks;
    private int index = 0;

    isolated function init(byte[][] chunks) {
        self.chunks = chunks.clone();
    }

    public isolated function next() returns record {|byte[] value;|}|error? {
        lock {
            if self.index >= self.chunks.length() {
                return ();
            }
            int current = self.index;
            self.index += 1;
            return {value: self.chunks[current].clone()};
        }
    }
}

// Generates `count` object entries keyed `<prefix>NNNNN.txt`, lexicographically ordered as S3
// would return them.
isolated function manyObjects(string prefix, int count, int startAt = 0) returns s3:S3Object[] {
    s3:S3Object[] objects = [];
    foreach int i in startAt ..< startAt + count {
        objects.push(obj(string `${prefix}${i.toString().padZero(5)}.txt`));
    }
    return objects;
}

isolated function loaderOver(s3:Client s3Client, string path, boolean recursive = false,
        LoaderOptions options = {}) returns TextDataLoader|ai:Error =>
    new (s3Client, [{bucket: PAGING_BUCKET, paths: [path], recursive}], options);

isolated function documentsOf(ai:Document[]|ai:Document loaded) returns ai:Document[] =>
    loaded is ai:Document[] ? loaded : [loaded];

// ---------------------------------------------------------------------------
// M1 — the arguments actually put on the wire
// ---------------------------------------------------------------------------

// Pins the exact `ListObjectsConfig` the loader sends, on both the first request and the
// continuation. This is the direct regression guard for the defect that made every prefix walk an
// unfiltered whole-bucket listing that paged forever: the config reached `listObjects` empty, so
// `prefix`, `delimiter` and `continuationToken` never went to S3. `withArguments` fails the mock
// if anything but these records arrives, so a silent argument loss cannot pass here.
//
// It cannot prove the connector then transmits them — that defect lived below this seam and needs
// the live multi-page walk to close.
@test:Config {}
function testPrefixAndTokenAreSentToListObjects() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    s3:ListObjectsConfig firstRequest = {maxKeys: 1000, prefix: "docs/", delimiter: "/"};
    s3:ListObjectsConfig secondRequest = {maxKeys: 1000, prefix: "docs/", delimiter: "/",
        continuationToken: "TOKEN-1"};

    test:prepare(mockClient).when("listObjects").withArguments(PAGING_BUCKET, firstRequest)
        .thenReturn(pageOf([obj("docs/a.txt")], true, "TOKEN-1"));
    test:prepare(mockClient).when("listObjects").withArguments(PAGING_BUCKET, secondRequest)
        .thenReturn(pageOf([obj("docs/b.txt")]));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("hello"));

    TextDataLoader loader = check loaderOver(mockClient, "docs/");
    ai:Document[] documents = documentsOf(check loader.load());
    test:assertEquals(documents.length(), 2,
            "Both pages must be walked when the continuation token is sent correctly");
}

// The recursive/non-recursive distinction is server-side: a recursive walk must send no delimiter
// at all, so S3 returns descendant keys rather than rolling them into CommonPrefixes.
@test:Config {}
function testRecursiveWalkSendsNoDelimiter() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    s3:ListObjectsConfig recursiveRequest = {maxKeys: 1000, prefix: "docs/"};

    test:prepare(mockClient).when("listObjects").withArguments(PAGING_BUCKET, recursiveRequest)
        .thenReturn(pageOf([obj("docs/nested/deep.txt")]));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("deep"));

    TextDataLoader loader = check loaderOver(mockClient, "docs/", true);
    ai:Document[] documents = documentsOf(check loader.load());
    test:assertEquals(documents.length(), 1, "A recursive walk must descend into sub-prefixes");
}

// ---------------------------------------------------------------------------
// M2 — paging crosses the page boundary
// ---------------------------------------------------------------------------

// A full 1000-key page followed by a 1-key page must yield 1001 documents. A result of exactly
// 1000 would mean the second page was dropped — the regression the live `expensive` test exists to
// catch, reproduced here in milliseconds instead of ~6 minutes and 1001 seeded objects.
@test:Config {}
function testPagingCrossesThePageBoundary() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("listObjects").thenReturnSequence(
        pageOf(manyObjects("many/", 1000), true, "TOKEN-1"),
        pageOf(manyObjects("many/", 1, 1000))
    );
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("x"));

    TextDataLoader loader = check loaderOver(mockClient, "many/");
    ai:Document[] documents = documentsOf(check loader.load());
    test:assertEquals(documents.length(), 1001,
            "A >1000-key prefix must be paged through completely, not truncated at one page");
}

// A page carrying no objects but reporting more results is legitimate: with a delimiter, S3 counts
// CommonPrefixes against the same 1000-entry budget, and the connector does not surface them, so
// a folder-heavy prefix genuinely returns object-less pages. The walk must continue rather than
// stop early or fail.
@test:Config {}
function testObjectLessTruncatedPagesDoNotStopTheWalk() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("listObjects").thenReturnSequence(
        pageOf([], true, "TOKEN-1"),
        pageOf([], true, "TOKEN-2"),
        pageOf([], true, "TOKEN-3"),
        pageOf([obj("wide/finally.txt")])
    );
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("found"));

    TextDataLoader loader = check loaderOver(mockClient, "wide/");
    ai:Document[] documents = documentsOf(check loader.load());
    test:assertEquals(documents.length(), 1,
            "Object-less but truncated pages must be paged through, not treated as the end");
}

// ---------------------------------------------------------------------------
// M3 — the loop always terminates
// ---------------------------------------------------------------------------

// A listing that re-serves the same page forever must be caught, not looped on. This is the exact
// shape of the original defect: every request returned page one, each with a *fresh* continuation
// token, so a token comparison could never detect it. Object keys are unique within a listing, so
// the repeat is what gives it away.
@test:Config {}
function testRepeatedPageIsDetected() {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("listObjects")
        .thenReturn(pageOf([obj("a/one.txt")], true, "FRESH-TOKEN"));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("x"));

    TextDataLoader|ai:Error loader = loaderOver(mockClient, "a/");
    if loader is ai:Error {
        test:assertFail("The loader must construct: " + loader.message());
    }
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    test:assertTrue(result is ai:Error, "A listing that repeats a page must not loop forever");
    if result is ai:Error {
        test:assertTrue(result.message().includes("not advancing"),
                "Unexpected message: " + result.message());
    }
}


// A truncated page must carry a continuation token. Without one the listing cannot be continued,
// and returning the objects read so far would be a silently partial corpus.
@test:Config {}
function testTruncatedPageWithoutTokenFails() {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("listObjects").thenReturn(pageOf([obj("a/one.txt")], true));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("x"));

    TextDataLoader|ai:Error loader = loaderOver(mockClient, "a/");
    if loader is ai:Error {
        test:assertFail("The loader must construct: " + loader.message());
    }
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    test:assertTrue(result is ai:Error, "A truncated page with no token must fail loudly");
    if result is ai:Error {
        test:assertTrue(result.message().includes("no continuation token"),
                "Unexpected message: " + result.message());
    }
}

// A stuck listing that *repeats* a continuation token on object-less pages cannot be caught by the
// key-based check (an empty page offers no key to compare). The seen-token guard rejects it as soon
// as a token is returned a second time — immediately, rather than only at the page ceiling.
@test:Config {}
function testRepeatedContinuationTokenIsRejected() {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("listObjects").thenReturn(pageOf([], true, "TOKEN"));

    TextDataLoader|ai:Error loader = loaderOver(mockClient, "wide/");
    if loader is ai:Error {
        test:assertFail("The loader must construct: " + loader.message());
    }
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    test:assertTrue(result is ai:Error, "A repeated continuation token must fail loudly");
    if result is ai:Error {
        test:assertTrue(result.message().includes("returned twice"),
                "Unexpected message: " + result.message());
    }
}

// The case no key-based or token check can see: object-less pages that report more results forever,
// each with a *fresh* token (so the seen-token guard never fires) — the legitimate folder-heavy
// walk shape. The page ceiling is what bounds this, and it is what makes the loop terminate for
// *any* response sequence. Removing the ceiling makes this test hang.
@test:Config {}
function testEndlessFreshTokenPagesHitTheCeiling() {
    s3:Client mockClient = test:mock(s3:Client, new FreshTokenListClient());

    TextDataLoader|ai:Error loader = loaderOver(mockClient, "wide/");
    if loader is ai:Error {
        test:assertFail("The loader must construct: " + loader.message());
    }
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    test:assertTrue(result is ai:Error, "An endless run of fresh-token pages must be bounded");
    if result is ai:Error {
        test:assertTrue(result.message().includes("page ceiling"),
                "Unexpected message: " + result.message());
    }
}

// Call counter for `FreshTokenListClient`, kept at module level because `test:mock` rejects a mock
// object that carries fields of its own.
isolated int freshTokenCalls = 0;

// A mocked client whose `listObjects` returns an object-less, truncated page with a distinct
// continuation token on every call — the legitimate endless-walk shape the page ceiling bounds.
isolated client class FreshTokenListClient {
    isolated remote function listObjects(string bucketName, *s3:ListObjectsConfig config)
            returns s3:ListObjectsResponse|s3:Error {
        int n;
        lock {
            freshTokenCalls += 1;
            n = freshTokenCalls;
        }
        return pageOf([], true, string `TOKEN-${n}`);
    }
}


// ---------------------------------------------------------------------------
// M4 — a key ending in '/' that actually carries content
// ---------------------------------------------------------------------------

// Nothing in S3 forbids an object whose key ends in `/` from holding content, but the walk dropped
// any such key on the suffix alone. The placeholder filter runs above the per-object paths, so that
// object disappeared without even the warning every other skip logs. Only a zero-byte marker is a
// folder placeholder; one with content must reach the classification path instead.
//
// Asserted on `includeInPrefixWalk` directly, because the distinction is not visible in the
// returned documents: `baseName("p/realdir/")` is `""`, so such a key has no extension, classifies
// as `UNSUPPORTED`, and is skipped either way. What the fix changes is that the skip is now logged
// like every other one rather than being silent — and that a future content-type-based
// classification would see the object at all.
@test:Config {}
function testTrailingSlashKeyIsSkippedOnlyWhenEmpty() {
    test:assertFalse(includeInPrefixWalk(itemOf("p/marker/", 0), "p/", true, ()),
            "A zero-byte '/'-suffixed key is a folder placeholder and must be skipped");
    test:assertTrue(includeInPrefixWalk(itemOf("p/realdir/", 4096), "p/", true, ()),
            "A '/'-suffixed key holding content must not be filtered out on its suffix alone");
}


// ---------------------------------------------------------------------------
// M5 — an extensionless folder marker must not shadow the folder
// ---------------------------------------------------------------------------

// `aws s3api put-object --key reports` and several Hadoop/S3A configurations create a zero-byte
// object keyed exactly `reports`, alongside the real objects under `reports/`. Resolving the path
// as an exact key found that marker, classified it as an unsupported type, and failed the entire
// load — a total failure on a legitimate bucket layout. The marker must fall through to the walk.
@test:Config {}
function testZeroByteMarkerFallsThroughToPrefixWalk() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("doesObjectExist").thenReturn(true);
    test:prepare(mockClient).when("getObjectMetadata").thenReturn(<s3:ObjectMetadata>{
        key: "reports",
        contentLength: 0,
        eTag: "\"d41d8cd98f00b204e9800998ecf8427e\"",
        lastModified: "2026-01-01T00:00:00Z",
        storageClass: s3:STANDARD
    });
    test:prepare(mockClient).when("listObjects").thenReturn(
        pageOf([obj("reports/q1.md"), obj("reports/q2.md")]));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("# report"));

    TextDataLoader loader = check loaderOver(mockClient, "reports");
    ai:Document[] documents = documentsOf(check loader.load());
    test:assertEquals(documents.length(), 2,
            "A zero-byte extensionless marker must not shadow the folder it names");
}

// The converse, so the fallback above cannot pass merely by ignoring exact keys: a named key that
// genuinely carries content and is genuinely unsupported must still fail loudly.
@test:Config {}
function testNamedUnsupportedKeyWithContentStillFails() {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("doesObjectExist").thenReturn(true);
    test:prepare(mockClient).when("getObjectMetadata").thenReturn(<s3:ObjectMetadata>{
        key: "photo.png",
        contentLength: 2048,
        eTag: "\"abc\"",
        lastModified: "2026-01-01T00:00:00Z",
        storageClass: s3:STANDARD
    });

    TextDataLoader|ai:Error loader = loaderOver(mockClient, "photo.png");
    if loader is ai:Error {
        test:assertFail("The loader must construct: " + loader.message());
    }
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    test:assertTrue(result is ai:Error, "A named unsupported key with content must still fail");
    if result is ai:Error {
        test:assertTrue(result.message().includes("photo.png"),
                "Unexpected message: " + result.message());
    }
}

// The marker fallthrough must not swallow a real empty object. `photo.png` at zero bytes is a
// marker candidate by size, but names no folder, so the walk finds nothing — and returning an
// empty array there would hide from the caller that the key they named is unloadable.
@test:Config {}
function testEmptyUnsupportedNamedKeyStillFails() {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("doesObjectExist").thenReturn(true);
    test:prepare(mockClient).when("getObjectMetadata").thenReturn(<s3:ObjectMetadata>{
        key: "photo.png",
        contentLength: 0,
        eTag: "\"abc\"",
        lastModified: "2026-01-01T00:00:00Z",
        storageClass: s3:STANDARD
    });
    test:prepare(mockClient).when("listObjects").thenReturn(pageOf([]));

    TextDataLoader|ai:Error loader = loaderOver(mockClient, "photo.png");
    if loader is ai:Error {
        test:assertFail("The loader must construct: " + loader.message());
    }
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    test:assertTrue(result is ai:Error,
            "A zero-byte unsupported key naming no folder must fail, not return an empty array");
    if result is ai:Error {
        test:assertTrue(result.message().includes("photo.png"),
                "Unexpected message: " + result.message());
    }
}
