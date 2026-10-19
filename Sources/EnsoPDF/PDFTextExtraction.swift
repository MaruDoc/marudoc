import Foundation
import CoreGraphics
import PDFKit
import AppKit
import EnsoDoc

/// Turns a PDFKit page into glyphs, segments (word groups) and visual lines.
///
/// Notes from measuring PDFKit on macOS 15-27:
/// - `PDFPage.characterBounds(at:)` drifts out of sync with `string` after PDFKit-inserted newlines, so it is not used.
/// - `selection(for: NSRange)` per character gives correct advance boxes (height = line box) and is cheap.
/// - `attributedString` has the same length as `string` and carries NSFont (real PostScript name, size, traits) and NSColor.
enum TextExtractor {

    // MARK: Glyphs

    static func glyphs(page: PDFPage, geo: PageGeometry, styles: StyleTable, textRuns: [TextRun] = []) -> [Glyph] {
        guard let raw = page.string, !raw.isEmpty else { return [] }
        let ns = raw as NSString
        let n = ns.length
        var runs: [(range: NSRange, style: Int)] = []
        if let attr = page.attributedString, attr.length == n {
            attr.enumerateAttributes(in: NSRange(location: 0, length: n), options: []) { attrs, range, _ in
                runs.append((range, styles.intern(style(from: attrs))))
            }
        }

        var out: [Glyph] = []
        out.reserveCapacity(n)
        var i = 0, runIdx = 0
        var pendingSpace = false
        while i < n {
            let c = ns.character(at: i)
            if CharClass.isWhitespaceUnit(c) { pendingSpace = true; i += 1; continue }
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            defer { i = max(i + 1, r.location + r.length) }
            if c == 0xFFFC || c == 0xFFFD || c < 0x20 { continue }
            guard let sel = page.selection(for: r) else { continue }
            let pb = sel.bounds(for: page)
            if pb.isNull || pb.isInfinite || (pb.width <= 0 && pb.height <= 0) { continue }
            let rect = geo.toDisplay(pb)
            while runIdx < runs.count && runs[runIdx].range.location + runs[runIdx].range.length <= i { runIdx += 1 }
            var st: Int
            if runIdx < runs.count, NSLocationInRange(i, runs[runIdx].range) {
                st = runs[runIdx].style
                let s = styles[st]
                // Fonts set at 1pt and scaled by the text matrix report 1pt; fall back to the box height.
                if s.size < 2.5 && rect.height > 4 || s.size > Double(rect.height) * 4 {
                    var fixed = s
                    fixed.size = (Double(rect.height) / 1.25 * 2).rounded() / 2
                    st = styles.intern(fixed)
                }
            } else {
                st = styles.intern(GlyphStyle(fontName: nil, size: (Double(rect.height) / 1.25 * 2).rounded() / 2, bold: false, italic: false, monospaced: false, color: nil))
            }
            out.append(Glyph(text: ns.substring(with: r), rect: rect, style: st, link: nil, spaceBefore: pendingSpace))
            pendingSpace = false
        }
        splitLigatures(&out, styles: styles)
        applyLinks(&out, page: page, geo: geo)
        if !textRuns.isEmpty { applyRuns(&out, runs: textRuns, styles: styles) }
        removeOverprint(&out, styles: styles)
        return out
    }

    /// PDFKit reports every character of a ligature ("ffi") with the ligature's box. Spread such runs
    /// over the shared box so they keep their order and are not mistaken for overprinted duplicates.
    static func splitLigatures(_ glyphs: inout [Glyph], styles: StyleTable) {
        var i = 0
        while i < glyphs.count {
            var j = i + 1
            while j < glyphs.count, abs(glyphs[j].rect.minX - glyphs[i].rect.minX) < 0.05, abs(glyphs[j].rect.minY - glyphs[i].rect.minY) < 0.5,
                  !glyphs[j].spaceBefore, CharClass.isLatinLetter(glyphs[j].text) { j += 1 }
            if j - i >= 2 && CharClass.isLatinLetter(glyphs[i].text) {
                let minX = glyphs[i].rect.minX
                let maxX = glyphs[i..<j].map(\.rect.maxX).max() ?? glyphs[i].rect.maxX
                let em = CGFloat(max(1, styles[glyphs[i].style].size))
                let distinct = Set(glyphs[i..<j].map(\.text)).count > 1
                if distinct || maxX - minX >= em * 0.45 * CGFloat(j - i) {
                    let w = (maxX - minX) / CGFloat(j - i)
                    for k in i..<j {
                        glyphs[k].rect = CGRect(x: minX + w * CGFloat(k - i), y: glyphs[k].rect.minY, width: w, height: glyphs[k].rect.height)
                    }
                }
            }
            i = max(j, i + 1)
        }
    }

    private static let genericFontName = try? NSRegularExpression(pattern: #"^(F|TT|T|C|R|Font|CIDFont\+F)\d+$"#)

    /// Takes font names, weights and the fill+stroke "fake bold" render mode from the content stream,
    /// which survive even when PDFKit only reports a fallback font.
    static func applyRuns(_ glyphs: inout [Glyph], runs: [TextRun], styles: StyleTable) {
        let hr = runs.filter { $0.horizontal && $0.font != nil && $0.maxX - $0.minX > 0.3 }
        guard !hr.isEmpty else { return }
        var buckets: [Int: [Int]] = [:]
        for (k, r) in hr.enumerated() { buckets[SafeInt.floor(Double(r.start.y / 8)), default: []].append(k) }
        var cache: [Int: Int] = [:]   // (style, run) -> style
        for gi in glyphs.indices {
            let g = glyphs[gi]
            let c = g.rect.center
            var best: Int?
            var bestD = CGFloat.greatestFiniteMagnitude
            let lo = SafeInt.floor(Double((g.rect.minY - 2) / 8), -100_000_000, 100_000_000), hi = SafeInt.floor(Double((g.rect.maxY + 2) / 8), -100_000_000, 100_000_000)
            for b in lo...max(lo, hi) {
                for k in buckets[b] ?? [] {
                    let r = hr[k]
                    guard r.start.y >= g.rect.minY - 1, r.start.y <= g.rect.maxY + 1, c.x >= r.minX - 0.5, c.x <= r.maxX + 0.5 else { continue }
                    let d = abs(r.start.y - (g.rect.minY + g.rect.height * 0.75))
                    if d < bestD { bestD = d; best = k }
                }
            }
            guard let k = best, let font = hr[k].font else { continue }
            let key = g.style &* 1_000_003 &+ k
            if let st = cache[key] { glyphs[gi].style = st; continue }
            var st = styles[g.style]
            let n = font.name
            let generic = n.isEmpty || genericFontName?.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) != nil
            if !generic { st.fontName = n; st.monospaced = nameLooksMono(n) }
            st.bold = st.bold || font.bold || hr[k].renderMode == 2
            st.italic = st.italic || font.italic || hr[k].slanted
            let idx = styles.intern(st)
            cache[key] = idx
            glyphs[gi].style = idx
        }
    }

    static func style(from attrs: [NSAttributedString.Key: Any]) -> GlyphStyle {
        var name: String?
        var size = 10.0
        var bold = false, italic = false, mono = false
        if let f = attrs[.font] as? NSFont {
            let clean = cleanFontName(f.fontName)
            name = clean
            size = Double(f.pointSize)
            let traits = f.fontDescriptor.symbolicTraits
            bold = traits.contains(.bold) || nameLooksBold(clean)
            italic = traits.contains(.italic) || nameLooksItalic(clean)
            mono = nameLooksMono(clean)
        }
        var color: DocColor?
        if let c = attrs[.foregroundColor] as? NSColor, let rgb = c.usingColorSpace(.sRGB) {
            let col = DocColor(r: Double(rgb.redComponent), g: Double(rgb.greenComponent), b: Double(rgb.blueComponent))
            // Black is the default; near-white text only shows on a fill we do not reproduce, so drop it too.
            let lum = 0.299 * col.r + 0.587 * col.g + 0.114 * col.b
            if !col.isNearlyBlack && lum < 0.82 { color = col }
        }
        return GlyphStyle(fontName: name, size: (size * 2).rounded() / 2, bold: bold, italic: italic, monospaced: mono, color: color)
    }

    static func cleanFontName(_ n: String) -> String {
        var s = n
        if let plus = s.firstIndex(of: "+"), s.distance(from: s.startIndex, to: plus) == 6 { s = String(s[s.index(after: plus)...]) }
        // CMap suffixes glued onto CID font names ("MS-Gothic-90ms-RKSJ-H", "Foo-Identity-H").
        for suffix in ["-90ms-RKSJ-H", "-90ms-RKSJ-V", "-90msp-RKSJ-H", "-RKSJ-H", "-RKSJ-V", "-Identity-H", "-Identity-V",
                       "-UniJIS-UCS2-H", "-UniJIS-UTF16-H", "-EUC-H", "-EUC-V", "-H", "-V"] where s.hasSuffix(suffix) && s.count > suffix.count + 2 {
            s = String(s.dropLast(suffix.count))
            break
        }
        return s
    }

    static func nameLooksBold(_ name: String) -> Bool {
        let l = name.lowercased()
        if l.hasSuffix("-b") || l.hasSuffix("-bd") || l.hasSuffix("-bold") || l.hasSuffix(",bold") || l.hasSuffix("-db") || l.hasSuffix("-eb") { return true }
        for t in ["bold", "heavy", "black", "semibold", "demibold", "w6", "w7", "w8", "w9", "extrab", "ultrab"] where l.contains(t) { return true }
        return false
    }

    static func nameLooksItalic(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.contains("italic") || l.contains("oblique") || l.hasSuffix("-it") || l.hasSuffix("-bi") || l.hasSuffix(",italic")
    }

    static func nameLooksMono(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.contains("courier") || l.contains("mono") || l.contains("menlo") || l.contains("consolas") || l.contains("monaco") || l.contains("sfmono") || l.contains("code")
    }

    private static func applyLinks(_ glyphs: inout [Glyph], page: PDFPage, geo: PageGeometry) {
        var links: [(CGRect, String)] = []
        for ann in page.annotations {
            let t = (ann.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard t == "Link" else { continue }
            guard let url = ann.url ?? (ann.action as? PDFActionURL)?.url,
                  let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "ftp"].contains(scheme) else { continue }
            links.append((geo.toDisplay(ann.bounds).insetBy(dx: -1, dy: -1), url.absoluteString))
        }
        guard !links.isEmpty else { return }
        for i in glyphs.indices {
            let c = glyphs[i].rect.center
            if let l = links.first(where: { $0.0.contains(c) }) { glyphs[i].link = l.1 }
        }
    }

    /// Drops glyphs drawn twice at (nearly) the same place. Offset duplicates are a common fake-bold
    /// technique, so the surviving glyph becomes bold in that case.
    static func removeOverprint(_ glyphs: inout [Glyph], styles: StyleTable) {
        guard glyphs.count > 1 else { return }
        var grid: [Int64: [Int]] = [:]
        var drop = [Bool](repeating: false, count: glyphs.count)
        func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
        for i in glyphs.indices {
            let g = glyphs[i]
            let em = max(2.0, CGFloat(styles[g.style].size))
            let cx = SafeInt.floor(Double(g.rect.midX / 4), -1_000_000_000, 1_000_000_000), cy = SafeInt.floor(Double(g.rect.midY / 4), -1_000_000_000, 1_000_000_000)
            var dup: Int?
            search: for dx in -1...1 {
                for dy in -1...1 {
                    for j in grid[key(cx + dx, cy + dy)] ?? [] where glyphs[j].text == g.text {
                        let tolX = min(0.3 * em, 0.3 * max(0.5, min(glyphs[j].rect.width, g.rect.width)))
                        if abs(glyphs[j].rect.midX - g.rect.midX) < tolX && abs(glyphs[j].rect.midY - g.rect.midY) < 0.15 * em {
                            dup = j; break search
                        }
                    }
                }
            }
            if let j = dup {
                drop[i] = true
                if abs(glyphs[j].rect.midX - g.rect.midX) > 0.05 || abs(glyphs[j].rect.midY - g.rect.midY) > 0.05 {
                    glyphs[j].style = styles.boldVariant(of: glyphs[j].style)
                }
            } else {
                grid[key(cx, cy), default: []].append(i)
            }
        }
        if drop.contains(true) {
            glyphs = glyphs.enumerated().filter { !drop[$0.offset] }.map(\.element)
        }
    }

    // MARK: Segments

    /// Groups glyphs (in content order) into word groups: runs on one baseline without large gaps.
    static func segments(_ glyphs: [Glyph], styles: StyleTable, splitGap: CGFloat = 1.2) -> [Segment] {
        var segs: [Segment] = []
        segs.reserveCapacity(glyphs.count / 4 + 1)
        for g in glyphs {
            if let last = segs.last, let p = last.glyphs.last, continues(p, g, styles: styles, splitGap: splitGap) {
                segs[segs.count - 1].append(g)
            } else {
                segs.append(Segment(g))
            }
        }
        return segs
    }

    static func continues(_ p: Glyph, _ g: Glyph, styles: StyleTable, splitGap: CGFloat) -> Bool {
        let em = CGFloat(max(styles[p.style].size, styles[g.style].size, 1))
        let ov = p.rect.verticalOverlap(g.rect)
        guard ov >= 0.5 * min(p.rect.height, g.rect.height) else { return false }
        let gap = g.rect.minX - p.rect.maxX
        return gap > -0.4 * em && gap < splitGap * em
    }

    /// Removes furigana: tiny kana-only segments sitting directly above larger text.
    static func removeRuby(_ segs: inout [Segment], styles: StyleTable) {
        func size(_ s: Segment) -> Double { s.glyphs.map { styles[$0.style].size }.max() ?? 10 }
        let sizes = segs.map(size)
        var drop = Set<Int>()
        for i in segs.indices where segs[i].glyphs.count <= 16 && CharClass.isKana(segs[i].text) {
            let s = segs[i], sz = sizes[i]
            for j in segs.indices where j != i && sizes[j] >= sz * 1.5 {
                let t = segs[j]
                guard t.rect.midY > s.rect.maxY - 0.5 else { continue }
                let vgap = t.rect.minY - s.rect.maxY
                guard vgap < CGFloat(sizes[j]) * 0.6 else { continue }
                guard s.rect.midX >= t.rect.minX - CGFloat(sz) && s.rect.midX <= t.rect.maxX + CGFloat(sz) else { continue }
                drop.insert(i)
                break
            }
        }
        if !drop.isEmpty { segs = segs.enumerated().filter { !drop.contains($0.offset) }.map(\.element) }
    }

    // MARK: Lines

    /// Clusters segments into visual lines (same baseline band, no horizontal collision).
    static func lines(_ segsIn: [Segment], page: Int, styles: StyleTable) -> [TextLine] {
        guard !segsIn.isEmpty else { return [] }
        let segs = segsIn.sorted { $0.rect.midY < $1.rect.midY }
        var groups: [[Segment]] = []
        var bands: [CGRect] = []   // anchor rect of each group (first segment)
        for s in segs {
            var best = -1
            var bestOv: CGFloat = 0
            var k = groups.count - 1
            var looked = 0
            while k >= 0 && looked < 12 {
                let b = bands[k]
                let ov = b.verticalOverlap(s.rect)
                if ov >= 0.5 * min(b.height, s.rect.height) && ov > bestOv {
                    let collides = groups[k].contains { $0.rect.horizontalOverlap(s.rect) > 0.3 * min($0.rect.width, s.rect.width) && $0.rect.horizontalOverlap(s.rect) > 1 }
                    if !collides { best = k; bestOv = ov }
                }
                k -= 1; looked += 1
            }
            if best >= 0 { groups[best].append(s) } else { groups.append([s]); bands.append(s.rect) }
        }
        var out: [TextLine] = []
        out.reserveCapacity(groups.count)
        for var g in groups {
            g.sort { $0.rect.minX < $1.rect.minX }
            var merged: [Segment] = []
            for s in g {
                if let last = merged.last, let p = last.glyphs.last, let f = s.glyphs.first {
                    let em = CGFloat(max(styles[p.style].size, styles[f.style].size, 1))
                    let gap = s.rect.minX - last.rect.maxX
                    let bare = merged.count == 1 && ListMarkers.isBareMarker(last.text) && gap < 6 * em
                    if gap < 1.2 * em || bare {
                        var m = last
                        var first = true
                        for var x in s.glyphs {
                            if first { x.spaceBefore = x.spaceBefore || gap > 0.2 * em; first = false }
                            m.append(x)
                        }
                        merged[merged.count - 1] = m
                        continue
                    }
                }
                merged.append(s)
            }
            out.append(TextLine(segments: merged, page: page, styles: styles))
        }
        out.sort { $0.rect.minY < $1.rect.minY || ($0.rect.minY == $1.rect.minY && $0.rect.minX < $1.rect.minX) }
        return out
    }

    /// Full glyph -> line pipeline for a set of glyphs.
    static func buildLines(_ glyphs: [Glyph], page: Int, styles: StyleTable) -> [TextLine] {
        var segs = segments(glyphs, styles: styles)
        removeRuby(&segs, styles: styles)
        return lines(segs, page: page, styles: styles)
    }
}
