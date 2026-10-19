import Foundation
import PDFKit
import EnsoDoc
import EnsoShared
import EnsoOffice
import EnsoPDF

/// The only place EnsoCore touches the format modules' APIs, so changes there stay contained.
enum Formats {
    // PDF analysis
    static func pdfModel(_ doc: PDFDocument, progress: ((Double) -> Void)?) -> DocModel {
        PDFReconstructor.model(from: doc, options: PDFReconstructionOptions(), progress: progress)
    }
    static func pdfWorkbook(_ doc: PDFDocument) -> Workbook { PDFTableExtractor.workbook(from: doc) }
    static func pdfImages(_ doc: PDFDocument) -> [DocImage] { PDFImageExtractor.images(from: doc).map(\.image) }
    static func searchablePDF(_ doc: PDFDocument, languages: [String], progress: ((Double) -> Void)?) throws -> Data {
        let data = PDFOCR.makeSearchable(doc, languages: languages, progress: progress)
        guard !data.isEmpty else { throw EngineError.failed(L("文字認識できませんでした")) }
        return data
    }

    // Office
    static func writeDocx(_ model: DocModel, to url: URL) throws { try DocxWriter.write(model, to: url) }
    static func readDocx(_ url: URL) throws -> DocModel { try DocxReader.read(url) }
    static func docxImages(_ url: URL) throws -> [(name: String, data: Data)] { try DocxReader.mediaImages(url) }
    static func docxComplexity(_ url: URL) throws -> DocxComplexity { try DocxInspector.inspect(url) }
    static func writeXlsx(_ wb: Workbook, to url: URL) throws { try XlsxWriter.write(wb, to: url) }
    static func readXlsx(_ url: URL) throws -> Workbook { try XlsxReader.read(url) }
    static func writePptx(slides: [DocImage], size: CGSize, notes: [String]?, to url: URL) throws {
        try PptxWriter.write(slides: slides, slideSize: size, notes: notes, to: url)
    }
    static func readPptx(_ url: URL) throws -> DocModel { try PptxReader.read(url) }
    static func pptxImages(_ url: URL) throws -> [(name: String, data: Data)] { try PptxReader.mediaImages(url) }
    static func readCSV(_ url: URL) throws -> Sheet { try CSVCodec.read(url) }
    static func writeCSV(_ sheet: Sheet, to url: URL) throws { try CSVCodec.write(sheet, to: url) }
}
