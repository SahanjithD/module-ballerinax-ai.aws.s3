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

// `load()` policy paths, driven offline through a mocked `s3:Client` (see `paging_test.bal` for
// the harness): whole-bucket sources, named keys, the missing-key fallback, the skip branches of a
// prefix walk, and bucket error mapping.

isolated function metadataOf(string key, int contentLength, s3:StorageClass storageClass = s3:STANDARD)
        returns s3:ObjectMetadata => {
    key,
    contentLength,
    eTag: "\"abc\"",
    lastModified: "2026-01-01T00:00:00Z",
    storageClass
};

@test:Config {}
function testWholeBucketSourceListsWithoutPrefix() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    s3:ListObjectsConfig wholeBucketRequest = {maxKeys: 1000, delimiter: "/"};
    test:prepare(mockClient).when("listObjects").withArguments(PAGING_BUCKET, wholeBucketRequest)
        .thenReturn(pageOf([obj("a.md"), obj("b.txt")]));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("text"));

    TextDataLoader loader = check new (mockClient, [{bucket: PAGING_BUCKET}]);
    ai:Document[] documents = documentsOf(check loader.load());
    test:assertEquals(documents.length(), 2, "A source without paths must load the whole bucket");
}

@test:Config {}
function testNamedKeyIsLoadedDirectly() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("getObjectMetadata").thenReturn(metadataOf("docs/guide.md", 7));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("# Guide"));

    TextDataLoader loader = check loaderOver(mockClient, "docs/guide.md");
    ai:Document|ai:Document[] loaded = check loader.load();
    test:assertTrue(loaded is ai:TextDocument, "A single named key must load as one bare document");
    if loaded is ai:TextDocument {
        test:assertEquals(loaded.content, "# Guide");
    }
}

@test:Config {}
function testMissingKeyFallsBackToPrefix() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("getObjectMetadata").thenReturn(error s3:NoSuchKeyError("Not Found"));
    s3:ListObjectsConfig folderRequest = {maxKeys: 1000, prefix: "reports/", delimiter: "/"};
    test:prepare(mockClient).when("listObjects").withArguments(PAGING_BUCKET, folderRequest)
        .thenReturn(pageOf([obj("reports/q1.md"), obj("reports/q2.md")]));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("# report"));

    TextDataLoader loader = check loaderOver(mockClient, "reports");
    ai:Document[] documents = documentsOf(check loader.load());
    test:assertEquals(documents.length(), 2, "A path that is not a key must be walked as a folder");
}

@test:Config {}
function testPathMatchingNothingReturnsNoDocuments() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("getObjectMetadata").thenReturn(error s3:NoSuchKeyError("Not Found"));
    test:prepare(mockClient).when("listObjects").thenReturn(pageOf([]));

    TextDataLoader loader = check loaderOver(mockClient, "reprots");
    ai:Document[] documents = documentsOf(check loader.load());
    test:assertEquals(documents.length(), 0, "A path matching nothing loads nothing (with a logged warning)");
}

@test:Config {}
function testPrefixWalkSkipsUnloadableObjects() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    s3:S3Object archived = {key: "docs/old.md", size: 12, lastModified: "2026-01-01T00:00:00Z",
        eTag: "\"abc\"", storageClass: s3:DEEP_ARCHIVE};
    test:prepare(mockClient).when("listObjects").thenReturn(pageOf([
        obj("docs/keep.md"),
        archived,
        obj("docs/huge.md", 5000),
        obj("docs/photo.png"),
        obj("docs/legacy.doc")
    ]));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("kept"));

    TextDataLoader loader = check loaderOver(mockClient, "docs/", options = {maxObjectSize: 1000});
    ai:Document|ai:Document[] loaded = check loader.load();
    test:assertTrue(loaded is ai:TextDocument,
            "Archived, over-sized and unsupported objects must be skipped, leaving one document");
    if loaded is ai:TextDocument {
        test:assertEquals(loaded.content, "kept");
    }
}

@test:Config {}
function testPrefixWalkSkipsUnparseableAndDeletedObjects() returns error? {
    s3:Client parseClient = test:mock(s3:Client);
    test:prepare(parseClient).when("listObjects").thenReturn(pageOf([obj("docs/broken.pdf"), obj("docs/ok.md")]));
    test:prepare(parseClient).when("getObject").thenReturn(contentStream("this is not a PDF"));
    TextDataLoader parseLoader = check loaderOver(parseClient, "docs/");
    test:assertEquals(documentsOf(check parseLoader.load()).length(), 1,
            "A PDF that fails to parse must be skipped during a prefix walk");

    s3:Client deletedClient = test:mock(s3:Client);
    test:prepare(deletedClient).when("listObjects").thenReturn(pageOf([obj("docs/gone.md")]));
    test:prepare(deletedClient).when("getObject").thenReturn(error s3:NoSuchKeyError("NoSuchKey"));
    TextDataLoader deletedLoader = check loaderOver(deletedClient, "docs/");
    test:assertEquals(documentsOf(check deletedLoader.load()).length(), 0,
            "An object deleted after listing must be skipped during a prefix walk");
}

@test:Config {}
function testPrefixWalkStillFailsOnAccessErrors() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("listObjects").thenReturn(pageOf([obj("docs/a.md")]));
    test:prepare(mockClient).when("getObject").thenReturn(error s3:Error("AccessDenied"));
    TextDataLoader loader = check loaderOver(mockClient, "docs/");
    test:assertTrue(loader.load() is ai:Error,
            "A failure that is not specific to one object must still fail the load");
}

@test:Config {}
function testNamedUnparseableKeyFails() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("getObjectMetadata").thenReturn(metadataOf("docs/broken.pdf", 17));
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("this is not a PDF"));
    TextDataLoader loader = check loaderOver(mockClient, "docs/broken.pdf");
    test:assertTrue(loader.load() is ai:Error, "A named key that fails to parse must return the error");
}

@test:Config {}
function testNamedArchivedOrOversizedKeyFails() {
    s3:Client archivedClient = test:mock(s3:Client);
    test:prepare(archivedClient).when("getObjectMetadata")
        .thenReturn(metadataOf("docs/old.md", 12, s3:GLACIER));
    s3:Client oversizedClient = test:mock(s3:Client);
    test:prepare(oversizedClient).when("getObjectMetadata").thenReturn(metadataOf("docs/old.md", 5000));

    foreach s3:Client mockClient in [archivedClient, oversizedClient] {
        TextDataLoader|ai:Error loader = loaderOver(mockClient, "docs/old.md", options = {maxObjectSize: 1000});
        if loader is ai:Error {
            test:assertFail("The loader must construct: " + loader.message());
        }
        test:assertTrue(loader.load() is ai:Error,
                "A named archived or over-sized key must fail rather than be skipped");
    }
}

@test:Config {}
function testMissingBucketIsReportedClearly() {
    s3:Client mockClient = test:mock(s3:Client);
    test:prepare(mockClient).when("listObjects").thenReturn(error s3:NoSuchBucketError("NoSuchBucket"));

    TextDataLoader|ai:Error loader = loaderOver(mockClient, "docs/");
    if loader is ai:Error {
        test:assertFail("The loader must construct: " + loader.message());
    }
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    test:assertTrue(result is ai:Error, "A missing bucket must fail the load");
    if result is ai:Error {
        test:assertTrue(result.message().includes("was not found"), "Unexpected message: " + result.message());
    }
}

@test:Config {}
function testNamedExtensionlessKeyUsesContentType() returns error? {
    s3:Client mockClient = test:mock(s3:Client);
    s3:ObjectMetadata metadata = metadataOf("notes/README", 7);
    metadata.contentType = "text/markdown; charset=utf-8";
    test:prepare(mockClient).when("getObjectMetadata").thenReturn(metadata);
    test:prepare(mockClient).when("getObject").thenReturn(contentStream("# Notes"));

    TextDataLoader loader = check loaderOver(mockClient, "notes/README");
    ai:Document|ai:Document[] loaded = check loader.load();
    test:assertTrue(loaded is ai:TextDocument, "An extensionless key with a text Content-Type must load");
    if loaded is ai:TextDocument {
        test:assertEquals(loaded.content, "# Notes");
        test:assertEquals((loaded.metadata ?: {}).mimeType, "text/markdown",
                "The Content-Type, without parameters, must become the document's MIME type");
    }
}
