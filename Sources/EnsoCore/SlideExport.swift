import Foundation
import EnsoShared
import EnsoOffice

/// PowerPoint decks as slides: PDF pages and images drawn by the slide renderer (not the text reflow).
extension Formats {
    static func slidesPDF(_ url: URL, progress: @escaping Engine.Progress, cancelled: @escaping Engine.Cancelled) throws -> Data {
        do {
            return try PptxSlideRenderer.renderPDF(contentsOf: url, progress: { progress($0 * 0.95) }, cancelled: cancelled).pdf
        } catch is CancellationError {
            throw EngineError.cancelled
        }
    }

    /// One image per slide (a folder for several), written next to the deck.
    static func slideImages(_ url: URL, format: String, dpi: Double, progress: @escaping Engine.Progress, cancelled: @escaping Engine.Cancelled) throws -> URL {
        let pdf = try slidesPDF(url, progress: { progress($0 * 0.5) }, cancelled: cancelled)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pdfURL = tmp.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("pdf")
        try pdf.write(to: pdfURL)
        let rendered = try Rasterizer.export(pdfURL, format: format, dpi: dpi, progress: { progress(0.5 + $0 * 0.5) }, cancelled: cancelled)
        let isDir = (try? rendered.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let final = OutputNamer.unique(url.deletingLastPathComponent().appendingPathComponent(rendered.lastPathComponent), isDirectory: isDir == true)
        try FileManager.default.moveItem(at: rendered, to: final)
        return final
    }
}
