import Foundation
import CoreText
import CoreGraphics
import ImageIO
import EnsoDoc

/// Prints sheets to PDF the way Excel prints them: the file's page setup (paper, orientation, scale or fit to
/// pages, margins, print area, print titles, manual breaks, centring, gridlines, headers and footers), column widths
/// and row heights, merged cells, fills, borders, fonts, alignment, overflowing and wrapped text, pictures and
/// charts. Text is real text. A sheet without its own print setup (landscape, a scale, fit to pages) is laid out
/// automatically: portrait at 100 %, portrait shrunk to the width down to 80 %, landscape at 100 %, landscape shrunk
/// down to the size where 11 pt text prints at 6.5 pt; past that its columns continue on further pages, down then
/// over.
public enum SheetPrinter {

    public struct Output {
        public let data: Data
        public let pageCount: Int
        /// Sheets printed, with the page each starts on (1-based).
        public let sheetPages: [(name: String, firstPage: Int, pages: Int)]
        /// What the files contain that is not drawn, per sheet ("グラフ: conditional formatting").
        public let notDrawn: [String]
        /// Per page: paper size in points.
        public let pageSizes: [CGSize]
    }

    /// Lowest print scale reached by shrinking on our own: 11 pt text stays at least 6.5 pt.
    static func minimumScale(_ defaultFont: SheetFont) -> Double { min(1, 6.5 / max(defaultFont.size, 1)) }

    public static func pdf(_ wb: PrintWorkbook, title: String?, fileName: String, date: Date = Date(),
                           cancelled: () -> Bool = { false }) -> Output? {
        // Plan every page first: headers and footers need the total.
        var plans: [PagePlan] = []
        var sheetPages: [(name: String, firstPage: Int, pages: Int)] = []
        var notDrawn: [String] = []
        for sheet in wb.sheets {
            if cancelled() { return nil }
            for n in sheet.notDrawn { notDrawn.append("\(sheet.name): \(n)") }
            let pages = plan(sheet, defaultFont: wb.defaultFont)
            if !pages.isEmpty { sheetPages.append((sheet.name, plans.count + 1, pages.count)) }
            plans += pages
        }
        guard !plans.isEmpty else { return nil }

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: plans[0].paper)
        var info: [CFString: Any] = [kCGPDFContextCreator: "MaruDoc"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return nil }
        let painter = SheetPainter(ctx: ctx, fileName: fileName, date: date, total: plans.count)
        for (i, page) in plans.enumerated() {
            if cancelled() { ctx.closePDF(); return nil }
            var box = CGRect(origin: .zero, size: page.paper)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            painter.draw(page, number: i + 1)
            ctx.endPDFPage()
        }
        // One bookmark per sheet.
        if sheetPages.count > 1 {
            let children = sheetPages.map { ["Title": $0.name, "Destination": $0.firstPage] as [String: Any] }
            CGPDFContextSetOutline(ctx, ["Children": children] as CFDictionary)
        }
        ctx.closePDF()
        return Output(data: data as Data, pageCount: plans.count, sheetPages: sheetPages, notDrawn: notDrawn, pageSizes: plans.map(\.paper))
    }

    // MARK: Paper

    /// ECMA-376 paper sizes in millimetres (the common ones).
    static let papers: [Int: (Double, Double)] = [
        1: (215.9, 279.4), 2: (215.9, 279.4), 3: (279.4, 431.8), 4: (431.8, 279.4), 5: (215.9, 355.6), 6: (139.7, 215.9),
        7: (184.15, 266.7), 8: (297, 420), 9: (210, 297), 10: (210, 297), 11: (148, 210), 12: (250, 353), 13: (176, 250),
        14: (215.9, 330.2), 15: (215, 275), 16: (254, 355.6), 17: (279.4, 431.8), 18: (215.9, 279.4), 19: (98.4, 225.4),
        20: (104.8, 241.3), 21: (114.3, 263.5), 22: (120.7, 279.4), 23: (127, 292.1), 24: (431.8, 558.8), 25: (558.8, 863.6),
        26: (863.6, 1117.6), 27: (110, 220), 28: (162, 229), 29: (324, 458), 30: (229, 324), 31: (114, 162), 32: (114, 229),
        33: (250, 353), 34: (176, 250), 35: (176, 125), 36: (110, 230), 37: (98.4, 190.5), 38: (92.1, 165.1),
        39: (377.8, 279.4), 40: (215.9, 304.8), 41: (215.9, 330.2), 42: (250, 353), 43: (100, 148), 66: (420, 594),
        67: (297, 420), 70: (105, 148), 119: (257, 364),
    ]

    static func paperSize(_ setup: SheetPageSetup) -> CGSize {
        if let mm = setup.paperSizeMM, mm.width > 20, mm.height > 20, mm.width < 5000, mm.height < 5000 {
            return CGSize(width: mm.width / 25.4 * 72, height: mm.height / 25.4 * 72)
        }
        let mm = setup.paperSize.flatMap { papers[$0] } ?? (210, 297)
        return CGSize(width: mm.0 / 25.4 * 72, height: mm.1 / 25.4 * 72)
    }

    // MARK: Planning

    struct Segment { var first: Int; var last: Int; var origin: Double }

    struct PagePlan {
        let layout: SheetLayout
        let paper: CGSize
        /// left, right, top, bottom, header, footer (points).
        let margins: [Double]
        let scale: Double
        /// Row segments (print titles, then the band) and column segments, each placed at an offset on the page.
        let rows: [Segment]
        let cols: [Segment]
        /// Where the sheet area starts on the page (top-left, points), centring included.
        let origin: CGPoint
        let headings: Bool
        let pageIndexInSheet: Int
        /// The page holds the area's last columns: text may overflow into the free space to their right, up to
        /// the printable edge (in sheet points from the page's origin), as Excel prints it.
        var overflowEdge: Double? = nil
    }

    /// The cells that print when there is no print area: every cell with a value, plus merged blocks, fills and
    /// borders that touch them, plus pictures and charts. A sheet with only formatting prints that formatting.
    static func usedRange(_ s: PrintSheet, layoutHint: SheetLayout? = nil) -> SheetRange? {
        var r0 = Int.max, c0 = Int.max, r1 = -1, c1 = -1
        var styled: [(Int, Int)] = []
        let decorated = s.styles.map { $0.fill != nil || !$0.borders.isEmpty }
        for (r, row) in s.cells.enumerated() {
            for (c, cell) in row.enumerated() {
                guard let cell else { continue }
                if !cell.text.isEmpty {
                    if r < r0 { r0 = r }; if r > r1 { r1 = r }
                    if c < c0 { c0 = c }; if c > c1 { c1 = c }
                } else if cell.style < decorated.count, decorated[cell.style] {
                    styled.append((r, c))
                }
            }
        }
        // Pictures and charts count as content.
        for d in s.drawings {
            let a = d.anchor
            let fromR = a.fromRow, fromC = a.fromCol
            var toR = a.toRow ?? fromR, toC = a.toCol ?? fromC
            if a.toRow == nil, let size = a.size {
                // Walk the rows / columns the picture covers.
                var h = Double(size.height) + a.fromRowOffset, w = Double(size.width) + a.fromColOffset
                toR = fromR
                while h > 0 && toR < fromR + 5000 { h -= s.isHiddenRow(toR) ? 0 : (s.rowHeights[toR] ?? s.defaultRowHeight); if h > 0 { toR += 1 } }
                toC = fromC
                while w > 0 && toC < fromC + 2000 { w -= s.columnWidth(toC); if w > 0 { toC += 1 } }
            }
            if a.absolute != nil { r0 = min(r0, 0); c0 = min(c0, 0) }
            r0 = min(r0, fromR); c0 = min(c0, fromC); r1 = max(r1, toR); c1 = max(c1, toC)
        }
        if r1 < 0 {
            // Only formatting: print the formatted block (a blank form).
            guard !styled.isEmpty else { return nil }
            for (r, c) in styled { r0 = min(r0, r); r1 = max(r1, r); c0 = min(c0, c); c1 = max(c1, c) }
            return SheetRange(r0: r0, c0: c0, r1: r1, c1: c1)
        }
        // Grow by merged blocks and decorated cells touching the range, until nothing more touches it.
        var changed = true
        var passes = 0
        while changed && passes < 64 {
            changed = false
            passes += 1
            for m in s.merges where m.r0 <= r1 + 1 && m.r1 >= r0 - 1 && m.c0 <= c1 + 1 && m.c1 >= c0 - 1 {
                // A merge counts when it overlaps or when its top-left cell holds a value inside.
                let overlaps = m.r0 <= r1 && m.r1 >= r0 && m.c0 <= c1 && m.c1 >= c0
                if !overlaps { continue }
                if m.r0 < r0 { r0 = m.r0; changed = true }; if m.r1 > r1 { r1 = min(m.r1, r1 + 1000); changed = true }
                if m.c0 < c0 { c0 = m.c0; changed = true }; if m.c1 > c1 { c1 = min(m.c1, c1 + 100); changed = true }
            }
            for (r, c) in styled where r >= r0 - 1 && r <= r1 + 1 && c >= c0 - 1 && c <= c1 + 1 {
                if r < r0 { r0 = r; changed = true }; if r > r1 { r1 = r; changed = true }
                if c < c0 { c0 = c; changed = true }; if c > c1 { c1 = c; changed = true }
            }
        }
        return SheetRange(r0: r0, c0: c0, r1: r1, c1: c1)
    }

    static func plan(_ s: PrintSheet, defaultFont: SheetFont) -> [PagePlan] {
        guard let used = usedRange(s) else { return [] }
        var areas: [SheetRange] = []
        if s.pageSetup.printAreas.isEmpty {
            areas = [used]
        } else {
            // Print areas as given, with whole rows / columns cut to what is used.
            for a in s.pageSetup.printAreas {
                var r = a
                if r.r1 >= XlsxWriter.maxRows - 1 { r.r1 = max(r.r0, used.r1) }
                if r.c1 >= XlsxWriter.maxColumns - 1 { r.c1 = max(r.c0, used.c1) }
                areas.append(r)
            }
        }
        var lastRow = areas.map(\.r1).max() ?? 0, lastCol = areas.map(\.c1).max() ?? 0
        if let t = s.pageSetup.titleRows { lastRow = max(lastRow, min(t.upperBound, lastRow + 100)) }
        if let t = s.pageSetup.titleColumns { lastCol = max(lastCol, min(t.upperBound, lastCol + 50)) }
        let layout = SheetLayout(s, lastRow: lastRow, lastCol: lastCol)
        var pages: [PagePlan] = []
        for area in areas { pages += plan(area, layout: layout, defaultFont: defaultFont, startIndex: pages.count) }
        return pages
    }

    static func plan(_ area: SheetRange, layout L: SheetLayout, defaultFont: SheetFont, startIndex: Int) -> [PagePlan] {
        let s = L.sheet
        let setup = s.pageSetup
        let visibleCols = (area.c0...area.c1).filter { L.width($0) > 0 }
        let visibleRows = (area.r0...area.r1).filter { L.height($0) > 0 }
        guard !visibleCols.isEmpty, !visibleRows.isEmpty else { return [] }
        let m = (setup.margins ?? [0.7, 0.7, 0.75, 0.75, 0.3, 0.3]).map { $0 * 72 }
        var paper = paperSize(setup)
        if setup.orientation == "landscape" { paper = CGSize(width: max(paper.width, paper.height), height: min(paper.width, paper.height)) }
        else { paper = CGSize(width: min(paper.width, paper.height), height: max(paper.width, paper.height)) }

        let headingW = setup.headings ? max(20, Double(String(area.r1 + 1).count) * 7 + 8) : 0
        let headingH = setup.headings ? s.defaultRowHeight : 0
        let totalW = L.x(area.c1 + 1) - L.x(area.c0) + headingW
        let totalH = L.y(area.r1 + 1) - L.y(area.r0) + headingH

        // Print titles: the file's, else frozen top rows / left columns (as Numbers repeats header rows).
        var titleRows = setup.titleRows
        var titleCols = setup.titleColumns
        if titleRows == nil, setup.titleColumns == nil, s.frozenRows > 0, s.frozenRows - 1 >= area.r0, s.frozenRows - 1 < area.r1 {
            titleRows = area.r0...(s.frozenRows - 1)
        }
        if titleCols == nil, setup.titleRows == nil, s.frozenColumns > 0, s.frozenColumns - 1 >= area.c0, s.frozenColumns - 1 < area.c1 {
            titleCols = area.c0...(s.frozenColumns - 1)
        }
        func span(_ t: ClosedRange<Int>?, _ start: (Int) -> Double) -> Double { t.map { start($0.upperBound + 1) - start($0.lowerBound) } ?? 0 }

        func printable(_ p: CGSize) -> (w: Double, h: Double) { (Double(p.width) - m[0] - m[1], Double(p.height) - m[2] - m[3]) }
        var scale = 1.0
        // The file's own print setup is landscape, a scale other than 100 % or fit to pages. "portrait" and
        // scale="100" are written on every sheet by LibreOffice, Numbers, openpyxl and often Excel, so they say
        // nothing; such sheets get the automatic layout.
        if setup.fitToPage {
            let (pw, ph) = printable(paper)
            if setup.fitToWidth > 0 { scale = min(scale, pw * Double(setup.fitToWidth) / max(totalW, 1)) }
            if setup.fitToHeight > 0 { scale = min(scale, ph * Double(setup.fitToHeight) / max(totalH, 1)) }
            scale = max(scale, 0.1)
        } else if let sc = setup.scale, sc != 100 {
            scale = Double(sc) / 100
        } else if setup.orientation != "landscape" {
            // Automatic: portrait at 100 %; portrait shrunk to the width when that keeps 80 % or more; landscape at
            // 100 %; landscape shrunk to the width down to the floor; past the floor, column bands at the floor.
            let portraitW = printable(paper).w
            if totalW > portraitW {
                if portraitW / totalW >= 0.8 {
                    scale = portraitW / totalW
                } else {
                    paper = CGSize(width: paper.height, height: paper.width)
                    let landscapeW = printable(paper).w
                    if totalW > landscapeW { scale = max(landscapeW / totalW, minimumScale(defaultFont)) }
                }
            }
        }
        let (pw, ph) = printable(paper)
        let titleRowH = span(titleRows, L.y), titleColW = span(titleCols, L.x)
        // Titles that would take most of the page are not repeated.
        if titleRowH > ph / scale * 0.5 { titleRows = nil }
        if titleColW > pw / scale * 0.5 { titleCols = nil }

        // Pages across (column bands) and down (row bands).
        func bands(_ items: [Int], available: Double, titles: ClosedRange<Int>?, titleSize: Double,
                   size: (Int) -> Double, breaks: Set<Int>, keepTogether: (Int, Int) -> Int?) -> [[Int]] {
            var out: [[Int]] = []
            var cur: [Int] = []
            var used = 0.0, room = available
            var i = 0
            while i < items.count {
                let item = items[i]
                if cur.isEmpty {
                    // A page that starts after the print titles repeats them above its own rows.
                    room = available - ((titles.map { item > $0.upperBound } ?? false) ? titleSize : 0)
                    used = 0
                }
                let sz = size(item)
                if !cur.isEmpty && (breaks.contains(item) || used + sz > room + 0.01) {
                    // Keep a merged block together when it fits on one page: break before it instead.
                    if !breaks.contains(item), let blockStart = keepTogether(item, cur[0]), let k = cur.firstIndex(of: blockStart), k > 0 {
                        i -= cur.count - k
                        out.append(Array(cur[..<k]))
                        cur = []
                        continue
                    }
                    out.append(cur)
                    cur = []
                    continue
                }
                cur.append(item)
                used += sz
                i += 1
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }
        let available = (w: pw / scale - headingW, h: ph / scale - headingH)
        let colBands = bands(visibleCols, available: available.w, titles: titleCols, titleSize: titleColW,
                             size: L.width, breaks: setup.columnBreaks, keepTogether: { _, _ in nil })
        let rowBands = bands(visibleRows, available: available.h, titles: titleRows, titleSize: titleRowH,
                             size: L.height, breaks: setup.rowBreaks, keepTogether: { r, bandStart in
            // A row inside a vertically merged block that started on this page: break before the block when the
            // block fits on a page.
            guard let mg = L.merge(r, area.c0...area.c1, rowOnly: true), mg.r0 < r, mg.r0 > bandStart else { return nil }
            let blockH = L.y(mg.r1 + 1) - L.y(mg.r0)
            return blockH <= available.h - titleRowH ? mg.r0 : nil
        })

        var pages: [PagePlan] = []
        func page(_ rb: [Int], _ cb: [Int]) {
            var rows: [Segment] = [], cols: [Segment] = []
            var y = headingH, x = headingW
            if let t = titleRows, let first = rb.first, first > t.upperBound {
                rows.append(Segment(first: t.lowerBound, last: t.upperBound, origin: y)); y += titleRowH
            }
            if let t = titleCols, let first = cb.first, first > t.upperBound {
                cols.append(Segment(first: t.lowerBound, last: t.upperBound, origin: x)); x += titleColW
            }
            rows.append(Segment(first: rb.first!, last: rb.last!, origin: y))
            cols.append(Segment(first: cb.first!, last: cb.last!, origin: x))
            let usedW = (cols.last.map { $0.origin + L.x($0.last + 1) - L.x($0.first) } ?? 0)
            let usedH = (rows.last.map { $0.origin + L.y($0.last + 1) - L.y($0.first) } ?? 0)
            var origin = CGPoint(x: m[0], y: m[2])
            if setup.centerHorizontally { origin.x += max(0, (pw - usedW * scale) / 2) }
            if setup.centerVertically { origin.y += max(0, (ph - usedH * scale) / 2) }
            var plan = PagePlan(layout: L, paper: paper, margins: m, scale: scale, rows: rows, cols: cols, origin: origin,
                                headings: setup.headings, pageIndexInSheet: startIndex + pages.count)
            if cb.last == visibleCols.last { plan.overflowEdge = (Double(paper.width) - m[1] - Double(origin.x)) / scale }
            pages.append(plan)
        }
        if setup.overThenDown {
            for rb in rowBands { for cb in colBands { page(rb, cb) } }
        } else {
            for cb in colBands { for rb in rowBands { page(rb, cb) } }
        }
        return pages
    }
}

extension SheetLayout {
    /// A vertical merge covering row r within the given columns.
    func merge(_ r: Int, _ cols: ClosedRange<Int>, rowOnly: Bool) -> SheetRange? {
        var best: SheetRange?
        for m in sheet.merges where m.r0 <= r && m.r1 >= r && m.r1 > m.r0 && m.c1 >= cols.lowerBound && m.c0 <= cols.upperBound {
            if best == nil || m.r0 < best!.r0 { best = m }
        }
        return best
    }
}
