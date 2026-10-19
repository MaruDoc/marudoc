import Foundation
import CoreGraphics
import EnsoDoc

/// A table found on a page, kept as lines per cell until document-wide styling is known.
struct TableGrid {
    struct Cell {
        var lines: [TextLine]
        var colSpan: Int
        /// True for the lower parts of a vertically merged cell (rendered empty).
        var continuation: Bool
    }
    var rect: CGRect
    var rows: [[Cell]]
    var columnWidths: [Double]
    var headerRows: Int
    var ruled: Bool
}

private struct UnionFind {
    var parent: [Int]
    init(_ n: Int) { parent = Array(0..<n) }
    mutating func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r { r = parent[r] }
        var y = x
        while parent[y] != r { let n = parent[y]; parent[y] = r; y = n }
        return r
    }
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[rb] = ra }
    }
}

// MARK: - Ruled tables

enum RuledTableDetector {
    private struct HSeg { var y: CGFloat; var x0: CGFloat; var x1: CGFloat }
    private struct VSeg { var x: CGFloat; var y0: CGFloat; var y1: CGFloat }

    static func detect(graphics: PageGraphics, glyphs: [Glyph], consumed: inout [Bool], page: Int,
                       pageSize: CGSize, styles: StyleTable) -> [TableGrid] {
        var hs: [HSeg] = [], vs: [VSeg] = []
        for r in graphics.rules {
            if r.horizontal { hs.append(HSeg(y: r.pos, x0: r.lo, x1: r.hi)) } else { vs.append(VSeg(x: r.pos, y0: r.lo, y1: r.hi)) }
        }
        let pageArea = pageSize.width * pageSize.height
        for f in graphics.fills where f.rect.area < pageArea * 0.5 && f.rect.width >= 8 && f.rect.height >= 6 {
            let r = f.rect
            hs.append(HSeg(y: r.minY, x0: r.minX, x1: r.maxX)); hs.append(HSeg(y: r.maxY, x0: r.minX, x1: r.maxX))
            vs.append(VSeg(x: r.minX, y0: r.minY, y1: r.maxY)); vs.append(VSeg(x: r.maxX, y0: r.minY, y1: r.maxY))
        }
        // Rules are built from numbers in the file (a huge CTM scale gives infinity): anything non-finite is dropped
        // here, so the merging and clustering below only ever see finite coordinates.
        hs = hs.filter { $0.y.isFinite && $0.x0.isFinite && $0.x1.isFinite }
        vs = vs.filter { $0.x.isFinite && $0.y0.isFinite && $0.y1.isFinite }
        guard hs.count >= 2, vs.count >= 2, hs.count * vs.count < 600_000 else { return [] }
        hs = mergeH(hs)
        vs = mergeV(vs)

        // Connected components of intersecting rules.
        var uf = UnionFind(hs.count + vs.count)
        let tol: CGFloat = 3
        for (i, h) in hs.enumerated() {
            for (j, v) in vs.enumerated() where v.x >= h.x0 - tol && v.x <= h.x1 + tol && h.y >= v.y0 - tol && h.y <= v.y1 + tol {
                uf.union(i, hs.count + j)
            }
        }
        var comps: [Int: (h: [HSeg], v: [VSeg])] = [:]
        for (i, h) in hs.enumerated() { comps[uf.find(i), default: ([], [])].h.append(h) }
        for (j, v) in vs.enumerated() { comps[uf.find(hs.count + j), default: ([], [])].v.append(v) }

        var out: [TableGrid] = []
        for (_, c) in comps.sorted(by: { ($0.value.h.first?.y ?? 0) < ($1.value.h.first?.y ?? 0) }) where c.h.count >= 2 && c.v.count >= 2 {
            if let t = buildGrid(h: c.h, v: c.v, glyphs: glyphs, consumed: &consumed, page: page, pageSize: pageSize, graphics: graphics, styles: styles) {
                out.append(t)
            }
        }
        return out
    }

    private static func mergeH(_ input: [HSeg]) -> [HSeg] {
        let segs = input.filter { $0.y.isFinite && $0.x0.isFinite && $0.x1.isFinite }
        let sorted = segs.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x0 < $1.x0 }
        var out: [HSeg] = []
        var i = 0
        while i < sorted.count {
            // The group always holds at least segment i, so it is never empty (a NaN comparison cannot empty it).
            var j = i + 1
            var ys: [CGFloat] = [sorted[i].y]
            while j < sorted.count && sorted[j].y - sorted[i].y <= 1.5 { ys.append(sorted[j].y); j += 1 }
            let y = ys.reduce(0, +) / CGFloat(ys.count)
            let group = sorted[i..<j].sorted { $0.x0 < $1.x0 }
            var cur = HSeg(y: y, x0: group[group.startIndex].x0, x1: group[group.startIndex].x1)
            for s in group.dropFirst() {
                if s.x0 <= cur.x1 + 2.5 { cur.x1 = max(cur.x1, s.x1) } else { out.append(cur); cur = HSeg(y: y, x0: s.x0, x1: s.x1) }
            }
            out.append(cur)
            i = j
        }
        return out
    }

    private static func mergeV(_ segs: [VSeg]) -> [VSeg] {
        let asH = segs.map { HSeg(y: $0.x, x0: $0.y0, x1: $0.y1) }
        return mergeH(asH).map { VSeg(x: $0.y, y0: $0.x0, y1: $0.x1) }
    }

    private static func cluster(_ values: [CGFloat], tol: CGFloat) -> [CGFloat] {
        let s = values.sorted()
        var out: [CGFloat] = []
        var group: [CGFloat] = []
        for v in s {
            if let last = group.last, v - last > tol {
                out.append(group.reduce(0, +) / CGFloat(group.count)); group = []
            }
            group.append(v)
        }
        if !group.isEmpty { out.append(group.reduce(0, +) / CGFloat(group.count)) }
        return out
    }

    private static func buildGrid(h: [HSeg], v: [VSeg], glyphs: [Glyph], consumed: inout [Bool], page: Int,
                                  pageSize: CGSize, graphics: PageGraphics, styles: StyleTable) -> TableGrid? {
        let minX = min(h.map(\.x0).min() ?? 0, v.map(\.x).min() ?? 0)
        let maxX = max(h.map(\.x1).max() ?? 0, v.map(\.x).max() ?? 0)
        let minY = min(v.map(\.y0).min() ?? 0, h.map(\.y).min() ?? 0)
        let maxY = max(v.map(\.y1).max() ?? 0, h.map(\.y).max() ?? 0)
        let bbox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard bbox.width >= 30, bbox.height >= 12 else { return nil }

        var xs = cluster(v.map(\.x) + [minX, maxX], tol: 2.5)
        var ys = cluster(h.map(\.y) + [minY, maxY], tol: 2.5)
        // Collapse slivers produced by double borders.
        func collapse(_ a: inout [CGFloat]) {
            var k = 1
            while k < a.count {
                if a[k] - a[k - 1] < 3.5 && a.count > 2 { a.remove(at: k == a.count - 1 ? k - 1 : k) } else { k += 1 }
            }
        }
        collapse(&xs); collapse(&ys)
        let nCols = xs.count - 1, nRows = ys.count - 1
        guard nCols >= 2, nRows >= 2, nCols <= 60, nRows <= 400 else { return nil }

        func covered(_ lo: CGFloat, _ hi: CGFloat, by segs: [(CGFloat, CGFloat)]) -> Bool {
            let need = (hi - lo) * 0.6
            var total: CGFloat = 0
            for (a, b) in segs { total += max(0, min(b, hi) - max(a, lo)) }
            return total >= need
        }
        // Vertical rules near each internal x boundary, horizontal rules near each internal y boundary.
        var vAt: [[(CGFloat, CGFloat)]] = Array(repeating: [], count: xs.count)
        for s in v { if let k = xs.firstIndex(where: { abs($0 - s.x) <= 3 }) { vAt[k].append((s.y0, s.y1)) } }
        var hAt: [[(CGFloat, CGFloat)]] = Array(repeating: [], count: ys.count)
        for s in h { if let k = ys.firstIndex(where: { abs($0 - s.y) <= 3 }) { hAt[k].append((s.x0, s.x1)) } }

        var uf = UnionFind(nRows * nCols)
        for i in 0..<nRows {
            for j in 0..<nCols {
                if j + 1 < nCols && !covered(ys[i], ys[i + 1], by: vAt[j + 1]) { uf.union(i * nCols + j, i * nCols + j + 1) }
                if i + 1 < nRows && !covered(xs[j], xs[j + 1], by: hAt[i + 1]) { uf.union(i * nCols + j, (i + 1) * nCols + j) }
            }
        }
        // Regions must be rectangles; otherwise fall back to single cells.
        var regionOf = [Int](repeating: 0, count: nRows * nCols)
        var boxes: [Int: (r0: Int, r1: Int, c0: Int, c1: Int)] = [:]
        for i in 0..<nRows {
            for j in 0..<nCols {
                let r = uf.find(i * nCols + j)
                regionOf[i * nCols + j] = r
                if let b = boxes[r] { boxes[r] = (min(b.r0, i), max(b.r1, i), min(b.c0, j), max(b.c1, j)) } else { boxes[r] = (i, i, j, j) }
            }
        }
        for (r, b) in boxes {
            var rect = true
            outer: for i in b.r0...b.r1 { for j in b.c0...b.c1 where regionOf[i * nCols + j] != r { rect = false; break outer } }
            if !rect {
                for i in b.r0...b.r1 { for j in b.c0...b.c1 where regionOf[i * nCols + j] == r { regionOf[i * nCols + j] = i * nCols + j + 1_000_000 } }
            }
        }
        var regionBox: [Int: (r0: Int, r1: Int, c0: Int, c1: Int)] = [:]
        for i in 0..<nRows {
            for j in 0..<nCols {
                let r = regionOf[i * nCols + j]
                if let b = regionBox[r] { regionBox[r] = (min(b.r0, i), max(b.r1, i), min(b.c0, j), max(b.c1, j)) } else { regionBox[r] = (i, i, j, j) }
            }
        }

        // Assign glyphs.
        func index(_ a: [CGFloat], _ v: CGFloat) -> Int? {
            guard let f = a.first, let l = a.last, v >= f - 1, v <= l + 1 else { return nil }
            var k = 0
            while k + 1 < a.count - 1 && v >= a[k + 1] { k += 1 }
            return k
        }
        var cellGlyphs: [Int: [Glyph]] = [:]
        var taken: [Int] = []
        let inner = bbox.insetBy(dx: -1, dy: -1)
        for (gi, g) in glyphs.enumerated() where !consumed[gi] && inner.contains(g.rect.center) {
            guard let i = index(ys, g.rect.midY), let j = index(xs, g.rect.midX) else { continue }
            cellGlyphs[regionOf[i * nCols + j], default: []].append(g)
            taken.append(gi)
        }
        let filled = cellGlyphs.values.filter { !$0.isEmpty }.count
        guard filled >= 2 else { return nil }
        // Diagrams are built from boxes and connector lines too; tables rarely contain curves or pictures.
        let decorations = graphics.shapes.filter { !$0.isRect && bbox.contains($0.rect.center) }.count
            + graphics.images.filter { bbox.contains($0.rect.center) && $0.rect.width > 6 }.count
        if decorations >= 2 { return nil }
        if Double(filled) < Double(regionBox.count) * 0.35 { return nil }
        // Big frames with few cells are page borders or layout boxes, not tables.
        let pageArea = pageSize.width * pageSize.height
        if bbox.area > pageArea * 0.7 && regionBox.count <= 4 { return nil }
        // Effective shape after merges: need at least two columns and two rows somewhere.
        let distinctCols = Set(regionBox.values.map(\.c0)).count
        let distinctRows = Set(regionBox.values.map(\.r0)).count
        guard distinctCols >= 2, distinctRows >= 2 else { return nil }

        var rows: [[TableGrid.Cell]] = []
        for i in 0..<nRows {
            var row: [TableGrid.Cell] = []
            var j = 0
            while j < nCols {
                let r = regionOf[i * nCols + j]
                guard let b = regionBox[r] else { j += 1; continue }
                let span = b.c1 - b.c0 + 1
                if b.r0 == i {
                    let lines = TextExtractor.buildLines(cellGlyphs[r] ?? [], page: page, styles: styles)
                    row.append(TableGrid.Cell(lines: lines, colSpan: span, continuation: false))
                } else {
                    row.append(TableGrid.Cell(lines: [], colSpan: span, continuation: true))
                }
                j = b.c1 + 1
            }
            rows.append(row)
        }
        // Drop rows that are entirely empty (spacer rows).
        rows = rows.filter { row in row.contains { !$0.lines.isEmpty || $0.continuation } }
        guard rows.count >= 2 else { return nil }
        for gi in taken { consumed[gi] = true }

        // Header: shaded or bold first row.
        var header = 0
        let firstRowRect = CGRect(x: xs[0], y: ys[0], width: xs[nCols] - xs[0], height: ys[1] - ys[0])
        let secondRowRect = CGRect(x: xs[0], y: ys[1], width: xs[nCols] - xs[0], height: ys[min(2, nRows)] - ys[1])
        func shade(_ r: CGRect) -> CGFloat {
            graphics.fills.filter { !($0.color?.isNearlyWhite ?? false) }.reduce(0) { acc, f in
                let x = f.rect.intersection(r); return acc + (x.isNull ? 0 : x.area)
            } / max(1, r.area)
        }
        let firstBold = boldRatio(rows[0]), restBold = rows.dropFirst().map(boldRatio).reduce(0, +) / Double(max(1, rows.count - 1))
        if shade(firstRowRect) > 0.5 && shade(secondRowRect) < 0.5 { header = 1 } else if firstBold > 0.6 && restBold < 0.4 { header = 1 }
        let widths = (0..<nCols).map { Double(xs[$0 + 1] - xs[$0]) }
        return TableGrid(rect: bbox, rows: rows, columnWidths: widths, headerRows: header, ruled: true)
    }

    static func boldRatio(_ row: [TableGrid.Cell]) -> Double {
        var n = 0.0, b = 0.0
        for c in row { for l in c.lines { n += Double(l.charCount); b += l.boldRatio * Double(l.charCount) } }
        return n > 0 ? b / n : 0
    }
}

// MARK: - Vector figures

/// Finds clusters of vector graphics (diagrams, charts) that should be exported as a picture
/// instead of as scattered text labels.
enum FigureDetector {
    struct Figure {
        var rect: CGRect
        var imageKeys: Set<Int>
        /// Glyphs (indices into the page glyph array) that belong to the picture.
        var glyphs: [Int]
    }

    static func detect(graphics: PageGraphics, glyphs: [Glyph], consumed: [Bool], tables: [CGRect],
                       pageSize: CGSize, page: Int, styles: StyleTable, debug: Bool = false) -> [Figure] {
        let pageArea = pageSize.width * pageSize.height
        func log(_ s: @autoclosure () -> String) { if debug { print("  [fig] " + s()) } }
        struct Item { var rect: CGRect; var kind: Int; var key: Int }   // kind 0 shape, 1 rect, 2 image, 3 rule
        var items: [Item] = []
        func outsideTables(_ r: CGRect) -> Bool { !tables.contains { $0.insetBy(dx: -2, dy: -2).contains(r.center) } }
        for s in graphics.shapes where s.rect.area < pageArea * 0.6 && outsideTables(s.rect) { items.append(Item(rect: s.rect, kind: s.isRect ? 1 : 0, key: 0)) }
        for f in graphics.fills where f.rect.area < pageArea * 0.6 && outsideTables(f.rect) { items.append(Item(rect: f.rect, kind: 1, key: 0)) }
        for im in graphics.images where im.rect.area < pageArea * 0.85 && im.rect.width >= 4 && im.rect.height >= 4 && outsideTables(im.rect) {
            items.append(Item(rect: im.rect, kind: 2, key: im.key))
        }
        guard items.count >= 2 else { return [] }
        // Glyph rows, to recognise underlines (a rule hugging the bottom of a run of text).
        let textRows = TextExtractor.buildLines(glyphs, page: page, styles: styles)
        for r in graphics.rules {
            let rect = r.horizontal ? CGRect(x: r.lo, y: r.pos - 0.5, width: r.hi - r.lo, height: 1) : CGRect(x: r.pos - 0.5, y: r.lo, width: 1, height: r.hi - r.lo)
            guard outsideTables(rect) else { continue }
            if r.horizontal {
                let underline = textRows.contains { l in
                    abs(r.pos - l.rect.maxY) <= 4 && r.lo >= l.rect.minX - 4 && r.hi <= l.rect.maxX + 4
                }
                if underline { continue }
            }
            items.append(Item(rect: rect, kind: 3, key: 0))
        }
        guard items.count <= 5000 else { return [] }

        var uf = UnionFind(items.count)
        let order = items.indices.sorted { items[$0].rect.minY < items[$1].rect.minY }
        for (oi, a) in order.enumerated() {
            let ra = items[a].rect.insetBy(dx: -4, dy: -4)
            var ob = oi + 1
            while ob < order.count {
                let b = order[ob]
                if items[b].rect.minY > ra.maxY { break }
                if ra.intersects(items[b].rect) { uf.union(a, b) }
                ob += 1
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in items.indices { groups[uf.find(i), default: []].append(i) }

        // Pull small satellite clusters (speech bubbles, icons) into nearby rich clusters.
        func stats(_ idx: [Int]) -> (box: CGRect, rich: Bool) {
            var shapes = 0, rects = 0, images = 0, rules = 0
            var box = CGRect.null
            for i in idx {
                box = box.union(items[i].rect)
                switch items[i].kind { case 0: shapes += 1; case 1: rects += 1; case 2: images += 1; default: rules += 1 }
            }
            let rich = shapes >= 3 || (shapes >= 2 && rects + rules >= 2) || (images >= 1 && shapes + rects + rules >= 3) || rects >= 6 || (images >= 2 && shapes + rects >= 1)
            return (box, rich)
        }
        var clusters = Array(groups.values)
        var merged = true
        while merged && clusters.count > 1 {
            merged = false
            outer: for a in clusters.indices {
                let sa = stats(clusters[a])
                guard sa.rich else { continue }
                for b in clusters.indices where b != a {
                    let sb = stats(clusters[b])
                    if sa.box.insetBy(dx: -10, dy: -10).intersects(sb.box) && sb.box.area < sa.box.area {
                        clusters[a] += clusters[b]
                        clusters.remove(at: b)
                        merged = true
                        break outer
                    }
                }
            }
        }
        groups = Dictionary(uniqueKeysWithValues: clusters.enumerated().map { ($0.offset, $0.element) })

        let medianSize = Stats.median(glyphs.map { styles[$0.style].size }) ?? 10
        // Word groups of the free text, with glyph ids pointing back into `glyphs`.
        var free: [Glyph] = []
        for (gi, g) in glyphs.enumerated() where !consumed[gi] { var c = g; c.id = gi; free.append(c) }
        var freeSegs = TextExtractor.segments(free, styles: styles)
        TextExtractor.removeRuby(&freeSegs, styles: styles)
        var figures: [Figure] = []
        for (_, idx) in groups {
            var shapes = 0, rects = 0, images = 0, rules = 0
            var box = CGRect.null
            var keys = Set<Int>()
            for i in idx {
                box = box.union(items[i].rect)
                switch items[i].kind {
                case 0: shapes += 1
                case 1: rects += 1
                case 2: images += 1; keys.insert(items[i].key)
                default: rules += 1
                }
            }
            log("cluster \(box.integral) shapes \(shapes) rects \(rects) images \(images) rules \(rules)")
            guard box.width >= 40, box.height >= 30, box.area >= pageArea * 0.015, box.area < pageArea * 0.92 else { log("  size"); continue }
            let rich = shapes >= 3 || (shapes >= 2 && rects + rules >= 2) || (images >= 1 && shapes + rects + rules >= 3) || rects >= 6 || (images >= 2 && shapes + rects >= 1)
            guard rich else { log("  not rich"); continue }
            // Text inside must be label-like. Long text that merely touches the box stays in the text flow.
            var kept: [Segment] = []
            var long = 0
            for seg in freeSegs where seg.rect.intersects(box) {
                let inter = seg.rect.intersection(box)
                let frac = inter.isNull ? 0 : inter.area / max(1, seg.rect.area)
                if frac < 0.5 || (seg.glyphs.count > 24 && frac < 0.6) { continue }
                if seg.glyphs.count > 24 { long += 1 }
                kept.append(seg)
            }
            if long > max(1, kept.count / 6) { log("  long lines \(long)/\(kept.count)"); continue }
            if kept.contains(where: { s in s.glyphs.count >= 4 && (s.glyphs.map { styles[$0.style].size }.max() ?? 0) > medianSize * 1.45 }) { log("  title text"); continue }
            let chars = kept.reduce(0) { $0 + $1.glyphs.count }
            if chars > 700 { log("  too much text"); continue }
            let textArea = kept.reduce(CGFloat(0)) { $0 + $1.rect.area }
            if textArea > box.area * 0.45 { log("  text area"); continue }
            log("  FIGURE")
            for seg in kept { box = box.union(seg.rect) }
            let claimed = kept.flatMap { $0.glyphs.map(\.id) }.filter { $0 >= 0 }
            figures.append(Figure(rect: box.insetBy(dx: -2, dy: -2), imageKeys: keys, glyphs: claimed))
        }
        return figures
    }
}
