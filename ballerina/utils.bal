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
import ballerina/jballerina.java;
import ballerina/time;

// How an object's content is turned into text.
enum DocumentKind {
    PLAIN_TEXT,
    PDF,
    DOCX,
    PPTX,
    XLSX,
    // The legacy binary .doc/.ppt/.xls formats: recognised only to give a clear error.
    UNSUPPORTED_OFFICE,
    UNSUPPORTED
}

// Builds a text document from an object's bytes, or returns `()` when it can't be represented as
// text.
isolated function buildDocument(byte[] content, string bucket, string key, int size,
        string lastModified, string eTag, string? contentType = ()) returns ai:TextDocument?|ai:Error {
    ai:Metadata metadata = {fileName: baseName(key)};
    // `ai`'s `guessChunker` matches `text/markdown`/`text/html` exactly, so no `; charset=...`.
    string? mimeType = mimeTypeForExtension(getExtension(key)) ?: bareMimeType(contentType);
    if mimeType is string {
        metadata.mimeType = mimeType;
    }
    metadata.fileSize = <decimal>size;
    time:Utc? modifiedAt = toUtc(lastModified);
    if modifiedAt is time:Utc {
        metadata.modifiedAt = modifiedAt;
    }
    // `ai:Metadata`'s declared fields are fixed, so these go in as open fields.
    metadata["bucket"] = bucket;
    metadata["key"] = key;
    if eTag != "" {
        metadata["eTag"] = eTag;
    }

    match classifyObject(key, contentType) {
        PLAIN_TEXT => {
            string|error text = string:fromBytes(stripUtf8Bom(content));
            if text is error {
                // Tagged recoverable so a prefix walk skips an undecodable object (e.g. a
                // UTF-16 or Windows-1252 file) rather than aborting the whole load; a named
                // key still surfaces the error to its caller.
                return error ai:Error(
                    string `Failed to decode text content of '${key}' in bucket '${bucket}': ${text.message()}`,
                    text, recoverableInWalk = true);
            }
            return {content: text, metadata};
        }
        PDF => {
            string|error text = extractPdfText(content, key);
            if text is error {
                return extractionError(bucket, key, text);
            }
            return {content: text, metadata};
        }
        DOCX => {
            string|error text = extractDocxText(content, key);
            if text is error {
                return extractionError(bucket, key, text);
            }
            return {content: text, metadata};
        }
        PPTX => {
            string|error text = extractPptxText(content, key);
            if text is error {
                return extractionError(bucket, key, text);
            }
            return {content: text, metadata};
        }
        XLSX => {
            string|error text = extractXlsxText(content, key);
            if text is error {
                return extractionError(bucket, key, text);
            }
            return {content: text, metadata};
        }
    }
    return ();
}

// Extraction failures are specific to one object, so a prefix walk can skip them.
isolated function extractionError(string bucket, string key, error cause) returns ai:Error =>
    error ai:Error(string `Failed to extract text from '${key}' in bucket '${bucket}': ${cause.message()}`,
            cause, recoverableInWalk = true);

// Parser dispatch is explicit: Tika's AutoDetectParser is never used.
isolated function extractPdfText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractPdfText"
} external;

// POI is used directly: Tika's OOXMLParser probes archives through a commons-compress that
// conflicts with the runtime's commons-lang3 (see TextExtractor.java).
isolated function extractDocxText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractDocxText"
} external;

isolated function extractPptxText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractPptxText"
} external;

// Cells are tab-separated, one row per line, and each sheet starts with its name.
isolated function extractXlsxText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractXlsxText"
} external;

// The extension decides when it's recognised, since S3 Content-Types are often generic or wrong;
// the Content-Type is the fallback for keys without a known extension.
isolated function classifyObject(string key, string? contentType) returns DocumentKind {
    DocumentKind kind = classify(key, ());
    if kind == UNSUPPORTED && contentType is string {
        return classify(key, contentType);
    }
    return kind;
}

// The Content-Type without parameters, or `()` when it says nothing about the content.
isolated function bareMimeType(string? contentType) returns string? {
    if contentType is () {
        return ();
    }
    int? semicolon = contentType.indexOf(";");
    string mime = (semicolon is int ? contentType.substring(0, semicolon) : contentType).trim().toLowerAscii();
    return mime == "" || mime == "application/octet-stream" || mime == "binary/octet-stream" ? () : mime;
}

// Classifies by MIME type when one is given, then by extension.
isolated function classify(string fileName, string? mimeType) returns DocumentKind {
    string rawMime = (mimeType ?: "").toLowerAscii();
    int? semicolon = rawMime.indexOf(";");
    string mime = (semicolon is int ? rawMime.substring(0, semicolon) : rawMime).trim();
    string extension = getExtension(fileName);
    // An explicit MIME type wins over the extension.
    if mime != "" {
        if mime.startsWith("text/") || TEXT_MIME_TYPES.indexOf(mime) !is () {
            return PLAIN_TEXT;
        }
        if mime == "application/pdf" {
            return PDF;
        }
        if mime == DOCX_MIME_TYPE {
            return DOCX;
        }
        if mime == PPTX_MIME_TYPE {
            return PPTX;
        }
        if mime == XLSX_MIME_TYPE {
            return XLSX;
        }
        if UNSUPPORTED_OFFICE_MIME_TYPES.indexOf(mime) !is () {
            return UNSUPPORTED_OFFICE;
        }
        // An unrecognised MIME type says nothing, so fall back to the extension.
    }
    if TEXT_EXTENSIONS.indexOf(extension) !is () {
        return PLAIN_TEXT;
    }
    if extension == "pdf" {
        return PDF;
    }
    if extension == "docx" {
        return DOCX;
    }
    if extension == "pptx" {
        return PPTX;
    }
    if extension == "xlsx" {
        return XLSX;
    }
    if UNSUPPORTED_OFFICE_EXTENSIONS.indexOf(extension) !is () {
        return UNSUPPORTED_OFFICE;
    }
    return UNSUPPORTED;
}

// Reads a stream into memory up to `maxBytes`, closing it on every path.
isolated function drainStream(stream<byte[], error?> objStream, int maxBytes, string bucket, string key)
        returns byte[]|ai:Error {
    byte[] content = [];
    int total = 0;
    while true {
        record {|byte[] value;|}|error? next = objStream.next();
        if next is error {
            closeQuietly(objStream);
            return error ai:Error(
                string `Failed to read object '${key}' in bucket '${bucket}': ${next.message()}`, next);
        }
        if next is () {
            break;
        }
        total += next.value.length();
        if total > maxBytes {
            closeQuietly(objStream);
            // The reported size was within the limit but the content isn't; still per-object.
            return error ai:Error(string `Object '${key}' in bucket '${bucket}' exceeds the configured ` +
                string `maximum size of ${maxBytes} bytes and was not read into memory.`, recoverableInWalk = true);
        }
        content.push(...next.value);
    }
    error? closeResult = objStream.close();
    if closeResult is error {
        return error ai:Error(
            string `Failed to close the stream for object '${key}' in bucket '${bucket}': ${closeResult.message()}`,
            closeResult);
    }
    return content;
}

isolated function closeQuietly(stream<byte[], error?> objStream) {
    error? closeResult = objStream.close();
    if closeResult is error {
        // A close failure must not mask the original error.
    }
}

// Drops a leading UTF-8 byte-order mark, which would otherwise end up in the text.
isolated function stripUtf8Bom(byte[] content) returns byte[] {
    if content.length() >= 3 && content[0] == 0xEF && content[1] == 0xBB && content[2] == 0xBF {
        return content.slice(3);
    }
    return content;
}

// The last '/'-separated segment of a key.
isolated function baseName(string key) returns string {
    int? lastSlash = key.lastIndexOf("/");
    return lastSlash is () ? key : key.substring(lastSlash + 1);
}

// Lower-cased extension of the key's last segment, so a dotted folder name isn't an extension.
isolated function getExtension(string fileName) returns string {
    string name = baseName(fileName);
    int? lastDotIndex = name.lastIndexOf(".");
    if lastDotIndex is () {
        return "";
    }
    return name.substring(lastDotIndex + 1).toLowerAscii();
}

// Case-insensitive; a leading dot on an allowed extension is optional. Empty allows everything.
isolated function matchesExtensionFilter(string fileName, string[]? includeExtensions) returns boolean {
    if includeExtensions is () || includeExtensions.length() == 0 {
        return true;
    }
    string extension = getExtension(fileName);
    foreach string allowed in includeExtensions {
        string normalized = allowed.toLowerAscii();
        if normalized.startsWith(".") {
            normalized = normalized.substring(1);
        }
        if normalized == extension {
            return true;
        }
    }
    return false;
}

isolated function toUtc(string dateTime) returns time:Utc? {
    if dateTime.trim() == "" {
        return ();
    }
    time:Utc|error utc = time:utcFromString(dateTime);
    return utc is time:Utc ? utc : ();
}

// The text/markdown and text/html values route markup to `ai`'s Markdown/HTML chunkers.
isolated function mimeTypeForExtension(string extension) returns string? => MIME_TYPES_BY_EXTENSION[extension];

// Non-`text/` MIME types that are decoded as text.
final readonly & string[] TEXT_MIME_TYPES = [
    "application/json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/x-yaml",
    "application/yaml",
    "application/csv",
    "application/typescript"
];

// `ts` is left out: in S3 it is far more often a video segment than TypeScript.
final readonly & string[] TEXT_EXTENSIONS = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
    "yaml", "yml", "log", "ini", "conf", "properties", "css", "js"
];

const string DOCX_MIME_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

const string PPTX_MIME_TYPE = "application/vnd.openxmlformats-officedocument.presentationml.presentation";

const string XLSX_MIME_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

final readonly & string[] UNSUPPORTED_OFFICE_MIME_TYPES = [
    "application/msword",
    "application/vnd.ms-powerpoint",
    "application/vnd.ms-excel"
];

final readonly & string[] UNSUPPORTED_OFFICE_EXTENSIONS = ["doc", "ppt", "xls"];

final readonly & map<string> MIME_TYPES_BY_EXTENSION = {
    "md": "text/markdown",
    "markdown": "text/markdown",
    "html": "text/html",
    "htm": "text/html",
    "txt": "text/plain",
    "text": "text/plain",
    "log": "text/plain",
    "ini": "text/plain",
    "conf": "text/plain",
    "properties": "text/plain",
    "csv": "text/csv",
    "tsv": "text/tab-separated-values",
    "json": "application/json",
    "xml": "application/xml",
    "yaml": "application/yaml",
    "yml": "application/yaml",
    "css": "text/css",
    "js": "text/javascript",
    "pdf": "application/pdf",
    "docx": DOCX_MIME_TYPE,
    "pptx": PPTX_MIME_TYPE,
    "xlsx": XLSX_MIME_TYPE
};
