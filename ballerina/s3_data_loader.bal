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
import ballerina/log;
import ballerinax/aws.s3;

// ListObjectsV2's maximum page size.
const int MAX_KEYS_PER_PAGE = 1000;

// Guarantees a prefix walk terminates whatever the listing returns. Ten million entries is far
// more than a loader holding every document in memory could use.
const int MAX_LIST_PAGES = 10000;

# Loads text documents from AWS S3 buckets.
@display {
    label: "AWS S3 Text Data Loader"
}
public isolated class TextDataLoader {
    *ai:DataLoader;

    private final s3:Client s3Client;
    private final readonly & Source[] sources;
    private final int maxObjectSize;

    # Initializes the AWS S3 data loader.
    #
    # + s3Connection - Connection settings for S3, or an existing `s3:Client` to reuse
    # + sources - The buckets and paths to load documents from
    # + options - Limits that apply to every object loaded
    # + return - An `ai:Error` if the configuration is invalid or the client cannot be created
    public isolated function init(
            @display {label: "Connection Config"} s3:ConnectionConfig|s3:Client s3Connection,
            @display {label: "Data Sources"} Source[] sources,
            @display {label: "Loader Options"} LoaderOptions options = {}) returns ai:Error? {
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the AWS S3 data loader");
        }
        foreach Source src in sources {
            string[]? paths = src?.paths;
            if paths is string[] && paths.length() == 0 {
                return error ai:Error(string `Source '${src.bucket}' has an empty 'paths' list, which ` +
                    "would load nothing. Omit 'paths' to load the whole bucket");
            }
        }
        if options.maxObjectSize < 1 {
            return error ai:Error("maxObjectSize must be at least 1");
        }
        self.s3Client = s3Connection is s3:Client ? s3Connection : check buildS3Client(s3Connection);
        self.sources = sources.cloneReadOnly();
        self.maxObjectSize = options.maxObjectSize;
    }

    # Loads the configured S3 objects as text documents.
    #
    # + return - One document if exactly one object was loaded, otherwise an array of documents,
    # or an `ai:Error` if loading fails
    public isolated function load() returns ai:Document[]|ai:Document|ai:Error {
        ai:Document[] documents = [];
        foreach Source src in self.sources {
            string[]? paths = src?.paths;
            if paths is () {
                ai:Document[] loaded =
                    check self.loadPrefix(src.bucket, (), src.recursive, src.includeExtensions);
                documents.push(...loaded);
            } else {
                foreach string path in paths {
                    ai:Document[] loaded =
                        check self.loadTarget(src.bucket, path, src.recursive, src.includeExtensions);
                    documents.push(...loaded);
                }
            }
        }
        if documents.length() == 1 {
            return documents[0];
        }
        return documents;
    }

    // A path ending in `/` (or empty) is a prefix; anything else is tried as a key first.
    private isolated function loadTarget(string bucket, string path, boolean recursive,
            string[]? includeExtensions) returns ai:Document[]|ai:Error {
        if path == "" || path.endsWith("/") {
            return self.loadPrefix(bucket, path == "" ? () : path, recursive, includeExtensions);
        }
        S3Item? exact = check self.findExactKey(bucket, path);
        // A zero-byte, extensionless object named like the path is usually a folder marker (some
        // tools create `reports` next to `reports/`), so walk the folder instead.
        boolean markerCandidate = exact is S3Item && exact.size == 0
            && classify(exact.key, ()) is UNSUPPORTED|UNSUPPORTED_OFFICE;
        if exact is S3Item && !markerCandidate {
            return [check self.loadExactKey(bucket, exact)];
        }
        // The trailing "/" keeps "reports" from also matching "reports-archive/".
        ai:Document[] documents =
            check self.loadPrefix(bucket, path + "/", recursive, includeExtensions);
        if documents.length() == 0 && exact is S3Item {
            // Not a folder after all: report why the named key can't be loaded.
            return [check self.loadExactKey(bucket, exact)];
        }
        if documents.length() == 0 {
            log:printWarn("A configured path matched no loadable objects", bucket = bucket, path = path);
        }
        return documents;
    }

    private isolated function findExactKey(string bucket, string key) returns S3Item?|ai:Error {
        return headObject(self.s3Client, bucket, key);
    }

    // Unlike a prefix walk, a key named directly that can't be loaded is an error.
    private isolated function loadExactKey(string bucket, S3Item item) returns ai:TextDocument|ai:Error {
        match classifyObject(item.key, item.contentType) {
            UNSUPPORTED_OFFICE => {
                return error ai:Error(string `Unsupported file type for key '${item.key}' in bucket ` +
                    string `'${bucket}': text extraction for the legacy binary Microsoft Office formats ` +
                    string `(.doc, .ppt, .xls) is not supported. Convert the document to ` +
                    string `.docx, .pptx, .xlsx or PDF.`);
            }
            UNSUPPORTED => {
                return error ai:Error(
                    string `Unsupported (non-text) file type for key '${item.key}' in bucket '${bucket}'`);
            }
        }
        if isArchivedStorageClass(item.storageClass) {
            return error ai:Error(string `Object '${item.key}' in bucket '${bucket}' is in the ` +
                string `${item.storageClass} storage class and must be restored with RestoreObject ` +
                string `before it can be read.`);
        }
        if item.size > self.maxObjectSize {
            return error ai:Error(string `Object '${item.key}' in bucket '${bucket}' is ${item.size} ` +
                string `bytes, which exceeds the configured maximum size of ${self.maxObjectSize} ` +
                string `bytes, and was not read into memory.`);
        }
        ai:TextDocument? document = check self.loadObject(bucket, item);
        if document is () {
            return error ai:Error(
                string `Failed to build a document for key '${item.key}' in bucket '${bucket}'`);
        }
        return document;
    }

    // Loads every supported object under a prefix, following continuation tokens to the end.
    private isolated function loadPrefix(string bucket, string? prefix, boolean recursive,
            string[]? includeExtensions) returns ai:Document[]|ai:Error {
        ai:Document[] documents = [];
        string? delimiter = recursive ? () : "/";
        string? continuationToken = ();
        // A listing never returns a key twice, so two pages ending at the same key, or a repeated
        // continuation token, mean it isn't advancing. The page ceiling bounds everything else,
        // including runs of pages that hold only sub-folders.
        string? previousPageLastKey = ();
        int pagesFetched = 0;
        map<boolean> seenContinuationTokens = {};
        while true {
            S3Page page = check listObjectPage(self.s3Client, bucket, prefix, delimiter,
                    continuationToken, MAX_KEYS_PER_PAGE);
            pagesFetched += 1;
            int pageSize = page.items.length();
            if pageSize > 0 {
                string lastKey = page.items[pageSize - 1].key;
                if lastKey == previousPageLastKey {
                    return error ai:Error(string `Listing for bucket '${bucket}'` +
                        (prefix is () ? "" : string ` under prefix '${prefix}'`) +
                        string ` is not advancing: two consecutive pages ended at the same key ` +
                        string `('${lastKey}'), so the listing cannot be fully read.`);
                }
                previousPageLastKey = lastKey;
            }
            foreach S3Item item in page.items {
                if !includeInPrefixWalk(item, prefix ?: "", recursive, includeExtensions) {
                    continue;
                }
                ai:TextDocument? document = check self.loadObjectSkippingUnsupported(bucket, item);
                if document is ai:TextDocument {
                    documents.push(document);
                }
            }
            if !page.truncated {
                break;
            }
            string? nextToken = page.continuationToken;
            if nextToken is () {
                return error ai:Error(string `Listing for bucket '${bucket}'` +
                    (prefix is () ? "" : string ` under prefix '${prefix}'`) +
                    string ` is truncated but returned no continuation token, so it cannot be fully read.`);
            }
            if pagesFetched >= MAX_LIST_PAGES {
                return error ai:Error(string `Listing for bucket '${bucket}'` +
                    (prefix is () ? "" : string ` under prefix '${prefix}'`) +
                    string ` reached the ${MAX_LIST_PAGES}-page ceiling without completing, so ` +
                    string `it cannot be fully read. Narrow the prefix if the listing is ` +
                    string `genuinely this large.`);
            }
            if seenContinuationTokens.hasKey(nextToken) {
                return error ai:Error(string `Listing for bucket '${bucket}'` +
                    (prefix is () ? "" : string ` under prefix '${prefix}'`) +
                    string ` is not advancing: continuation token '${nextToken}' was returned twice, ` +
                    string `so the listing cannot be fully read.`);
            }
            seenContinuationTokens[nextToken] = true;
            continuationToken = nextToken;
        }
        return documents;
    }

    // Loads an object found in a prefix walk, skipping (with a warning) any that can't be loaded,
    // so one bad object doesn't fail the whole load.
    private isolated function loadObjectSkippingUnsupported(string bucket, S3Item item)
            returns ai:TextDocument?|ai:Error {
        match classify(item.key, ()) {
            UNSUPPORTED_OFFICE => {
                log:printWarn("Skipping an unsupported Microsoft Office object: text extraction " +
                        "for the legacy binary .doc/.ppt/.xls formats is not supported",
                        bucket = bucket, key = item.key);
                return ();
            }
            UNSUPPORTED => {
                log:printWarn("Skipping a non-text object", bucket = bucket, key = item.key);
                return ();
            }
        }
        if isArchivedStorageClass(item.storageClass) {
            log:printWarn("Skipping an archived object; restore it with RestoreObject before it " +
                    "can be loaded", bucket = bucket, key = item.key, storageClass = item.storageClass);
            return ();
        }
        if item.size > self.maxObjectSize {
            log:printWarn("Skipping an over-sized object", bucket = bucket, key = item.key,
                    size = item.size, maxObjectSize = self.maxObjectSize);
            return ();
        }
        ai:TextDocument?|ai:Error document = self.loadObject(bucket, item);
        if document is ai:Error {
            if isRecoverableInWalk(document) {
                log:printWarn("Skipping an object that could not be loaded", bucket = bucket, key = item.key,
                        reason = document.message());
                return ();
            }
            return document;
        }
        return document;
    }

    // The drain enforces `maxObjectSize` again, since the reported size may not match the content.
    private isolated function loadObject(string bucket, S3Item item) returns ai:TextDocument?|ai:Error {
        stream<byte[], error?> objStream = check openObjectStream(self.s3Client, bucket, item.key);
        byte[] content = check drainStream(objStream, self.maxObjectSize, bucket, item.key);
        return buildDocument(content, bucket, item.key, item.size, item.lastModified, item.eTag,
                item.contentType);
    }
}

// Applies the folder-placeholder, recursion and extension rules to an object found in a walk.
isolated function includeInPrefixWalk(S3Item item, string prefix, boolean recursive,
        string[]? includeExtensions) returns boolean {
    string key = item.key;
    // S3 console folder placeholders.
    if key.endsWith("/") && item.size == 0 {
        return false;
    }
    if !recursive {
        // The "/" delimiter already excludes nested keys; this is a backstop.
        string remainder = key.startsWith(prefix) ? key.substring(prefix.length()) : key;
        if remainder.startsWith("/") {
            remainder = remainder.substring(1);
        }
        if remainder.includes("/") {
            return false;
        }
    }
    return matchesExtensionFilter(key, includeExtensions);
}
