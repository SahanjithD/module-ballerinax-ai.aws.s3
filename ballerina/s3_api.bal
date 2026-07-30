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
import ballerinax/aws.s3;

// Everything that touches `ballerinax/aws.s3` lives here, so the loader deals in normalized
// values and the connector's quirks are absorbed in one place.

// A normalized S3 listing entry — the subset of an object's metadata the loader uses. The
// connector's `s3:S3Object` fields are carried through here rather than being handled
// throughout the loader. In `aws.s3` 5.0.0 `size` is a required `int` and `eTag`/`lastModified`
// are required strings, so `size` is used directly; the string fields are still parsed
// defensively when metadata is built (a blank/unparseable timestamp is omitted rather than
// failing the load).
type S3Item record {|
    // The full object key, including any '/' separators.
    string key;
    // The object size in bytes as reported by S3.
    int size = 0;
    // The object's entity tag, with S3's surrounding double quotes stripped.
    string eTag = "";
    // The last-modified timestamp as reported by S3 (ISO-8601).
    string lastModified = "";
    // The object's storage class as reported by the listing. Objects in an archived class
    // (GLACIER/DEEP_ARCHIVE) require a RestoreObject before they can be read, so the loader
    // skips or rejects them by this field rather than failing on a GetObject error.
    s3:StorageClass storageClass = s3:STANDARD;
|};

// One page of an S3 object listing.
type S3Page record {|
    // The objects on this page.
    S3Item[] items;
    // Whether more objects exist beyond this page.
    boolean truncated;
    // The token to fetch the next page, as returned by S3 (`NextContinuationToken`). Present only
    // when `truncated` is true; the caller passes it back to continue the listing.
    string? continuationToken;
|};

// Builds the S3 client the loader reads through, from the connector's own configuration.
isolated function buildS3Client(s3:ConnectionConfig config) returns s3:Client|ai:Error {
    s3:Client|error s3Client = new s3:Client(config);
    if s3Client is error {
        return error ai:Error("Failed to initialize the AWS S3 client: " + s3Client.message(), s3Client);
    }
    return s3Client;
}

// Lists one page of objects under a prefix, normalizing the connector's result.
//
// The connector's `listObjects` is a single ListObjectsV2 call — it does not paginate; the caller
// (`loadPrefix`) drives paging with the `continuationToken`. `()` for `continuationToken` requests
// the first page; the `NextContinuationToken` from a truncated page is passed back for the next.
// `delimiter` ("/" for a non-recursive walk) makes S3 return only same-level keys in `objects`.
// The one `s3:S3Object` field that needs normalizing is the ETag, whose surrounding double quotes
// are stripped here rather than in the loader.
isolated function listObjectPage(s3:Client s3Client, string bucket, string? prefix, string? delimiter,
        string? continuationToken, int maxKeys) returns S3Page|ai:Error {
    // Build the config incrementally: each field of `s3:ListObjectsConfig` is optional, so an
    // absent value is simply left unset rather than passed as `()`.
    s3:ListObjectsConfig config = {maxKeys};
    if prefix is string {
        config.prefix = prefix;
    }
    if delimiter is string {
        config.delimiter = delimiter;
    }
    if continuationToken is string {
        config.continuationToken = continuationToken;
    }
    // Passed positionally. `listObjects` takes an included record parameter
    // (`*ListObjectsConfig`), and on Ballerina 2201.12 a rest-argument spread against one —
    // `listObjects(bucket, ...[config])` — compiles cleanly but delivers an empty record to
    // the callee, silently dropping prefix/delimiter/continuationToken. That turned every
    // call into an unfiltered whole-bucket listing whose paging never terminated, because
    // each response carried a fresh continuation token. Do not reintroduce the spread form.
    s3:ListObjectsResponse|s3:Error listing = s3Client->listObjects(bucket, config);
    if listing is s3:Error {
        return error ai:Error(
            string `Failed to list objects in bucket '${bucket}'` +
            (prefix is string ? string ` under prefix '${prefix}'` : "") +
            string `: ${listing.message()}`, listing);
    }
    S3Item[] items = [];
    foreach s3:S3Object obj in listing.objects {
        string key = obj.key;
        if key == "" {
            continue;
        }
        items.push({
            key,
            size: obj.size,
            // S3 returns the ETag wrapped in literal double quotes (it is an HTTP entity-tag).
            // Strip them so the metadata value compares against the bare hex digest callers have.
            eTag: unquote(obj.eTag),
            lastModified: obj.lastModified,
            storageClass: obj.storageClass
        });
    }
    return {items, truncated: listing.isTruncated, continuationToken: listing?.nextContinuationToken};
}

// Opens a byte stream over an object's content. The caller drains and closes the stream.
isolated function openObjectStream(s3:Client s3Client, string bucket, string key)
        returns stream<byte[], error?>|ai:Error {
    stream<byte[], error?>|error objStream = s3Client->getObjectAsStream(bucket, key);
    if objStream is error {
        return error ai:Error(
            string `Failed to open object '${key}' in bucket '${bucket}': ${objStream.message()}`, objStream);
    }
    return objStream;
}

// Resolves an exact object with HEAD requests (no body download): returns a normalized item if
// the object exists, `()` if it does not, or an `ai:Error` on a transport failure. Uses HEAD
// rather than a ListObjectsV2 probe because HEAD is order-independent (so it also works on
// directory buckets, whose listings are not lexicographically ordered) and needs only
// `s3:GetObject` on the key rather than `s3:ListBucket` on the bucket. `doesObjectExist`
// cleanly distinguishes "not found" (false) from a transport error; the follow-up
// `getObjectMetadata` supplies the size/ETag/last-modified/storage-class the caller needs.
isolated function headObject(s3:Client s3Client, string bucket, string key) returns S3Item?|ai:Error {
    boolean|s3:Error exists = s3Client->doesObjectExist(bucket, key);
    if exists is s3:Error {
        return error ai:Error(
            string `Failed to check whether '${key}' exists in bucket '${bucket}': ${exists.message()}`, exists);
    }
    if !exists {
        return ();
    }
    s3:ObjectMetadata|s3:Error metadata = s3Client->getObjectMetadata(bucket, key);
    if metadata is s3:Error {
        return error ai:Error(
            string `Failed to read metadata for '${key}' in bucket '${bucket}': ${metadata.message()}`, metadata);
    }
    return {
        key,
        size: metadata.contentLength,
        eTag: unquote(metadata.eTag),
        lastModified: metadata.lastModified,
        storageClass: metadata.storageClass
    };
}

// Whether an object's storage class requires a RestoreObject before it can be read. GLACIER
// and DEEP_ARCHIVE are asynchronous-retrieval tiers, so GetObject on them returns
// InvalidObjectState; GLACIER_IR and INTELLIGENT_TIERING retrieve synchronously and stay
// loadable. The loader decides by this field (authoritative in the listing) rather than by
// probing GetObject and inspecting the error.
isolated function isArchivedStorageClass(s3:StorageClass storageClass) returns boolean {
    return storageClass == s3:GLACIER || storageClass == s3:DEEP_ARCHIVE;
}

// Whether an error is a per-object failure that a prefix walk may skip rather than abort the
// whole load (e.g. an undecodable text object), as opposed to a fatal error such as an auth or
// connectivity failure. Signalled by a `recoverableInWalk` flag on the error's detail.
isolated function isRecoverableInWalk(error e) returns boolean {
    var flag = e.detail()["recoverableInWalk"];
    return flag is boolean && flag;
}

// Strips a single pair of surrounding double quotes, as S3 wraps ETag values in them.
isolated function unquote(string value) returns string {
    if value.length() >= 2 && value.startsWith("\"") && value.endsWith("\"") {
        return value.substring(1, value.length() - 1);
    }
    return value;
}
