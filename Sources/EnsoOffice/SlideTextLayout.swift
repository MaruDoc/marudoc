import Foundation
import CoreText
import CoreGraphics

/// Lays out styled paragraphs the way PowerPoint does (single line spacing = 1.2 x the largest font size on the line,
/// extra spacing added above the text) and draws them as real text with Core Text.
final class SlideTextLayout {
    let fonts: SlideFonts

    init(fonts: SlideFonts) { self.fonts = fonts }

    /// Distance from a line's baseline to the bottom of its line box, as a fraction of the font size.
    static let descentFraction = 0.2

    /// Line pitch: single spacing is 1.2 x the largest font size on the line, whatever the font (the heights
    /// PowerPoint stores for autofit text boxes give 1.2-1.22). A percentage scales the whole line, the first line of
    /// the text included, and exact spacing (points) replaces it; LibreOffice's PowerPoint import does the same.
    static func pitch(size: Double, pct: Double?, pts: Double?) -> Double {
        if let pts { return pts }
        return 1.2 * size * (pct ?? 1)
    }

    struct RunPiece {
        var index: Int
        var x: Double, width: Double
        var style: StyledRun
        var font: CTFont
    }

    struct Line {
        var ct: CTLine
        var x: Double
        var width: Double
        var top: Double = 0
        var pitch: Double
        var baseline: Double = 0
        var size: Double
        var pieces: [RunPiece] = []
        var bullet: (line: CTLine, x: Double)?
    }

    struct Block {
        var lines: [Line] = []
        var height: Double = 0
        /// Height up to the last line with text (trailing empty paragraphs left out), for fitting decisions.
        var contentHeight: Double = 0
        /// Widest line extent from the left edge, for anchorCtr and unwrapped text.
        var width: Double = 0
        /// Widest line including its indent, whatever its alignment: what an unwrapped label needs.
        var maxLineWidth: Double = 0
        /// Some text is drawn in a Mac substitute for a font the deck names (not installed here).
        var usesSubstitute = false
        var isEmpty: Bool { lines.allSatisfy { $0.pieces.allSatisfy { $0.style.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && $0.bullet == nil } }
    }

    private static let runKey = "EnsoRunIndex" as CFString
    private static let shiftKey = "EnsoBaselineShift" as CFString

    // MARK: Layout

    func layout(_ paras: [StyledParagraph], width: Double, wrap: Bool) -> Block {
        var block = Block()
        var y = 0.0
        let areaWidth = wrap ? max(width, 1) : 1e7
        var anyLine = false
        for para in paras {
            let hasText = para.runs.contains { !$0.text.isEmpty && !$0.isBreak } || para.runs.contains { $0.isBreak }
            let firstSize = para.runs.first(where: { !$0.text.isEmpty })?.size ?? para.endSize
            let beforePitch = 1.2 * firstSize
            // Space before is not added above the first paragraph of a text body.
            if anyLine { y += para.spaceBefore.pts + para.spaceBefore.pct * beforePitch }
            guard hasText else {
                let size = para.endSize
                let pitch = SlideTextLayout.pitch(size: size, pct: para.lineSpacingPct, pts: para.lineSpacingPts)
                anyLine = true
                y += pitch
                y += para.spaceAfter.pts + para.spaceAfter.pct * 1.2 * size
                continue
            }
            var (attr, styles, substitute) = attributed(para)
            if substitute { block.usesSubstitute = true }
            var bullet: (CTLine, Double)?
            var firstX = para.marL + para.indent, restX = para.marL
            if let b = bulletLine(para) {
                let bx = max(para.marL + para.indent, 0)
                let bw = CTLineGetTypographicBounds(b, nil, nil, nil)
                bullet = (b, bx)
                firstX = para.indent < 0 ? max(para.marL, bx + bw) : bx + bw
            }
            firstX = max(firstX, 0); restX = max(restX, 0)
            if attr.length == 0 { attr = NSAttributedString(string: " ") }
            let ts = CTTypesetterCreateWithAttributedString(attr as CFAttributedString)
            var pos = 0
            var first = true
            var paraLines: [Line] = []
            let length = attr.length
            while pos < length {
                let lx = first ? firstX : restX
                let avail = max(areaWidth - lx, 1)
                var count = CTTypesetterSuggestLineBreakWithOffset(ts, pos, avail, lx)
                if count <= 0 { count = max(1, CTTypesetterSuggestClusterBreakWithOffset(ts, pos, avail, lx)) }
                count = min(count, length - pos)
                var ct = CTTypesetterCreateLineWithOffset(ts, CFRange(location: pos, length: count), lx)
                let lastOfPara = pos + count >= length
                let endsWithBreak = (attr.string as NSString).substring(with: NSRange(location: pos, length: count)).hasSuffix("\u{2028}")
                let full = CTLineGetTypographicBounds(ct, nil, nil, nil)
                let trailing = CTLineGetTrailingWhitespaceWidth(ct)
                var w = max(full - trailing, 0)
                if wrap, ((para.align == "just" && !lastOfPara && !endsWithBreak) || para.align == "dist"), w > avail * 0.6,
                   let j = CTLineCreateJustifiedLine(ct, 1.0, avail) {
                    ct = j; w = avail
                }
                block.maxLineWidth = max(block.maxLineWidth, lx + w)
                var line = Line(ct: ct, x: lx, width: w, pitch: 0, size: 0)
                line.pieces = pieces(ct, styles: styles)
                var size = line.pieces.filter { !$0.style.isBreak || line.pieces.count == 1 }.map(\.style.size).max() ?? para.endSize
                if size <= 0 { size = para.endSize }
                line.size = size
                line.pitch = SlideTextLayout.pitch(size: size, pct: para.lineSpacingPct, pts: para.lineSpacingPts)
                anyLine = true
                if first, let bullet { line.bullet = (bullet.0, bullet.1) }
                // Horizontal alignment within the text area.
                switch para.align {
                case "ctr": line.x = lx + (areaWidth == 1e7 ? (width - lx - w) / 2 : (areaWidth - lx - w) / 2)
                case "r": line.x = (areaWidth == 1e7 ? width : areaWidth) - w
                default: break
                }
                paraLines.append(line)
                pos += count
                first = false
            }
            for var l in paraLines {
                l.top = y
                l.baseline = y + l.pitch - SlideTextLayout.descentFraction * l.size
                y += l.pitch
                block.width = max(block.width, l.x + l.width)
                block.lines.append(l)
            }
            block.contentHeight = y
            let lastSize = paraLines.last?.size ?? firstSize
            y += para.spaceAfter.pts + para.spaceAfter.pct * 1.2 * lastSize
        }
        block.height = y
        return block
    }

    /// The paragraph's runs as one attributed string, each scalar in the font of its slot (Latin, East Asian, symbol).
    private func attributed(_ para: StyledParagraph) -> (NSAttributedString, [StyledRun], Bool) {
        let out = NSMutableAttributedString()
        var styles: [StyledRun] = []
        var substitute = false
        // Tab stops are measured from the left of the text area (the typesetter is given each line's offset).
        let tabs: [CTTextTab] = para.tabs.map { t in
            let a: CTTextAlignment = t.align == "r" ? .right : t.align == "ctr" ? .center : t.align == "dec" ? .right : .left
            return CTTextTabCreate(a, t.pos, nil)
        }
        var tabArray = tabs as CFArray
        var interval = CGFloat(para.defTab)
        let style: CTParagraphStyle = withUnsafeBytes(of: &tabArray) { tp in
            withUnsafeBytes(of: &interval) { ip in
                let settings = [
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: tp.baseAddress!),
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: ip.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        for r in para.runs where !r.text.isEmpty {
            let idx = styles.count
            styles.append(r)
            let shrink = r.baseline != 0 ? 2.0 / 3.0 : 1.0
            let size = r.size * shrink
            var segment = ""
            var segFace: SlideFonts.Face?
            let latinFace = fonts.face(r.latin, size: size, bold: r.bold, italic: r.italic, eastAsian: false)
            let eaFace = fonts.face(r.ea, size: size, bold: r.bold, italic: r.italic, eastAsian: true)
            func flush() {
                guard !segment.isEmpty, let f = segFace else { return }
                var attrs: [CFString: Any] = [
                    kCTFontAttributeName: f.font,
                    kCTParagraphStyleAttributeName: style,
                    kCTLigatureAttributeName: 0,
                    SlideTextLayout.runKey: idx,
                ]
                if r.baseline != 0 { attrs[SlideTextLayout.shiftKey] = r.baseline * r.size }
                attrs[kCTForegroundColorAttributeName] = (r.color ?? DColor(r: 0, g: 0, b: 0, a: 0)).cgColor
                if r.spacing != 0 { attrs[kCTKernAttributeName] = r.spacing }
                if let o = r.outline {
                    attrs[kCTStrokeColorAttributeName] = o.color.cgColor
                    let pct = o.width / max(r.size, 1) * 100
                    attrs[kCTStrokeWidthAttributeName] = r.color == nil ? pct : -pct
                } else if f.fakeBold, let c = r.color {
                    attrs[kCTStrokeColorAttributeName] = c.cgColor
                    attrs[kCTStrokeWidthAttributeName] = -3.0
                }
                out.append(NSAttributedString(string: segment, attributes: attrs as [NSAttributedString.Key: Any]))
                segment = ""
            }
            for sc in r.text.unicodeScalars {
                let ea = SlideTextLayout.usesEastAsianFont(sc, eaLang: r.eaLang)
                var f = ea ? eaFace : latinFace
                if !substitute, !sc.properties.isWhitespace, !fonts.isInstalled(ea ? r.ea : r.latin) { substitute = true }
                // Characters this font shares a glyph with another code point would come back wrong from the PDF's
                // text layer (Hiragino's em dash reads as U+0336); they are drawn from a font that keeps them apart.
                if SlideFonts.sharedGlyphScalars.contains(sc.value), SlideFonts.sharesGlyphs(f.font) {
                    f = fonts.textLayerSafeFace(for: f, scalar: sc, size: size, bold: r.bold)
                }
                if segFace.map({ !CFEqual($0.font, f.font) || $0.fakeBold != f.fakeBold }) ?? true { flush(); segFace = f }
                segment.unicodeScalars.append(sc)
            }
            flush()
        }
        // PDFKit drops the second of two identical narrow glyphs that touch ("..." reads as ".."), taking it for a
        // doubled bold stroke. A hair of extra space (5% of the size) keeps both in the text layer.
        let ns = out.string as NSString
        if ns.length > 1 {
            for i in 0..<(ns.length - 1) {
                let c = ns.character(at: i)
                guard c == ns.character(at: i + 1), SlideTextLayout.narrowRepeatable.contains(c) else { continue }
                let font = out.attribute(NSAttributedString.Key(kCTFontAttributeName as String), at: i, effectiveRange: nil) as! CTFont
                let kern = (out.attribute(NSAttributedString.Key(kCTKernAttributeName as String), at: i, effectiveRange: nil) as? Double) ?? 0
                out.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: kern + Double(CTFontGetSize(font)) * 0.05, range: NSRange(location: i, length: 1))
            }
        }
        return (out, styles, substitute)
    }

    static let narrowRepeatable: Set<unichar> = Set(".,:;'`!|・･‥…".utf16)

    /// Characters drawn with the East Asian font: CJK scripts and full-width forms always, shared punctuation and
    /// symbols when the run's language is Japanese, Chinese or Korean.
    static func usesEastAsianFont(_ s: Unicode.Scalar, eaLang: Bool) -> Bool {
        if DocxDisplayFonts.isEastAsian(s) { return true }
        if eaLang, DocxDisplayFonts.isAmbiguous(s) { return true }
        if eaLang, (0x2460...0x24FF).contains(s.value) || (0x25A0...0x25FF).contains(s.value) || (0x2600...0x26FF).contains(s.value) { return true }
        return false
    }

    private func bulletLine(_ para: StyledParagraph) -> CTLine? {
        guard let firstRun = para.runs.first(where: { !$0.text.isEmpty && !$0.isBreak }) else { return nil }
        var text: String
        var fontName: String
        switch para.bullet {
        case .none: return nil
        case .char(let c, let f):
            if let f, SlideFonts.isSymbolFont(f) {
                text = SlideFonts.unicodeBullet(c, font: f); fontName = firstRun.latin
            } else {
                text = c; fontName = (para.bulletFontFollowsText ? nil : f) ?? firstRun.latin
            }
        case .number(let type, _):
            text = SlideTextLayout.numberText(type, para.number); fontName = firstRun.latin
        }
        let size = para.bulletSizePts ?? firstRun.size * (para.bulletSizePct ?? 1)
        let ea = text.unicodeScalars.contains { DocxDisplayFonts.isEastAsian($0) }
        let face = fonts.face(ea ? firstRun.ea : fontName, size: size, bold: firstRun.bold, italic: false, eastAsian: ea)
        let color = para.bulletColor ?? firstRun.color ?? .black
        let attrs: [CFString: Any] = [kCTFontAttributeName: face.font, kCTForegroundColorAttributeName: color.cgColor]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs as [NSAttributedString.Key: Any]) as CFAttributedString)
    }

    static func numberText(_ type: String, _ n: Int) -> String {
        func roman(_ v: Int) -> String {
            let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
            var v = max(v, 1), s = ""
            for (k, r) in table { while v >= k { s += r; v -= k } }
            return s
        }
        func alpha(_ v: Int) -> String {
            var v = max(v, 1), s = ""
            while v > 0 { v -= 1; s = String(UnicodeScalar(UInt8(65 + v % 26))) + s; v /= 26 }
            return s
        }
        func wide(_ s: String) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value >= 0x21 && $0.value <= 0x7E ? UnicodeScalar($0.value + 0xFEE0)! : $0 }))
        }
        let base: String
        if type.hasPrefix("roman") { base = type.hasPrefix("romanLc") ? roman(n).lowercased() : roman(n) }
        else if type.hasPrefix("alpha") { base = type.hasPrefix("alphaLc") ? alpha(n).lowercased() : alpha(n) }
        else if type.hasPrefix("circleNum") {
            if type.contains("WdBlack") { return n >= 1 && n <= 10 ? String(UnicodeScalar(0x2776 + UInt32(n - 1))!) : "\(n)" }
            if n >= 1 && n <= 20 { return String(UnicodeScalar(0x2460 + UInt32(n - 1))!) }
            if n >= 21 && n <= 35 { return String(UnicodeScalar(0x3251 + UInt32(n - 21))!) }
            return "(\(n))"
        } else { base = String(n) }
        if type.hasSuffix("ParenBoth") { return "(\(base))" }
        if type.hasSuffix("ParenR") { return "\(base))" }
        if type.hasSuffix("Plain") { return type.contains("Db") ? wide(base) : base }
        if type.contains("DbPeriod") || type.contains("JpnChsDbPeriod") { return wide(base) + "．" }
        if type.hasSuffix("Comma") { return base + "、" }
        return base + "."
    }

    private func pieces(_ line: CTLine, styles: [StyledRun]) -> [RunPiece] {
        var out: [RunPiece] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let idx = attrs[SlideTextLayout.runKey] as? Int, idx < styles.count else { continue }
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var pos = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &pos)
            let w = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)
            let font = attrs[kCTFontAttributeName] as! CTFont
            out.append(RunPiece(index: idx, x: Double(pos.x), width: w, style: styles[idx], font: font))
        }
        return out
    }

    // MARK: Drawing

    /// Draws a block whose top-left is `origin` in a y-down context. `pdf`: add link annotations.
    func draw(_ block: Block, at origin: CGPoint, in ctx: CGContext, pdf: Bool) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for line in block.lines {
            let bx = Double(origin.x) + line.x, by = Double(origin.y) + line.baseline
            // Highlights go under the text.
            for p in line.pieces {
                if let h = p.style.highlight {
                    ctx.setFillColor(h.cgColor)
                    ctx.fill(CGRect(x: bx + p.x, y: Double(origin.y) + line.top, width: p.width, height: line.pitch))
                }
            }
            if let b = line.bullet {
                ctx.textPosition = CGPoint(x: Double(origin.x) + b.x, y: by)
                CTLineDraw(b.line, ctx)
            }
            for run in CTLineGetGlyphRuns(line.ct) as? [CTRun] ?? [] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let shift = attrs[SlideTextLayout.shiftKey] as? Double ?? 0
                ctx.textPosition = CGPoint(x: bx, y: by - shift)
                if let idx = attrs[SlideTextLayout.runKey] as? Int, let sh = line.pieces.first(where: { $0.index == idx })?.style.shadow {
                    // Shadow offsets are given in the base space (y up); map the slide's offset through the CTM.
                    ctx.saveGState()
                    let m = ctx.userSpaceToDeviceSpaceTransform
                    let off = CGSize(width: m.a * sh.dx + m.c * sh.dy, height: m.b * sh.dx + m.d * sh.dy)
                    ctx.setShadow(offset: off, blur: sh.blur * (abs(m.a) + abs(m.d)) / 2, color: sh.color.cgColor)
                    CTRunDraw(run, ctx, CFRange(location: 0, length: 0))
                    ctx.restoreGState()
                    continue
                }
                CTRunDraw(run, ctx, CFRange(location: 0, length: 0))
            }
            for p in line.pieces {
                let s = p.style
                let color = (s.color ?? s.outline?.color ?? .black).cgColor
                let thick = max(Double(CTFontGetUnderlineThickness(p.font)), s.size / 18)
                if let u = s.underline {
                    let uy = by - Double(CTFontGetUnderlinePosition(p.font)) + thick / 2 - s.baseline * s.size
                    ctx.setStrokeColor(color)
                    let heavy = u.lowercased().contains("heavy") || u == "thick"
                    ctx.setLineWidth(heavy ? thick * 2 : thick)
                    if u.lowercased().contains("dot") || u.lowercased().contains("dash") {
                        ctx.setLineDash(phase: 0, lengths: u.lowercased().contains("dot") ? [thick, thick * 2] : [thick * 4, thick * 2])
                    } else { ctx.setLineDash(phase: 0, lengths: []) }
                    ctx.strokeLineSegments(between: [CGPoint(x: bx + p.x, y: uy), CGPoint(x: bx + p.x + p.width, y: uy)])
                    if u == "dbl" {
                        ctx.strokeLineSegments(between: [CGPoint(x: bx + p.x, y: uy + thick * 2), CGPoint(x: bx + p.x + p.width, y: uy + thick * 2)])
                    }
                    ctx.setLineDash(phase: 0, lengths: [])
                }
                if let st = s.strike {
                    let sy = by - s.size * 0.3 - s.baseline * s.size
                    ctx.setStrokeColor(color)
                    ctx.setLineWidth(thick)
                    ctx.strokeLineSegments(between: [CGPoint(x: bx + p.x, y: sy), CGPoint(x: bx + p.x + p.width, y: sy)])
                    if st == "dblStrike" {
                        ctx.strokeLineSegments(between: [CGPoint(x: bx + p.x, y: sy - thick * 2), CGPoint(x: bx + p.x + p.width, y: sy - thick * 2)])
                    }
                }
                if pdf, let link = s.link, let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    let r = CGRect(x: bx + p.x, y: Double(origin.y) + line.top, width: p.width, height: line.pitch)
                    let page = r.applying(ctx.userSpaceToDeviceSpaceTransform)
                    if page.width > 0, page.height > 0 { ctx.setURL(url as CFURL, for: page) }
                }
            }
        }
        ctx.restoreGState()
    }
}
