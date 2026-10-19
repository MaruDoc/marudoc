import Foundation
import CoreGraphics
import EnsoDoc

/// Something placed on the page that is not a text line (table, picture).
struct Atom {
    var rect: CGRect
    var item: FlowItem
}

struct ImageAtom {
    var image: DocImage
    var rect: CGRect
}

/// Page content in reading order, consumed by the block builder.
enum FlowItem {
    case line(TextLine)
    case table(TableGrid)
    case image(ImageAtom)
    case pageStart(Int)
}

/// Reading order: column detection (recursive gutter splitting with full-width "bands"),
/// then unruled table detection inside each column.
enum LayoutAnalyzer {

    /// - Parameter docRight: right margin shared by the document's pages of this width, if known.
    static func order(lines: [TextLine], atoms: [Atom], pageSize: CGSize, bodySize: Double, docRight: CGFloat? = nil,
                      slides: Bool = false, styles: StyleTable) -> [FlowItem] {
        var m: Metrics?
        if !slides, rightEdge(lines) == nil, let dr = docRight, let maxRight = lines.map(\.right).max(), maxRight <= dr + CGFloat(bodySize) * 2 {
            let textLines = lines.filter { $0.charCount >= 2 }
            m = ((textLines.isEmpty ? lines : textLines).map(\.left).min() ?? 0, dr)
        }
        return layout(lines: lines, atoms: atoms, bounds: CGRect(origin: .zero, size: pageSize), root: true, metrics: m,
                      depth: 0, pageSize: pageSize, bodySize: bodySize, slides: slides, styles: styles)
    }

    typealias Metrics = (left: CGFloat, right: CGFloat)

    /// `slides`: text boxes are not justified, so only right edges shared exactly count as margins.
    private static func layout(lines: [TextLine], atoms: [Atom], bounds: CGRect, root: Bool, metrics: Metrics?, depth: Int,
                               pageSize: CGSize, bodySize: Double, slides: Bool, styles: StyleTable) -> [FlowItem] {
        if depth < 5, lines.count >= 3, let split = findGutter(lines: lines, atoms: atoms, bodySize: bodySize, styles: styles) {
            var out: [FlowItem] = []
            // Bands between full-width (crossing) items.
            var crossing: [(y: CGFloat, item: Either)] = split.crossLines.map { ($0.rect.midY, .line($0)) } + split.crossAtoms.map { ($0.rect.midY, .atom($0)) }
            crossing.sort { $0.y < $1.y }
            var bandTop = -CGFloat.infinity
            for k in 0...crossing.count {
                let bandBottom = k < crossing.count ? crossing[k].y : .infinity
                let l = split.left.filter { $0.rect.midY >= bandTop && $0.rect.midY < bandBottom }
                let la = split.leftAtoms.filter { $0.rect.midY >= bandTop && $0.rect.midY < bandBottom }
                let r = split.right.filter { $0.rect.midY >= bandTop && $0.rect.midY < bandBottom }
                let ra = split.rightAtoms.filter { $0.rect.midY >= bandTop && $0.rect.midY < bandBottom }
                if !l.isEmpty || !la.isEmpty {
                    out += layout(lines: l, atoms: la, bounds: CGRect(x: bounds.minX, y: bounds.minY, width: split.g0 - bounds.minX, height: bounds.height),
                                  root: false, metrics: nil, depth: depth + 1, pageSize: pageSize, bodySize: bodySize, slides: slides, styles: styles)
                }
                if !r.isEmpty || !ra.isEmpty {
                    out += layout(lines: r, atoms: ra, bounds: CGRect(x: split.g1, y: bounds.minY, width: bounds.maxX - split.g1, height: bounds.height),
                                  root: false, metrics: nil, depth: depth + 1, pageSize: pageSize, bodySize: bodySize, slides: slides, styles: styles)
                }
                if k < crossing.count {
                    switch crossing[k].item {
                    case .line(var line):
                        let m = metrics ?? regionMetrics(lines, atoms: atoms, bounds: bounds, root: root, pageSize: pageSize, slides: slides)
                        line.colLeft = m.left
                        line.colRight = max(line.right, m.right)
                        out.append(.line(line))
                    case .atom(let a):
                        out.append(a.item)
                    }
                }
                bandTop = bandBottom
            }
            return out
        }
        if depth < 5, lines.count >= 3, let bands = horizontalBands(lines: lines, atoms: atoms), bands.count > 1 {
            // Bands keep the column margins of the region they were cut from.
            let m = metrics ?? regionMetrics(lines, atoms: atoms, bounds: bounds, root: root, pageSize: pageSize, slides: slides)
            var out: [FlowItem] = []
            for b in bands {
                out += layout(lines: b.lines, atoms: b.atoms, bounds: bounds, root: root, metrics: m, depth: depth + 1,
                              pageSize: pageSize, bodySize: bodySize, slides: slides, styles: styles)
            }
            return out
        }
        let m = metrics ?? regionMetrics(lines, atoms: atoms, bounds: bounds, root: root, pageSize: pageSize, slides: slides)
        return leaf(lines: lines, atoms: atoms, metrics: m, styles: styles)
    }

    /// Splits a region at large empty horizontal gaps so local multi-column zones (a header band,
    /// a two-column list under single-column text) can be analysed on their own.
    private static func horizontalBands(lines: [TextLine], atoms: [Atom]) -> [(lines: [TextLine], atoms: [Atom])]? {
        var spans: [(CGFloat, CGFloat)] = lines.map { ($0.rect.minY, $0.rect.maxY) }
        spans.sort { $0.0 < $1.0 }
        let lineH = CGFloat(Stats.median(lines.map { Double($0.rect.height) }) ?? 12)
        var cuts: [CGFloat] = []
        var bottom = spans.first?.1 ?? 0
        for s in spans.dropFirst() {
            if s.0 - bottom >= lineH * 1.5 { cuts.append((s.0 + bottom) / 2) }
            bottom = max(bottom, s.1)
        }
        guard !cuts.isEmpty else { return nil }
        var bands = [(lines: [TextLine], atoms: [Atom])](repeating: ([], []), count: cuts.count + 1)
        func band(_ y: CGFloat) -> Int { cuts.firstIndex { y < $0 } ?? cuts.count }
        for l in lines { bands[band(l.rect.midY)].lines.append(l) }
        for a in atoms { bands[band(a.rect.midY)].atoms.append(a) }
        return bands.filter { !$0.lines.isEmpty || !$0.atoms.isEmpty }
    }

    private enum Either { case line(TextLine); case atom(Atom) }

    private struct Split {
        var g0: CGFloat, g1: CGFloat
        var left: [TextLine], right: [TextLine], crossLines: [TextLine]
        var leftAtoms: [Atom], rightAtoms: [Atom], crossAtoms: [Atom]
    }

    private static func findGutter(lines: [TextLine], atoms: [Atom], bodySize: Double, styles: StyleTable) -> Split? {
        let x0 = floor(min(lines.map(\.left).min() ?? 0, atoms.map(\.rect.minX).min() ?? .infinity))
        let x1 = ceil(max(lines.map(\.right).max() ?? 0, atoms.map(\.rect.maxX).max() ?? -.infinity))
        let width = x1 - x0
        guard width > 80, width < 20000 else { return nil }
        let n = Int(width) + 1
        var cover = [Int](repeating: 0, count: n)
        func mark(_ a: CGFloat, _ b: CGFloat, weight: Int = 1) {
            let lo = max(0, SafeInt.floor(Double(a - x0), -1, n)), hi = min(n - 1, SafeInt.floor(Double((b - x0).rounded(.up)), -1, n))
            if lo <= hi { for x in lo...hi { cover[x] += weight } }
        }
        for l in lines { for s in l.segments { mark(s.rect.minX, s.rect.maxX) } }
        // A picture blocks a gutter as much as the text lines beside it.
        for a in atoms { mark(a.rect.minX, a.rect.maxX, weight: max(1, lines.filter { $0.rect.verticalOverlap(a.rect) > 0 }.count)) }
        let allowed = lines.count / 4
        let minGap = max(6, CGFloat(bodySize) * 0.5)

        // Candidate runs of low coverage, best (lowest cover, widest) first.
        var cands: [(g0: CGFloat, g1: CGFloat, peak: Int)] = []
        var x = 0
        while x < n {
            if cover[x] <= allowed {
                var y = x
                var peak = 0
                while y < n && cover[y] <= allowed { peak = max(peak, cover[y]); y += 1 }
                let g0 = x0 + CGFloat(x), g1 = x0 + CGFloat(y - 1)
                if g1 >= g0 && x > 0 && y < n { cands.append((g0, g1, peak)) }
                x = y
            } else { x += 1 }
        }
        cands.sort { $0.peak != $1.peak ? $0.peak < $1.peak : ($0.g1 - $0.g0) > ($1.g1 - $1.g0) }

        for c in cands.prefix(6) {
            var left: [TextLine] = [], right: [TextLine] = [], cross: [TextLine] = []
            var pairs = 0
            var leftChars: [Double] = [], rightChars: [Double] = []
            for l in lines {
                if l.segments.contains(where: { $0.rect.maxX > c.g0 + 1 && $0.rect.minX < c.g1 - 1 }) { cross.append(l); continue }
                let ls = l.segments.filter { $0.rect.maxX <= c.g0 + 1 }
                let rs = l.segments.filter { $0.rect.minX >= c.g1 - 1 }
                if !ls.isEmpty {
                    var nl = l; nl.segments = ls; nl.computeStats(styles)
                    left.append(nl); leftChars.append(Double(nl.charCount))
                }
                if !rs.isEmpty {
                    var nr = l; nr.segments = rs; nr.computeStats(styles)
                    right.append(nr); rightChars.append(Double(nr.charCount))
                }
                if !ls.isEmpty && !rs.isEmpty { pairs += 1 }
            }
            var la: [Atom] = [], ra: [Atom] = [], ca: [Atom] = []
            for a in atoms {
                if a.rect.maxX <= c.g0 + 2 { la.append(a) } else if a.rect.minX >= c.g1 - 2 { ra.append(a) } else { ca.append(a) }
            }
            guard cross.count <= max(2, lines.count / 4) else { continue }
            // A picture beside a text box: the text is its own column.
            func pictureSide(_ atoms: [Atom], _ text: [TextLine]) -> Bool {
                guard let top = text.map(\.rect.minY).min(), let bottom = text.map(\.rect.maxY).max() else { return false }
                return atoms.contains { a in
                    let ov = min(a.rect.maxY, bottom) - max(a.rect.minY, top)
                    return a.rect.width >= 60 && ov > 0.5 * (bottom - top)
                }
            }
            if left.isEmpty && right.count >= 2 && pictureSide(la, right) || right.isEmpty && left.count >= 2 && pictureSide(ra, left) {
                return Split(g0: c.g0, g1: c.g1, left: left, right: right, crossLines: cross, leftAtoms: la, rightAtoms: ra, crossAtoms: ca)
            }
            guard c.g1 - c.g0 >= minGap, left.count >= 2, right.count >= 2 else { continue }
            guard c.g0 - x0 >= max(28, width * 0.08), x1 - c.g1 >= max(28, width * 0.08) else { continue }
            let ml = Stats.median(leftChars) ?? 0, mr = Stats.median(rightChars) ?? 0
            if ml < 6 && mr < 6 { continue }
            let sl = Stats.median(left.map(\.size)) ?? 10, sr = Stats.median(right.map(\.size)) ?? 10
            let sameSize = max(sl, sr) <= min(sl, sr) * 1.3
            if sameSize && Double(pairs) >= 0.75 * Double(min(left.count, right.count)) && min(ml, mr) < 12 { continue }
            // Sides must sit next to each other, not above one another.
            let lTop = left.map(\.rect.minY).min() ?? 0, lBot = left.map(\.rect.maxY).max() ?? 0
            let rTop = right.map(\.rect.minY).min() ?? 0, rBot = right.map(\.rect.maxY).max() ?? 0
            let ov = min(lBot, rBot) - max(lTop, rTop)
            guard ov > 0.3 * min(lBot - lTop, rBot - rTop) else { continue }

            return Split(g0: c.g0, g1: c.g1, left: left, right: right, crossLines: cross, leftAtoms: la, rightAtoms: ra, crossAtoms: ca)
        }
        return nil
    }

    // MARK: Leaf columns

    /// The column's right margin: the right-most edge shared by several long lines
    /// (ignores margin notes that stick out further right).
    static func rightEdge(_ lines: [TextLine], strict: Bool = false) -> CGFloat? {
        let long = lines.filter { $0.charCount >= (strict ? 4 : 8) }
        guard long.count >= 2 else { return nil }
        let rights = long.map(\.right).sorted(by: >)
        let em = CGFloat(Stats.median(long.map(\.size)) ?? 10)
        // Right-most edge that several lines share; inner boxes and indented blocks end earlier.
        let need = strict ? 2 : (long.count <= 4 ? 2 : 3)
        let tol = strict ? min(em * 0.5, 8) : em
        for r in rights {
            let cluster = rights.filter { abs($0 - r) <= tol }
            if cluster.count >= need { return cluster.max() ?? r }
        }
        return nil
    }

    private static func regionMetrics(_ lines: [TextLine], atoms: [Atom], bounds: CGRect, root: Bool, pageSize: CGSize, slides: Bool) -> Metrics {
        let textLines = lines.filter { $0.charCount >= 2 }
        let colLeft = (textLines.isEmpty ? lines : textLines).map(\.left).min() ?? bounds.minX
        let maxRight = lines.map(\.right).max() ?? bounds.maxX
        if let edge = rightEdge(lines, strict: slides) { return (colLeft, edge) }
        let fallback = root ? pageSize.width - colLeft : bounds.maxX
        return (colLeft, max(maxRight, min(fallback, bounds.maxX)))
    }

    private static func leaf(lines: [TextLine], atoms: [Atom], metrics: Metrics, styles: StyleTable) -> [FlowItem] {
        var ls = lines.sorted { $0.rect.minY != $1.rect.minY ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        let colLeft = metrics.left, colRight = metrics.right
        for i in ls.indices {
            ls[i].colLeft = colLeft
            ls[i].colRight = colRight
            // Neighbours with the same left edge that end at the same x form a (boxed) block.
            let em = CGFloat(max(ls[i].size, 4))
            var rights: [CGFloat] = []
            for j in max(0, i - 3)...min(ls.count - 1, i + 3) where abs(ls[j].left - ls[i].left) <= em * 2 || j == i {
                if ls[j].charCount >= 6 || j == i { rights.append(ls[j].right) }
            }
            rights.sort(by: >)
            for r in rights where rights.filter({ abs($0 - r) <= em * 0.5 }).count >= 2 {
                ls[i].localRight = min(r, colRight)
                break
            }
            // Text flowing around a picture on the right ends early on purpose.
            for a in atoms where a.rect.minX > ls[i].right && a.rect.verticalOverlap(ls[i].rect) > 0 {
                ls[i].colRight = min(ls[i].colRight, a.rect.minX - 2)
            }
        }

        // Unruled tables.
        let tables = UnruledTableDetector.detect(ls, styles: styles)
        var items: [(y: CGFloat, x: CGFloat, item: FlowItem)] = []
        var consumed = Set<Int>()
        for t in tables {
            for i in t.range { consumed.insert(i) }
            items.append((t.grid.rect.minY, t.grid.rect.minX, .table(t.grid)))
        }
        for (i, l) in ls.enumerated() where !consumed.contains(i) { items.append((l.rect.minY, l.rect.minX, .line(l))) }
        for a in atoms { items.append((a.rect.minY, a.rect.minX, a.item)) }
        // Stable sort by top edge; lines keep their relative order.
        let indexed = items.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            let ya = a.1.y, yb = b.1.y
            if abs(ya - yb) > 2 { return ya < yb }
            return a.0 < b.0
        }
        return sorted.map(\.1.item)
    }
}

// MARK: - Unruled tables

enum UnruledTableDetector {
    struct Found { var range: Range<Int>; var grid: TableGrid }

    static func detect(_ lines: [TextLine], styles: StyleTable) -> [Found] {
        var out: [Found] = []
        var i = 0
        while i < lines.count {
            guard lines[i].segments.count >= 2 else { i += 1; continue }
            var j = i + 1
            while j < lines.count {
                let prev = lines[j - 1], cur = lines[j]
                let h = max(prev.rect.height, cur.rect.height)
                let gap = cur.rect.minY - prev.rect.maxY
                guard gap <= max(h * 1.6, 6), abs(cur.size - lines[i].size) <= max(2, lines[i].size * 0.25) else { break }
                if cur.segments.count >= 2 { j += 1; continue }
                // A single-segment line can be a wrapped cell or a row with one value; accept it only
                // when another multi-segment row follows closely.
                if j + 1 < lines.count, lines[j + 1].segments.count >= 2, lines[j + 1].rect.minY - cur.rect.maxY <= max(h * 1.6, 6) {
                    j += 1; continue
                }
                break
            }
            if let grid = build(Array(lines[i..<j]), styles: styles) {
                out.append(Found(range: i..<j, grid: grid))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    private static func build(_ rows: [TextLine], styles: StyleTable) -> TableGrid? {
        let multi = rows.filter { $0.segments.count >= 2 }
        guard multi.count >= 2 else { return nil }
        let x0 = floor(rows.map(\.left).min() ?? 0), x1 = ceil(rows.map(\.right).max() ?? 0)
        let n = SafeInt.floor(Double(x1 - x0), 0, 100_000) + 2
        guard n > 2, n < 20000 else { return nil }
        var cover = [Int](repeating: 0, count: n)
        for r in rows {
            for s in r.segments {
                let lo = max(0, SafeInt.floor(Double(s.rect.minX - x0), -1, n)), hi = min(n - 1, SafeInt.floor(Double(s.rect.maxX - x0), -1, n))
                if lo <= hi { for x in lo...hi { cover[x] += 1 } }
            }
        }
        let allowed = rows.count >= 6 ? rows.count / 7 : 0
        let size = CGFloat(Stats.median(rows.map(\.size)) ?? 10)
        // Column intervals separated by low-coverage gaps.
        var cols: [(CGFloat, CGFloat)] = []
        var x = 0
        var start: Int?
        while x < n {
            if cover[x] > allowed {
                if start == nil { start = x }
                x += 1
            } else {
                var y = x
                while y < n && cover[y] <= allowed { y += 1 }
                if let s = start, CGFloat(y - x) >= size * 0.6 || y >= n {
                    cols.append((x0 + CGFloat(s), x0 + CGFloat(x)))
                    start = nil
                }
                x = y
            }
        }
        if let s = start { cols.append((x0 + CGFloat(s), x1)) }
        guard cols.count >= 2, cols.count <= 30 else { return nil }
        if rows.count == 2 && cols.count < 3 { return nil }

        func colIndex(_ r: CGRect) -> (Int, Int) {
            var first = -1, last = -1
            for (k, c) in cols.enumerated() where min(r.maxX, c.1) - max(r.minX, c.0) > 0 {
                if first < 0 { first = k }
                last = k
            }
            if first < 0 {
                let k = cols.enumerated().min { abs(($0.element.0 + $0.element.1) / 2 - r.midX) < abs(($1.element.0 + $1.element.1) / 2 - r.midX) }?.offset ?? 0
                return (k, k)
            }
            return (first, last)
        }

        struct RowBuild { var cells: [[Segment]]; var spans: [Int: Int]; var rect: CGRect; var page: Int }
        var built: [RowBuild] = []
        for r in rows {
            var cells = [[Segment]](repeating: [], count: cols.count)
            var spans: [Int: Int] = [:]
            for s in r.segments {
                let (a, b) = colIndex(s.rect)
                cells[a].append(s)
                if b > a { spans[a] = max(spans[a] ?? 1, b - a + 1) }
            }
            built.append(RowBuild(cells: cells, spans: spans, rect: r.rect, page: r.page))
        }
        // Merge wrapped continuation lines (first column empty, tight spacing) into the row above.
        let pitches = zip(built.dropFirst(), built).map { Double($0.rect.minY - $1.rect.minY) }
        let pitch = CGFloat(Stats.median(pitches) ?? Double(size * 2))
        var merged: [RowBuild] = []
        for b in built {
            if var last = merged.last, b.cells[0].isEmpty, !last.cells[0].isEmpty, b.rect.minY - last.rect.minY < pitch * 0.8 {
                for k in cols.indices { last.cells[k] += b.cells[k] }
                last.rect = last.rect.union(b.rect)
                merged[merged.count - 1] = last
            } else {
                merged.append(b)
            }
        }
        guard merged.count >= 2 else { return nil }

        // Validation: rows must actually use several columns and cells must be short.
        let filledPerRow = merged.map { row in row.cells.filter { !$0.isEmpty }.count }
        let avgFilled = Double(filledPerRow.reduce(0, +)) / Double(merged.count)
        guard avgFilled >= 1.6 else { return nil }
        var cellChars: [Double] = []
        for row in merged { for c in row.cells where !c.isEmpty { cellChars.append(Double(c.reduce(0) { $0 + $1.glyphs.count })) } }
        let meanChars = cellChars.reduce(0, +) / Double(max(1, cellChars.count))
        guard meanChars <= 40 else { return nil }

        var gridRows: [[TableGrid.Cell]] = []
        for row in merged {
            var cells: [TableGrid.Cell] = []
            var k = 0
            while k < cols.count {
                let span = min(row.spans[k] ?? 1, cols.count - k)
                let lines = TextExtractor.lines(row.cells[k], page: row.page, styles: styles)
                cells.append(TableGrid.Cell(lines: lines, colSpan: span, continuation: false))
                k += span
            }
            gridRows.append(cells)
        }
        // Header row: bold, or text over numeric columns.
        var header = 0
        let firstBold = RuledTableDetector.boldRatio(gridRows[0])
        let restBold = gridRows.dropFirst().map(RuledTableDetector.boldRatio).reduce(0, +) / Double(max(1, gridRows.count - 1))
        if firstBold > 0.6 && restBold < 0.4 { header = 1 } else {
            let firstNumeric = gridRows[0].contains { cell in NumericText.isNumeric(cell.lines.map(\.text).joined(separator: " ")) }
            let numericRows = gridRows.dropFirst().filter { row in row.contains { NumericText.isNumeric($0.lines.map(\.text).joined(separator: " ")) } }.count
            if !firstNumeric && numericRows * 2 >= gridRows.count - 1 && gridRows.count >= 3 { header = 1 }
        }
        let rect = rows.dropFirst().reduce(rows[0].rect) { $0.union($1.rect) }
        return TableGrid(rect: rect, rows: gridRows, columnWidths: cols.map { Double($0.1 - $0.0) }, headerRows: header, ruled: false)
    }
}
