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

// Everything that touches `ballerinax/aws.s3` lives here, so the loader deals in normalized values.

// The subset of an object's metadata the loader uses.
type S3Item record {|
    string key;
    int size = 0;
    // Without S3's surrounding double quotes.
    string eTag = "";
    string lastModified = "";
    s3:StorageClass storageClass = s3:STANDARD;
    // Known only for a key resolved with HEAD; listings carry none.
    string? contentType = ();
|};

type S3Page record {|
    S3Item[] items;
    boolean truncated;
    // S3's `NextContinuationToken`, present while `truncated` is true.
    string? continuationToken;
|};

isolated function buildS3Client(s3:ConnectionConfig config) returns s3:Client|ai:Error {
    s3:Client|error s3Client = new s3:Client(config);
    if s3Client is error {
        return error ai:Error("Failed to initialize the AWS S3 client: " + s3Client.message(), s3Client);
    }
    return s3Client;
}

// Lists one page of objects. `listObjects` makes a single ListObjectsV2 call, so the caller drives
// paging with `continuationToken`.
isolated function listObjectPage(s3:Client s3Client, string bucket, string? prefix, string? delimiter,
        string? continuationToken, int maxKeys) returns S3Page|ai:Error {
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
    // Pass the config positionally: on 2201.12 a rest spread (`...[config]`) into the included
    // record parameter compiles but delivers an empty record.
    s3:ListObjectsResponse|s3:Error listing = s3Client->listObjects(bucket, config);
    if listing is s3:NoSuchBucketError {
        return error ai:Error(
            string `Bucket '${bucket}' was not found. Check the bucket name and the connection's ` +
            string `region. (${listing.message()})`, listing);
    }
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
            eTag: unquote(obj.eTag),
            lastModified: obj.lastModified,
            storageClass: obj.storageClass
        });
    }
    return {items, truncated: listing.isTruncated, continuationToken: listing?.nextContinuationToken};
}

// Opens a byte stream over an object's content; the caller drains and closes it.
isolated function openObjectStream(s3:Client s3Client, string bucket, string key)
        returns stream<byte[], error?>|ai:Error {
    stream<byte[], error?>|error objStream = s3Client->getObject(bucket, key);
    if objStream is s3:NoSuchKeyError {
        // Deleted between being listed and being read: a prefix walk skips it. Other failures
        // (permissions, connectivity) affect every object, so they still fail the load.
        return error ai:Error(
            string `Object '${key}' in bucket '${bucket}' no longer exists: ${objStream.message()}`, objStream,
            recoverableInWalk = true);
    }
    if objStream is error {
        return error ai:Error(
            string `Failed to open object '${key}' in bucket '${bucket}': ${objStream.message()}`, objStream);
    }
    return objStream;
}

// Resolves a key with HEAD, returning `()` if it doesn't exist. HEAD needs only `s3:GetObject`
// and, unlike a listing probe, works on directory buckets, whose listings are unordered. A 403
// maps to the base `s3:Error`, so a key the caller can't read still fails rather than looking absent.
isolated function headObject(s3:Client s3Client, string bucket, string key) returns S3Item?|ai:Error {
    s3:ObjectMetadata|s3:Error metadata = s3Client->getObjectMetadata(bucket, key);
    if metadata is s3:NoSuchKeyError {
        return ();
    }
    if metadata is s3:Error {
        return error ai:Error(
            string `Failed to read metadata for '${key}' in bucket '${bucket}': ${metadata.message()}`, metadata);
    }
    return {
        key,
        size: metadata.contentLength,
        eTag: unquote(metadata.eTag),
        lastModified: metadata.lastModified,
        storageClass: metadata.storageClass,
        contentType: metadata?.contentType
    };
}

// GLACIER and DEEP_ARCHIVE objects need a RestoreObject before GetObject can read them.
isolated function isArchivedStorageClass(s3:StorageClass storageClass) returns boolean {
    return storageClass == s3:GLACIER || storageClass == s3:DEEP_ARCHIVE;
}

// Whether an error affects only one object (so a prefix walk can skip it), as flagged by
// `recoverableInWalk` on the error detail.
isolated function isRecoverableInWalk(error e) returns boolean {
    var flag = e.detail()["recoverableInWalk"];
    return flag is boolean && flag;
}

isolated function unquote(string value) returns string {
    if value.length() >= 2 && value.startsWith("\"") && value.endsWith("\"") {
        return value.substring(1, value.length() - 1);
    }
    return value;
}
