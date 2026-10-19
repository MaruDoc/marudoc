import Foundation
import PDFKit
import EnsoShared
import EnsoDoc

/// File -> file conversions. Documents go through DocModel; spreadsheets through Workbook; images through ImageIO.
struct Converter {
    var options: EngineOptions

    static let imageTargets: Set<String> = ["png", "jpeg", "heic", "tiff"]

    func convert(_ file: URL, kind: FileKind, to target: String, progress: @escaping Engine.Progress, cancelled: @escaping Engine.Cancelled) async throws -> [URL] {
        switch (kind, target) {

        // Already in the target format (mixed selections): nothing to do.
        case (.pdf, "pdf"), (.markdown, "md"), (.text, "txt"), (.html, "html"), (.rtf, "rtf"), (.csv, "csv"), (.spreadsheet, "xlsx"):
            throw EngineError.failed(L("すでにこの形式です"))

        // PDF
        case (.pdf, "docx"):
            let model = try await pdfModel(file, progress: progress)
            let out = OutputNamer.file(for: file, ext: "docx")
            try Formats.writeDocx(model, to: out)
            return [out]
        case (.pdf, "xlsx"):
            let doc = try openPDF(file)
            let wb = Formats.pdfWorkbook(doc)
            guard wb.sheets.contains(where: { !$0.rows.isEmpty }) else { throw EngineError.failed(L("表や文字が見つかりませんでした")) }
            let out = OutputNamer.file(for: file, ext: "xlsx")
            try Formats.writeXlsx(wb, to: out)
            return [out]
        case (.pdf, "pptx"):
            let doc = try openPDF(file)
            var slides: [DocImage] = []
            var size = CGSize(width: 960, height: 540)
            for i in 0..<doc.pageCount {
                if cancelled() { throw EngineError.cancelled }
                guard let page = doc.page(at: i) else { continue }
                if i == 0 { size = Rasterizer.displaySize(page) }
                guard let img = Rasterizer.render(page, dpi: max(150, options.imageDPI)),
                      let data = ImageCodec.encode(img, as: .jpeg, quality: 0.9) else { continue }
                let ps = Rasterizer.displaySize(page)
                slides.append(DocImage(data: data, format: .jpeg, pixelWidth: img.width, pixelHeight: img.height,
                                       displayWidth: Double(ps.width), displayHeight: Double(ps.height)))
                progress(Double(i + 1) / Double(doc.pageCount) * 0.9)
            }
            let notes = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
            let out = OutputNamer.file(for: file, ext: "pptx")
            try Formats.writePptx(slides: slides, size: size, notes: notes, to: out)
            return [out]
        case (.pdf, let t) where Self.imageTargets.contains(t):
            return [try Rasterizer.export(file, format: t, dpi: options.imageDPI, progress: progress, cancelled: cancelled)]
        case (.pdf, "md"), (.pdf, "txt"), (.pdf, "html"), (.pdf, "rtf"):
            let model = try await pdfModel(file, progress: progress)
            return try await write(model, near: file, as: target)

        // Images
        case (.image, "pdf"):
            return [try PDFOps.imagesToPDF([file], output: OutputNamer.file(for: file, ext: "pdf"))]
        case (.image, let t) where Self.imageTargets.contains(t):
            return [try ImageOps.convert(file, to: t)]

        // Spreadsheets
        case (.spreadsheet, "csv"):
            let wb = try Formats.readXlsx(file)
            let sheets = wb.sheets.filter { !$0.rows.isEmpty }
            if sheets.count <= 1 {
                let out = OutputNamer.file(for: file, ext: "csv")
                try Formats.writeCSV(sheets.first ?? Sheet(name: "", rows: []), to: out)
                return [out]
            }
            let folder = OutputNamer.folder(for: file, tag: "CSV")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for s in sheets {
                let name = s.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                try Formats.writeCSV(s, to: folder.appendingPathComponent(name).appendingPathExtension("csv"))
            }
            return [folder]
        case (.csv, "xlsx"):
            var sheet = try Formats.readCSV(file)
            sheet.name = String(file.deletingPathExtension().lastPathComponent.prefix(31))
            let out = OutputNamer.file(for: file, ext: "xlsx")
            try Formats.writeXlsx(Workbook(sheets: [sheet]), to: out)
            return [out]
        case (.spreadsheet, _), (.csv, _):
            let wb: Workbook = kind == .csv ? Workbook(sheets: [try Formats.readCSV(file)]) : try Formats.readXlsx(file)
            let model = DocumentReader.model(from: wb, title: file.deletingPathExtension().lastPathComponent)
            return try await write(model, near: file, as: target)

        // Documents
        case (.word, _), (.rtf, _), (.markdown, _), (.text, _), (.html, _), (.presentation, _):
            let model = try await DocumentReader.model(of: file, kind: kind)
            if Self.imageTargets.contains(target) {
                // Lay out as PDF, then render pages.
                let pdfData = PDFRenderer.pdfData(from: model)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let pdfURL = tmp.appendingPathComponent(file.deletingPathExtension().lastPathComponent).appendingPathExtension("pdf")
                try pdfData.write(to: pdfURL)
                let rendered = try Rasterizer.export(pdfURL, format: target, dpi: options.imageDPI, progress: progress, cancelled: cancelled)
                let dest = file.deletingLastPathComponent().appendingPathComponent(rendered.lastPathComponent)
                let final = OutputNamer.unique(dest)
                try FileManager.default.moveItem(at: rendered, to: final)
                return [final]
            }
            return try await write(model, near: file, as: target)

        default:
            throw EngineError.unsupported("\(kind.rawValue) → \(target)")
        }
    }

    // MARK: Helpers

    private func openPDF(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw DocIOError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw DocIOError.encrypted }
        return doc
    }

    private func pdfModel(_ url: URL, progress: @escaping Engine.Progress) async throws -> DocModel {
        let doc = try openPDF(url)
        var model = Formats.pdfModel(doc) { progress($0 * 0.9) }
        if model.title == nil { model.title = url.deletingPathExtension().lastPathComponent }
        if model.blocks.isEmpty { throw EngineError.failed(L("文字が見つかりませんでした")) }
        return model
    }

    /// Writes a DocModel in the requested format next to `input`.
    func write(_ model: DocModel, near input: URL, as target: String) async throws -> [URL] {
        switch target {
        case "docx":
            let out = OutputNamer.file(for: input, ext: "docx")
            try Formats.writeDocx(model, to: out)
            return [out]
        case "pdf":
            let out = OutputNamer.file(for: input, ext: "pdf")
            try PDFRenderer.pdfData(from: model).write(to: out, options: .atomic)
            return [out]
        case "md":
            let out = OutputNamer.file(for: input, ext: "md")
            let parent = out.deletingLastPathComponent()
            var imageDir = out.deletingPathExtension().lastPathComponent + "_images"
            var md = MarkdownWriter.string(from: model, imageDirectoryName: imageDir)
            var outs = [out]
            if !md.images.isEmpty {
                // Always a fresh folder: an existing "<name>_images" (possibly planted next to the input, or a symlink)
                // is never reused. A taken name gets a number, and the Markdown refers to the name actually used.
                let dir = OutputNamer.unique(parent.appendingPathComponent(imageDir, isDirectory: true), isDirectory: true)
                if dir.lastPathComponent != imageDir {
                    imageDir = dir.lastPathComponent
                    md = MarkdownWriter.string(from: model, imageDirectoryName: imageDir)
                }
                // withIntermediateDirectories: false fails when anything (folder, file, symlink) is already there.
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                guard OutputNamer.isRealDirectory(dir) else { throw EngineError.failed(L("画像フォルダを作れませんでした")) }
                for img in md.images {
                    // .withoutOverwriting is O_EXCL: it never follows or replaces an existing entry.
                    try img.data.write(to: dir.appendingPathComponent(img.name), options: .withoutOverwriting)
                }
                outs.append(dir)
            }
            try md.text.write(to: out, atomically: true, encoding: .utf8)
            return outs
        case "txt":
            let out = OutputNamer.file(for: input, ext: "txt")
            try PlainTextWriter.string(from: model).write(to: out, atomically: true, encoding: .utf8)
            return [out]
        case "html":
            let out = OutputNamer.file(for: input, ext: "html")
            try HTMLWriter.string(from: model).write(to: out, atomically: true, encoding: .utf8)
            return [out]
        case "rtf":
            let out = OutputNamer.file(for: input, ext: "rtf")
            let written = try await MainActor.run { try CocoaDocumentIO.writeRTF(model, to: out) }
            return [written]
        case "xlsx":
            let tables = model.blocks.compactMap { b -> DocTable? in if case .table(let t) = b { return t }; return nil }
            guard !tables.isEmpty else { throw EngineError.failed(L("表が見つかりませんでした")) }
            let sheets = tables.enumerated().map { i, t in
                Sheet(name: "\(L("表")) \(i + 1)", rows: t.rows.map { $0.map { CellValue.guess($0.text) } })
            }
            let out = OutputNamer.file(for: input, ext: "xlsx")
            try Formats.writeXlsx(Workbook(sheets: sheets), to: out)
            return [out]
        default:
            throw EngineError.unsupported(target)
        }
    }
}

/// Reads any supported document into a DocModel.
public enum DocumentReader {

    public static func model(of file: URL, kind: FileKind? = nil) async throws -> DocModel {
        let kind = kind ?? FileKind.of(file)
        let title = file.deletingPathExtension().lastPathComponent
        var model: DocModel
        switch kind {
        case .word:
            if ["docx", "docm", "dotx"].contains(file.pathExtension.lowercased()) {
                do { model = try Formats.readDocx(file) } catch {
                    model = try await MainActor.run { try CocoaDocumentIO.readModel(file) }
                }
            } else {
                model = try await MainActor.run { try CocoaDocumentIO.readModel(file) }
            }
        case .html:
            model = try HTMLReader.model(from: Data(contentsOf: file), baseURL: file.deletingLastPathComponent())
        case .rtf:
            model = try await MainActor.run { try CocoaDocumentIO.readModel(file) }
        case .markdown:
            let text = PlainTextReader.decode(try Data(contentsOf: file))
            model = MarkdownReader.model(from: text, baseURL: file.deletingLastPathComponent())
        case .text:
            model = PlainTextReader.model(from: PlainTextReader.decode(try Data(contentsOf: file)))
        case .presentation:
            model = try Formats.readPptx(file)
        case .spreadsheet:
            model = Self.model(from: try Formats.readXlsx(file), title: title)
        case .csv:
            model = Self.model(from: Workbook(sheets: [try Formats.readCSV(file)]), title: title)
        case .pdf:
            guard let doc = PDFDocument(url: file) else { throw DocIOError.unreadable(file.lastPathComponent) }
            model = Formats.pdfModel(doc, progress: nil)
        case .image, .other:
            throw EngineError.unsupported(kind.rawValue)
        }
        if model.title == nil { model.title = title }
        return model
    }

    public static func model(from wb: Workbook, title: String) -> DocModel {
        var blocks: [DocBlock] = []
        let sheets = wb.sheets.filter { !$0.rows.isEmpty }
        for s in sheets {
            if sheets.count > 1 { blocks.append(.heading(level: 2, DocParagraph(text: s.name))) }
            let cols = s.columnCount
            let rows = s.rows.map { row -> [DocTableCell] in
                var cells = row.map { DocTableCell(text: $0.displayString) }
                while cells.count < cols { cells.append(DocTableCell(text: "")) }
                return cells
            }
            blocks.append(.table(DocTable(rows: rows, headerRows: 1)))
        }
        return DocModel(title: title, blocks: blocks, bodyFontSize: 10)
    }
}
