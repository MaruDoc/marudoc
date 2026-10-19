import AppKit
import PDFKit
import EnsoDoc
import EnsoCore

/// The first conversion after launch paid ~3 s for loading PDFKit, fonts and ImageIO codecs.
/// Doing a tiny conversion in the background shortly after launch moves that cost out of the user's way.
enum Warmup {
    static func run() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            let model = MarkdownReader.model(from: "# MaruDoc\n\nウォームアップ warm-up\n\n- a\n- b\n")
            let data = PDFRenderer.pdfData(from: model)
            if let doc = PDFDocument(data: data), let page = doc.page(at: 0) {
                _ = page.string
                _ = page.thumbnail(of: NSSize(width: 64, height: 64), for: .cropBox)
            }
            _ = HTMLWriter.string(from: model)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("marudoc-warmup.docx")
            try? DocumentWarmup.writeDocx(model, to: tmp)
            try? FileManager.default.removeItem(at: tmp)
            if let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let img = ctx.makeImage() {
                _ = ImageCodec.encode(img, as: .jpeg)
            }
        }
    }
}
