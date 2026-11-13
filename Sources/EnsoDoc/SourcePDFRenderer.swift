import AppKit

/// PDF of a document that brings its own page layout (Word): every page takes its size, margins, header and footer
/// from the section its first character belongs to; headers and footers are laid out in their own boxes with the page
/// fields filled in; headings that would end a page move to the next one with their text (keep with next); tab
/// leaders are drawn. Paragraph formatting comes from AttributedConverter's source layout.
extension PDFRenderer {

    /// One page of the source layout.
    struct SourcePage {
        var section: Int
        /// The number the page shows (sections can restart numbering).
        var number: Int
        var kind: DocHeaderKind
        var origin: CGPoint
        var size: CGSize
        var lm: NSLayoutManager?
        var tc: NSTextContainer?
        var notes: Notes?
    }

    static func sourcePDF(_ model: DocModel, layout: DocPageLayout, pageNumbers: Bool) -> Data {
        let sections = layout.sections
        let first = sections[0]
        let style = AttributedConverter.Style(bodySize: CGFloat(model.bodyFontSize), contentWidth: CGFloat(first.contentWidth),
                                              contentHeight: CGFloat(max(first.height - first.top - first.bottom, 36)), paged: true)
        let attr = TextLayerFonts.fixed(AttributedConverter.attributedString(from: model, style: style))

        // Headers and footers as attributed text, once per section, kind and side; page fields are filled per page.
        var heads: [String: NSAttributedString] = [:]
        func head(_ s: Int, _ kind: DocHeaderKind, header: Bool) -> NSAttributedString? {
            let key = "\(s)|\(kind.rawValue)|\(header)"
            if let hit = heads[key] { return hit.length > 0 ? hit : nil }
            let blocks = (header ? sections[s].headers[kind] : sections[s].footers[kind]) ?? []
            var built = NSAttributedString()
            if !blocks.isEmpty {
                var sec = sections[s]
                sec.firstBlock = 0; sec.headers = [:]; sec.footers = [:]
                var sub = DocModel(blocks: blocks, bodyFontSize: model.bodyFontSize, bodyFontName: model.bodyFontName,
                                   bodyEastAsianFontName: model.bodyEastAsianFontName)
                sub.pageLayout = DocPageLayout(sections: [sec], defaultTabStop: layout.defaultTabStop)
                let st = AttributedConverter.Style(bodySize: CGFloat(model.bodyFontSize), contentWidth: CGFloat(sec.contentWidth),
                                                   contentHeight: CGFloat(sec.height / 3), paged: true)
                built = TextLayerFonts.fixed(trimmedTrailingNewline(AttributedConverter.attributedString(from: sub, style: st)))
            }
            heads[key] = built
            return built.length > 0 ? built : nil
        }
        func kind(section s: Int, firstOfSection: Bool, number: Int) -> DocHeaderKind {
            if firstOfSection && sections[s].titlePage { return .first }
            if layout.evenAndOddHeaders && number % 2 == 0 { return .even }
            return .default
        }
        /// Height a header or footer takes on a page (page fields filled with wide stand-ins).
        func headHeight(_ s: Int, _ k: DocHeaderKind, header: Bool, number: Int) -> CGFloat {
            guard let h = head(s, k, header: header) else { return 0 }
            let filled = fillFields(h, page: format(number, sections[s].pageNumberFormat), total: "888", sectionTotal: "888")
            return layoutBox(filled, width: CGFloat(sections[s].contentWidth)).height
        }

        var pages: [SourcePage] = []
        var storages: [NSTextStorage] = []
        var hasFootnotes = false
        attr.enumerateAttribute(.ensoFootnote, in: NSRange(location: 0, length: attr.length)) { v, _, stop in
            if v != nil { hasFootnotes = true; stop.pointee = true }
        }
        var carried = NSAttributedString()
        var prevSection = -1
        var number = 0

        func newPage(section s: Int) -> SourcePage {
            let firstOfSection = s != prevSection
            if firstOfSection, let start = sections[s].pageNumberStart { number = start } else { number += 1 }
            prevSection = s
            let k = kind(section: s, firstOfSection: firstOfSection, number: number)
            let sec = sections[s]
            // The body starts below the header when the header reaches past the top margin, as in Word; same at the foot.
            let top = max(CGFloat(sec.top), CGFloat(sec.headerDistance) + headHeight(s, k, header: true, number: number))
            let bottom = max(CGFloat(sec.bottom), CGFloat(sec.footerDistance) + headHeight(s, k, header: false, number: number))
            let height = max(CGFloat(sec.height) - top - bottom, 36)
            return SourcePage(section: s, number: number, kind: k, origin: CGPoint(x: CGFloat(sec.left), y: top),
                              size: CGSize(width: CGFloat(sec.contentWidth), height: height))
        }
        func section(at loc: Int, in s: NSAttributedString) -> Int {
            guard loc < s.length, let v = s.attribute(.ensoSection, at: loc, effectiveRange: nil) as? Int, sections.indices.contains(v) else {
                return max(prevSection, 0)
            }
            return v
        }

        for segment in splitRanges(attr) {
            let storage = NSTextStorage(attributedString: attr.attributedSubstring(from: segment))
            let lm = NSLayoutManager()
            // Line heights come from the paragraph styles (Word's metrics), not from the Mac fonts' leading.
            lm.usesFontLeading = false
            storage.addLayoutManager(lm)
            storages.append(storage)
            var next = 0
            var guardCount = 0
            while true {
                var page = newPage(section: section(at: next, in: storage))
                let tc = NSTextContainer(size: page.size)
                tc.lineFragmentPadding = 0
                lm.addTextContainer(tc)
                page.lm = lm; page.tc = tc
                if hasFootnotes { page.notes = placeFootnotes(lm, tc, page.size, carried: &carried) }
                keepWithNext(lm, tc, storage)
                let range = lm.glyphRange(for: tc)
                pages.append(page)
                guardCount += 1
                if NSMaxRange(range) >= lm.numberOfGlyphs || guardCount > 5000 { break }
                // An element taller than the page can make no progress; stop instead of looping forever.
                if range.length == 0 { break }
                next = NSMaxRange(lm.characterRange(forGlyphRange: range, actualGlyphRange: nil))
            }
        }
        // Notes still waiting after the last page get pages of their own.
        var noteGuard = 0
        while carried.length > 0, noteGuard < 1000 {
            noteGuard += 1
            var page = newPage(section: max(prevSection, 0))
            let fit = fitNotes(carried, width: page.size.width, height: page.size.height)
            page.notes = fit.notes
            pages.append(page)
            carried = fit.rest
            if fit.notes == nil { break }
        }

        // Draw.
        let data = NSMutableData()
        var firstBox = CGRect(origin: .zero, size: first.size)
        var info: [CFString: Any] = [kCGPDFContextCreator: "MaruDoc"]
        if let title = model.title { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, info as CFDictionary) else { return Data() }
        let total = pages.count
        var sectionTotals: [Int: Int] = [:]
        for p in pages { sectionTotals[p.section, default: 0] += 1 }
        for (index, page) in pages.enumerated() {
            let sec = sections[page.section]
            var box = CGRect(origin: .zero, size: sec.size)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: sec.size.height)
            ctx.scaleBy(x: 1, y: -1)
            if let lm = page.lm, let tc = page.tc {
                let range = lm.glyphRange(for: tc)
                if range.length > 0 {
                    drawBorders(lm, tc, glyphs: range, origin: page.origin, ctx: ctx)
                    lm.drawBackground(forGlyphRange: range, at: page.origin)
                    lm.drawGlyphs(forGlyphRange: range, at: page.origin)
                    drawTabLeaders(lm, tc, glyphs: range, origin: page.origin, ctx: ctx)
                }
            }
            if let notes = page.notes {
                let top = page.lm == nil ? page.origin.y : page.origin.y + page.size.height - notes.height
                if page.lm != nil {
                    ctx.saveGState()
                    ctx.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
                    ctx.setLineWidth(0.5)
                    ctx.move(to: CGPoint(x: page.origin.x, y: top - 5))
                    ctx.addLine(to: CGPoint(x: page.origin.x + min(144, page.size.width / 3), y: top - 5))
                    ctx.strokePath()
                    ctx.restoreGState()
                }
                let nOrigin = CGPoint(x: page.origin.x, y: top)
                notes.lm.drawBackground(forGlyphRange: notes.glyphs, at: nOrigin)
                notes.lm.drawGlyphs(forGlyphRange: notes.glyphs, at: nOrigin)
            }
            let pageText = format(page.number, sec.pageNumberFormat)
            let sectionTotal = String(sectionTotals[page.section] ?? total)
            for header in [true, false] {
                guard let h = head(page.section, page.kind, header: header) else { continue }
                let filled = fillFields(h, page: pageText, total: String(total), sectionTotal: sectionTotal)
                let laid = layoutBox(filled, width: CGFloat(sec.contentWidth))
                let y = header ? CGFloat(sec.headerDistance) : CGFloat(sec.height - sec.footerDistance) - laid.height
                let origin = CGPoint(x: CGFloat(sec.left), y: y)
                laid.lm.drawBackground(forGlyphRange: laid.glyphs, at: origin)
                laid.lm.drawGlyphs(forGlyphRange: laid.glyphs, at: origin)
                drawTabLeaders(laid.lm, laid.tc, glyphs: laid.glyphs, origin: origin, ctx: ctx)
            }
            if pageNumbers && total > 1 {
                let label = "\(index + 1) / \(total)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: (sec.size.width - size.width) / 2, y: sec.size.height - CGFloat(sec.bottom) / 2 - size.height / 2), withAttributes: attrs)
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

    /// Ranges of `attr` between paragraphs carrying `.ensoPageBreak` (each starts a new page).
    static func splitRanges(_ attr: NSAttributedString) -> [NSRange] {
        var cuts: [Int] = []
        attr.enumerateAttribute(.ensoPageBreak, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
            if v != nil, r.location > 0 { cuts.append(r.location) }
        }
        var out: [NSRange] = []
        var start = 0
        for c in cuts where c > start {
            out.append(NSRange(location: start, length: c - start))
            start = c
        }
        out.append(NSRange(location: start, length: attr.length - start))
        return out.filter { $0.length > 0 }
    }

    /// Word's "keep with next": paragraphs that end the page and keep with the next one (headings) move to the next
    /// page together with the text they introduce. Never empties a page.
    static func keepWithNext(_ lm: NSLayoutManager, _ tc: NSTextContainer, _ storage: NSTextStorage) {
        let glyphs = lm.glyphRange(for: tc)
        guard glyphs.length > 0, NSMaxRange(glyphs) < lm.numberOfGlyphs else { return }
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ns = storage.string as NSString
        var cut = NSMaxRange(chars)
        var moved = 0
        while cut > chars.location, moved < 5 {
            let para = ns.paragraphRange(for: NSRange(location: cut - 1, length: 0))
            guard NSMaxRange(para) == cut, para.location > chars.location,
                  storage.attribute(.ensoKeepNext, at: para.location, effectiveRange: nil) != nil else { break }
            cut = para.location
            moved += 1
        }
        guard cut < NSMaxRange(chars) else { return }
        let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: cut), effectiveRange: nil)
        guard rect.minY > 1 else { return }
        tc.size = CGSize(width: tc.size.width, height: rect.minY)
        _ = lm.glyphRange(for: tc)
    }

    /// Text laid out in a box of the given width, unlimited height (headers and footers).
    struct Box {
        let storage: NSTextStorage
        let lm: NSLayoutManager
        let tc: NSTextContainer
        let glyphs: NSRange
        let height: CGFloat
    }

    static func layoutBox(_ text: NSAttributedString, width: CGFloat) -> Box {
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        lm.usesFontLeading = false
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: max(width, 1), height: 10_000))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let glyphs = lm.glyphRange(for: tc)
        return Box(storage: storage, lm: lm, tc: tc, glyphs: glyphs, height: ceil(lm.usedRect(for: tc).height))
    }

    static func trimmedTrailingNewline(_ s: NSAttributedString) -> NSAttributedString {
        guard s.length > 0, (s.string as NSString).character(at: s.length - 1) == 0x0A else { return s }
        return s.attributedSubstring(from: NSRange(location: 0, length: s.length - 1))
    }

    /// The text with the page field placeholders (DocField) replaced by the numbers.
    static func fillFields(_ s: NSAttributedString, page: String, total: String, sectionTotal: String) -> NSAttributedString {
        let ns = s.string as NSString
        let fields = CharacterSet(charactersIn: String(DocField.page) + String(DocField.numPages) + String(DocField.sectionPages))
        guard ns.rangeOfCharacter(from: fields).location != NSNotFound else { return s }
        let out = NSMutableAttributedString(attributedString: s)
        var r = (out.string as NSString).rangeOfCharacter(from: fields, options: .backwards)
        var count = 0
        while r.location != NSNotFound, count < 1000 {
            count += 1
            let ch = Character((out.string as NSString).substring(with: r))
            let value = ch == DocField.page ? page : ch == DocField.numPages ? total : sectionTotal
            out.replaceCharacters(in: r, with: value)
            r = (out.string as NSString).rangeOfCharacter(from: fields, options: .backwards, range: NSRange(location: 0, length: r.location))
        }
        return out
    }

    /// A page number in Word's number formats (`w:pgNumType w:fmt`); unknown formats print as decimal.
    static func format(_ n: Int, _ fmt: String?) -> String {
        func roman(_ v: Int) -> String {
            guard (1...3999).contains(v) else { return String(v) }
            let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                          (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
            var v = v, s = ""
            for (k, r) in table { while v >= k { s += r; v -= k } }
            return s
        }
        func letters(_ v: Int, _ base: UInt32) -> String {
            guard v >= 1, v <= 26 * 50 else { return String(v) }
            return String(repeating: String(UnicodeScalar(base + UInt32((v - 1) % 26))!), count: (v - 1) / 26 + 1)
        }
        switch fmt {
        case "upperRoman": return roman(n)
        case "lowerRoman": return roman(n).lowercased()
        case "upperLetter": return letters(n, 0x41)
        case "lowerLetter": return letters(n, 0x61)
        case "numberInDash": return "- \(n) -"
        case "decimalFullWidth", "decimalFullWidth2":
            return n >= 0 ? String(String(n).unicodeScalars.map { Character(UnicodeScalar($0.value - 0x30 + 0xFF10)!) }) : String(n)
        case "decimalEnclosedCircle", "decimalEnclosedCircleChinese":
            return (1...20).contains(n) ? String(UnicodeScalar(0x2460 + UInt32(n - 1))!) : String(n)
        default: return String(n)
        }
    }

    /// Dot, hyphen or line leaders before the text at tab stops that have one (tables of contents).
    static func drawTabLeaders(_ lm: NSLayoutManager, _ tc: NSTextContainer, glyphs: NSRange, origin: CGPoint, ctx: CGContext) {
        guard let storage = lm.textStorage else { return }
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ns = storage.string as NSString
        storage.enumerateAttribute(.ensoTabLeaders, in: chars) { v, r, _ in
            guard let stops = v as? [DocTabStop], !stops.isEmpty else { return }
            var i = r.location
            while i < NSMaxRange(r) {
                let tab = ns.range(of: "\t", options: [], range: NSRange(location: i, length: NSMaxRange(r) - i))
                if tab.location == NSNotFound { break }
                i = NSMaxRange(tab)
                let g = lm.glyphIndexForCharacter(at: tab.location)
                var line = NSRange()
                let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &line)
                guard g + 1 < NSMaxRange(line) else { continue }
                let x0 = frag.minX + lm.location(forGlyphAt: g).x
                let x1 = frag.minX + lm.location(forGlyphAt: g + 1).x
                // The stop the tab went to: the first one past where it started (TextKit's rule, and Word's).
                guard x1 - x0 > 6, let stop = stops.first(where: { CGFloat($0.position) > x0 + 0.5 }), stop.leader != .none else { continue }
                let font = (storage.attribute(.font, at: tab.location, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 10)
                let size = font.pointSize
                let baseline = frag.minY + lm.location(forGlyphAt: g).y
                let color = (storage.attribute(.foregroundColor, at: tab.location, effectiveRange: nil) as? NSColor) ?? .black
                let start = origin.x + x0 + size * 0.2, end = origin.x + x1 - size * 0.2
                guard end > start else { continue }
                let y = origin.y + baseline
                ctx.saveGState()
                ctx.setFillColor(color.cgColor)
                ctx.setStrokeColor(color.cgColor)
                switch stop.leader {
                case .dot, .middleDot:
                    // Dots on a fixed pitch, aligned across lines like Word's periods.
                    let pitch = max(size * 0.33, 2)
                    let r = max(size * 0.045, 0.35)
                    let dy = stop.leader == .middleDot ? y - size * 0.3 : y - r
                    var x = (ceil(start / pitch)) * pitch
                    while x <= end { ctx.fillEllipse(in: CGRect(x: x - r, y: dy - r, width: 2 * r, height: 2 * r)); x += pitch }
                case .hyphen:
                    ctx.setLineWidth(max(size * 0.05, 0.5))
                    let pitch = max(size * 0.5, 3)
                    var x = (ceil(start / pitch)) * pitch
                    while x + pitch * 0.6 <= end {
                        ctx.move(to: CGPoint(x: x, y: y - size * 0.3)); ctx.addLine(to: CGPoint(x: x + pitch * 0.6, y: y - size * 0.3))
                        x += pitch
                    }
                    ctx.strokePath()
                case .underscore:
                    ctx.setLineWidth(max(size * 0.05, 0.5))
                    ctx.move(to: CGPoint(x: start, y: y + 1)); ctx.addLine(to: CGPoint(x: end, y: y + 1))
                    ctx.strokePath()
                case .none: break
                }
                ctx.restoreGState()
            }
        }
    }

    /// Paragraph borders: one box around each run of neighbouring paragraphs with equal borders, cut at the page edge
    /// like Word's. The lines stand `space` points off the text, the sides off the paragraph's indents.
    static func drawBorders(_ lm: NSLayoutManager, _ tc: NSTextContainer, glyphs: NSRange, origin: CGPoint, ctx: CGContext) {
        guard let storage = lm.textStorage else { return }
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ns = storage.string as NSString
        storage.enumerateAttribute(.ensoBorders, in: chars) { v, r, _ in
            guard let b = v as? DocBorders, !b.isEmpty else { return }
            let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard g.length > 0 else { return }
            var top = CGFloat.greatestFiniteMagnitude, bottom: CGFloat = 0
            lm.enumerateLineFragments(forGlyphRange: g) { rect, _, _, _, _ in
                top = min(top, rect.minY); bottom = max(bottom, rect.maxY)
            }
            guard bottom > top else { return }
            // Spacing before the first paragraph and after the last lies outside the box.
            let first = storage.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
            let lastIndex = max(r.location, NSMaxRange(r) - 1)
            let last = storage.attribute(.paragraphStyle, at: lastIndex, effectiveRange: nil) as? NSParagraphStyle
            if ns.paragraphRange(for: NSRange(location: r.location, length: 0)).location == r.location, r.location >= chars.location {
                top += first?.paragraphSpacingBefore ?? 0
            }
            if NSMaxRange(r) <= NSMaxRange(chars) { bottom -= last?.paragraphSpacing ?? 0 }
            let indent = min(first?.headIndent ?? 0, first?.firstLineHeadIndent ?? 0)
            let tail = first.map { $0.tailIndent < 0 ? tc.size.width + $0.tailIndent : ($0.tailIndent > 0 ? $0.tailIndent : tc.size.width) } ?? tc.size.width
            let left = origin.x + indent - CGFloat(b.left?.space ?? 0) - 1
            let right = origin.x + tail + CGFloat(b.right?.space ?? 0) + 1
            let y0 = origin.y + top - CGFloat(b.top?.space ?? 0)
            // Exactly spaced lines can set descenders below their line; the bottom line keeps clear of them.
            let y1 = origin.y + bottom + CGFloat(b.bottom?.space ?? 0) + 1.5
            func line(_ e: DocBorders.Edge?, _ a: CGPoint, _ z: CGPoint) {
                guard let e else { return }
                ctx.saveGState()
                ctx.setStrokeColor(e.color.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) } ?? CGColor(gray: 0, alpha: 1))
                ctx.setLineWidth(CGFloat(e.width))
                ctx.move(to: a); ctx.addLine(to: z); ctx.strokePath()
                ctx.restoreGState()
            }
            line(b.top, CGPoint(x: left, y: y0), CGPoint(x: right, y: y0))
            line(b.bottom, CGPoint(x: left, y: y1), CGPoint(x: right, y: y1))
            line(b.left, CGPoint(x: left, y: y0), CGPoint(x: left, y: y1))
            line(b.right, CGPoint(x: right, y: y0), CGPoint(x: right, y: y1))
        }
    }
}
