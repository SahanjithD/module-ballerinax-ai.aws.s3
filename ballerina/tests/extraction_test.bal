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

// These tests run real fixture files — a genuine PDF, Word .docx, PowerPoint .pptx, and a legacy
// binary .doc — through `buildDocument`, the function the loader calls once an object's bytes are
// in hand. They are what stops a Tika, PDFBox or POI version bump from silently breaking text
// extraction: a dependency change that broke a parser would fail here rather than quietly
// yielding empty documents in production.
//
// The three binary fixtures are deliberately **multi-unit**: the PDF has two pages, the .docx two
// paragraphs, and the .pptx two slides, with the two asserted phrases placed in *separate* units.
// `assertOrderedPhrases` then checks both are present and that the first precedes the second, so an
// extractor that dropped the trailing page/slide/paragraph, or concatenated units out of order,
// fails here rather than passing on the first unit alone.

// Asserts `first` and `second` both appear in `content`, with `first` strictly before `second`.
isolated function assertOrderedPhrases(string content, string first, string second, string label) {
    int? firstAt = content.indexOf(first);
    int? secondAt = content.indexOf(second);
    test:assertTrue(firstAt !is (), label + ": first unit missing; extracted: " + content);
    test:assertTrue(secondAt !is (), label + ": second unit missing (dropped?); extracted: " + content);
    if firstAt is int && secondAt is int {
        test:assertTrue(firstAt < secondAt,
                label + ": units extracted out of order; extracted: " + content);
    }
}

// Runs a fixture through document construction exactly as the loader does after draining.
isolated function buildFromFixture(string fixture, string key, int size = 1024,
        string lastModified = "2026-01-15T10:30:00Z", string eTag = "abc123")
        returns ai:TextDocument?|ai:Error {
    byte[]|io:Error content = io:fileReadBytes("tests/resources/" + fixture);
    if content is io:Error {
        return error ai:Error("Failed to read the test fixture " + fixture, content);
    }
    return buildDocument(content, TEST_BUCKET, key, size, lastModified, eTag);
}

// Returns the text content of a document.
isolated function contentOf(ai:Document doc) returns string {
    anydata content = doc.content;
    return content is string ? content : "";
}

@test:Config {}
isolated function testExtractTextFromPdfFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.pdf", "corpus/sample.pdf").ensureType();
    string content = contentOf(doc);
    // Page 1 phrase then page 2 phrase — proves both pages are concatenated, in order.
    assertOrderedPhrases(content, "Ballerina S3 loader PDF fixture",
            "Extracted from a real PDF document", "PDF");
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "application/pdf");
    test:assertEquals(metadata["key"], "corpus/sample.pdf");
}

@test:Config {}
isolated function testExtractTextFromDocxFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.docx", "corpus/sample.docx").ensureType();
    string content = contentOf(doc);
    // Paragraph 1 phrase then paragraph 2 phrase — the two now sit in separate <w:p> elements,
    // so an extractor returning only the first paragraph would fail this.
    assertOrderedPhrases(content, "Ballerina S3 loader DOCX fixture",
            "Extracted from a real Word document", "DOCX");
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType,
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
}

@test:Config {}
isolated function testExtractTextFromPptxFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.pptx", "corpus/sample.pptx").ensureType();
    string content = contentOf(doc);
    // Slide 1 title then slide 2 body — proves both slides are concatenated, in order.
    assertOrderedPhrases(content, "S3 Loader PPTX Fixture",
            "Extracted from a real PowerPoint presentation", "PPTX");
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType,
            "application/vnd.openxmlformats-officedocument.presentationml.presentation");
}

@test:Config {}
isolated function testExtractTextFromXlsxFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.xlsx", "corpus/sample.xlsx").ensureType();
    string content = contentOf(doc);
    // A phrase on the first sheet then a phrase on a second sheet — proves every sheet is
    // extracted and concatenated in workbook order, so dropping the trailing sheet fails here.
    assertOrderedPhrases(content, "Ballerina S3 loader XLSX fixture",
            "Extracted from a real Excel spreadsheet", "XLSX");
    // A cell value from the tabular region must survive alongside the free-text cells.
    test:assertTrue(content.includes("Revenue"),
            "Tabular cell values must be extracted; got: " + content);
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType,
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
}

// ---------------------------------------------------------------------------
// Image-bearing documents (image-only and image+text) for each binary format
// ---------------------------------------------------------------------------
//
// The extractors are text-only by design — Tika's PDFParser runs no OCR, and POI's
// XWPFWordExtractor/SlideShowExtractor read text runs, not pictures. These fixtures pin down what
// that means for the two content shapes the pure-text fixtures above never exercise:
//
//   *image-only.*  a scanned-style document whose only content is an embedded image and no text
//                  run at all. Extraction yields no text, and `buildDocument` wraps that verbatim:
//                  the object becomes a `TextDocument` with empty content — no skip, no warning, no
//                  error (contrast `testUnsupportedBinaryYieldsNoDocument`, where an unsupported
//                  *type* is skipped; here the type is supported but its text is empty). This is a
//                  known limitation, not a defect to fix: a caller wanting scanned PDFs indexed must
//                  OCR them upstream. The tests assert the empty-but-successful contract so a future
//                  change that started erroring, panicking, or skipping these would be caught.
//
//   *mixed.*       an image and text together. The text must still come through intact and the
//                  image must not corrupt or truncate it, so extraction of a real-world document
//                  that interleaves both is proven, not assumed.
//
// The fixtures embed a genuine 1x1 PNG (PDFs embed a raw RGB image XObject); the .docx/.pptx are
// built from the same known-good OPC packages as the sample.* fixtures with the image part added.

// Asserts a supported binary type with no extractable text yields a successful, empty document.
isolated function assertEmptyButSuccessful(string fixture, string key, string expectedMime,
        string label) returns error? {
    ai:TextDocument doc = check buildFromFixture(fixture, key).ensureType();
    test:assertEquals(contentOf(doc).trim(), "",
            label + ": an image-only document must extract to empty text; got: " + contentOf(doc));
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, expectedMime,
            label + ": the MIME type must still be recorded for an image-only document");
    test:assertEquals(metadata["key"], key, label + ": the key must still be recorded");
}

@test:Config {}
isolated function testImageOnlyPdfYieldsEmptyDocument() returns error? {
    check assertEmptyButSuccessful("image-only.pdf", "corpus/image-only.pdf",
            "application/pdf", "PDF");
}

@test:Config {}
isolated function testImageOnlyDocxYieldsEmptyDocument() returns error? {
    check assertEmptyButSuccessful("image-only.docx", "corpus/image-only.docx",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "DOCX");
}

@test:Config {}
isolated function testImageOnlyPptxYieldsEmptyDocument() returns error? {
    check assertEmptyButSuccessful("image-only.pptx", "corpus/image-only.pptx",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation", "PPTX");
}

@test:Config {}
isolated function testImageOnlyXlsxYieldsNoCellText() returns error? {
    // The .xlsx analogue of the image-only PDF/DOCX/PPTX cases: a sheet whose only content is an
    // embedded image. POI reads no OCR text from the picture, so no *cell* data is extracted — but
    // unlike the other formats, XSSFExcelExtractor always emits each sheet's name, so the result is
    // the sheet name alone ("Picture") rather than literally empty. The contract this pins down is
    // that the image contributes no text and no binary leaks into the output.
    ai:TextDocument doc =
        check buildFromFixture("image-only.xlsx", "corpus/image-only.xlsx").ensureType();
    string content = contentOf(doc);
    test:assertEquals(content.trim(), "Picture",
            "An image-only sheet must extract to its sheet name only, with no cell text; got: " + content);
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType,
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "The MIME type must still be recorded for an image-only workbook");
}

@test:Config {}
isolated function testMixedImageAndTextPdfExtractsText() returns error? {
    // A page with both an image XObject and a text-show operator: the image must not swallow the
    // text.
    ai:TextDocument doc =
        check buildFromFixture("mixed.pdf", "corpus/mixed.pdf").ensureType();
    string content = contentOf(doc);
    test:assertTrue(content.includes("Ballerina S3 loader mixed PDF fixture"),
            "The text alongside the image must be extracted; got: " + content);
}

@test:Config {}
isolated function testMixedImageAndTextDocxExtractsText() returns error? {
    // The original two text paragraphs plus an inline picture: all the text must survive, in order.
    ai:TextDocument doc =
        check buildFromFixture("mixed.docx", "corpus/mixed.docx").ensureType();
    string content = contentOf(doc);
    assertOrderedPhrases(content, "Ballerina S3 loader DOCX fixture",
            "Extracted from a real Word document", "mixed DOCX");
}

@test:Config {}
isolated function testMixedImageAndTextPptxExtractsText() returns error? {
    // A slide carrying both text shapes and a picture: the slide text must still be extracted.
    ai:TextDocument doc =
        check buildFromFixture("mixed.pptx", "corpus/mixed.pptx").ensureType();
    string content = contentOf(doc);
    assertOrderedPhrases(content, "S3 Loader PPTX Fixture",
            "This is slide one of the deck.", "mixed PPTX");
}

@test:Config {}
isolated function testMixedImageAndTextXlsxExtractsText() returns error? {
    // A sheet carrying both cell text and a picture: the cell text must still be extracted.
    ai:TextDocument doc =
        check buildFromFixture("mixed.xlsx", "corpus/mixed.xlsx").ensureType();
    string content = contentOf(doc);
    assertOrderedPhrases(content, "Ballerina S3 loader XLSX fixture",
            "Extracted from a real Excel spreadsheet", "mixed XLSX");
}

@test:Config {}
isolated function testExtractTextFromMarkdownFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.md", "corpus/sample.md").ensureType();
    string content = contentOf(doc);
    // Markdown is passed through verbatim, exactly as `ai`'s own loader does — the markup is
    // stripped later by the Markdown chunker, not here.
    test:assertTrue(content.includes("# S3 Loader Markdown Fixture"),
            "Markdown must be decoded verbatim, including its markup; got: " + content);
    test:assertTrue(content.includes("- first bullet"), "Markdown body missing; got: " + content);
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "text/markdown");
}

@test:Config {}
isolated function testExtractTextFromHtmlFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.html", "corpus/sample.html").ensureType();
    string content = contentOf(doc);
    // HTML is likewise decoded verbatim, tags included.
    test:assertTrue(content.includes("<h1>Heading of the HTML fixture</h1>"),
            "HTML must be decoded verbatim, including its tags; got: " + content);
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "text/html");
}

@test:Config {}
isolated function testExtractTextFromPlainTextFixture() returns error? {
    ai:TextDocument doc = check buildFromFixture("sample.txt", "corpus/sample.txt").ensureType();
    string content = contentOf(doc);
    test:assertTrue(content.includes("Ballerina S3 loader plain text fixture"),
            "Plain text decoding failed; got: " + content);
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "text/plain");
}

@test:Config {}
isolated function testLegacyDocFixtureIsNotExtracted() returns error? {
    // A genuine legacy binary Word document. Classification must reject it before any parser
    // sees it, so `buildDocument` returns () and the caller decides whether that is a skip
    // (prefix walk) or an error (explicitly named key).
    ai:TextDocument? doc = check buildFromFixture("legacy.doc", "corpus/legacy.doc");
    test:assertTrue(doc is (), "A legacy .doc must not produce a document");
    test:assertEquals(classify("corpus/legacy.doc", ()), UNSUPPORTED_OFFICE,
            "A legacy .doc must classify as unsupported Office, driving the format-specific error");
}

@test:Config {}
isolated function testCorruptPdfSurfacesAsExtractionError() {
    // Bytes with a PDF header but a garbage body: the parser must fail, and that failure must
    // arrive as a wrapped ai:Error naming the object — never as a panic.
    byte[] corrupt = "%PDF-1.4\nnot actually a pdf body".toBytes();
    ai:TextDocument?|ai:Error result =
        buildDocument(corrupt, TEST_BUCKET, "corpus/broken.pdf", 31, "", "");
    test:assertTrue(result is ai:Error, "A corrupt PDF must fail rather than yield an empty document");
    if result is ai:Error {
        test:assertTrue(result.message().includes("Failed to extract text from"),
                "Unexpected message: " + result.message());
        test:assertTrue(result.message().includes("corpus/broken.pdf"),
                "The error must name the key: " + result.message());
        test:assertTrue(result.message().includes(TEST_BUCKET), "The error must name the bucket");
    }
}

@test:Config {}
isolated function testUnsupportedBinaryYieldsNoDocument() returns error? {
    ai:TextDocument? doc = check buildDocument([1, 2, 3], TEST_BUCKET, "a.png", 3, "", "");
    test:assertTrue(doc is (), "An unsupported type must yield no document, signalling a skip");
}

@test:Config {}
isolated function testUtf8ContentIsDecodedCorrectly() returns error? {
    string body = "héllo wörld — ünïcode ✓";
    ai:TextDocument doc =
        check buildDocument(body.toBytes(), TEST_BUCKET, "utf8.txt", 0, "", "").ensureType();
    test:assertEquals(contentOf(doc), body, "UTF-8 content must round-trip exactly");
}

@test:Config {}
isolated function testInvalidUtf8SurfacesAsError() {
    // A lone continuation byte is not valid UTF-8.
    ai:TextDocument?|ai:Error result =
        buildDocument([0xC3, 0x28, 0xA9], TEST_BUCKET, "bad.txt", 3, "", "");
    test:assertTrue(result is ai:Error, "Undecodable content must surface as an error");
    if result is ai:Error {
        test:assertTrue(result.message().includes("Failed to decode text content"),
                "Unexpected message: " + result.message());
    }
}

// ---------------------------------------------------------------------------
// Metadata mapping
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testMetadataMapping() returns error? {
    ai:TextDocument doc = check buildDocument("# Title".toBytes(), TEST_BUCKET, "docs/report.md",
            1234, "2026-01-15T10:30:00Z", "abc123").ensureType();
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.fileName, "report.md", "fileName must be the basename, not the full key");
    test:assertEquals(metadata["bucket"], TEST_BUCKET);
    test:assertEquals(metadata["key"], "docs/report.md");
    test:assertEquals(metadata["eTag"], "abc123");
    test:assertEquals(metadata.fileSize, <decimal>1234);
    // A markdown key must carry a clean `text/markdown` (no charset parameter), which is what
    // `ai`'s `guessChunker` matches on exactly.
    test:assertEquals(metadata.mimeType, "text/markdown");
    test:assertTrue(metadata.modifiedAt !is (), "A valid timestamp must map to modifiedAt");
}

@test:Config {}
isolated function testMetadataToleratesMalformedLastModified() returns error? {
    // `lastModified` is a required string in the connector, but its value is still parsed
    // defensively: an unparseable timestamp is omitted rather than failing the load.
    ai:TextDocument doc = check buildDocument("body".toBytes(), TEST_BUCKET, "docs/a.txt",
            10, "not-a-timestamp", "e").ensureType();
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertTrue(metadata.modifiedAt is (),
            "An unparseable timestamp must be omitted rather than failing the load");
    test:assertEquals(metadata.fileName, "a.txt", "The rest of the metadata must survive");
}

@test:Config {}
isolated function testBlankStringMetadataFieldsAreOmitted() returns error? {
    // `size` is a required int (0 for an empty object), but `lastModified`/`eTag` are strings
    // whose blank value is treated as "no value" and left out of the metadata rather than
    // stored as "". A zero size is a real value and is recorded as fileSize 0.
    ai:TextDocument doc =
        check buildDocument("body".toBytes(), TEST_BUCKET, "a.txt", 0, "", "").ensureType();
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.fileSize, <decimal>0, "A zero size is a real value, recorded as 0");
    test:assertTrue(metadata.modifiedAt is (), "A blank timestamp must be omitted");
    test:assertTrue(metadata["eTag"] is (), "A blank ETag must be omitted, not stored as empty");
    test:assertEquals(metadata["bucket"], TEST_BUCKET, "The bucket must still be recorded");
}

@test:Config {}
isolated function testHtmlMimeTypeIsCleanForChunkerRouting() returns error? {
    ai:TextDocument doc =
        check buildDocument("<h1>Hi</h1>".toBytes(), TEST_BUCKET, "page.html", 0, "", "").ensureType();
    ai:Metadata metadata = check doc.metadata.ensureType();
    test:assertEquals(metadata.mimeType, "text/html");
}

// ---------------------------------------------------------------------------
// Classification table
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testClassificationMatchesAiSupportedTypes() {
    // The supported set covers `ballerina/ai`'s built-in TextDataLoader (pdf, docx, pptx, html,
    // htm, md, plus the natively-textual types S3 buckets hold) and additionally .xlsx, which
    // this loader extracts via POI's XSSFExcelExtractor.
    test:assertEquals(classify("a.pdf", ()), PDF);
    test:assertEquals(classify("a.docx", ()), DOCX);
    test:assertEquals(classify("a.pptx", ()), PPTX);
    test:assertEquals(classify("a.xlsx", ()), XLSX);
    test:assertEquals(classify("a.html", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.htm", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.md", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.txt", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.csv", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.json", ()), PLAIN_TEXT);
    // The legacy binary Office formats are unsupported; their OOXML successors are extracted.
    test:assertEquals(classify("a.doc", ()), UNSUPPORTED_OFFICE);
    test:assertEquals(classify("a.ppt", ()), UNSUPPORTED_OFFICE);
    test:assertEquals(classify("a.xls", ()), UNSUPPORTED_OFFICE);
    // Anything else is skipped.
    test:assertEquals(classify("a.png", ()), UNSUPPORTED);
    test:assertEquals(classify("noextension", ()), UNSUPPORTED);
}

@test:Config {}
isolated function testClassificationIsCaseInsensitive() {
    // S3 keys are frequently uppercase; `ai`'s own loader mishandles this, so we must not.
    test:assertEquals(classify("REPORT.PDF", ()), PDF);
    test:assertEquals(classify("Notes.MD", ()), PLAIN_TEXT);
    test:assertEquals(classify("Deck.PPTX", ()), PPTX);
    test:assertEquals(classify("OLD.DOC", ()), UNSUPPORTED_OFFICE);
}

@test:Config {}
isolated function testClassificationIgnoresDotsInDirectoryComponents() {
    // The extension must be read from the last '/'-segment only. A dot in a directory
    // component must never be mistaken for a file extension (regression).
    test:assertEquals(classify("example.com/homepage.html", ()), PLAIN_TEXT,
            "A dotted directory prefix must not shadow the real .html extension");
    test:assertEquals(classify("v1.2/report.pdf", ()), PDF,
            "A dotted directory prefix must not shadow the real .pdf extension");
    // An extension-less key under a dotted prefix must classify by the segment after the
    // last '/', not pick up "com/homepage" or "2/README" as an "extension".
    test:assertEquals(classify("example.com/homepage", ()), UNSUPPORTED);
    test:assertEquals(classify("v1.2/README", ()), UNSUPPORTED);
    // The extension allowlist reads the same segment, so it must agree.
    test:assertTrue(matchesExtensionFilter("v1.2/report.pdf", ["pdf"]),
            "includeExtensions must match on the real extension, not a directory dot");
    test:assertFalse(matchesExtensionFilter("example.com/homepage", ["pdf"]));
}

@test:Config {}
isolated function testClassificationPrefersMimeTypeWhenSupplied() {
    test:assertEquals(classify("noextension", "application/pdf"), PDF);
    test:assertEquals(classify("noextension", "text/plain"), PLAIN_TEXT);
    test:assertEquals(classify("noextension", "application/msword"), UNSUPPORTED_OFFICE);
    test:assertEquals(classify("noextension", "application/vnd.ms-excel"), UNSUPPORTED_OFFICE);
    test:assertEquals(classify("noextension",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"), XLSX);
}
