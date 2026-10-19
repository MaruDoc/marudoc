import Foundation
import CoreGraphics
import EnsoDoc

/// Document-wide typography statistics.
struct DocStats {
    var bodySize: Double
    var bodyFont: String?
    var bodyMono: Bool
    /// Normal baseline-to-baseline distance per (rounded) font size.
    var pitch: [Double: CGFloat]
    var pitchRatio: Double
    /// Slide decks never continue a paragraph onto the next page.
    var slides = false

    func normalPitch(_ size: Double) -> CGFloat {
        let key = (size * 2).rounded() / 2
        if let p = pitch[key] { return p }
        return CGFloat(size * pitchRatio)
    }

    static func compute(flows: [[FlowItem]], styles: StyleTable) -> DocStats {
        var sizeWeight: [Double: Int] = [:]
        var fontWeight: [String: Int] = [:]
        var monoChars = 0, total = 0
        var allLines: [TextLine] = []
        for flow in flows {
            for item in flow {
                guard case .line(let l) = item else { continue }
                allLines.append(l)
                sizeWeight[l.size, default: 0] += l.charCount
                total += l.charCount
                if l.monoRatio > 0.8 { monoChars += l.charCount }
            }
        }
        let body = sizeWeight.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 10.5
        for l in allLines where abs(l.size - body) < 0.6 { if let f = l.fontName { fontWeight[f, default: 0] += l.charCount } }
        let bodyFont = fontWeight.max { $0.value < $1.value }?.key

        var samples: [Double: [Double]] = [:]
        var ratios: [Double] = []
        for flow in flows {
            var prev: TextLine?
            for item in flow {
                switch item {
                case .line(let l):
                    if let p = prev, p.page == l.page, abs(p.colLeft - l.colLeft) < 2, l.midY > p.midY, abs(p.size - l.size) < 0.6,
                       p.right >= p.colRight - CGFloat(p.size) * 2.5 {
                        let dy = Double(l.midY - p.midY)
                        if dy >= p.size * 0.9 && dy <= p.size * 3.2 {
                            samples[p.size, default: []].append(dy)
                            ratios.append(dy / p.size)
                        }
                    }
                    prev = l
                default:
                    prev = nil
                }
            }
        }
        var pitch: [Double: CGFloat] = [:]
        for (s, v) in samples where v.count >= 3 {
            // Lower half of the distribution: intra-paragraph spacing, not paragraph gaps.
            pitch[s] = CGFloat(Stats.percentile(v, 0.35) ?? s * 1.5)
        }
        let ratio = Stats.percentile(ratios, 0.35) ?? 1.5
        return DocStats(bodySize: body, bodyFont: bodyFont, bodyMono: total > 0 && Double(monoChars) / Double(total) > 0.6,
                        pitch: pitch, pitchRatio: min(max(ratio, 1.1), 2.8))
    }
}

/// Builds DocBlocks from page flows: paragraphs, headings, lists, code, tables and images.
final class BlockBuilder {
    private let styles: StyleTable
    private let stats: DocStats

    init(styles: StyleTable, stats: DocStats) {
        self.styles = styles
        self.stats = stats
    }

    // MARK: Paragraph candidates

    private struct Para {
        var lines: [TextLine]
        var marker: ListMarker?
        var markerX: CGFloat = 0
        var textX: CGFloat = 0
        var code = false
        var centered = false
    }

    private enum Piece {
        case para(Para)
        case table(TableGrid)
        case image(ImageAtom)
        case pageBreak
    }

    func build(flows: [[FlowItem]], pageBreaks: Bool) -> (blocks: [DocBlock], firstHeading: String?) {
        var pieces: [Piece] = []
        var current: Para?
        var crossPage = false

        func flush() {
            if let p = current { pieces.append(.para(p)) }
            current = nil
        }

        for (fi, flow) in flows.enumerated() {
            if fi > 0 {
                if pageBreaks { flush(); pieces.append(.pageBreak) } else if stats.slides { flush() } else { crossPage = true }
            }
            for item in flow {
                switch item {
                case .line(let l):
                    if var p = current, canContinue(p, l, crossPage: crossPage) {
                        p.lines.append(l)
                        current = p
                    } else {
                        flush()
                        current = startPara(l)
                    }
                    crossPage = false
                case .table(let t):
                    flush(); pieces.append(.table(t)); crossPage = false
                case .image(let a):
                    flush(); pieces.append(.image(a)); crossPage = false
                case .pageStart:
                    break
                }
            }
        }
        flush()
        return emit(pieces)
    }

    private func lineText(_ l: TextLine) -> String {
        var s = ""
        forEachGlyph(in: l) { g, sep in s += sep; s += g.text }
        return s
    }

    private func startPara(_ l: TextLine) -> Para {
        var p = Para(lines: [l])
        p.code = isCode(l)
        p.centered = isCentered(l)
        if !p.code, let m = ListMarkers.detect(lineText(l)) {
            p.marker = m
            p.markerX = l.left
            let skip = markerGlyphCount(lineText(l), m)
            let gs = l.glyphs
            p.textX = skip < gs.count ? gs[skip].rect.minX : l.left
        }
        return p
    }

    private func markerGlyphCount(_ text: String, _ m: ListMarker) -> Int {
        text.prefix(m.length).filter { !$0.isWhitespace }.count
    }

    private func isCode(_ l: TextLine) -> Bool { l.monoRatio > 0.8 && !stats.bodyMono && l.charCount > 0 }

    private func isCentered(_ l: TextLine) -> Bool {
        let em = CGFloat(l.size)
        let colW = l.colRight - l.colLeft
        guard colW > em * 6, l.left > l.colLeft + em * 2, l.right < l.colRight - em * 2, l.rect.width < colW * 0.75 else { return false }
        return abs(l.rect.midX - (l.colLeft + l.colRight) / 2) < max(em, colW * 0.025)
    }

    private func isRightAligned(_ l: TextLine) -> Bool {
        let colW = l.colRight - l.colLeft
        return l.left > l.colLeft + colW * 0.3 && abs(l.right - l.colRight) < CGFloat(l.size) * 1.5 && !isCentered(l)
    }

    private func lastChars(_ l: TextLine) -> (String, String?) {
        let gs = l.glyphs
        guard let last = gs.last else { return ("", nil) }
        return (last.text, gs.count > 1 ? gs[gs.count - 2].text : nil)
    }

    private func firstTokenWidth(_ l: TextLine) -> CGFloat {
        let gs = l.glyphs
        guard let f = gs.first else { return 0 }
        if CharClass.isCJK(f.text) { return f.rect.width }
        var w = f.rect.width
        var prev = f
        for g in gs.dropFirst() {
            if g.spaceBefore || CharClass.isCJK(g.text) || g.rect.minX - prev.rect.maxX > CGFloat(styles[g.style].size) * 0.25 { break }
            w = g.rect.maxX - f.rect.minX
            prev = g
        }
        return w
    }

    /// The line ran up to the right edge of its column (so the paragraph wraps into the next line).
    private func isFull(_ a: TextLine, next b: TextLine) -> Bool {
        let em = CGFloat(a.size)
        let slack = min(a.colRight, a.localRight) - a.right
        if slack <= em * 0.6 { return true }
        let (last, _) = lastChars(a)
        if ["。", "．", ".", "!", "！", "?", "？", ":", "："].contains(last) && slack > em * 1.2 { return false }
        return slack < firstTokenWidth(b) + em * 0.8
    }

    private func hangingAligned(_ a: TextLine, _ x: CGFloat) -> Bool {
        let em = CGFloat(a.size)
        for g in a.glyphs.dropFirst() where g.rect.minX - a.left <= em * 8 {
            if abs(g.rect.minX - x) < em * 0.35 { return true }
        }
        return false
    }

    private static let leaderChars: Set<Character> = [".", "．", "…", "‥", "・", "･", "·", "_"]
    private static let pageChars: Set<Character> = Set("0123456789０１２３４５６７８９ivxIVX")

    /// Linear-time equivalent of `[leaders]{4,}\s*[0-9ivx]{0,6}\s*$` (a backtracking regex goes quadratic on long runs).
    static func endsWithLeader(_ t: String) -> Bool {
        let c = Array(t)
        var i = c.count
        while i > 0, c[i - 1].isWhitespace { i -= 1 }
        var pages = 0
        while i > 0, pageChars.contains(c[i - 1]) { i -= 1; pages += 1 }
        if pages > 6 { return false }
        while i > 0, c[i - 1].isWhitespace { i -= 1 }
        var leaders = 0
        while i > 0, leaderChars.contains(c[i - 1]) { i -= 1; leaders += 1 }
        return leaders >= 4
    }

    /// Replaces each run of 4+ leader characters (with the spaces around it) by a tab, in one pass.
    static func replacingLeaderRuns(_ t: String) -> String {
        let c = Array(t)
        var out: [Character] = []
        out.reserveCapacity(c.count)
        var i = 0
        while i < c.count {
            guard leaderChars.contains(c[i]) else { out.append(c[i]); i += 1; continue }
            var j = i
            while j < c.count, leaderChars.contains(c[j]) { j += 1 }
            if j - i >= 4 {
                while let l = out.last, l.isWhitespace { out.removeLast() }
                out.append("\t")
                while j < c.count, c[j].isWhitespace { j += 1 }
            } else {
                out.append(contentsOf: c[i..<j])
            }
            i = j
        }
        return String(out)
    }

    /// Table-of-contents entry: dot leaders running to a page number.
    private func isLeaderLine(_ l: TextLine) -> Bool {
        let t = lineText(l)
        return BlockBuilder.endsWithLeader(t)
    }

    private func canContinue(_ p: Para, _ b: TextLine, crossPage: Bool) -> Bool {
        guard let a = p.lines.last else { return false }
        if isLeaderLine(a) { return false }
        let em = CGFloat(max(a.size, b.size))
        if p.code != isCode(b) { return false }
        if p.code {
            return crossPage || (b.midY > a.midY && b.midY - a.midY <= stats.normalPitch(a.size) * 1.6 + 1)
        }
        if ListMarkers.detect(lineText(b)) != nil { return false }
        if abs(a.size - b.size) > max(0.6, 0.1 * min(a.size, b.size)) { return false }
        if a.boldRatio >= 0.8 && b.boldRatio <= 0.2 { return false }
        if b.boldRatio >= 0.9 && a.boldRatio < 0.3 && !isFull(b, next: b) { return false }

        let sameColumn = abs(a.colLeft - b.colLeft) < 2 && b.midY > a.midY
        if crossPage || !sameColumn {
            guard !p.centered, isFull(a, next: b) else { return false }
            return b.left <= b.colLeft + em * 0.5 && a.page <= b.page
        }
        let dy = b.midY - a.midY
        if dy < em * 0.5 || dy > stats.normalPitch(a.size) * 1.35 + 1 { return false }
        if p.centered { return isCentered(b) }
        if isCentered(b) && !isFull(a, next: b) { return false }
        if isRightAligned(a) && p.lines.count == 1 { return false }
        guard isFull(a, next: b) else { return false }

        if p.marker != nil {
            return abs(b.left - p.textX) <= em * 0.8 || abs(b.left - p.markerX) <= em * 0.5
        }
        if p.lines.count == 1 {
            if b.left > a.left + em * 0.5 { return hangingAligned(a, b.left) }
            return true
        }
        return abs(b.left - a.left) <= em * 0.5
    }

    // MARK: Emission

    private func paraSize(_ p: Para) -> Double {
        var w: [Double: Int] = [:]
        for l in p.lines { w[l.size, default: 0] += l.charCount }
        return w.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key ?? stats.bodySize
    }

    private func paraBold(_ p: Para) -> Double {
        let n = p.lines.reduce(0) { $0 + $1.charCount }
        return n > 0 ? p.lines.reduce(0) { $0 + $1.boldRatio * Double($1.charCount) } / Double(n) : 0
    }

    private enum HeadingKind { case size(Double), emphasis(Double, Bool) }

    private func headingKind(_ p: Para, text: String) -> HeadingKind? {
        guard !p.code else { return nil }
        let chars = text.filter { !$0.isWhitespace }
        guard !chars.isEmpty, chars.count <= 150, p.lines.count <= 3 else { return nil }
        guard chars.contains(where: { $0.isLetter }) else { return nil }
        if let m = p.marker, !m.ordered { return nil }
        let size = paraSize(p)
        let last = chars.last.map { String($0) } ?? ""
        let endsSentence = ["。", "．", "."].contains(last) && chars.count > 25
        if size >= stats.bodySize * 1.2 && chars.count <= 110 && !endsSentence { return .size(size) }
        guard let a = p.lines.first, size >= stats.bodySize - 0.6 else { return nil }
        let short = p.lines.count == 1 && !(a.right >= a.colRight - CGFloat(a.size) * 1.5 && chars.count > 30)
        if paraBold(p) >= 0.85 && short && !endsSentence && chars.count <= 60 { return .emphasis(size, true) }
        // "（1）見出し" set in a gothic face inside a mincho document.
        if p.marker?.ordered == true && short && !endsSentence && chars.count <= 40, let f = a.fontName, isGothic(f), let bf = stats.bodyFont, isMincho(bf) {
            return .emphasis(size, false)
        }
        return nil
    }

    private func isGothic(_ n: String) -> Bool {
        let l = n.lowercased()
        return l.contains("gothic") || l.contains("kaku") || l.contains("goth") || l.contains("sans") || l.contains("meiryo") || l.contains("hiraginosans") || l.contains("yugo")
    }

    private func isMincho(_ n: String) -> Bool {
        let l = n.lowercased()
        return l.contains("mincho") || l.contains("min") || l.contains("ming") || l.contains("serif") || l.contains("times")
    }

    private func emit(_ pieces: [Piece]) -> (blocks: [DocBlock], firstHeading: String?) {
        // Heading levels by size rank.
        var headingSizes: Set<Double> = []
        var kinds: [Int: HeadingKind] = [:]
        var texts: [Int: String] = [:]
        for (i, piece) in pieces.enumerated() {
            guard case .para(let p) = piece else { continue }
            let t = p.lines.map(lineText).joined(separator: " ")
            texts[i] = t
            if let k = headingKind(p, text: t) {
                kinds[i] = k
                if case .size(let s) = k { headingSizes.insert(s) }
            }
        }
        var levels: [Double: Int] = [:]
        var rank = 0
        var lastSize: Double?
        for s in headingSizes.sorted(by: >) {
            if let ls = lastSize, s >= ls * 0.92 { levels[s] = min(rank, 3) } else { rank += 1; levels[s] = min(rank, 3) }
            lastSize = s
        }
        // Body-size headings: bigger first, bold before merely gothic.
        var emphasisKeys: Set<String> = []
        for k in kinds.values { if case .emphasis(let s, let b) = k { emphasisKeys.insert("\(s)|\(b)") } }
        let emphasisOrder = emphasisKeys.sorted { a, b in
            let pa = a.split(separator: "|"), pb = b.split(separator: "|")
            let sa = Double(pa[0]) ?? 0, sb = Double(pb[0]) ?? 0
            if sa != sb { return sa > sb }
            return pa[1] == "true" && pb[1] != "true"
        }

        var blocks: [DocBlock] = []
        var firstHeading: String?
        var listStack: [CGFloat] = []
        var i = 0
        while i < pieces.count {
            let piece = pieces[i]
            switch piece {
            case .pageBreak:
                blocks.append(.pageBreak); listStack = []
            case .image(let a):
                blocks.append(.image(a.image)); listStack = []
            case .table(let t):
                blocks.append(.table(docTable(t))); listStack = []
            case .para(let p):
                if p.code {
                    blocks.append(.code(codeText(p), language: nil)); listStack = []
                    break
                }
                if let k = kinds[i] {
                    let level: Int
                    switch k {
                    case .size(let s): level = levels[s] ?? 1
                    case .emphasis(let s, let b): level = min(rank + 1 + (emphasisOrder.firstIndex(of: "\(s)|\(b)") ?? 0), 3)
                    }
                    var para = paragraph(p, skipGlyphs: 0)
                    para.alignment = p.centered ? .center : .left
                    para.indent = 0
                    if !para.isEmpty {
                        blocks.append(.heading(level: level, para))
                        if firstHeading == nil { firstHeading = para.plainText }
                    }
                    listStack = []
                } else if let m = p.marker {
                    let em = CGFloat(p.lines.first?.size ?? stats.bodySize)
                    while let top = listStack.last, p.markerX < top - em * 0.6 { listStack.removeLast() }
                    if let top = listStack.last {
                        if p.markerX > top + em * 0.6 { listStack.append(p.markerX) } else { listStack[listStack.count - 1] = p.markerX }
                    } else { listStack = [p.markerX] }
                    let skip = markerGlyphCount(lineText(p.lines[0]), m)
                    var para = paragraph(p, skipGlyphs: skip)
                    para.indent = 0
                    para.alignment = .left
                    if !para.isEmpty {
                        blocks.append(.listItem(DocListItem(ordered: m.ordered, level: min(listStack.count - 1, 8), number: m.number, paragraph: para)))
                    }
                } else {
                    let para = paragraph(p, skipGlyphs: 0)
                    if !para.isEmpty { blocks.append(.paragraph(para)) }
                    listStack = []
                }
            }
            i += 1
        }
        return (blocks, firstHeading)
    }

    private func codeText(_ p: Para) -> String {
        let minLeft = p.lines.map(\.left).min() ?? 0
        let charW: CGFloat = p.lines.compactMap { l -> CGFloat? in
            let gs = l.glyphs
            guard gs.count > 1, let f = gs.first, let la = gs.last else { return nil }
            return (la.rect.maxX - f.rect.minX) / CGFloat(gs.count)
        }.min() ?? CGFloat(stats.bodySize * 0.6)
        return p.lines.map { l in
            let indent = charW > 0 ? SafeInt.round(Double((l.left - minLeft) / charW), 0, 40) : 0
            return String(repeating: " ", count: max(0, min(indent, 40))) + lineText(l)
        }.joined(separator: "\n")
    }

    // MARK: Runs

    /// Calls body for each glyph of a line with the separator that should precede it.
    private func forEachGlyph(in l: TextLine, _ body: (Glyph, String) -> Void) {
        for (si, seg) in l.segments.enumerated() {
            var prev: Glyph?
            for g in seg.glyphs {
                var sep = ""
                if let p = prev {
                    sep = spacing(p, g)
                } else if si > 0 {
                    sep = " "
                }
                body(g, sep)
                prev = g
            }
        }
    }

    private func spacing(_ p: Glyph, _ g: Glyph) -> String {
        let em = CGFloat(max(styles[p.style].size, styles[g.style].size, 1))
        let gap = g.rect.minX - p.rect.maxX
        let cp = CharClass.isCJK(p.text), cg = CharClass.isCJK(g.text)
        if cp && cg { return gap >= em * 0.6 || (g.spaceBefore && gap >= em * 0.2) ? " " : "" }
        if cp || cg { return (g.spaceBefore && gap >= em * 0.12) || gap >= em * 0.5 ? " " : "" }
        return (g.spaceBefore && gap > -em * 0.1) || gap >= em * 0.3 ? " " : ""
    }

    private func runStyle(_ g: Glyph) -> DocRun {
        let st = styles[g.style]
        return DocRun("", bold: st.bold, italic: st.italic, code: st.monospaced && !stats.bodyMono,
                      fontSize: abs(st.size - stats.bodySize) < 0.6 ? nil : st.size,
                      fontName: st.fontName == stats.bodyFont ? nil : st.fontName,
                      color: st.color, link: g.link)
    }

    /// Spaces between words take the previous style, but never extend a link or emphasis the next word does not share.
    private func separatorStyle(_ prev: DocRun, next g: Glyph) -> DocRun {
        let n = runStyle(g)
        var s = prev
        if s.link != n.link { s.link = nil }
        if s.bold != n.bold { s.bold = false }
        if s.italic != n.italic { s.italic = false }
        if s.underline != n.underline { s.underline = false }
        return s
    }

    func runs(for lines: [TextLine], skipGlyphs: Int) -> [DocRun] {
        var runs: [DocRun] = []
        var skipped = 0
        var prevLine: TextLine?
        func append(_ text: String, style: DocRun) {
            if var last = runs.last, last.sameStyle(as: style) {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                var r = style
                r.text = text
                runs.append(r)
            }
        }
        for l in lines {
            var firstInLine = true
            forEachGlyph(in: l) { g, sep in
                if skipped < skipGlyphs { skipped += 1; return }
                if firstInLine {
                    firstInLine = false
                    if let pl = prevLine, !runs.isEmpty {
                        let (last, before) = lastChars(pl)
                        let (joiner, dropHyphen) = TextJoin.lineJoin(prevLast: last, prevBeforeLast: before, nextFirst: g.text)
                        if dropHyphen, var r = runs.last, r.text.hasSuffix(last) {
                            r.text.removeLast(); runs[runs.count - 1] = r
                            if r.text.isEmpty { runs.removeLast() }
                        }
                        if !joiner.isEmpty, let lr = runs.last { append(joiner, style: separatorStyle(lr, next: g)) }
                    }
                } else if !sep.isEmpty, !runs.isEmpty, let lr = runs.last {
                    append(sep, style: separatorStyle(lr, next: g))
                }
                append(g.text, style: runStyle(g))
            }
            if !firstInLine { prevLine = l }
        }
        return runs
    }

    private func paragraph(_ p: Para, skipGlyphs: Int) -> DocParagraph {
        var r = runs(for: p.lines, skipGlyphs: skipGlyphs)
        guard let first = p.lines.first else { return DocParagraph([]) }
        let em = CGFloat(first.size)
        var alignment: DocAlignment = .left
        var indent: Double = 0
        if p.centered {
            alignment = .center
        } else if p.lines.count == 1 && isRightAligned(first) {
            alignment = .right
        } else {
            let body = p.lines.count > 1 ? Array(p.lines.dropFirst()) : p.lines
            let left = body.map(\.left).min() ?? first.left
            let offset = left - first.colLeft
            if offset > em * 1.2 { indent = Double(offset) }
            let firstOffset = first.left - (p.lines.count > 1 ? left : first.colLeft)
            let cjk = CharClass.isCJK(first.glyphs.first?.text ?? "")
            if cjk && firstOffset > em * 0.65 && firstOffset < em * 1.4 && skipGlyphs == 0, var head = r.first {
                head.text = "\u{3000}" + head.text
                r[0] = head
                if p.lines.count == 1 { indent = 0 }
            }
            if p.lines.count >= 3 {
                let inner = p.lines.dropLast()
                if inner.allSatisfy({ abs($0.right - $0.colRight) < 1.5 }) { alignment = .justify }
            }
        }
        for k in r.indices where r[k].text.count >= 4 {
            r[k].text = BlockBuilder.replacingLeaderRuns(r[k].text)
        }
        return DocParagraph(r, alignment: alignment, indent: indent).normalized()
    }

    // MARK: Tables

    func docTable(_ t: TableGrid) -> DocTable {
        let rows: [[DocTableCell]] = t.rows.map { row in
            row.map { cell in DocTableCell(cellParagraphs(cell.lines), colSpan: cell.colSpan) }
        }
        return DocTable(rows: rows, headerRows: t.headerRows, columnWidths: t.columnWidths)
    }

    func cellParagraphs(_ lines: [TextLine]) -> [DocParagraph] {
        guard !lines.isEmpty else { return [DocParagraph([])] }
        let maxRight = lines.map(\.right).max() ?? 0
        var groups: [[TextLine]] = []
        for l in lines {
            if let lastGroup = groups.last, let a = lastGroup.last {
                let em = CGFloat(max(a.size, l.size))
                let full = a.right >= maxRight - em * 1.6
                let gap = l.rect.minY - a.rect.maxY
                if full && gap < em * 1.2 && ListMarkers.detect(lineText(l)) == nil && abs(a.size - l.size) < 1 {
                    groups[groups.count - 1].append(l)
                    continue
                }
            }
            groups.append([l])
        }
        return groups.map { DocParagraph(runs(for: $0, skipGlyphs: 0)).normalized() }
    }

    /// Plain strings for a table grid (used by the spreadsheet extractor).
    func cellText(_ cell: TableGrid.Cell) -> String {
        cellParagraphs(cell.lines).map(\.plainText).joined(separator: "\n")
    }

    func plainLine(_ l: TextLine) -> String { lineText(l) }
}
