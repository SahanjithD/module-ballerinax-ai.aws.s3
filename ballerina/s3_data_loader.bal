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

// S3's ListObjectsV2 caps a single response at 1000 entries — object keys plus, when a delimiter
// is used (a non-recursive walk), the CommonPrefixes that count against the same limit. The
// prefix walk requests the maximum to minimise round-trips, then pages via the continuation token.
const int MAX_KEYS_PER_PAGE = 1000;

// The ceiling on how many pages one prefix walk will fetch. This is the loop's termination
// proof — the last-key check below is a fast diagnostic, but only a page count bounds *every*
// possible response sequence, including a run of object-less pages that offers no key to compare.
//
// 10,000 pages covers ten million listed entries. A recursive walk cannot usefully return that
// many (every document is held in memory), so the binding case is a non-recursive walk over a
// prefix with millions of sub-folders, whose CommonPrefixes consume the page budget invisibly;
// ten million of those still fits. Raising it much further would not protect a larger real
// listing, only lengthen how long a stuck one spins before reporting.
const int MAX_LIST_PAGES = 10000;

# A data loader that reads objects from AWS S3 buckets as text for a RAG ingestion
# pipeline. It implements `ai:DataLoader`, so what it loads feeds directly into
# `ai:KnowledgeBase.ingest`.
#
# Natively-textual objects (`md`, `html`, `htm`, `txt`, `csv`, `json`, `xml`, `yaml`, …)
# are decoded directly; `pdf`, `docx`, `pptx`, and `xlsx` are extracted in memory via Apache
# Tika and POI. Legacy binary Office formats (`doc`, `ppt`, `xls`) are not supported.
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
    # + s3Connection - Either an `s3:ConnectionConfig` describing how to reach S3 (the loader
    #                  builds the client from it), or an already-configured `s3:Client` to reuse
    # + sources - One or more buckets, each with the targets (prefixes/keys) to load
    # + options - Loader-wide options: the in-memory per-object size ceiling
    # + return - An `ai:Error` if the configuration is invalid or the client cannot be built
    public isolated function init(
            @display {label: "Connection Config"} s3:ConnectionConfig|s3:Client s3Connection,
            @display {label: "Data Sources"} Source[] sources,
            @display {label: "Loader Options"} LoaderOptions options = {}) returns ai:Error? {
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the AWS S3 data loader");
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
    # + return - The single loaded document when exactly one object is resolved, an array of
    #            documents otherwise, or an `ai:Error` on failure
    public isolated function load() returns ai:Document[]|ai:Document|ai:Error {
        ai:Document[] documents = [];
        foreach Source src in self.sources {
            foreach Target target in src.targets {
                ai:Document[] loaded = check self.loadTarget(src.bucket, target);
                documents.push(...loaded);
            }
        }
        if documents.length() == 1 {
            return documents[0];
        }
        return documents;
    }

    // Loads a single target, choosing prefix traversal or exact-key resolution. A value
    // ending in `/` (or empty) is a prefix; anything else is tried as an exact key first and
    // falls back to a prefix on a miss.
    private isolated function loadTarget(string bucket, Target target)
            returns ai:Document[]|ai:Error {
        string path = target.path;
        if path == "" || path.endsWith("/") {
            return self.loadPrefix(bucket, path, target.recursive, target.includeExtensions);
        }
        S3Item? exact = check self.findExactKey(bucket, path);
        // A zero-byte object keyed exactly as the path may be a folder marker rather than a
        // document — `aws s3api put-object --key reports` creates one — and rejecting it as an
        // unsupported type failed the whole load instead of walking `reports/`. Such a key is
        // therefore treated as a marker and falls through to the prefix walk. An object that
        // carries content is always resolved as the named key, so an unsupported one still fails
        // loudly.
        boolean markerCandidate = exact is S3Item && exact.size == 0
            && classify(exact.key, ()) is UNSUPPORTED|UNSUPPORTED_OFFICE;
        if exact is S3Item && !markerCandidate {
            return [check self.loadExactKey(bucket, exact)];
        }
        // Exact-key miss: treat the value as a folder prefix. Append "/" so it matches the
        // folder's contents rather than sibling prefixes (e.g. "reports" must not also match
        // "reports-archive/"), and so a non-recursive walk — which now passes delimiter="/" —
        // still sees the folder's same-level objects instead of rolling them into a CommonPrefix.
        ai:Document[] documents =
            check self.loadPrefix(bucket, path + "/", target.recursive, target.includeExtensions);
        if documents.length() == 0 && exact is S3Item {
            // The key was a marker candidate but names no folder either, so it was simply an empty
            // object of an unsupported type. Report that rather than returning nothing: the caller
            // named this key, and a silent empty result would hide the reason from them.
            return [check self.loadExactKey(bucket, exact)];
        }
        return documents;
    }

    // Resolves an exact key with HEAD requests (no download), returning the item if it exists or
    // `()` if not. See `headObject` for why HEAD is used over a ListObjectsV2 probe.
    private isolated function findExactKey(string bucket, string key) returns S3Item?|ai:Error {
        return headObject(self.s3Client, bucket, key);
    }

    // Loads an explicitly named key. Unlike a prefix walk, an unsupported named key is an
    // error (the caller asked for it by name), not a silent skip.
    private isolated function loadExactKey(string bucket, S3Item item) returns ai:TextDocument|ai:Error {
        match classify(item.key, ()) {
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
        // The caller named this key, so an archived or over-sized object is a hard error rather
        // than a silent skip (unlike a prefix walk).
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
            // Unreachable: the type was classified as supported above.
            return error ai:Error(
                string `Failed to build a document for key '${item.key}' in bucket '${bucket}'`);
        }
        return document;
    }

    // Lists a prefix and loads all its supported objects, paginating with S3's continuation token.
    // The loop passes each page's `NextContinuationToken` back until a page reports it is not
    // truncated — so it reads the whole prefix. Like the SharePoint loader, there is no document
    // cap: every matching object is returned. A non-recursive walk passes `delimiter = "/"`, so S3
    // returns only same-level objects (descendant keys roll into CommonPrefixes, which the
    // connector drops and the loader does not need); the client-side filter in `includeInPrefixWalk`
    // stays as a belt-and-braces check.
    private isolated function loadPrefix(string bucket, string prefix, boolean recursive,
            string[]? includeExtensions) returns ai:Document[]|ai:Error {
        ai:Document[] documents = [];
        string? effectivePrefix = prefix == "" ? () : prefix;
        string? delimiter = recursive ? () : "/";
        string? continuationToken = ();
        // The final key of the previous object-bearing page. ListObjectsV2 never returns a key
        // twice within one listing, so seeing the same key end two pages means the listing is not
        // advancing — which catches the realistic stuck shape (page one re-served forever) on the
        // very next page instead of after the ceiling. Deliberately O(1): tracking every key seen
        // would catch more exotic sequences that S3 cannot produce, at the cost of a map growing
        // with every key listed, which on a multi-million-object bucket is hundreds of megabytes.
        string? previousPageLastKey = ();
        // Pages fetched so far, bounded by MAX_LIST_PAGES whatever the server returns.
        int pagesFetched = 0;
        while true {
            S3Page page = check listObjectPage(self.s3Client, bucket, effectivePrefix, delimiter,
                    continuationToken, MAX_KEYS_PER_PAGE);
            pagesFetched += 1;
            int pageSize = page.items.length();
            if pageSize > 0 {
                string lastKey = page.items[pageSize - 1].key;
                if lastKey == previousPageLastKey {
                    return error ai:Error(string `Listing for bucket '${bucket}'` +
                        (prefix == "" ? "" : string ` under prefix '${prefix}'`) +
                        string ` is not advancing: two consecutive pages ended at the same key ` +
                        string `('${lastKey}'), so the listing cannot be fully read.`);
                }
                previousPageLastKey = lastKey;
            }
            foreach S3Item item in page.items {
                if !includeInPrefixWalk(item, prefix, recursive, includeExtensions) {
                    continue;
                }
                ai:TextDocument? document = check self.loadObjectSkippingUnsupported(bucket, item);
                if document is ai:TextDocument {
                    documents.push(document);
                }
            }
            if !page.truncated {
                break; // last page
            }
            string? nextToken = page.continuationToken;
            if nextToken is () {
                // A truncated page must carry a continuation token; if it does not, the listing
                // cannot be continued. Surface an error rather than silently returning a partial
                // corpus. Not expected in practice.
                return error ai:Error(string `Listing for bucket '${bucket}'` +
                    (prefix == "" ? "" : string ` under prefix '${prefix}'`) +
                    string ` is truncated but returned no continuation token, so it cannot be fully read.`);
            }
            // The last-key check above catches a stuck listing as soon as it re-serves a page,
            // but it cannot see a run of object-less pages — and those are legitimate: a
            // non-recursive walk of a folder-heavy prefix returns pages holding nothing but
            // CommonPrefixes, which the connector does not surface though they still consume the
            // page's key budget. With the default `Target` (`path: ""`, `recursive: false`), a
            // bucket organised as one prefix per tenant produces exactly that, so capping
            // consecutive empty pages would fail a perfectly good listing. The page ceiling bounds
            // that path instead, and is what makes this loop terminate for *any* response
            // sequence. A continuation-token comparison would serve neither purpose: S3 mints a
            // fresh token per response, so two identical requests yield two different tokens and
            // the comparison never fires — which is how a listing that re-fetched page one forever
            // once went undetected.
            if pagesFetched >= MAX_LIST_PAGES {
                return error ai:Error(string `Listing for bucket '${bucket}'` +
                    (prefix == "" ? "" : string ` under prefix '${prefix}'`) +
                    string ` reached the ${MAX_LIST_PAGES}-page ceiling without completing, so ` +
                    string `it cannot be fully read. Narrow the prefix if the listing is ` +
                    string `genuinely this large.`);
            }
            continuationToken = nextToken;
        }
        return documents;
    }

    // Decides whether to load an object found while walking a prefix, applying the folder,
    // recursion, and extension rules (unsupported-type filtering happens at load time).
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
        // A single problem object must not fail an entire corpus load, so archived, over-sized
        // and undecodable objects are skipped with a warning during a prefix walk (a named key
        // hits the hard-error paths in loadExactKey instead).
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
                log:printWarn("Skipping an object whose text could not be decoded",
                        bucket = bucket, key = item.key);
                return ();
            }
            return document;
        }
        return document;
    }

    // Downloads an object's content (draining the stream with the size ceiling) and builds a
    // text document from it. Callers pre-screen archived/over-sized objects (skipping them in a
    // prefix walk, rejecting them for a named key); the drain still enforces the ceiling here as
    // a backstop, because the listing-reported size is not guaranteed present or accurate.
    private isolated function loadObject(string bucket, S3Item item) returns ai:TextDocument?|ai:Error {
        stream<byte[], error?> objStream = check openObjectStream(self.s3Client, bucket, item.key);
        byte[] content = check drainStream(objStream, self.maxObjectSize, bucket, item.key);
        return buildDocument(content, bucket, item.key, item.size, item.lastModified, item.eTag);
    }
}

# Decides whether an object found while walking a prefix should be considered for loading,
# applying (in order): the console-placeholder skip, the non-recursive same-level filter, and
# the extension allowlist. Unsupported file types are filtered later, at load time.
#
# + item - The listing entry under consideration
# + prefix - The prefix being walked (possibly empty)
# + recursive - Whether nested keys are included
# + includeExtensions - The extension allowlist (`()`/empty = all)
# + return - `true` if the object should be loaded, `false` to skip it
isolated function includeInPrefixWalk(S3Item item, string prefix, boolean recursive,
        string[]? includeExtensions) returns boolean {
    string key = item.key;
    // Skip S3 console "folder" placeholders: zero-byte keys whose name ends in '/'. One carrying
    // content is not a placeholder, so it falls through to be classified and skipped with a
    // warning like any other unloadable object, rather than disappearing here without a trace.
    if key.endsWith("/") && item.size == 0 {
        return false;
    }
    if !recursive {
        // Non-recursive listing passes delimiter "/", so S3 already rolls descendant keys into
        // CommonPrefixes (which the connector's S3Object[] cannot represent and so drops) and
        // returns only same-level objects. This client-side check is a belt-and-braces backstop:
        // anything with a further '/' after the prefix is a descendant of a sub-prefix and is
        // skipped.
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
