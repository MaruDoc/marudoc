import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Vision
import EnsoDoc

/// One recognised line of text.
public struct OCRLine: Sendable, Hashable {
    public var text: String
    /// Bounding box in image pixel coordinates, origin at the bottom-left of the image.
    public var boundingBox: CGRect
    public var confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text; self.boundingBox = boundingBox; self.confidence = confidence
    }
}

public enum PDFOCR {
    /// Resolution used when rasterising pages for recognition (2.5 = 180 dpi).
    static let renderScale: CGFloat = 2.5

    /// Recognises text lines in an image with Vision (accurate mode, language correction on).
    public static func recognize(image: CGImage, languages: [String] = ["ja-JP", "en-US"]) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if VNRecognizeTextRequest.supportedRevisions.contains(VNRecognizeTextRequestRevision3) {
            request.revision = VNRecognizeTextRequestRevision3
        }
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let langs = languages.filter { l in supported.contains(l) || supported.contains { $0.hasPrefix(String(l.prefix(2))) } }
        if !langs.isEmpty { request.recognitionLanguages = langs }
        request.minimumTextHeight = 0.004
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var out: [OCRLine] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = cand.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let b = obs.boundingBox
            out.append(OCRLine(text: text, boundingBox: CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h),
                               confidence: cand.confidence))
        }
        return out
    }

    /// True when the page has (almost) no extractable text but shows a scan or outlined text.
    public static func pageNeedsOCR(_ page: PDFPage) -> Bool {
        let visible = visibleCharacterCount(page)
        guard let cg = page.pageRef else { return false }
        let geo = PageGeometry(page: page)
        let g = GraphicsScanner.scan(page: cg, geo: geo, vectors: visible < 24)
        if needsOCR(visibleChars: visible, graphics: g, geo: geo) { return true }
        let glyphs = TextExtractor.glyphs(page: page, geo: geo, styles: StyleTable(), textRuns: [])
        return textIsUnreadable(glyphs: glyphs, graphics: g)
    }

    /// Text the content stream shows where PDFKit produced no characters: fonts without a usable
    /// ToUnicode map (common with some Japanese PDF printers). Counted per text-showing operation,
    /// so pages where only digits and Latin letters survive are caught as well.
    static func textIsUnreadable(glyphs: [Glyph], graphics g: PageGraphics) -> Bool {
        let runs = g.textRuns.filter { $0.renderMode != 3 && $0.renderMode != 7 && $0.horizontal && $0.glyphCount >= 2 && $0.maxX - $0.minX > 1 }
        let shown = runs.reduce(0) { $0 + $1.glyphCount }
        guard shown >= 40 else { return false }
        var buckets: [Int: [Int]] = [:]
        for (i, gl) in glyphs.enumerated() { buckets[SafeInt.floor(Double(gl.rect.midY / 8)), default: []].append(i) }
        var missing = 0
        for r in runs {
            let b = SafeInt.floor(Double(r.start.y / 8), -100_000_000, 100_000_000)
            var matched = 0, cjk = 0
            for bb in (b - 3)...(b + 3) {
                for i in buckets[bb] ?? [] {
                    let gr = glyphs[i].rect
                    if gr.midX >= r.minX - 1 && gr.midX <= r.maxX + 1 && r.start.y >= gr.minY - 2 && r.start.y <= gr.maxY + 2 {
                        matched += 1
                        if CharClass.isCJK(glyphs[i].text) { cjk += 1 }
                    }
                }
            }
            // Full-width Shift-JIS/EUC codes must come out as CJK characters; anything else is mojibake.
            if r.wideCount >= 2 && cjk < r.wideCount / 2 { missing += r.wideCount - cjk } else { missing += max(0, r.glyphCount - matched) }
        }
        return Double(missing) >= Double(shown) * 0.3
    }

    static func visibleCharacterCount(_ page: PDFPage) -> Int {
        guard let s = page.string else { return 0 }
        var n = 0
        for u in s.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(u) && u.value != 0xFFFC { n += 1 }
        return n
    }

    static func needsOCR(visibleChars: Int, graphics g: PageGraphics, geo: PageGeometry) -> Bool {
        guard visibleChars < 24 else { return false }
        let area = geo.size.width * geo.size.height
        // A scan is one picture covering (nearly) the whole page; photos on slides are not scans.
        let imageArea = g.images.filter { !$0.isMask }.map { $0.rect.intersection(geo.bounds).area }.max() ?? 0
        if imageArea >= area * 0.8 { return true }
        // Text converted to outlines shows up as a large number of filled paths.
        return visibleChars == 0 && g.paintedPaths >= 300
    }

    /// Renders a page (crop box, rotation applied) into an opaque RGB bitmap.
    static func render(page: PDFPage, scale: CGFloat) -> CGImage? {
        let geo = PageGeometry(page: page)
        let w = SafeInt.round(Double(geo.size.width * scale), 0, 1_000_000), h = SafeInt.round(Double(geo.size.height * scale), 0, 1_000_000)
        guard w > 0, h > 0, SafeInt.isReasonablePixelSize(w, h, limit: 200_000_000),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// OCR lines in display space (points, origin top-left) for a page.
    static func displayLines(page: PDFPage, languages: [String]) -> [(text: String, rect: CGRect)] {
        let geo = PageGeometry(page: page)
        guard let img = render(page: page, scale: renderScale) else { return [] }
        return displayLines(image: img, pageSize: geo.size, languages: languages)
    }

    /// OCR lines of a rendered page image, converted to display space of a page of `pageSize`.
    static func displayLines(image img: CGImage, pageSize: CGSize, languages: [String]) -> [(text: String, rect: CGRect)] {
        let sx = pageSize.width / CGFloat(img.width), sy = pageSize.height / CGFloat(img.height)
        return recognize(image: img, languages: languages).map { l in
            let b = l.boundingBox
            return (l.text, CGRect(x: b.minX * sx, y: pageSize.height - b.maxY * sy, width: b.width * sx, height: b.height * sy))
        }
    }

    /// Approximate advance of a character in ems, used to estimate font sizes from OCR line widths.
    private static func advance(_ c: Character) -> CGFloat {
        if c == " " { return 0.28 }
        let s = String(c)
        if CharClass.isCJK(s) { return 1.0 }
        if c.isUppercase { return 0.66 }
        if c.isNumber { return 0.56 }
        if c.isLetter { return 0.5 }
        return 0.35
    }

    /// Synthesises glyphs from OCR lines so they can go through the normal layout pipeline.
    /// Vision's box heights vary a lot between lines of the same size, so the size is estimated
    /// from the line width per character and then snapped to the page's dominant size.
    static func glyphs(from lines: [(text: String, rect: CGRect)], styles: StyleTable) -> [Glyph] {
        var estimates: [Double] = []
        for (text, rect) in lines {
            let ems = Array(text).reduce(CGFloat(0)) { $0 + advance($1) }
            var size = ems > 0 ? rect.width / ems : rect.height / 1.15
            size = min(max(size, rect.height * 0.6), rect.height * 1.05)
            estimates.append(Double(size))
        }
        let long = zip(lines, estimates).filter { $0.0.text.count >= 8 }.map(\.1)
        let dominant = Stats.median(long.isEmpty ? estimates : long) ?? 10
        var out: [Glyph] = []
        for (k, (text, rect)) in lines.enumerated() {
            var size = estimates[k]
            if abs(size - dominant) <= dominant * 0.18 { size = dominant }
            size = max(4, (size * 2).rounded() / 2)
            let style = styles.intern(GlyphStyle(fontName: nil, size: size, bold: false, italic: false, monospaced: false, color: nil))
            let chars = Array(text)
            let weights = chars.map(advance)
            let total = weights.reduce(0, +)
            guard total > 0 else { continue }
            // Lines share one vertical band of the dominant height so pitch statistics stay stable.
            let band = CGRect(x: rect.minX, y: rect.midY - CGFloat(size) * 0.6, width: rect.width, height: CGFloat(size) * 1.2)
            var x = rect.minX
            var pendingSpace = false
            for (i, c) in chars.enumerated() {
                let w = rect.width * weights[i] / total
                if c == " " { pendingSpace = true; x += w; continue }
                out.append(Glyph(text: String(c), rect: CGRect(x: x, y: band.minY, width: w, height: band.height), style: style, link: nil, spaceBefore: pendingSpace))
                pendingSpace = false
                x += w
            }
        }
        return out
    }

    // MARK: Searchable PDF

    /// Returns a copy of the document where every page that needs OCR is replaced by the original page
    /// (drawn as vector content) plus an invisible, selectable text layer. Pages with real text are left untouched.
    /// Falls back to the unmodified document data if anything fails.
    public static func makeSearchable(_ document: PDFDocument, languages: [String] = ["ja-JP", "en-US"],
                                      progress: ((Double) -> Void)? = nil) -> Data {
        guard let original = document.dataRepresentation() else { return Data() }
        guard let out = PDFDocument(data: original) else { return original }
        let n = out.pageCount
        var changed = false
        for i in 0..<n {
            if let page = out.page(at: i), pageNeedsOCR(page), let replacement = searchablePage(page, languages: languages) {
                out.removePage(at: i)
                out.insert(replacement, at: i)
                changed = true
            }
            progress?(Double(i + 1) / Double(max(1, n)))
        }
        guard changed else { return original }
        return out.dataRepresentation() ?? original
    }

    static func searchablePage(_ page: PDFPage, languages: [String]) -> PDFPage? {
        let geo = PageGeometry(page: page)
        guard let img = render(page: page, scale: renderScale) else { return nil }
        let lines = recognize(image: img, languages: languages)
        guard !lines.isEmpty else { return nil }
        let scale = CGFloat(img.width) / geo.size.width
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: geo.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
        ctx.saveGState()
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        drawInvisibleText(lines, scale: scale, in: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    static func drawInvisibleText(_ lines: [OCRLine], scale: CGFloat, in ctx: CGContext) {
        let baseFont = CTFontCreateWithName("HiraginoSans-W3" as CFString, 12, nil)
        for l in lines {
            let r = CGRect(x: l.boundingBox.minX / scale, y: l.boundingBox.minY / scale,
                           width: l.boundingBox.width / scale, height: l.boundingBox.height / scale)
            guard r.width > 1, r.height > 1 else { continue }
            let fontSize = max(2, r.height * 0.9)
            let font = CTFontCreateCopyWithAttributes(baseFont, fontSize, nil, nil)
            let attrs = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: attrs))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            ctx.textMatrix = .identity
            ctx.translateBy(x: r.minX, y: r.minY + (r.height - ascent - descent) / 2 + descent)
            ctx.scaleBy(x: r.width / width, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}
