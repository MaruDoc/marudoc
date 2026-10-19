import Foundation
import CoreGraphics
import CoreText
import PDFKit
import EnsoDoc

public struct PDFReconstructionOptions: Sendable {
    public var includeImages: Bool
    public var ocrWhenNeeded: Bool
    public var removeRunningHeadersFooters: Bool
    /// false: one continuous document; true: a .pageBreak between pages.
    public var pageBreaks: Bool
    public var languages: [String]
    /// Export clusters of vector graphics (diagrams, charts) as pictures instead of loose text labels.
    public var rasterizeVectorFigures: Bool

    public init(includeImages: Bool = true, ocrWhenNeeded: Bool = true, removeRunningHeadersFooters: Bool = true,
                pageBreaks: Bool = false, languages: [String] = ["ja-JP", "en-US"], rasterizeVectorFigures: Bool = true) {
        self.includeImages = includeImages
        self.ocrWhenNeeded = ocrWhenNeeded
        self.removeRunningHeadersFooters = removeRunningHeadersFooters
        self.pageBreaks = pageBreaks
        self.languages = languages
        self.rasterizeVectorFigures = rasterizeVectorFigures
    }
}

/// Rebuilds an editable document (headings, paragraphs, lists, tables, images) from a PDF.
public enum PDFReconstructor {
    public static func model(from document: PDFDocument, options: PDFReconstructionOptions = .init(),
                             progress: ((Double) -> Void)? = nil) -> DocModel {
        let analyzer = DocumentAnalyzer(options: options)
        analyzer.analyze(document) { progress?($0 * 0.9) }
        let flows = analyzer.flows()
        var stats = DocStats.compute(flows: flows, styles: analyzer.styles)
        stats.slides = analyzer.isSlideDeck
        let builder = BlockBuilder(styles: analyzer.styles, stats: stats)
        let (blocks, firstHeading) = builder.build(flows: flows, pageBreaks: options.pageBreaks)
        progress?(1)
        return DocModel(title: documentTitle(document) ?? firstHeading,
                        blocks: blocks,
                        pageSize: analyzer.pages.first?.geo.size,
                        bodyFontSize: stats.bodySize,
                        bodyFontName: stats.bodyFont.map(familyName))
    }

    static func documentTitle(_ doc: PDFDocument) -> String? {
        guard var t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String else { return nil }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Microsoft Word - ", "Microsoft PowerPoint - ", "Microsoft Excel - "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        let lower = t.lowercased()
        for ext in [".docx", ".doc", ".pptx", ".ppt", ".xlsx", ".pages", ".key", ".numbers", ".odt", ".rtf", ".txt", ".pdf", ".indd", ".md", ".html"] where lower.hasSuffix(ext) {
            t = String(t.dropLast(ext.count))
            break
        }
        let junk = ["untitled", "無題", "document", "slide 1", "powerpoint presentation", "スライド 1", "pdf"]
        if t.isEmpty || junk.contains(t.lowercased()) || t.contains("/") || t.contains("\\") { return nil }
        return t
    }

    static func familyName(_ postScript: String) -> String {
        let f = CTFontCreateWithName(postScript as CFString, 12, nil)
        if (CTFontCopyPostScriptName(f) as String) == postScript { return CTFontCopyFamilyName(f) as String }
        return postScript
    }
}

/// Per-page analysis results.
struct PageAnalysis {
    var index: Int
    var geo: PageGeometry
    var lines: [TextLine]
    var tables: [TableGrid]
    var images: [(atom: ImageAtom, hash: UInt64)]
    var ocr: Bool
}

/// Shared by the reconstructor and the spreadsheet extractor.
final class DocumentAnalyzer {
    let styles = StyleTable()
    let options: PDFReconstructionOptions
    private(set) var pages: [PageAnalysis] = []
    private var layoutBodySize: Double = 10
    /// Presentation exported to PDF: landscape pages with large type or a presentation app as creator.
    private(set) var isSlideDeck = false

    init(options: PDFReconstructionOptions) { self.options = options }

    /// First pass over a page: geometry, content-stream graphics and PDFKit glyphs.
    private struct Prepared {
        var page: PDFPage
        var index: Int
        var geo: PageGeometry
        var graphics: PageGraphics
        var glyphs: [Glyph]
        var scanned: Bool
        var unreadable: Bool
    }

    func analyze(_ document: PDFDocument, progress: ((Double) -> Void)?) {
        let n = document.pageCount
        var prepared: [Prepared] = []
        prepared.reserveCapacity(n)
        for i in 0..<n {
            guard let page = document.page(at: i) else { continue }
            let geo = PageGeometry(page: page)
            let graphics = page.pageRef.map { GraphicsScanner.scan(page: $0, geo: geo, vectors: true) } ?? PageGraphics()
            let glyphs = TextExtractor.glyphs(page: page, geo: geo, styles: styles, textRuns: graphics.textRuns)
            let scanned = PDFOCR.needsOCR(visibleChars: glyphs.count, graphics: graphics, geo: geo)
            let unreadable = !scanned && PDFOCR.textIsUnreadable(glyphs: glyphs, graphics: graphics)
            prepared.append(Prepared(page: page, index: i, geo: geo, graphics: graphics, glyphs: glyphs, scanned: scanned, unreadable: unreadable))
        }
        let ocrPages = options.ocrWhenNeeded ? prepared.indices.filter { prepared[$0].scanned || prepared[$0].unreadable } : []
        // OCR dominates the cost, so it gets most of the progress range.
        let ocrShare = ocrPages.isEmpty ? 0.0 : 0.8
        progress?(0.1 * (1 - ocrShare))
        let ocrResults = recognize(prepared: prepared, indices: ocrPages) { done in
            progress?(0.1 * (1 - ocrShare) + ocrShare * Double(done) / Double(max(1, ocrPages.count)))
        }
        pages.reserveCapacity(prepared.count)
        for (k, p) in prepared.enumerated() {
            pages.append(analyzePage(p, ocrLines: ocrResults[k]))
            progress?(0.1 * (1 - ocrShare) + ocrShare + (1 - ocrShare) * 0.9 * Double(k + 1) / Double(max(1, prepared.count)))
        }
        if options.removeRunningHeadersFooters { removeRunningHeadersFooters() }
        if options.includeImages { dedupeRepeatedImages() }
        var w: [Double: Int] = [:]
        for p in pages { for l in p.lines { w[l.size, default: 0] += l.charCount } }
        layoutBodySize = w.max { $0.value < $1.value }?.key ?? 10
        let landscape = pages.filter { $0.geo.size.width > $0.geo.size.height * 1.15 }.count
        let creator = ((document.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String) ?? "") + " " +
            ((document.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String) ?? "")
        let presentationApp = ["PowerPoint", "Keynote", "Impress", "Google Slides", "Presentation"].contains { creator.localizedCaseInsensitiveContains($0) }
        isSlideDeck = !pages.isEmpty && Double(landscape) >= Double(pages.count) * 0.6 && (presentationApp || layoutBodySize >= 16)
    }

    func flows() -> [[FlowItem]] {
        // Right margin shared across pages of the same width.
        var rightsByWidth: [Int: [CGFloat]] = [:]
        for p in pages { for l in p.lines where l.charCount >= 8 { rightsByWidth[SafeInt.floor(Double(p.geo.size.width)), default: []].append(l.right) } }
        var docRight: [Int: CGFloat] = [:]
        for (w, rights) in rightsByWidth {
            let sorted = rights.sorted(by: >)
            let need = max(3, sorted.count / 30)
            let tol = CGFloat(layoutBodySize)
            if let r = sorted.first(where: { r in sorted.filter { abs($0 - r) <= tol }.count >= need }) {
                docRight[w] = sorted.filter { abs($0 - r) <= tol }.max() ?? r
            }
        }
        return pages.map { p in
            var atoms: [Atom] = p.tables.map { Atom(rect: $0.rect, item: .table($0)) }
            atoms += p.images.map { Atom(rect: $0.atom.rect, item: .image($0.atom)) }
            return [.pageStart(p.index)] + LayoutAnalyzer.order(lines: p.lines, atoms: atoms, pageSize: p.geo.size, bodySize: layoutBodySize,
                                                                 docRight: docRight[SafeInt.floor(Double(p.geo.size.width))], slides: isSlideDeck, styles: styles)
        }
    }

    /// Renders pages on the calling thread (PDFKit drawing) and runs Vision concurrently, a few pages at a time.
    private func recognize(prepared: [Prepared], indices: [Int], progress: (Int) -> Void) -> [Int: [(text: String, rect: CGRect)]] {
        guard !indices.isEmpty else { return [:] }
        var results: [Int: [(text: String, rect: CGRect)]] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))
        let languages = options.languages
        var done = 0
        for k in indices {
            slots.wait()
            let p = prepared[k]
            guard let img = PDFOCR.render(page: p.page, scale: PDFOCR.renderScale) else {
                slots.signal(); continue
            }
            let size = p.geo.size
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let lines = PDFOCR.displayLines(image: img, pageSize: size, languages: languages)
                lock.lock(); results[k] = lines; done += 1; lock.unlock()
                slots.signal()
            }
            lock.lock(); let d = done; lock.unlock()
            progress(d)
        }
        group.wait()
        progress(indices.count)
        return results
    }

    private func analyzePage(_ prep: Prepared, ocrLines: [(text: String, rect: CGRect)]?) -> PageAnalysis {
        let page = prep.page, index = prep.index, geo = prep.geo, scanned = prep.scanned
        var graphics = prep.graphics
        var glyphs = prep.glyphs
        var ocr = false
        if let lines = ocrLines {
            if !lines.isEmpty {
                glyphs = PDFOCR.glyphs(from: lines, styles: styles)
                ocr = true
                if scanned {
                    // The scan itself is not content.
                    let area = geo.size.width * geo.size.height
                    graphics.images.removeAll { $0.rect.area >= area * 0.3 }
                    graphics.rules = []; graphics.fills = []; graphics.shapes = []
                }
            }
        }
        var consumed = [Bool](repeating: false, count: glyphs.count)
        let tables = (ocr && scanned) ? [] : RuledTableDetector.detect(graphics: graphics, glyphs: glyphs, consumed: &consumed, page: index, pageSize: geo.size, styles: styles)

        var images: [(ImageAtom, UInt64)] = []
        var figureKeys = Set<Int>()
        if options.includeImages && options.rasterizeVectorFigures && !(ocr && scanned) {
            let figures = FigureDetector.detect(graphics: graphics, glyphs: glyphs, consumed: consumed, tables: tables.map(\.rect),
                                                pageSize: geo.size, page: index, styles: styles)
            for f in figures {
                for gi in f.glyphs { consumed[gi] = true }
                figureKeys.formUnion(f.imageKeys)
                if let img = renderRegion(page: page, geo: geo, rect: f.rect) {
                    images.append((ImageAtom(image: img, rect: f.rect), ContentHash.hash(img.data)))
                }
            }
        }
        let remaining = glyphs.enumerated().filter { !consumed[$0.offset] }.map(\.element)
        let lines = TextExtractor.buildLines(remaining, page: index, styles: styles)

        if options.includeImages {
            let pageArea = geo.size.width * geo.size.height
            var seen = Set<Int>()
            for p in graphics.images where !p.isMask && !figureKeys.contains(p.key) {
                let r = p.rect.intersection(geo.bounds)
                guard !r.isNull, max(r.width, r.height) >= 24, min(r.width, r.height) >= 6 else { continue }
                // Full-page pictures under real text are backgrounds (or the scan behind an OCR layer).
                if r.area >= pageArea * 0.8 && glyphs.count >= 24 { continue }
                if r.area >= pageArea * 0.3 && ocr { continue }
                // The same XObject drawn twice at the same spot (e.g. shadow) only once.
                let spot = p.key ^ SafeInt.floor(Double(r.minX)) &* 31 ^ SafeInt.floor(Double(r.minY)) &* 131
                guard seen.insert(spot).inserted else { continue }
                guard let dec = PDFImageDecoder.decode(p) else { continue }
                var data = dec.data, format = dec.format, pw = dec.width, ph = dec.height
                // Crop pictures that are clipped to a much smaller window.
                if r.area < p.drawnRect.area * 0.9, let cropped = crop(dec, drawn: p.drawnRect, visible: r) {
                    data = cropped.data; format = cropped.format; pw = cropped.width; ph = cropped.height
                }
                let img = DocImage(data: data, format: format, pixelWidth: pw, pixelHeight: ph,
                                   displayWidth: Double(r.width), displayHeight: Double(r.height))
                images.append((ImageAtom(image: img, rect: r), ContentHash.hash(data)))
            }
        }
        return PageAnalysis(index: index, geo: geo, lines: lines, tables: tables, images: images.map { (atom: $0.0, hash: $0.1) }, ocr: ocr)
    }

    private func crop(_ dec: PDFImageDecoder.Decoded, drawn: CGRect, visible: CGRect) -> PDFImageDecoder.Decoded? {
        guard drawn.width > 0, drawn.height > 0, let img = ImageCodec.decode(dec.data) else { return nil }
        let sx = CGFloat(img.width) / drawn.width, sy = CGFloat(img.height) / drawn.height
        let r = CGRect(x: (visible.minX - drawn.minX) * sx, y: (visible.minY - drawn.minY) * sy,
                       width: visible.width * sx, height: visible.height * sy).integral
        guard r.width >= 4, r.height >= 4, let c = img.cropping(to: r) else { return nil }
        return PDFImageDecoder.encode(c, photo: dec.format == .jpeg, hasAlpha: dec.format == .png && c.alphaInfo != .none && c.alphaInfo != .noneSkipLast && c.alphaInfo != .noneSkipFirst)
    }

    private func renderRegion(page: PDFPage, geo: PageGeometry, rect: CGRect) -> DocImage? {
        let r = rect.intersection(geo.bounds)
        guard !r.isNull, r.width >= 4, r.height >= 4 else { return nil }
        let scale: CGFloat = 2
        let w = SafeInt.round(Double(r.width * scale), 0, 1_000_000), h = SafeInt.round(Double(r.height * scale), 0, 1_000_000)
        guard w > 0, h > 0, SafeInt.isReasonablePixelSize(w, h, limit: 40_000_000),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -r.minX, y: -(geo.size.height - r.maxY))
        page.draw(with: .cropBox, to: ctx)
        guard let img = ctx.makeImage(), let dec = PDFImageDecoder.encode(img, photo: PDFImageDecoder.looksPhotographic(img), hasAlpha: false) else { return nil }
        return DocImage(data: dec.data, format: dec.format, pixelWidth: dec.width, pixelHeight: dec.height,
                        displayWidth: Double(r.width), displayHeight: Double(r.height))
    }

    // MARK: Running headers / footers

    private static let pageNumberPatterns: [NSRegularExpression] = [
        #"^[-–—\s]*\d{1,4}[-–—\s]*$"#,
        #"^\d{1,4}\s*/\s*\d{1,4}$"#,
        #"^(?i:page|p\.)\s*\d{1,4}(\s*(of|/)\s*\d{1,4})?$"#,
        #"^[\(（]?\s*\d{1,4}\s*[\)）]?$"#,
        #"^第?\s*\d{1,4}\s*(ページ|頁)$"#,
        #"^\d{1,4}\s*ページ\s*/\s*\d{1,4}$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func isPageNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        let r = NSRange(location: 0, length: (t as NSString).length)
        return pageNumberPatterns.contains { $0.firstMatch(in: t, range: r) != nil }
    }

    private func normalizedKey(_ l: TextLine) -> String {
        var s = ""
        for g in l.glyphs {
            if g.text.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                if !s.hasSuffix("#") { s += "#" }
            } else { s += g.text }
        }
        return s
    }

    /// Removes running headers/footers and page numbers. Deliberately conservative: a candidate must sit in a
    /// block at the very top or bottom of the page that is set apart from the body (a clear gap, or smaller type
    /// with some gap), be short, not be the page's largest text, and repeat on at least half of the pages.
    private func removeRunningHeadersFooters() {
        let n = pages.count
        var sizeWeight: [Double: Int] = [:]
        for p in pages { for l in p.lines { sizeWeight[l.size, default: 0] += l.charCount } }
        let body = sizeWeight.max { $0.value < $1.value }?.key ?? 10
        let builder = BlockBuilder(styles: styles, stats: DocStats(bodySize: body, bodyFont: nil, bodyMono: false, pitch: [:], pitchRatio: 1.5))
        // Identical pages (forms, repeated handouts) make every line "repeat"; they get extra protection.
        let fingerprints = pages.map { p in p.lines.map(normalizedKey).joined(separator: "\n") }

        struct Candidate { var line: Int; var outer: Bool }
        func candidates(_ p: PageAnalysis) -> [Candidate] {
            let h = p.geo.size.height
            let order = p.lines.indices.sorted { p.lines[$0].rect.minY < p.lines[$1].rect.minY }
            guard order.count >= 2 else { return [] }
            var gaps: [CGFloat] = []
            for k in 1..<order.count { gaps.append(p.lines[order[k]].rect.minY - p.lines[order[k - 1]].rect.maxY) }
            let typical = max(1, CGFloat(Stats.median(gaps.filter { $0 > 0 }.map(Double.init)) ?? 6))
            var out: [Candidate] = []
            func block(_ idx: [Int], gap: CGFloat, inZone: (TextLine) -> Bool, outerZone: (TextLine) -> Bool) -> Bool {
                let ls = idx.map { p.lines[$0] }
                guard ls.allSatisfy(inZone) else { return false }
                let lineH = ls.map(\.rect.height).max() ?? 10
                let small = ls.allSatisfy { $0.size < body - 0.4 }
                let outer = ls.allSatisfy(outerZone)
                let clear = gap >= max(typical * 2, lineH * 0.8) || (small && gap >= lineH * 0.5) || (outer && gap >= typical * 1.5)
                if clear { out += idx.map { Candidate(line: $0, outer: outer) } }
                return clear
            }
            // The header block ends at the widest gap among its first three lines; same for the footer.
            let kmax = min(3, order.count - 1)
            if let k = (0..<kmax).max(by: { gaps[$0] < gaps[$1] }) {
                _ = block(Array(order[0...k]), gap: gaps[k], inZone: { $0.rect.maxY <= h * 0.2 }, outerZone: { $0.rect.maxY <= h * 0.09 })
            }
            if let k = (0..<kmax).max(by: { gaps[order.count - 2 - $0] < gaps[order.count - 2 - $1] }) {
                let first = order.count - 1 - k
                _ = block(Array(order[first...]), gap: gaps[first - 1], inZone: { $0.rect.minY >= h * 0.8 }, outerZone: { $0.rect.minY >= h * 0.91 })
            }
            // A lone page number as the first or last line only needs to stand apart a little.
            for (i, gap) in [(order[0], gaps[0]), (order[order.count - 1], gaps[gaps.count - 1])] where !out.contains(where: { $0.line == i }) {
                let l = p.lines[i]
                let edge = l.rect.maxY <= h * 0.2 || l.rect.minY >= h * 0.8
                if edge && gap >= max(l.rect.height * 0.8, typical * 0.8) && l.charCount <= 12 && isPageNumberLine(l, builder) {
                    out.append(Candidate(line: i, outer: false))
                }
            }
            return out
        }
        let cands = pages.map(candidates)
        var pagesWithKey: [String: Set<Int>] = [:]
        for (pi, p) in pages.enumerated() {
            for c in cands[pi] { pagesWithKey[normalizedKey(p.lines[c.line]), default: []].insert(pi) }
        }
        let threshold = max(2, Int((Double(n) * 0.5).rounded(.up)))
        for pi in pages.indices {
            let p = pages[pi]
            let maxSize = p.lines.map(\.size).max() ?? 0
            var drop = Set<Int>()
            for c in cands[pi] {
                let l = p.lines[c.line]
                if isPageNumberLine(l, builder) { drop.insert(c.line); continue }
                guard n >= 2, l.charCount <= 60, l.size <= body * 1.15, l.size < maxSize - 0.25 else { continue }
                guard let where_ = pagesWithKey[normalizedKey(l)], where_.count >= threshold else { continue }
                let identical = Set(where_.map { fingerprints[$0] }).count == 1
                if identical && !c.outer { continue }
                drop.insert(c.line)
            }
            // A page number sharing a baseline with other text (slide numbers in a corner) on the last/first line.
            let h = p.geo.size.height, w = p.geo.size.width
            let order = p.lines.indices.sorted { p.lines[$0].rect.minY < p.lines[$1].rect.minY }
            for i in [order.first, order.last].compactMap({ $0 }) where !drop.contains(i) {
                let l = p.lines[i]
                guard l.segments.count >= 2, l.rect.minY >= h * 0.88 || l.rect.maxY <= h * 0.12 else { continue }
                var segs = l.segments
                let em = CGFloat(l.size)
                if let last = segs.last, last.rect.minX >= w * 0.75, last.rect.minX - segs[segs.count - 2].rect.maxX > em * 2,
                   DocumentAnalyzer.isPageNumber(last.text) { segs.removeLast() }
                if segs.count >= 2, let first = segs.first, first.rect.maxX <= w * 0.25, segs[1].rect.minX - first.rect.maxX > em * 2,
                   DocumentAnalyzer.isPageNumber(first.text) { segs.removeFirst() }
                if segs.count != l.segments.count {
                    var nl = l
                    nl.segments = segs
                    nl.computeStats(styles)
                    pages[pi].lines[i] = nl
                }
            }
            if !drop.isEmpty { pages[pi].lines = pages[pi].lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element) }
        }
    }

    private func isPageNumberLine(_ l: TextLine, _ b: BlockBuilder) -> Bool {
        l.charCount <= 16 && DocumentAnalyzer.isPageNumber(b.plainLine(l))
    }

    // MARK: Repeated images (logos)

    private func dedupeRepeatedImages() {
        let n = pages.count
        var pagesWithHash: [UInt64: Set<Int>] = [:]
        for p in pages { for im in p.images { pagesWithHash[im.hash, default: []].insert(p.index) } }
        var kept = Set<UInt64>()
        for pi in pages.indices {
            pages[pi].images = pages[pi].images.filter { im in
                let count = pagesWithHash[im.hash]?.count ?? 0
                let repeated = count >= 3 || (count >= 2 && Double(count) >= Double(n) * 0.5)
                guard repeated else { return true }
                return kept.insert(im.hash).inserted
            }
        }
    }
}
