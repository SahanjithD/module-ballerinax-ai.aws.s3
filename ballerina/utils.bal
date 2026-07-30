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

// How an object's content is turned into text, derived from its key/MIME type. Matches the
// file types supported by `ballerina/ai`'s built-in `TextDataLoader` exactly: `md`/`html`/`htm`
// and other natively-textual types are decoded directly; `pdf` is extracted with Tika and
// `docx`/`pptx` with POI; the remaining Office formats are recognised only so they can be
// rejected or skipped.
enum DocumentKind {
    // Inherently textual (md/html/htm/txt/csv/json/xml/yaml/…); decoded from its bytes.
    PLAIN_TEXT,
    // A PDF document; text extracted via Tika's PDFParser.
    PDF,
    // A Word document (.docx); text extracted via POI's XWPFWordExtractor.
    DOCX,
    // A PowerPoint presentation (.pptx); text extracted via POI's SlideShowExtractor.
    PPTX,
    // An Excel workbook (.xlsx); text extracted via POI's XSSFExcelExtractor.
    XLSX,
    // An unsupported Microsoft Office format: the legacy binary ones (.doc/.ppt/.xls). They are
    // skipped in prefix walks and rejected with a format-specific error when named explicitly.
    UNSUPPORTED_OFFICE,
    // Cannot be represented as text (images, audio, unknown binary); skipped.
    UNSUPPORTED
}

// Builds an `ai:TextDocument` from an object's downloaded bytes: natively-textual content is
// decoded directly, `pdf` is extracted with Tika, and `docx`/`pptx` with POI. Returns `()` when
// the object cannot be represented as text (unsupported Office, images, unknown binary),
// signalling the caller to skip or reject it. `size` is the byte count S3 reported; `lastModified`
// is parsed defensively — a blank or unparseable timestamp is omitted rather than failing the load.
isolated function buildDocument(byte[] content, string bucket, string key, int size,
        string lastModified, string eTag) returns ai:TextDocument?|ai:Error {
    ai:Metadata metadata = {fileName: baseName(key)};
    // A clean, parameter-free MIME type derived from the key extension. `ai`'s
    // `guessChunker` matches `text/markdown`/`text/html` *exactly*, so a `; charset=...`
    // suffix (which S3's Content-Type often carries) must never reach it.
    string? mimeType = mimeTypeForExtension(getExtension(key));
    if mimeType is string {
        metadata.mimeType = mimeType;
    }
    metadata.fileSize = <decimal>size;
    time:Utc? modifiedAt = toUtc(lastModified);
    if modifiedAt is time:Utc {
        metadata.modifiedAt = modifiedAt;
    }
    // bucket/key/eTag are recorded as open metadata fields (quoted keys), the only way to
    // extend `ai:Metadata`, whose declared fields are a fixed set.
    metadata["bucket"] = bucket;
    metadata["key"] = key;
    if eTag != "" {
        metadata["eTag"] = eTag;
    }

    match classify(key, ()) {
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
                return error ai:Error(
                    string `Failed to extract text from '${key}' in bucket '${bucket}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
        DOCX => {
            string|error text = extractDocxText(content, key);
            if text is error {
                return error ai:Error(
                    string `Failed to extract text from '${key}' in bucket '${bucket}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
        PPTX => {
            string|error text = extractPptxText(content, key);
            if text is error {
                return error ai:Error(
                    string `Failed to extract text from '${key}' in bucket '${bucket}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
        XLSX => {
            string|error text = extractXlsxText(content, key);
            if text is error {
                return error ai:Error(
                    string `Failed to extract text from '${key}' in bucket '${bucket}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
    }
    return ();
}

// Extracts plain text from a PDF document using Apache Tika's PDFParser, reading directly
// from the in-memory bytes (no temporary file). `fileName` is passed as a Tika resource-name
// hint. Dispatch is explicit — AutoDetectParser is never used — so Tika's container
// detection (and its version-sensitive commons-compress probing) never runs.
isolated function extractPdfText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractPdfText"
} external;

// Extracts plain text from a Word document (.docx) using POI's XWPFWordExtractor, reading the
// OPC package straight from the in-memory bytes (no temporary file). Tika is bypassed for
// OOXML on purpose: its OOXMLParser runs a zip-container detection pass that probes archive
// formats through commons-compress, which both defeats the point of explicit dispatch and
// breaks against the commons-lang3 the Ballerina runtime bundles (see TextExtractor.java).
isolated function extractDocxText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractDocxText"
} external;

// Extracts plain text from a PowerPoint presentation (.pptx) using POI's SlideShowExtractor,
// reading straight from the in-memory bytes (no temporary file). See `extractDocxText` for why
// Tika's OOXMLParser is not used.
isolated function extractPptxText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractPptxText"
} external;

// Extracts plain text from an Excel workbook (.xlsx) using POI's XSSFExcelExtractor, reading
// straight from the in-memory bytes (no temporary file). Cells are rendered tab-separated, one
// row per line, each sheet prefixed with its name. See `extractDocxText` for why Tika's
// OOXMLParser is not used.
isolated function extractXlsxText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.aws.s3.TextExtractor",
    name: "extractXlsxText"
} external;

// Classifies an object by how its text is obtained, using MIME type (when known) then the
// key extension. S3 object listings carry no Content-Type, so in practice classification is
// by extension; the `mimeType` parameter is honoured when a caller has one.
isolated function classify(string fileName, string? mimeType) returns DocumentKind {
    // Drop any media-type parameters (e.g. "; charset=utf-8") before comparing against the bare
    // MIME constants and tables, which hold no parameters.
    string rawMime = (mimeType ?: "").toLowerAscii();
    int? semicolon = rawMime.indexOf(";");
    string mime = (semicolon is int ? rawMime.substring(0, semicolon) : rawMime).trim();
    string extension = getExtension(fileName);
    if mime.startsWith("text/") || (mime != "" && TEXT_MIME_TYPES.indexOf(mime) !is ())
            || TEXT_EXTENSIONS.indexOf(extension) !is () {
        return PLAIN_TEXT;
    }
    if mime == "application/pdf" || extension == "pdf" {
        return PDF;
    }
    if mime == DOCX_MIME_TYPE || extension == "docx" {
        return DOCX;
    }
    if mime == PPTX_MIME_TYPE || extension == "pptx" {
        return PPTX;
    }
    if mime == XLSX_MIME_TYPE || extension == "xlsx" {
        return XLSX;
    }
    // The remaining Office formats are recognised solely so they can be rejected with a clear
    // message (named keys) or skipped (prefix walks) — the loader extracts text from PDF, .docx,
    // .pptx and .xlsx only, not the legacy binary .doc/.ppt/.xls formats.
    if (mime != "" && UNSUPPORTED_OFFICE_MIME_TYPES.indexOf(mime) !is ())
            || UNSUPPORTED_OFFICE_EXTENSIONS.indexOf(extension) !is () {
        return UNSUPPORTED_OFFICE;
    }
    return UNSUPPORTED;
}

// Drains a byte stream fully into memory, enforcing a size ceiling, and closes the stream on
// every exit path (normal completion, ceiling exceeded, or a mid-read error) so no stream is
// ever leaked. An object exceeding `maxBytes` fails with a clear `ai:Error` rather than risking
// an out-of-memory condition; the over-limit chunk is never appended, so the bound is exact.
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
            return error ai:Error(string `Object '${key}' in bucket '${bucket}' exceeds the configured ` +
                string `maximum size of ${maxBytes} bytes and was not read into memory.`);
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

// Closes a stream, ignoring any close error. Used on error paths where the original error
// is the one worth surfacing.
isolated function closeQuietly(stream<byte[], error?> objStream) {
    error? closeResult = objStream.close();
    if closeResult is error {
        // Intentionally ignored: a close failure must not mask the read/ceiling error.
    }
}

// Returns `content` with a leading UTF-8 byte-order mark (EF BB BF) removed, or `content`
// unchanged when none is present. S3 objects exported from Excel/Windows tools carry a BOM;
// left in place it decodes to a leading U+FEFF that pollutes embeddings and defeats the
// first-character heuristics of `ai`'s Markdown/HTML chunkers. Only the 3 BOM bytes are dropped
// — the object's actual content is never altered. (UTF-16/Windows-1252 encodings are not
// decoded; an object in one of those fails to decode and is skipped during a prefix walk.)
isolated function stripUtf8Bom(byte[] content) returns byte[] {
    if content.length() >= 3 && content[0] == 0xEF && content[1] == 0xBB && content[2] == 0xBF {
        return content.slice(3);
    }
    return content;
}

// Returns the last '/'-separated segment of a key (its "file name"), or the whole key
// when it contains no '/'. Used so that a dot in a directory component (e.g.
// "example.com/homepage") is never mistaken for a file extension.
isolated function baseName(string key) returns string {
    int? lastSlash = key.lastIndexOf("/");
    return lastSlash is () ? key : key.substring(lastSlash + 1);
}

// Returns the lower-cased extension of a key's last path segment (without the dot), or ""
// if none. Only the segment after the final '/' is considered, so keys with a dotted
// directory component (e.g. "example.com/homepage", "v1.2/README") are not misclassified.
isolated function getExtension(string fileName) returns string {
    string name = baseName(fileName);
    int? lastDotIndex = name.lastIndexOf(".");
    if lastDotIndex is () {
        return "";
    }
    return name.substring(lastDotIndex + 1).toLowerAscii();
}

// Reports whether a key passes the extension allowlist (()/empty matches all). A leading
// dot on an allowed entry is optional and matching is case-insensitive.
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

// Parses an ISO 8601 timestamp into time:Utc, or () if absent/blank/unparseable.
isolated function toUtc(string dateTime) returns time:Utc? {
    if dateTime.trim() == "" {
        return ();
    }
    time:Utc|error utc = time:utcFromString(dateTime);
    return utc is time:Utc ? utc : ();
}

// Maps a key extension to a clean, parameter-free MIME type, or () when unknown. The
// text/markdown and text/html values are set precisely so `ai`'s `guessChunker` routes
// markup to its Markdown/HTML chunkers.
isolated function mimeTypeForExtension(string extension) returns string? => MIME_TYPES_BY_EXTENSION[extension];

// MIME types (outside the `text/` family) treated as natively textual. Consulted only when a
// caller supplies a MIME type; S3 listings carry none, so in practice extensions decide.
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

// Key extensions treated as natively textual (decoded directly, matching `ai`'s handling of
// md/html/htm plus the natively-textual types S3 buckets hold constantly).
final readonly & string[] TEXT_EXTENSIONS = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
    "yaml", "yml", "log", "ini", "conf", "properties", "css", "js", "ts"
];

// The Word (.docx) OOXML media type; extracted via POI's XWPFWordExtractor.
const string DOCX_MIME_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

// The PowerPoint (.pptx) OOXML media type; extracted via POI's SlideShowExtractor.
const string PPTX_MIME_TYPE = "application/vnd.openxmlformats-officedocument.presentationml.presentation";

// The Excel (.xlsx) OOXML media type; extracted via POI's XSSFExcelExtractor.
const string XLSX_MIME_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

// Unsupported Microsoft Office MIME types, recognised only to reject/skip. These are the legacy
// binary formats; their OOXML successors (.docx/.pptx/.xlsx) are all extracted.
final readonly & string[] UNSUPPORTED_OFFICE_MIME_TYPES = [
    "application/msword",
    "application/vnd.ms-powerpoint",
    "application/vnd.ms-excel"
];

// Unsupported Microsoft Office key extensions: the legacy binary formats only.
final readonly & string[] UNSUPPORTED_OFFICE_EXTENSIONS = ["doc", "ppt", "xls"];

// Extension-to-MIME-type table used for document metadata and chunker routing.
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
    "ts": "application/typescript",
    "pdf": "application/pdf",
    "docx": DOCX_MIME_TYPE,
    "pptx": PPTX_MIME_TYPE,
    "xlsx": XLSX_MIME_TYPE
};
