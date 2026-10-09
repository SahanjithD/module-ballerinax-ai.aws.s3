/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.ballerina.lib.ai.aws.s3;

import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BString;
import org.apache.poi.openxml4j.opc.OPCPackage;
import org.apache.poi.sl.extractor.SlideShowExtractor;
import org.apache.poi.xslf.usermodel.XMLSlideShow;
import org.apache.poi.xssf.extractor.XSSFExcelExtractor;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.apache.poi.xwpf.extractor.XWPFWordExtractor;
import org.apache.tika.metadata.Metadata;
import org.apache.tika.metadata.TikaCoreProperties;
import org.apache.tika.parser.ParseContext;
import org.apache.tika.parser.Parser;
import org.apache.tika.parser.pdf.PDFParser;
import org.apache.tika.parser.pdf.PDFParserConfig;
import org.apache.tika.sax.BodyContentHandler;

import java.io.ByteArrayInputStream;
import java.io.InputStream;

/**
 * Extracts plain text from PDF and OOXML documents held in memory, so object content never touches
 * disk.
 *
 * <p>Parsers are chosen explicitly; Tika's {@code AutoDetectParser} and {@code OOXMLParser} are not
 * used, because their container detection probes archives through a commons-compress that needs a
 * newer commons-lang3 than the one bundled in the Ballerina runtime. The OOXML formats go through
 * POI directly.
 */
public final class TextExtractor {

    private static final int UNLIMITED_CONTENT_SIZE = -1;

    // -1 keeps PDFBox from spilling to a temporary file.
    private static final long UNLIMITED_MAIN_MEMORY = -1L;

    private TextExtractor() {
    }

    /**
     * Extracts the text of a PDF.
     *
     * @param content  the PDF bytes
     * @param fileName the object key, passed to Tika as a resource-name hint
     * @return the text, or a Ballerina error
     */
    public static Object extractPdfText(BArray content, BString fileName) {
        try (InputStream stream = new ByteArrayInputStream(content.getBytes())) {
            Parser parser = new PDFParser();
            BodyContentHandler handler = new BodyContentHandler(UNLIMITED_CONTENT_SIZE);
            Metadata metadata = new Metadata();
            metadata.set(TikaCoreProperties.RESOURCE_NAME_KEY, fileName.getValue());
            PDFParserConfig pdfConfig = new PDFParserConfig();
            pdfConfig.setMaxMainMemoryBytes(UNLIMITED_MAIN_MEMORY);
            ParseContext parseContext = new ParseContext();
            parseContext.set(PDFParserConfig.class, pdfConfig);
            parser.parse(stream, handler, metadata, parseContext);
            return StringUtils.fromString(handler.toString());
        } catch (Throwable t) {
            return toBallerinaError(t);
        }
    }

    /**
     * Extracts the text of a Word document (.docx).
     *
     * @param content  the document bytes
     * @param fileName unused; kept so all extractors share a signature
     * @return the text, or a Ballerina error
     */
    public static Object extractDocxText(BArray content, BString fileName) {
        // The package is the closed resource; closing the extractor too would close it twice.
        try (InputStream stream = new ByteArrayInputStream(content.getBytes());
             OPCPackage pkg = OPCPackage.open(stream)) {
            XWPFWordExtractor extractor = new XWPFWordExtractor(pkg);
            return StringUtils.fromString(extractor.getText());
        } catch (Throwable t) {
            return toBallerinaError(t);
        }
    }

    /**
     * Extracts the text of a PowerPoint presentation (.pptx).
     *
     * @param content  the presentation bytes
     * @param fileName unused; kept so all extractors share a signature
     * @return the text, or a Ballerina error
     */
    public static Object extractPptxText(BArray content, BString fileName) {
        try (InputStream stream = new ByteArrayInputStream(content.getBytes());
             XMLSlideShow slideShow = new XMLSlideShow(stream)) {
            SlideShowExtractor<?, ?> extractor = new SlideShowExtractor<>(slideShow);
            return StringUtils.fromString(extractor.getText());
        } catch (Throwable t) {
            return toBallerinaError(t);
        }
    }

    /**
     * Extracts the text of an Excel workbook (.xlsx): tab-separated cells, one row per line, each
     * sheet prefixed with its name. Formula cells give their cached result.
     *
     * @param content  the workbook bytes
     * @param fileName unused; kept so all extractors share a signature
     * @return the text, or a Ballerina error
     */
    public static Object extractXlsxText(BArray content, BString fileName) {
        try (InputStream stream = new ByteArrayInputStream(content.getBytes());
             XSSFWorkbook workbook = new XSSFWorkbook(stream)) {
            XSSFExcelExtractor extractor = new XSSFExcelExtractor(workbook);
            extractor.setIncludeSheetNames(true);
            return StringUtils.fromString(extractor.getText());
        } catch (Throwable t) {
            return toBallerinaError(t);
        }
    }

    /**
     * Converts a failure into a Ballerina error with the exception as its cause. {@link Throwable}
     * is caught because an {@code Error} escaping to Ballerina is an unrecoverable panic, and a
     * {@code StackOverflowError} from a malformed document affects only that document. Other
     * {@link VirtualMachineError}s, such as {@link OutOfMemoryError}, are rethrown.
     */
    private static Object toBallerinaError(Throwable t) {
        if (t instanceof VirtualMachineError && !(t instanceof StackOverflowError)) {
            throw (VirtualMachineError) t;
        }
        String message = t.getMessage();
        String detail = message != null && !message.isBlank()
                ? t.getClass().getSimpleName() + ": " + message
                : t.getClass().getSimpleName();
        return ErrorCreator.createError(StringUtils.fromString(detail), t);
    }
}
