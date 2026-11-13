import Foundation
import CoreText
import CoreGraphics
import ImageIO
import EnsoDoc

/// Draws one planned page. Sheet geometry is in points with y growing downwards from the top-left of the printed
/// area; the context is translated and scaled so that a sheet point (x, y) lands at user space (x, -y). Text is
/// drawn upright (no flipped CTM), so PDF text extraction reads it normally.
final class SheetPainter {
    let ctx: CGContext
    let fileName: String
    let date: Date
    let total: Int
    private var images: [String: CGImage] = [:]
    private let black = CGColor(gray: 0, alpha: 1)

    init(ctx: CGContext, fileName: String, date: Date, total: Int) {
        self.ctx = ctx; self.fileName = fileName; self.date = date; self.total = total
    }

    typealias Segment = SheetPrinter.Segment

    @inline(__always) func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: -(y + h), width: w, height: h) }

    func draw(_ p: SheetPrinter.PagePlan, number: Int) {
        let L = p.layout
        ctx.saveGState()
        ctx.translateBy(x: p.origin.x, y: p.paper.height - p.origin.y)
        ctx.scaleBy(x: p.scale, y: p.scale)
        ctx.textMatrix = .identity
        let grid = L.sheet.pageSetup.gridLines || L.sheet.isCSV
        func each(_ body: (Geometry, CGRect) -> Void) {
            for rs in p.rows {
                for cs in p.cols {
                    let g = Geometry(L: L, rs: rs, cs: cs)
                    let x0 = cs.origin, x1 = g.x(cs.last + 1), y0 = rs.origin, y1 = g.y(rs.last + 1)
                    body(g, R(x0, y0, x1 - x0, y1 - y0))
                }
            }
        }
        // Fills and gridlines under the text; a little room around each area so outer borders are not cut in half.
        each { g, area in
            ctx.saveGState()
            ctx.clip(to: area.insetBy(dx: -2, dy: -2))
            drawFills(g)
            if grid { drawGrid(g) }
            ctx.restoreGState()
        }
        // Text row by row across all column areas, each sheet row tagged as a table row so that copied and
        // searched text follows the rows even across wide gaps between columns.
        CGPDFContextBeginTag(ctx, .table, [:] as CFDictionary)
        for rs in p.rows {
            var drawnMerges = Set<Int>()
            for r in rs.first...rs.last where L.height(r) > 0 {
                CGPDFContextBeginTag(ctx, .tableRow, [:] as CFDictionary)
                var batch = GlyphBatch()
                for (ci, cs) in p.cols.enumerated() {
                    var g = Geometry(L: L, rs: rs, cs: cs)
                    if ci == p.cols.count - 1 { g.overflowEdge = p.overflowEdge }
                    drawTexts(g, row: r, segment: ci, drawnMerges: &drawnMerges, batch: &batch)
                }
                flush(&batch)
                CGPDFContextEndTag(ctx)
            }
        }
        CGPDFContextEndTag(ctx)
        each { g, area in
            ctx.saveGState()
            ctx.clip(to: area.insetBy(dx: -2, dy: -2))
            drawBorders(g)
            ctx.clip(to: area)
            drawDrawings(g)
            ctx.restoreGState()
        }
        if p.headings { drawHeadings(p) }
        ctx.restoreGState()
        drawHeaderFooter(p, number: number)
    }

    /// Where a segment's rows and columns are on the page.
    struct Geometry {
        let L: SheetLayout
        let rs: Segment
        let cs: Segment
        /// Right edge text may overflow to past the last printed column (last column band only).
        var overflowEdge: Double? = nil
        @inline(__always) func x(_ c: Int) -> Double { cs.origin + L.x(c) - L.x(cs.first) }
        @inline(__always) func y(_ r: Int) -> Double { rs.origin + L.y(r) - L.y(rs.first) }
        func rect(_ m: SheetRange) -> (x: Double, y: Double, w: Double, h: Double) {
            (x(m.c0), y(m.r0), L.x(m.c1 + 1) - L.x(m.c0), L.y(m.r1 + 1) - L.y(m.r0))
        }
        var rows: ClosedRange<Int> { rs.first...rs.last }
        var cols: ClosedRange<Int> { cs.first...cs.last }
    }

    // MARK: Fills

    func drawFills(_ g: Geometry) {
        let s = g.L.sheet
        var paths: [DocColor: CGMutablePath] = [:]
        var order: [DocColor] = []
        var merges = Set<Int>()
        let fills = s.styles.map(\.fill)
        let anyFill = fills.contains { $0 != nil }
        for r in g.rows where g.L.height(r) > 0 {
            let y = g.y(r), h = g.L.height(r)
            for c in g.cols where g.L.width(c) > 0 {
                if let m = g.L.mergeAt[SheetLayout.key(r, c)] { merges.insert(m); continue }
                guard anyFill else { continue }
                let si = s.styleIndex(r, c)
                guard si < fills.count, let f = fills[si] else { continue }
                if paths[f] == nil { paths[f] = CGMutablePath(); order.append(f) }
                paths[f]!.addRect(R(g.x(c), y, g.L.width(c), h))
            }
        }
        for mi in merges.sorted() {
            let m = s.merges[mi]
            guard let f = s.style(m.r0, m.c0).fill else { continue }
            let rc = g.rect(m)
            if paths[f] == nil { paths[f] = CGMutablePath(); order.append(f) }
            paths[f]!.addRect(R(rc.x, rc.y, rc.w, rc.h))
        }
        for f in order {
            ctx.setFillColor(SheetText.cg(f))
            ctx.addPath(paths[f]!)
            ctx.fillPath()
        }
    }

    // MARK: Gridlines

    func drawGrid(_ g: Geometry) {
        let L = g.L
        let path = CGMutablePath()
        let cols = g.cols.filter { L.width($0) > 0 }
        let rows = g.rows.filter { L.height($0) > 0 }
        guard let fc = cols.first, let fr = rows.first else { return }
        let left = g.x(fc), top = g.y(fr), right = g.x(cols.last! + 1), bottom = g.y(rows.last! + 1)
        path.move(to: CGPoint(x: left, y: -top)); path.addLine(to: CGPoint(x: right, y: -top))
        path.move(to: CGPoint(x: left, y: -top)); path.addLine(to: CGPoint(x: left, y: -bottom))
        let hasMerges = !L.mergeAt.isEmpty
        for r in rows {
            let y = g.y(r), yb = y + L.height(r)
            for c in cols {
                let x = g.x(c), xr = x + L.width(c)
                let m = hasMerges ? L.mergeAt[SheetLayout.key(r, c)] : nil
                // Right edge, unless the next column belongs to the same merged block.
                if m == nil || m != L.mergeAt[SheetLayout.key(r, c + 1)] || c == g.cs.last {
                    path.move(to: CGPoint(x: xr, y: -y)); path.addLine(to: CGPoint(x: xr, y: -yb))
                }
                if m == nil || m != L.mergeAt[SheetLayout.key(r + 1, c)] || r == g.rs.last {
                    path.move(to: CGPoint(x: x, y: -yb)); path.addLine(to: CGPoint(x: xr, y: -yb))
                }
            }
        }
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: L.sheet.isCSV ? 0.72 : 0.6, alpha: 1))
        ctx.setLineWidth(L.sheet.isCSV ? 0.5 : 0.4)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Text

    /// Underline and strike-through lines collected while a row's glyphs are batched.
    private var decorations: [(CGRect, CGColor)] = []

    /// The cells of one sheet row within one area of the page.
    func drawTexts(_ g: Geometry, row r: Int, segment: Int, drawnMerges: inout Set<Int>, batch: inout GlyphBatch) {
        let L = g.L, s = L.sheet
        let row: [SheetCell?] = r < s.cells.count ? s.cells[r] : []
        let hasMerges = !L.mergeAt.isEmpty
        for c in g.cols where L.width(c) > 0 {
            if hasMerges, let mi = L.mergeAt[SheetLayout.key(r, c)] {
                // A merged block is drawn once per area, from its top-left cell, across its whole area.
                let key = mi &* 64 &+ segment
                guard !drawnMerges.contains(key) else { continue }
                drawnMerges.insert(key)
                let m = s.merges[mi]
                guard let cell = s.cell(m.r0, m.c0), !cell.text.isEmpty else { continue }
                let rc = g.rect(m)
                drawCell(cell, style: s.style(m.r0, m.c0), x: rc.x, y: rc.y, w: rc.w, h: rc.h, r: m.r0, c: m.c0,
                         g: g, merged: true, batch: &batch)
                continue
            }
            guard c < row.count, let cell = row[c], !cell.text.isEmpty else { continue }
            drawCell(cell, style: s.style(r, c), x: g.x(c), y: g.y(r), w: L.width(c), h: L.height(r), r: r, c: c,
                     g: g, merged: false, batch: &batch)
        }
    }

    private func flush(_ batch: inout GlyphBatch) {
        if !batch.isEmpty { batch.flush(ctx) }
        for (rect, color) in decorations { ctx.setFillColor(color); ctx.fill(rect) }
        decorations.removeAll(keepingCapacity: true)
    }

    /// True when no cell of row r right of column c has a value.
    private func emptyBeyond(_ L: SheetLayout, _ r: Int, _ c: Int) -> Bool {
        guard r < L.sheet.cells.count else { return true }
        let row = L.sheet.cells[r]
        var k = c + 1
        while k < row.count { if !(row[k]?.text.isEmpty ?? true) { return false }; k += 1 }
        return true
    }

    private func isEmptyCell(_ L: SheetLayout, _ r: Int, _ c: Int) -> Bool {
        if L.mergeAt[SheetLayout.key(r, c)] != nil { return false }
        return (L.sheet.cell(r, c)?.text ?? "").isEmpty
    }

    func drawCell(_ cell: SheetCell, style st: SheetCellStyle, x: Double, y: Double, w: Double, h: Double, r: Int, c: Int,
                  g: Geometry, merged: Bool, batch: inout GlyphBatch) {
        let L = g.L
        let color = (cell.formatColor ?? st.font.color).map(SheetText.cg) ?? black
        let pad = SheetLayout.padding
        let indent = Double(st.indent) * (L.sheet.maxDigitWidth + 3) * 0.75
        var align = st.hAlign
        if align == .general {
            switch cell.kind {
            case .number: align = .right
            case .bool, .error: align = .center
            case .text: align = .left
            }
        }
        let wraps = st.wrap || st.hAlign == .justify || st.hAlign == .distributed
        if st.rotation != 0 || wraps {
            flush(&batch)
            ctx.saveGState()
            if merged { ctx.clip(to: R(g.cs.origin, g.rs.origin, g.x(g.cs.last + 1) - g.cs.origin, g.y(g.rs.last + 1) - g.rs.origin)) }
            if st.rotation != 0 {
                drawRotated(cell, style: st, color: color, x: x, y: y, w: w, h: h)
            } else {
                drawWrapped(cell, style: st, color: color, align: align == .justify ? .left : (align == .distributed ? .center : align),
                            x: x + indent * (align == .right ? 0 : 1), y: y, w: max(w - indent, 1), h: h)
            }
            ctx.restoreGState()
            return
        }

        // One line.
        var text = SheetText.singleLine(cell.text)
        var font = st.font
        let face0 = SheetFace.face(font)
        let simple = cell.runs == nil
        var width = (simple ? face0.simpleWidth(text) : nil) ?? Double(lineWidth(SheetText.attributed(cell, style: st, color: color)))
        let inner = w - 2 * pad - indent
        var shrunk = 1.0
        if st.shrink, width > inner, inner > 0 {
            shrunk = max(inner / width, 0.2)
        } else if cell.kind == .number, width > inner, !merged {
            // A number that does not fit is made smaller (down to 60 %), else shown as ####, as Excel does.
            let f = inner / width
            if f >= 0.6 { shrunk = (f * 20).rounded(.down) / 20 } else {
                let hash = face0.simpleWidth("#") ?? font.size * 0.55
                text = String(repeating: "#", count: max(1, Int(inner / hash)))
                width = Double(text.count) * hash
            }
        }
        if shrunk < 1 { font.size = (font.size * shrunk * 4).rounded(.down) / 4; width *= shrunk }
        if align == .fill, width > 0, inner > width {
            text = String(repeating: text, count: max(1, Int(inner / width)))
            width *= Double(Int(inner / (width)))
            align = .left
        }

        // Where the text may go: its cell, or empty neighbours it overflows into (text only, not in merges).
        var left = x, right = x + w
        if align == .centerContinuous {
            var c2 = c + 1
            while c2 <= g.cs.last, isEmptyCell(L, r, c2), L.sheet.style(r, c2).hAlign == .centerContinuous { right = g.x(c2 + 1); c2 += 1 }
            align = .center
        }
        let overflow = width > inner && !merged && cell.kind == .text
        if overflow {
            if align == .left || align == .center {
                var c2 = c + 1
                while c2 <= g.cs.last, isEmptyCell(L, r, c2) {
                    right = g.x(c2 + 1)
                    if right - x - pad - indent >= (align == .center ? (width + w) / 2 + pad : width) { break }
                    c2 += 1
                }
                // Past the last printed column: on into the free space up to the printable edge, when nothing
                // further right in the row has a value.
                if align == .left, c2 > g.cs.last, let edge = g.overflowEdge, edge > right, emptyBeyond(L, r, g.cs.last) {
                    right = edge
                }
            }
            if align == .right || align == .center {
                var c2 = c - 1
                while c2 >= g.cs.first, isEmptyCell(L, r, c2) {
                    left = g.x(c2)
                    if x + w - left - pad >= (align == .center ? (width + w) / 2 + pad : width) { break }
                    c2 -= 1
                }
            }
        }
        var tx: Double
        switch align {
        case .right: tx = x + w - pad - indent - width
        case .center: tx = (align == .center && st.hAlign == .centerContinuous) ? (left + right) / 2 - width / 2 : x + w / 2 - width / 2
        default: tx = x + pad + indent
        }
        if st.hAlign == .centerContinuous { tx = (left + right) / 2 - width / 2 }
        let face = shrunk < 1 ? SheetFace.face(font) : face0
        let lh = SheetFonts.lineHeight(font)
        let asc = Double(face.ascent), desc = Double(face.descent)
        let boxTop: Double
        switch st.vAlign {
        case .top: boxTop = y + 0.5
        case .center, .justify, .distributed: boxTop = y + (h - lh) / 2
        case .bottom: boxTop = y + h - lh - 0.5
        }
        let baseline = boxTop + (lh - (asc + desc)) / 2 + asc
        var needsClip = tx < left - 0.01 || tx + width > right + 0.01 || lh > h + 1
        var clip = R(left, y, right - left, h)
        if merged {
            // A block reaching past this page's area is cut at the area's edge.
            let area = R(g.cs.origin, g.rs.origin, g.x(g.cs.last + 1) - g.cs.origin, g.y(g.rs.last + 1) - g.rs.origin)
            if !area.contains(clip) { clip = clip.intersection(area); needsClip = true }
        }

        if simple && !needsClip && font.baseline == .normal, face.append(text, x: tx, y: -baseline, to: &batch, color: color) {
            decorate(font, face: face, x: tx, width: width, baseline: baseline, color: color)
            return
        }
        // CoreText for rich text, fallback fonts and text that must be cut at the cell edge. What is batched so far
        // goes first, so the PDF keeps the cells in reading order.
        flush(&batch)
        var c2 = cell
        c2.text = text
        if c2.runs != nil { c2.runs = c2.runs!.map { SheetRun(text: SheetText.singleLine($0.text), font: $0.font) } }
        let attr = NSMutableAttributedString(attributedString: SheetText.attributed(c2, style: st, color: color, sizeScale: CGFloat(shrunk < 1 ? font.size / st.font.size : 1)))
        // A space after the value keeps neighbouring cells apart in copied text (it draws nothing).
        if attr.length > 0 { attr.append(NSAttributedString(string: " ", attributes: attr.attributes(at: attr.length - 1, effectiveRange: nil))) }
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        if needsClip { ctx.clip(to: clip) }
        ctx.textPosition = CGPoint(x: tx, y: -baseline)
        CTLineDraw(line, ctx)
        ctx.textMatrix = .identity
        ctx.restoreGState()
        if let runs = c2.runs {
            var rx = tx
            for run in runs {
                let rw = Double(lineWidth(SheetFonts.attributed([(run.text, run.font, color)])))
                decorate(run.font, face: SheetFace.face(run.font), x: rx, width: rw, baseline: baseline, color: run.font.color.map(SheetText.cg) ?? color, clip: needsClip ? clip : nil)
                rx += rw
            }
        } else {
            decorate(font, face: face, x: tx, width: width, baseline: baseline, color: color, clip: needsClip ? clip : nil)
        }
    }

    private func lineWidth(_ a: NSAttributedString) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(a), nil, nil, nil))
    }

    /// Underline / double underline / strike-through as thin rectangles (CoreText does not draw them).
    private func decorate(_ f: SheetFont, face: SheetFace, x: Double, width: Double, baseline: Double, color: CGColor, clip: CGRect? = nil) {
        guard f.underline > 0 || f.strike, width > 0 else { return }
        let thick = max(0.5, f.size / 16)
        var rects: [CGRect] = []
        if f.underline > 0 {
            let uy = baseline + max(1, f.size * 0.11)
            rects.append(R(x, uy, width, thick))
            if f.underline == 2 { rects.append(R(x, uy + thick * 2, width, thick)) }
        }
        if f.strike { rects.append(R(x, baseline - f.size * 0.3, width, thick)) }
        for var rc in rects {
            if let clip { rc = rc.intersection(clip); if rc.isNull { continue } }
            decorations.append((rc, color))
        }
    }

    func drawWrapped(_ cell: SheetCell, style st: SheetCellStyle, color: CGColor, align: SheetHAlign, x: Double, y: Double, w: Double, h: Double) {
        let pad = SheetLayout.padding
        let attr = NSMutableAttributedString(attributedString: SheetText.attributed(cell, style: st, color: color))
        // A trailing space (it hangs at the end of the last line) keeps the next cell apart in copied text.
        if attr.length > 0, !attr.string.hasSuffix("\n"), !attr.string.hasSuffix("\r") {
            attr.append(NSAttributedString(string: " ", attributes: attr.attributes(at: attr.length - 1, effectiveRange: nil)))
        }
        let inner = max(w - 2 * pad, 1)
        let lines = SheetText.lines(attr, width: inner)
        guard !lines.isEmpty else { return }
        let fonts = cell.runs?.map(\.font) ?? [st.font]
        let lh = fonts.map(SheetFonts.lineHeight).max() ?? SheetFonts.lineHeight(st.font)
        let blockH = Double(lines.count) * lh
        var top: Double
        switch st.vAlign {
        case .top, .justify: top = y + 0.5
        case .center, .distributed: top = y + (h - blockH) / 2
        case .bottom: top = y + h - blockH - 0.5
        }
        // Too tall for the cell: the first lines show and the last are lost, as in Excel.
        if blockH > h - 0.5 { top = y + 0.5 }
        let pending = decorations
        decorations = []
        ctx.saveGState()
        ctx.clip(to: R(x, y, w, h))
        for (i, line) in lines.enumerated() {
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let lw = Double(CTLineGetTypographicBounds(line, &a, &d, &l)) - Double(CTLineGetTrailingWhitespaceWidth(line))
            let tx: Double
            switch align {
            case .right: tx = x + w - pad - lw
            case .center, .centerContinuous: tx = x + w / 2 - lw / 2
            default: tx = x + pad
            }
            let lineTop = top + Double(i) * lh
            let baseline = lineTop + (lh - Double(a + d)) / 2 + Double(a)
            // Only whole lines are drawn (the first always), so no line shows its top sliver and the PDF holds no
            // text that cannot be seen.
            if i > 0, baseline + Double(d) > y + h + 0.5 { break }
            ctx.textPosition = CGPoint(x: tx, y: -baseline)
            CTLineDraw(line, ctx)
            ctx.textMatrix = .identity
            if cell.runs == nil { decorate(st.font, face: SheetFace.face(st.font), x: tx, width: lw, baseline: baseline, color: color) }
        }
        ctx.restoreGState()
        for (rect, c) in decorations { let clipped = rect.intersection(R(x, y, w, h)); if !clipped.isNull { ctx.setFillColor(c); ctx.fill(clipped) } }
        decorations = pending
    }

    func drawRotated(_ cell: SheetCell, style st: SheetCellStyle, color: CGColor, x: Double, y: Double, w: Double, h: Double) {
        let pad = SheetLayout.padding
        ctx.saveGState()
        ctx.clip(to: R(x, y, w, h))
        if st.rotation == 255 {
            // Stacked: one character under the other.
            let lh = SheetFonts.lineHeight(st.font)
            let chars = Array(SheetText.singleLine(cell.text))
            let blockH = Double(chars.count) * lh
            var top = st.vAlign == .top ? y + pad : (st.vAlign == .bottom ? y + h - blockH - pad : y + (h - blockH) / 2)
            if blockH > h { top = y + pad }
            for (i, ch) in chars.enumerated() {
                let line = CTLineCreateWithAttributedString(SheetFonts.attributed([(String(ch), st.font, color)]))
                var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
                let lw = Double(CTLineGetTypographicBounds(line, &a, &d, &l))
                let baseline = top + Double(i) * lh + (lh - Double(a + d)) / 2 + Double(a)
                ctx.textPosition = CGPoint(x: x + w / 2 - lw / 2, y: -baseline)
                CTLineDraw(line, ctx)
                ctx.textMatrix = .identity
            }
        } else {
            var c2 = cell
            c2.text = SheetText.singleLine(cell.text)
            let line = CTLineCreateWithAttributedString(SheetText.attributed(c2, style: st, color: color))
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let lw = Double(CTLineGetTypographicBounds(line, &a, &d, &l))
            let angle = Double(st.rotation) * .pi / 180
            var anchor = CGPoint(x: x + w / 2, y: -(y + h / 2))
            var start = -lw / 2
            if st.rotation == 90 || st.rotation == -90 {
                let up = st.rotation == 90
                switch st.vAlign {
                case .bottom: anchor.y = -(y + h - pad); start = up ? 0 : -lw
                case .top: anchor.y = -(y + pad); start = up ? -lw : 0
                default: break
                }
            }
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: angle)
            ctx.textPosition = CGPoint(x: start, y: -Double(a - d) / 2)
            CTLineDraw(line, ctx)
            ctx.textMatrix = .identity
        }
        ctx.restoreGState()
    }

    // MARK: Borders

    struct Edge: Hashable { let horizontal: Bool; let r: Int; let c: Int }

    func drawBorders(_ g: Geometry) {
        let L = g.L, s = L.sheet
        let bordered = s.styles.map { !$0.borders.isEmpty }
        guard bordered.contains(true) else { return }
        var edges: [Edge: SheetBorderLine] = [:]
        var diagonals: [(SheetBorderLine, CGPoint, CGPoint)] = []
        func put(_ e: Edge, _ line: SheetBorderLine?) {
            guard let line else { return }
            if let old = edges[e], old.style.weight >= line.style.weight { return }
            edges[e] = line
        }
        // One cell beyond the area on each side, for the neighbour's half of a shared edge.
        let rows = max(0, g.rs.first - 1)...(g.rs.last + 1)
        let cols = max(0, g.cs.first - 1)...(g.cs.last + 1)
        for r in rows where L.height(r) > 0 || r == g.rs.first - 1 || r == g.rs.last + 1 {
            for c in cols {
                let si = s.styleIndex(r, c)
                guard si < bordered.count, bordered[si] else { continue }
                let b = s.styles[si].borders
                let m = L.mergeAt[SheetLayout.key(r, c)]
                let inRows = g.rows.contains(r), inCols = g.cols.contains(c)
                // Edges inside a merged block are not drawn.
                func sameMerge(_ r2: Int, _ c2: Int) -> Bool { m != nil && L.mergeAt[SheetLayout.key(r2, c2)] == m }
                if inRows && inCols {
                    if !sameMerge(r - 1, c) { put(Edge(horizontal: true, r: r, c: c), b.top) }
                    if !sameMerge(r + 1, c) { put(Edge(horizontal: true, r: r + 1, c: c), b.bottom) }
                    if !sameMerge(r, c - 1) { put(Edge(horizontal: false, r: r, c: c), b.left) }
                    if !sameMerge(r, c + 1) { put(Edge(horizontal: false, r: r, c: c + 1), b.right) }
                    if let d = b.diagonalDown { diagonals.append((d, CGPoint(x: g.x(c), y: g.y(r)), CGPoint(x: g.x(c + 1), y: g.y(r + 1)))) }
                    if let d = b.diagonalUp { diagonals.append((d, CGPoint(x: g.x(c), y: g.y(r + 1)), CGPoint(x: g.x(c + 1), y: g.y(r)))) }
                } else if inCols && r == g.rs.first - 1 {
                    put(Edge(horizontal: true, r: r + 1, c: c), b.bottom)
                } else if inCols && r == g.rs.last + 1 {
                    put(Edge(horizontal: true, r: r, c: c), b.top)
                } else if inRows && c == g.cs.first - 1 {
                    put(Edge(horizontal: false, r: r, c: c + 1), b.right)
                } else if inRows && c == g.cs.last + 1 {
                    put(Edge(horizontal: false, r: r, c: c), b.left)
                }
            }
        }
        // Group by look and draw.
        struct Look: Hashable { let style: SheetBorderStyle; let color: DocColor? }
        var paths: [Look: CGMutablePath] = [:]
        for (e, line) in edges {
            let look = Look(style: line.style, color: line.color)
            let path = paths[look] ?? CGMutablePath()
            if e.horizontal {
                guard L.width(e.c) > 0 else { continue }
                let y = g.y(e.r), x0 = g.x(e.c), x1 = g.x(e.c + 1)
                add(path, line.style, from: CGPoint(x: x0, y: -y), to: CGPoint(x: x1, y: -y), horizontal: true)
            } else {
                guard L.height(e.r) > 0 else { continue }
                let x = g.x(e.c), y0 = g.y(e.r), y1 = g.y(e.r + 1)
                add(path, line.style, from: CGPoint(x: x, y: -y0), to: CGPoint(x: x, y: -y1), horizontal: false)
            }
            paths[look] = path
        }
        for (d, a, b) in diagonals {
            let look = Look(style: d.style, color: d.color)
            let path = paths[look] ?? CGMutablePath()
            path.move(to: CGPoint(x: a.x, y: -a.y)); path.addLine(to: CGPoint(x: b.x, y: -b.y))
            paths[look] = path
        }
        for (look, path) in paths {
            ctx.saveGState()
            ctx.setStrokeColor(look.color.map(SheetText.cg) ?? black)
            let (width, dash) = SheetPainter.lineLook(look.style)
            ctx.setLineWidth(width)
            if dash.isEmpty { ctx.setLineCap(.square) } else { ctx.setLineDash(phase: 0, lengths: dash) }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func add(_ path: CGMutablePath, _ style: SheetBorderStyle, from a: CGPoint, to b: CGPoint, horizontal: Bool) {
        if style == .double {
            let off: CGFloat = 0.75
            let dx: CGFloat = horizontal ? 0 : off, dy: CGFloat = horizontal ? off : 0
            path.move(to: CGPoint(x: a.x - dx, y: a.y - dy)); path.addLine(to: CGPoint(x: b.x - dx, y: b.y - dy))
            path.move(to: CGPoint(x: a.x + dx, y: a.y + dy)); path.addLine(to: CGPoint(x: b.x + dx, y: b.y + dy))
        } else {
            path.move(to: a); path.addLine(to: b)
        }
    }

    /// Line width and dash pattern of each Excel border style, in points.
    static func lineLook(_ s: SheetBorderStyle) -> (CGFloat, [CGFloat]) {
        switch s {
        case .hair: return (0.25, [])
        case .thin: return (0.5, [])
        case .medium: return (1.0, [])
        case .thick: return (1.5, [])
        case .double: return (0.4, [])
        case .dotted: return (0.5, [0.5, 1])
        case .dashed: return (0.5, [2.5, 1.5])
        case .mediumDashed: return (1.0, [4, 2])
        case .dashDot: return (0.5, [3, 1.5, 1, 1.5])
        case .mediumDashDot, .slantDashDot: return (1.0, [4, 2, 1.5, 2])
        case .dashDotDot: return (0.5, [3, 1.5, 1, 1.5, 1, 1.5])
        case .mediumDashDotDot: return (1.0, [4, 2, 1.5, 2, 1.5, 2])
        }
    }

    // MARK: Pictures, charts, shapes

    func anchorRect(_ a: SheetAnchor, _ L: SheetLayout) -> (x: Double, y: Double, w: Double, h: Double) {
        if let p = a.absolute, let s = a.size { return (Double(p.x), Double(p.y), Double(s.width), Double(s.height)) }
        let x0 = L.x(a.fromCol) + min(a.fromColOffset, L.width(a.fromCol))
        let y0 = L.y(a.fromRow) + min(a.fromRowOffset, L.height(a.fromRow))
        if let tc = a.toCol, let tr = a.toRow {
            let x1 = L.x(tc) + min(a.toColOffset, L.width(tc)), y1 = L.y(tr) + min(a.toRowOffset, L.height(tr))
            return (x0, y0, max(0, x1 - x0), max(0, y1 - y0))
        }
        let s = a.size ?? .zero
        return (x0, y0, Double(s.width), Double(s.height))
    }

    func drawDrawings(_ g: Geometry) {
        let L = g.L, s = L.sheet
        for (i, d) in s.drawings.enumerated() {
            let a = anchorRect(d.anchor, L)
            guard a.w > 0.5, a.h > 0.5 else { continue }
            // Sheet position -> page position for this segment.
            let x = g.cs.origin + a.x - L.x(g.cs.first), y = g.rs.origin + a.y - L.y(g.rs.first)
            let rect = R(x, y, a.w, a.h)
            guard rect.intersects(ctx.boundingBoxOfClipPath) else { continue }
            switch d.content {
            case .picture(let data):
                let key = "\(ObjectIdentifier(s).hashValue)-\(i)"
                var img = images[key]
                if img == nil, let src = CGImageSourceCreateWithData(data as CFData, nil), let im = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    img = im; images[key] = im
                }
                if let img {
                    ctx.saveGState()
                    ctx.interpolationQuality = .high
                    ctx.draw(img, in: rect)
                    ctx.restoreGState()
                }
            case .chart(let chart):
                SheetChartPainter(ctx: ctx).draw(chart, in: rect)
            case .shape(let fill, let line, let text):
                ctx.saveGState()
                if let fill { ctx.setFillColor(SheetText.cg(fill)); ctx.fill(rect) }
                if let line { ctx.setStrokeColor(SheetText.cg(line)); ctx.setLineWidth(0.75); ctx.stroke(rect) }
                if !text.isEmpty {
                    var cell = SheetCell(text: text)
                    cell.kind = .text
                    var st = SheetCellStyle()
                    st.font = SheetFont(name: nil, size: 11)
                    st.hAlign = .center; st.vAlign = .center; st.wrap = true
                    drawWrapped(cell, style: st, color: black, align: .center, x: x, y: y, w: a.w, h: a.h)
                }
                ctx.restoreGState()
            case .unsupported:
                break
            }
        }
    }

    // MARK: Headings

    func drawHeadings(_ p: SheetPrinter.PagePlan) {
        let L = p.layout
        let headingH = L.sheet.defaultRowHeight
        let headingW = (p.cols.first?.origin ?? 0)
        let font = SheetFont(name: nil, size: 9)
        let grey = CGColor(gray: 0.35, alpha: 1)
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        ctx.setLineWidth(0.4)
        var batch = GlyphBatch()
        let face = SheetFace.face(font)
        for cs in p.cols {
            for c in cs.first...cs.last where L.width(c) > 0 {
                let x = cs.origin + L.x(c) - L.x(cs.first)
                ctx.stroke(R(x, 0, L.width(c), headingH))
                let label = XlsxWriter.columnName(c)
                let w = face.simpleWidth(label) ?? 8
                _ = face.append(label, x: x + L.width(c) / 2 - w / 2, y: -(headingH / 2 + 3), to: &batch, color: grey)
            }
        }
        for rs in p.rows {
            for r in rs.first...rs.last where L.height(r) > 0 {
                let y = rs.origin + L.y(r) - L.y(rs.first)
                ctx.stroke(R(0, y, headingW, L.height(r)))
                let label = String(r + 1)
                let w = face.simpleWidth(label) ?? 8
                _ = face.append(label, x: headingW / 2 - w / 2, y: -(y + L.height(r) / 2 + 3), to: &batch, color: grey)
            }
        }
        batch.flush(ctx)
        ctx.restoreGState()
    }

    // MARK: Header and footer

    func drawHeaderFooter(_ p: SheetPrinter.PagePlan, number: Int) {
        let setup = p.layout.sheet.pageSetup
        let first = p.pageIndexInSheet == 0
        let even = number % 2 == 0
        func pick(_ odd: String?, _ evenText: String?, _ firstText: String?) -> String? {
            if setup.differentFirst && first { return firstText }
            if setup.differentOddEven && even { return evenText }
            return odd
        }
        let pageNumber = (setup.firstPageNumber.map { $0 - 1 } ?? 0) + number
        let scale = setup.scaleWithDoc ? p.scale : 1
        let left = setup.alignWithMargins ? p.margins[0] : 0.5 * 72
        let right = Double(p.paper.width) - (setup.alignWithMargins ? p.margins[1] : 0.5 * 72)
        if let h = pick(setup.oddHeader, setup.evenHeader, setup.firstHeader), !h.isEmpty {
            drawHeaderFooterText(h, top: p.margins[4], fromBottom: false, left: left, right: right, paper: p.paper, page: pageNumber, sheet: p.layout.sheet.name, scale: scale)
        }
        if let f = pick(setup.oddFooter, setup.evenFooter, setup.firstFooter), !f.isEmpty {
            drawHeaderFooterText(f, top: p.margins[5], fromBottom: true, left: left, right: right, paper: p.paper, page: pageNumber, sheet: p.layout.sheet.name, scale: scale)
        }
    }

    /// Excel header / footer codes: &L &C &R sections, &P page, &N pages, &D date, &T time, &F file, &A sheet,
    /// &"font,style", &nn size, &B &I &U &S toggles, && ampersand. Pictures (&G) are not drawn.
    func drawHeaderFooterText(_ code: String, top: Double, fromBottom: Bool, left: Double, right: Double, paper: CGSize,
                              page: Int, sheet: String, scale: Double) {
        var sections: [Character: [(String, SheetFont)]] = ["L": [], "C": [], "R": []]
        var current: Character = "C"
        var font = SheetFont(name: nil, size: 11)
        var text = ""
        func push() { if !text.isEmpty { sections[current, default: []].append((text, font)); text = "" } }
        let chars = Array(code)
        var i = 0
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        while i < chars.count {
            let ch = chars[i]
            guard ch == "&", i + 1 < chars.count else { text.append(ch); i += 1; continue }
            let n = chars[i + 1]
            i += 2
            switch n {
            case "L", "C", "R": push(); current = n
            case "P": text += String(page)
            case "N": text += String(total)
            case "D": df.dateFormat = "yyyy/MM/dd"; text += df.string(from: date)
            case "T": df.dateFormat = "H:mm"; text += df.string(from: date)
            case "F": text += fileName
            case "A": text += sheet
            case "Z": break
            case "G": break
            case "&": text += "&"
            case "B": push(); font.bold.toggle()
            case "I": push(); font.italic.toggle()
            case "U", "E": push(); font.underline = font.underline == 0 ? 1 : 0
            case "S": push(); font.strike.toggle()
            case "\"":
                push()
                var spec = ""
                while i < chars.count, chars[i] != "\"" { spec.append(chars[i]); i += 1 }
                i += 1
                let parts = spec.split(separator: ",", maxSplits: 1).map(String.init)
                if let name = parts.first, name != "-" { font.name = name }
                let styleName = parts.count > 1 ? parts[1].lowercased() : ""
                font.bold = styleName.contains("bold") || styleName.contains("太字")
                font.italic = styleName.contains("italic") || styleName.contains("斜体")
            case "K":
                push()
                let hex = String(chars[i..<min(i + 6, chars.count)])
                font.color = DocColor(hex: hex)
                i = min(i + 6, chars.count)
            default:
                if n.isNumber {
                    push()
                    var digits = String(n)
                    while i < chars.count, chars[i].isNumber { digits.append(chars[i]); i += 1 }
                    if let v = Double(digits), v >= 1, v <= 409 { font.size = v }
                } else {
                    text.append(n)
                }
            }
        }
        push()
        for (key, runs) in sections where !runs.isEmpty {
            let attr = SheetFonts.attributed(runs.map { ($0.0, $0.1, $0.1.color.map(SheetText.cg) ?? black) }, sizeScale: CGFloat(scale))
            // One line per text line.
            let lines = attr.string.components(separatedBy: "\n")
            var loc = 0
            let lineH = (runs.map { SheetFonts.lineHeight($0.1) }.max() ?? 15) * scale
            for (k, l) in lines.enumerated() {
                let len = (l as NSString).length
                let sub = attr.attributedSubstring(from: NSRange(location: loc, length: len))
                loc += len + 1
                let line = CTLineCreateWithAttributedString(sub)
                var a: CGFloat = 0, d: CGFloat = 0, lead: CGFloat = 0
                let w = Double(CTLineGetTypographicBounds(line, &a, &d, &lead))
                let x: Double
                switch key {
                case "L": x = left
                case "R": x = right - w
                default: x = Double(paper.width) / 2 - w / 2
                }
                let baselineFromTop: Double
                if fromBottom {
                    let n = Double(lines.count - 1 - k)
                    baselineFromTop = Double(paper.height) - top - Double(d) - n * lineH
                } else {
                    baselineFromTop = top + Double(a) + Double(k) * lineH
                }
                ctx.textPosition = CGPoint(x: x, y: Double(paper.height) - baselineFromTop)
                CTLineDraw(line, ctx)
                ctx.textMatrix = .identity
            }
        }
    }
}
