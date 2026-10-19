import AppKit

/// Lays out an attributed string on pages with TextKit 1 and writes a PDF.
/// Paragraphs tagged with `.ensoPageBreak` start a new page.
public enum PDFRenderer {

    public struct PageSetup {
        public var size: CGSize
        public var margins: NSEdgeInsets
        public init(size: CGSize = DocModel.a4, margins: NSEdgeInsets = NSEdgeInsets(top: 62, left: 60, bottom: 62, right: 60)) {
            self.size = size; self.margins = margins
        }
        public var contentSize: CGSize {
            CGSize(width: size.width - margins.left - margins.right, height: size.height - margins.top - margins.bottom)
        }
    }

    public static func pdfData(from model: DocModel, setup: PageSetup? = nil, pageNumbers: Bool = false) -> Data {
        var s = setup ?? PageSetup()
        if setup == nil, let size = model.pageSize, size.width > 100, size.height > 100 { s.size = size }
        let style = AttributedConverter.Style(bodySize: CGFloat(model.bodyFontSize), contentWidth: s.contentSize.width,
                                              contentHeight: s.contentSize.height)
        let attr = AttributedConverter.attributedString(from: model, style: style)
        return pdfData(from: attr, setup: s, title: model.title, pageNumbers: pageNumbers)
    }

    public static func pdfData(from attr: NSAttributedString, setup: PageSetup = PageSetup(), title: String? = nil, pageNumbers: Bool = false) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: setup.size)
        var info: [CFString: Any] = [kCGPDFContextCreator: "MaruDoc"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return Data() }

        let segments = split(attr)
        var pageIndex = 0
        var pages: [(NSLayoutManager, NSTextContainer)] = []
        var storages: [NSTextStorage] = []   // keep alive while drawing

        for segment in segments {
            let storage = NSTextStorage(attributedString: segment)
            let lm = NSLayoutManager()
            lm.usesFontLeading = true
            storage.addLayoutManager(lm)
            storages.append(storage)
            var guardCount = 0
            while true {
                let tc = NSTextContainer(size: setup.contentSize)
                tc.lineFragmentPadding = 0
                lm.addTextContainer(tc)
                let range = lm.glyphRange(for: tc)
                pages.append((lm, tc))
                guardCount += 1
                if NSMaxRange(range) >= lm.numberOfGlyphs || guardCount > 5000 { break }
                // An element taller than the page can make no progress; stop instead of looping forever.
                if range.length == 0 { break }
            }
        }

        let total = pages.count
        for (lm, tc) in pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            let nsctx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.current = nsctx
            ctx.saveGState()
            ctx.translateBy(x: 0, y: setup.size.height)
            ctx.scaleBy(x: 1, y: -1)
            let range = lm.glyphRange(for: tc)
            let origin = CGPoint(x: setup.margins.left, y: setup.margins.top)
            if range.length > 0 {
                lm.drawBackground(forGlyphRange: range, at: origin)
                lm.drawGlyphs(forGlyphRange: range, at: origin)
            }
            pageIndex += 1
            if pageNumbers && total > 1 {
                let label = "\(pageIndex) / \(total)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: (setup.size.width - size.width) / 2, y: setup.size.height - setup.margins.bottom / 2 - size.height / 2), withAttributes: attrs)
            }
            ctx.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        if pages.isEmpty { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        _ = storages
        return data as Data
    }

    /// Splits at paragraphs carrying `.ensoPageBreak`.
    static func split(_ attr: NSAttributedString) -> [NSAttributedString] {
        var cuts: [Int] = []
        attr.enumerateAttribute(.ensoPageBreak, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
            if v != nil, r.location > 0 { cuts.append(r.location) }
        }
        var out: [NSAttributedString] = []
        var start = 0
        for c in cuts where c > start {
            out.append(attr.attributedSubstring(from: NSRange(location: start, length: c - start)))
            start = c
        }
        out.append(attr.attributedSubstring(from: NSRange(location: start, length: attr.length - start)))
        return out.filter { $0.length > 0 }
    }
}
