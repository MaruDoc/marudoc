import Foundation
import EnsoShared
import EnsoDoc
import EnsoOffice

/// Spreadsheets and CSV printed as sheets (SheetPrinter) instead of as one document table.
extension Converter {

    /// The workbook as it prints: an .xlsx with its own layout, or a CSV / TSV with values exactly as written.
    static func printWorkbook(_ file: URL, kind: FileKind) throws -> PrintWorkbook {
        if kind == .csv {
            let sheet = try Formats.readCSV(file)
            return PrintWorkbook(sheets: [PrintSheet.csv(sheet, measure: SheetFonts.measure)],
                                 defaultFont: SheetFont(name: nil, size: PrintSheet.csvFontSize))
        }
        return try XlsxLayoutReader.read(file)
    }

    func sheetPDF(_ file: URL, kind: FileKind, cancelled: @escaping Engine.Cancelled) throws -> URL {
        let wb = try Self.printWorkbook(file, kind: kind)
        guard let out = SheetPrinter.pdf(wb, title: file.deletingPathExtension().lastPathComponent, fileName: file.lastPathComponent,
                                         cancelled: { cancelled() }) else {
            if cancelled() { throw EngineError.cancelled }
            // Nothing visible: an empty workbook, or one whose only content is in hidden sheets.
            throw EngineError.failed(L("表や文字が見つかりませんでした"))
        }
        let url = OutputNamer.file(for: file, ext: "pdf")
        try out.data.write(to: url, options: .atomic)
        return url
    }

    /// Excel -> Word: tables shaped like the sheet (SheetDocument).
    func sheetDocx(_ file: URL) throws -> URL {
        let wb = try XlsxLayoutReader.read(file)
        let model = SheetDocument.model(wb, title: file.deletingPathExtension().lastPathComponent)
        guard !model.blocks.isEmpty else { throw EngineError.failed(L("表や文字が見つかりませんでした")) }
        let out = OutputNamer.file(for: file, ext: "docx")
        try Formats.writeDocx(model, to: out)
        return out
    }
}
