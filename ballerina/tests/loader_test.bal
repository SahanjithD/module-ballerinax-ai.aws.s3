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
import ballerina/io;
import ballerina/test;
import ballerinax/aws.s3;

// ---------------------------------------------------------------------------
// Initialization and configuration validation
// ---------------------------------------------------------------------------

// A syntactically valid configuration; no request is issued when a client is built.
isolated function testConnection() returns s3:ConnectionConfig =>
    {auth: {accessKeyId: "AKIAEXAMPLE", secretAccessKey: "secret"}, region: "us-east-1"};

@test:Config {}
isolated function testInitRejectsEmptySources() {
    TextDataLoader|ai:Error loader = new (testConnection(), []);
    test:assertTrue(loader is ai:Error, "Expected an error when no sources are configured");
    if loader is ai:Error {
        test:assertEquals(loader.message(),
                "At least one source must be provided to the AWS S3 data loader");
    }
}

@test:Config {}
isolated function testInitRejectsNonPositiveMaxObjectSize() {
    TextDataLoader|ai:Error loader = new (testConnection(), [{bucket: TEST_BUCKET}], {maxObjectSize: 0});
    test:assertTrue(loader is ai:Error, "Expected an error for a non-positive maxObjectSize");
    if loader is ai:Error {
        test:assertEquals(loader.message(), "maxObjectSize must be at least 1");
    }
}

@test:Config {}
isolated function testInitSucceedsWithValidConfiguration() {
    TextDataLoader|ai:Error loader = new (testConnection(), [{bucket: TEST_BUCKET}]);
    test:assertFalse(loader is ai:Error, "A valid configuration must produce a loader");
}

@test:Config {}
isolated function testInitAcceptsTemporaryCredentials() {
    TextDataLoader|ai:Error loader = new ({
                auth: {
                    accessKeyId: "ASIAEXAMPLE",
                    secretAccessKey: "secret",
                    sessionToken: "session-token-value"
                },
                region: "eu-west-2"
            }, [{bucket: TEST_BUCKET}]);
    test:assertFalse(loader is ai:Error, "Temporary STS credentials must be accepted");
}

@test:Config {}
isolated function testInitAcceptsAPrebuiltClient() returns error? {
    // The union's second arm: an already-configured client can be reused, which is how a caller
    // supplies HTTP tuning (timeout, retry, proxy, secureSocket) the loader does not surface.
    s3:Client s3Client = check new (testConnection());
    TextDataLoader|ai:Error loader = new (s3Client, [{bucket: TEST_BUCKET}]);
    test:assertFalse(loader is ai:Error, "A pre-built s3:Client must be accepted");
}

@test:Config {}
isolated function testInitAcceptsDefaultCredentialsConfigShape() {
    // The default AWS credential chain (env vars, ECS/EC2 instance profiles, ...) is selected
    // with `s3:DEFAULT_CREDENTIALS`. Where the chain cannot resolve credentials this must surface
    // as a clean ai:Error, never a panic.
    TextDataLoader|ai:Error loader =
        new ({auth: s3:DEFAULT_CREDENTIALS, region: "us-east-1"}, [{bucket: TEST_BUCKET}]);
    if loader is ai:Error {
        test:assertTrue(loader.message().startsWith("Failed to initialize the AWS S3 client:"),
                "A credential-chain failure must be wrapped, got: " + loader.message());
    }
}

// ---------------------------------------------------------------------------
// Prefix-walk filtering: placeholders, recursion, extension allowlist
//
// `includeInPrefixWalk` is the decision the loader applies to every key it lists, so testing
// it directly covers the traversal rules without needing a live listing.
// ---------------------------------------------------------------------------

isolated function item(string key, int size = 10) returns S3Item => {key, size};

@test:Config {}
isolated function testFolderPlaceholdersAreSkipped() {
    // The S3 console creates zero-byte keys ending in '/' to fake folders. Two of these are
    // named so they *would* classify as supported text types if the trailing-slash rule were
    // removed, which is what binds this test to the placeholder rule specifically.
    test:assertFalse(includeInPrefixWalk(item("docs/", 0), "docs/", true, ()),
            "A bare folder placeholder must be skipped");
    test:assertFalse(includeInPrefixWalk(item("docs/notes.md/", 0), "docs/", true, ()),
            "A placeholder named like a markdown file must still be skipped");
    test:assertFalse(includeInPrefixWalk(item("docs/data.txt/", 0), "docs/", true, ()),
            "A placeholder named like a text file must still be skipped");
    test:assertTrue(includeInPrefixWalk(item("docs/real.txt"), "docs/", true, ()),
            "A real object must not be skipped");
}

@test:Config {}
isolated function testNonRecursiveSkipsNestedKeys() {
    test:assertTrue(includeInPrefixWalk(item("docs/top.txt"), "docs/", false, ()),
            "A key directly under the prefix must be included");
    test:assertFalse(includeInPrefixWalk(item("docs/nested/deep.txt"), "docs/", false, ()),
            "A key in a sub-prefix must be skipped when not recursive");
    test:assertFalse(includeInPrefixWalk(item("docs/a/b/c.txt"), "docs/", false, ()),
            "A deeply nested key must be skipped when not recursive");
}

@test:Config {}
isolated function testRecursiveIncludesNestedKeys() {
    test:assertTrue(includeInPrefixWalk(item("docs/top.txt"), "docs/", true, ()));
    test:assertTrue(includeInPrefixWalk(item("docs/nested/deep.txt"), "docs/", true, ()));
    test:assertTrue(includeInPrefixWalk(item("docs/a/b/c.txt"), "docs/", true, ()));
}

@test:Config {}
isolated function testNonRecursiveWithPrefixLackingTrailingSlash() {
    // Reached via the exact-key-miss fallback, where the prefix has no trailing slash. A single
    // leading '/' in the remainder is stripped, so this must behave like "docs/".
    test:assertTrue(includeInPrefixWalk(item("docs/top.txt"), "docs", false, ()),
            "A direct child must be included even when the prefix has no trailing slash");
    test:assertFalse(includeInPrefixWalk(item("docs/nested/deep.txt"), "docs", false, ()),
            "A nested key must still be skipped");
}

@test:Config {}
isolated function testNonRecursiveWithEmptyPrefix() {
    // The default target is {path: "", recursive: false} — "point at a bucket".
    test:assertTrue(includeInPrefixWalk(item("top.txt"), "", false, ()),
            "A top-level key must be included");
    test:assertFalse(includeInPrefixWalk(item("nested/deep.txt"), "", false, ()),
            "The default target must not descend into nested prefixes");
}

@test:Config {}
isolated function testIncludeExtensionsWithoutLeadingDot() {
    string[] allow = ["txt", "md"];
    test:assertTrue(includeInPrefixWalk(item("data/a.txt"), "data/", false, allow));
    test:assertTrue(includeInPrefixWalk(item("data/c.md"), "data/", false, allow));
    test:assertFalse(includeInPrefixWalk(item("data/b.json"), "data/", false, allow));
}

@test:Config {}
isolated function testIncludeExtensionsWithLeadingDotAndMixedCase() {
    // A leading dot is optional and matching is case-insensitive on both sides.
    string[] allow = [".Txt", ".MD"];
    test:assertTrue(includeInPrefixWalk(item("data/a.TXT"), "data/", false, allow));
    test:assertTrue(includeInPrefixWalk(item("data/c.Md"), "data/", false, allow));
    test:assertFalse(includeInPrefixWalk(item("data/b.json"), "data/", false, allow));
}

@test:Config {}
isolated function testEmptyExtensionAllowlistMatchesEverything() {
    test:assertTrue(includeInPrefixWalk(item("data/a.txt"), "data/", false, []),
            "An empty allowlist must behave like ()");
    test:assertTrue(includeInPrefixWalk(item("data/b.json"), "data/", false, ()));
}

@test:Config {}
isolated function testMatchesExtensionFilterDirectly() {
    test:assertTrue(matchesExtensionFilter("a.pdf", ()));
    test:assertTrue(matchesExtensionFilter("a.pdf", []));
    test:assertTrue(matchesExtensionFilter("REPORT.PDF", ["pdf"]));
    test:assertTrue(matchesExtensionFilter("report.pdf", [".PDF"]));
    test:assertFalse(matchesExtensionFilter("report.pdf", ["docx"]));
    test:assertFalse(matchesExtensionFilter("noextension", ["pdf"]));
}

// ---------------------------------------------------------------------------
// Per-object skip/reject screening: storage class, size, recoverable errors
//
// These pure helpers drive the "skip in a prefix walk, reject a named key" split, so testing
// them directly covers the decision without needing a live listing.
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testArchivedStorageClassesAreDetected() {
    // Asynchronous-retrieval tiers require a RestoreObject first, so they are archived.
    test:assertTrue(isArchivedStorageClass(s3:GLACIER), "GLACIER is archived");
    test:assertTrue(isArchivedStorageClass(s3:DEEP_ARCHIVE), "DEEP_ARCHIVE is archived");
    // Synchronously-retrievable classes remain loadable.
    test:assertFalse(isArchivedStorageClass(s3:STANDARD));
    test:assertFalse(isArchivedStorageClass(s3:GLACIER_IR), "GLACIER_IR retrieves instantly");
    test:assertFalse(isArchivedStorageClass(s3:INTELLIGENT_TIERING));
    test:assertFalse(isArchivedStorageClass(s3:STANDARD_IA));
    test:assertFalse(isArchivedStorageClass(s3:ONEZONE_IA));
    test:assertFalse(isArchivedStorageClass(s3:REDUCED_REDUNDANCY));
}

@test:Config {}
isolated function testUndecodableTextIsFlaggedRecoverable() returns error? {
    // An invalid UTF-8 sequence must fail decoding, and that failure must be marked recoverable
    // so a prefix walk skips the object rather than aborting the whole load.
    byte[] invalidUtf8 = [0xff, 0xfe, 0x00];
    ai:TextDocument?|ai:Error result = buildDocument(invalidUtf8, TEST_BUCKET, "docs/bad.txt",
            3, "", "");
    test:assertTrue(result is ai:Error, "Undecodable text must surface as an error");
    if result is ai:Error {
        test:assertTrue(isRecoverableInWalk(result),
                "A decode failure must be recoverable-in-walk so a corpus load can skip it");
    }
}

@test:Config {}
isolated function testFatalErrorsAreNotFlaggedRecoverable() {
    // A generic error carries no recoverable flag, so a prefix walk must not swallow it.
    test:assertFalse(isRecoverableInWalk(error("some unrelated failure")));
}

@test:Config {}
isolated function testStripUtf8BomOnlyRemovesTheBom() {
    byte[] bommed = [0xEF, 0xBB, 0xBF, 0x41, 0x42]; // BOM + "AB"
    test:assertEquals(stripUtf8Bom(bommed), [0x41, 0x42], "Only the 3 BOM bytes are removed");
    test:assertEquals(stripUtf8Bom([0x41, 0x42]), [0x41, 0x42], "Content without a BOM is unchanged");
    // Fewer than 3 leading bytes that look like the start of a BOM must be left intact.
    test:assertEquals(stripUtf8Bom([0xEF, 0xBB]), [0xEF, 0xBB], "A non-BOM prefix must not be touched");
}

@test:Config {}
isolated function testUtf8BomIsStrippedFromDecodedContent() returns error? {
    // A UTF-8 BOM prepended to real content must vanish from the decoded text, while every
    // content byte survives verbatim. The log line makes the before/after visible in the run.
    byte[] withBom = [0xEF, 0xBB, 0xBF];
    withBom.push(..."# Title".toBytes());
    ai:TextDocument doc = check buildDocument(withBom, TEST_BUCKET, "docs/bom.md", 10, "", "").ensureType();
    string content = contentOf(doc);
    io:println(string `[BOM test] input bytes=${withBom.length()} (${withBom.toString()}), ` +
            string `decoded content=${content.toJsonString()} (${content.length()} chars)`);
    test:assertEquals(content, "# Title", "The content must be preserved exactly, only the BOM removed");
    test:assertFalse(content.startsWith("\u{FEFF}"), "No leading U+FEFF may remain");
    test:assertEquals(content.length(), 7, "The 3 BOM bytes are gone; the 7 content characters remain");
}

// Each natively-textual type routes through the same PLAIN_TEXT decode, so a BOM must be
// stripped identically for every one of them. Binary types (pdf/docx/pptx) never reach that
// branch, so the BOM inside their bytes is (correctly) left to the parser.
@test:Config {
    dataProvider: bomTextTypes
}
isolated function testUtf8BomIsStrippedAcrossTextTypes(string key, string body) returns error? {
    byte[] withBom = [0xEF, 0xBB, 0xBF];
    withBom.push(...body.toBytes());
    ai:TextDocument doc = check buildDocument(withBom, TEST_BUCKET, key, 10, "", "").ensureType();
    string content = contentOf(doc);
    io:println(string `[BOM test] key=${key}: input ${withBom.length()} bytes -> ` +
            string `content=${content.toJsonString()} (${content.length()} chars)`);
    test:assertEquals(content, body, key + ": content must survive verbatim, only the BOM removed");
    test:assertFalse(content.startsWith("\u{FEFF}"), key + ": no leading U+FEFF may remain");
}

isolated function bomTextTypes() returns map<[string, string]> => {
    "txt": ["logs/app.txt", "hello world"],
    "csv": ["data/rows.csv", "id,name\n1,alice"],
    "json": ["data/doc.json", "{\"k\":\"v\"}"],
    "html": ["site/page.html", "<h1>Hi</h1>"],
    "yaml": ["conf/app.yaml", "key: value"],
    "markdown": ["docs/readme.md", "# Heading"]
};

// ---------------------------------------------------------------------------
// Stream draining: multi-chunk, size ceiling, and no leaks on failure
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testMultiChunkStreamIsDrainedInOrder() returns error? {
    byte[] body = "chunk-one|chunk-two|chunk-three".toBytes();
    TestByteIterator iterator = new (chunkBytes(body, 7));
    stream<byte[], io:Error?> byteStream = new (iterator);
    byte[] content = check drainStream(byteStream, 1024, TEST_BUCKET, "a.txt");
    test:assertEquals(content, body, "A stream delivered in several chunks must be reassembled exactly");
    test:assertTrue(iterator.isClosed(), "The stream must be closed after a successful drain");
}

@test:Config {}
isolated function testDrainClosesStreamOnNormalCompletion() returns error? {
    TestByteIterator iterator = new ([[104, 105]]);
    stream<byte[], io:Error?> byteStream = new (iterator);
    byte[] content = check drainStream(byteStream, 1024, TEST_BUCKET, "a.txt");
    test:assertEquals(content, [104, 105]);
    test:assertTrue(iterator.isClosed(), "The stream must be closed after a successful drain");
}

@test:Config {}
isolated function testDrainClosesStreamOnMidReadError() {
    // Fails on the second chunk, after one has been read.
    TestByteIterator iterator = new ([[1, 2, 3], [4, 5, 6]], 1);
    stream<byte[], io:Error?> byteStream = new (iterator);
    byte[]|ai:Error result = drainStream(byteStream, 1024, TEST_BUCKET, "a.txt");
    test:assertTrue(result is ai:Error, "A mid-read failure must produce an error");
    test:assertTrue(iterator.isClosed(), "The stream must be closed even when a read fails");
    if result is ai:Error {
        test:assertTrue(result.message().includes("a.txt"), "The error must name the key");
        test:assertTrue(result.message().includes(TEST_BUCKET), "The error must name the bucket");
        test:assertTrue(result.message().includes("Failed to read object"),
                "Unexpected message: " + result.message());
    }
}

@test:Config {}
isolated function testDrainClosesStreamWhenCeilingExceeded() {
    TestByteIterator iterator = new ([[1, 2, 3, 4], [5, 6, 7, 8]]);
    stream<byte[], io:Error?> byteStream = new (iterator);
    byte[]|ai:Error result = drainStream(byteStream, 5, TEST_BUCKET, "a.txt");
    test:assertTrue(result is ai:Error, "Exceeding the ceiling must produce an error");
    test:assertTrue(iterator.isClosed(), "The stream must be closed when the ceiling is exceeded");
    if result is ai:Error {
        test:assertTrue(result.message().includes("exceeds the configured maximum size"),
                "Unexpected message: " + result.message());
    }
}

@test:Config {}
isolated function testCeilingIsAnExactBound() {
    // The over-limit chunk must never be appended, so the bound is exact rather than
    // "limit plus one chunk".
    TestByteIterator iterator = new ([[1, 2, 3, 4]]);
    stream<byte[], io:Error?> exact = new (iterator);
    byte[]|ai:Error atLimit = drainStream(exact, 4, TEST_BUCKET, "a.txt");
    test:assertFalse(atLimit is ai:Error, "Content exactly at the ceiling must be accepted");

    TestByteIterator overIterator = new ([[1, 2, 3, 4, 5]]);
    stream<byte[], io:Error?> over = new (overIterator);
    byte[]|ai:Error overLimit = drainStream(over, 4, TEST_BUCKET, "a.txt");
    test:assertTrue(overLimit is ai:Error, "One byte over the ceiling must be rejected");
}

@test:Config {}
isolated function testEmptyStreamDrainsToEmptyContent() returns error? {
    TestByteIterator iterator = new ([]);
    stream<byte[], io:Error?> byteStream = new (iterator);
    byte[] content = check drainStream(byteStream, 1024, TEST_BUCKET, "empty.txt");
    test:assertEquals(content.length(), 0, "A zero-byte object must drain to empty content");
    test:assertTrue(iterator.isClosed());
}
