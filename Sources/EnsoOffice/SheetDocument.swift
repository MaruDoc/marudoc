import Foundation
import CoreGraphics
import ImageIO
import EnsoDoc

/// A printed sheet as a Word document: each sheet's print area (or used range) becomes a table with the sheet's
/// column proportions, horizontal and vertical merges, fonts (bold, italic, colour, size), cell fills, horizontal
/// alignment (numbers right-aligned) and the text number formats show. Title lines above the table (a merged title,
/// a subtitle) become paragraphs, so the first table row is the real header. Pictures and charts follow the table
/// as pictures. Wide or landscape sheets make the document landscape.
public enum SheetDocument {

    public static func model(_ wb: PrintWorkbook, title: String) -> DocModel {
        var blocks: [DocBlock] = []
        let printable = wb.sheets.compactMap { s -> (PrintSheet, [SheetRange])? in
            guard let used = SheetPrinter.usedRange(s) else { return nil }
            let areas = s.pageSetup.printAreas.isEmpty ? [used] : s.pageSetup.printAreas.map { a -> SheetRange in
                var r = a
                if r.r1 >= XlsxWriter.maxRows - 1 { r.r1 = max(r.r0, used.r1) }
                if r.c1 >= XlsxWriter.maxColumns - 1 { r.c1 = max(r.c0, used.c1) }
                return r
            }
            return (s, areas)
        }
        let baseSize = wb.defaultFont.size
        // Wider than an A4 portrait text column, or printed landscape: a landscape document (DocxWriter keeps
        // 20 mm margins, so the text is 482 pt wide in portrait and 728 pt in landscape).
        var landscape = false
        var layouts: [(PrintSheet, [SheetRange], SheetLayout)] = []
        for (s, areas) in printable {
            let L = SheetLayout(s, lastRow: areas.map(\.r1).max() ?? 0, lastCol: areas.map(\.c1).max() ?? 0)
            layouts.append((s, areas, L))
            let widest = areas.map { a in (a.c0...a.c1).reduce(0.0) { $0 + L.width($1) } }.max() ?? 0
            if widest > 500 || s.pageSetup.orientation == "landscape" { landscape = true }
        }
        let textWidth = landscape ? 728.0 : 482.0
        for (s, areas, L) in layouts {
            if printable.count > 1 { blocks.append(.heading(level: 2, DocParagraph(text: s.name))) }
            for area in areas {
                blocks += sheetBlocks(L, area: area, baseSize: baseSize, textWidth: textWidth)
            }
            for d in s.drawings {
                if let img = image(d, layout: L) { blocks.append(.image(img)) }
            }
        }
        var model = DocModel(title: title, blocks: blocks, bodyFontSize: 10)
        if landscape { model.pageSize = CGSize(width: DocModel.a4.height, height: DocModel.a4.width) }
        return model
    }

    /// Title paragraphs and the table for one area.
    static func sheetBlocks(_ L: SheetLayout, area: SheetRange, baseSize: Double, textWidth: Double) -> [DocBlock] {
        let s = L.sheet
        let cols = (area.c0...area.c1).filter { L.width($0) > 0 }
        var rows = (area.r0...area.r1).filter { L.height($0) > 0 }
        guard !cols.isEmpty, !rows.isEmpty else { return [] }
        func values(_ r: Int) -> [Int] {
            cols.filter { c in
                if let m = L.merge(r, c), (m.r0 != r || m.c0 != c) { return false }
                return !(s.cell(r, c)?.text.isEmpty ?? true)
            }
        }
        var blocks: [DocBlock] = []
        // Leading rows holding a single value (a title, a subtitle, a date line) are paragraphs, not table rows,
        // as long as a table with more than one column follows.
        if cols.count > 1 {
            var taken = 0
            while let r = rows.first, taken < 5 {
                let v = values(r)
                if v.isEmpty { rows.removeFirst(); continue }
                guard v.count == 1, rows.dropFirst().contains(where: { values($0).count > 1 }) else { break }
                let c = v[0]
                let st = s.style(r, c)
                var p = paragraph(s.cell(r, c)!, style: st, baseSize: baseSize)
                if let m = L.merge(r, c), m.c1 > m.c0, st.hAlign == .general || st.hAlign == .center || st.hAlign == .centerContinuous {
                    p.alignment = .center
                }
                blocks.append(.paragraph(p))
                rows.removeFirst()
                taken += 1
            }
            while let r = rows.last, values(r).isEmpty { rows.removeLast() }
        }
        guard !rows.isEmpty else { return blocks }

        // Word adds about 11 pt of margins to every cell, and draws in Arial / Yu Gothic: each column gets at least
        // the width of its longest value that must not break (numbers, dates, codes, Latin words), so
        // "2024-10-01" never splits in two. When those minimums do not fit the page, the table's text gets smaller.
        var need = Array(repeating: 0.0, count: cols.count)
        for (k, c) in cols.enumerated() {
            for r in rows {
                if let m = L.merge(r, c), m.c1 > m.c0 { continue }
                guard let cell = s.cell(r, c), !cell.text.isEmpty else { continue }
                let st = s.style(r, c)
                var f = SheetFont(name: "Arial", size: st.font.size * 10 / baseSize)
                f.bold = st.font.bold
                let tokens = cell.kind == .text ? unbreakable(cell.text) : [SheetText.singleLine(cell.text)]
                for t in tokens where !t.isEmpty { need[k] = max(need[k], min(SheetFonts.measure(t, f) * 1.05, 380)) }
            }
        }
        let margins = 11.0 * Double(cols.count)
        let sumNeed = need.reduce(0, +)
        var size = 10.0
        if sumNeed + margins > textWidth, sumNeed > 0 {
            size = max(7, (10 * (textWidth - margins) / sumNeed * 2).rounded(.down) / 2)
        }
        need = need.map { $0 * size / 10 + 11 }
        let sheetWidths = cols.map { L.width($0) }
        let total = max(sheetWidths.reduce(0, +), 1)
        var widths = zip(sheetWidths, need).map { max($0 * textWidth / total, $1) }
        let excess = widths.reduce(0, +) - textWidth
        let slack = zip(widths, need).map { max($0 - $1, 0) }
        let slackSum = slack.reduce(0, +)
        if excess > 0, slackSum > 0 {
            let take = min(excess, slackSum)
            widths = widths.enumerated().map { i, w in w - take * slack[i] / slackSum }
        }
        let runScale: Double? = size == 10 ? nil : size

        var table: [[DocTableCell]] = []
        for r in rows {
            var line: [DocTableCell] = []
            var i = 0
            while i < cols.count {
                let c = cols[i]
                if let m = L.merge(r, c) {
                    let span = cols[i...].prefix { $0 <= m.c1 }.count
                    if m.c0 == c || i == 0 {
                        if m.r0 == r || r == rows.first {
                            // The merged block's own cell, across its visible columns and rows.
                            var cell = docCell(s, m.r0, m.c0, baseSize: baseSize, tableSize: runScale)
                            cell.colSpan = span
                            cell.rowSpan = rows.filter { $0 >= r && $0 <= m.r1 }.count
                            line.append(cell)
                        } else {
                            // Covered by a block above: an empty placeholder the vertical merge spans.
                            var cell = DocTableCell([])
                            cell.colSpan = span
                            line.append(cell)
                        }
                    }
                    i += max(span, 1)
                    continue
                }
                line.append(docCell(s, r, c, baseSize: baseSize, tableSize: runScale))
                i += 1
            }
            table.append(line)
        }
        // The first row is a header when text fills at least half of the columns (a merged title never gets here,
        // nor does an address line such as "○○御中 … 請求日").
        let first = values(rows[0])
        let header = first.count >= 2 && first.count * 2 >= cols.count && rows.count > 1
            && first.allSatisfy { s.cell(rows[0], $0)?.kind == .text }
        blocks.append(.table(DocTable(rows: table, headerRows: header ? 1 : 0, columnWidths: widths)))
        return blocks
    }

    /// Pieces of text Word must not break: runs of Latin letters, digits and their punctuation ("ABC", "001-0005",
    /// "¥1,500"). Japanese text may break between any two characters, so it adds nothing.
    static func unbreakable(_ text: String) -> [String] {
        var out: [String] = [], cur = ""
        for u in text.unicodeScalars {
            if u.value < 0x2E80 && !CharacterSet.whitespacesAndNewlines.contains(u) { cur.unicodeScalars.append(u) }
            else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func docCell(_ s: PrintSheet, _ r: Int, _ c: Int, baseSize: Double, tableSize: Double? = nil) -> DocTableCell {
        let st = s.style(r, c)
        guard let cell = s.cell(r, c), !cell.text.isEmpty else {
            var empty = DocTableCell([])
            empty.fill = st.fill
            return empty
        }
        var out = DocTableCell([paragraph(cell, style: st, baseSize: baseSize, tableSize: tableSize)])
        out.fill = st.fill
        return out
    }

    /// `tableSize`: the size a table's default text is set in when it is not the 10 pt body size.
    static func paragraph(_ cell: SheetCell, style st: SheetCellStyle, baseSize: Double, tableSize: Double? = nil) -> DocParagraph {
        func run(_ text: String, _ f: SheetFont, color: DocColor?) -> DocRun {
            // Sizes relative to the workbook's default font, which becomes the document's 10 pt body text.
            let body = tableSize ?? 10
            let size: Double? = abs(f.size - baseSize) < 0.01 && tableSize == nil ? nil : ((f.size * body / baseSize) * 2).rounded() / 2
            return DocRun(text, bold: f.bold, italic: f.italic, underline: f.underline > 0, strikethrough: f.strike,
                          fontSize: size, color: color, baseline: f.baseline)
        }
        let text = st.wrap ? cell.text : SheetText.singleLine(cell.text)
        var runs: [DocRun]
        if let rich = cell.runs, !st.wrap {
            runs = rich.map { run(SheetText.singleLine($0.text), $0.font, color: $0.font.color) }
        } else if let rich = cell.runs {
            runs = rich.map { run($0.text, $0.font, color: $0.font.color) }
        } else {
            runs = [run(text, st.font, color: cell.formatColor ?? st.font.color)]
        }
        var align: DocAlignment
        switch st.hAlign {
        case .general: align = cell.kind == .number ? .right : (cell.kind == .text ? .left : .center)
        case .left, .fill: align = .left
        case .center, .centerContinuous, .distributed: align = .center
        case .right: align = .right
        case .justify: align = .justify
        }
        if runs.isEmpty { runs = [DocRun(text)] }
        return DocParagraph(runs, alignment: align, indent: Double(st.indent) * 7.5)
    }

    /// A picture as it is, or a chart drawn to a picture at its size on the sheet.
    static func image(_ d: SheetDrawing, layout L: SheetLayout) -> DocImage? {
        let painter = SheetPainter(ctx: CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!,
                                   fileName: "", date: Date(), total: 1)
        let a = painter.anchorRect(d.anchor, L)
        guard a.w > 1, a.h > 1 else { return nil }
        switch d.content {
        case .picture(let data):
            guard let cg = ImageCodec.decode(data) else { return nil }
            if let f = OfficeImage.sniff(data) {
                return DocImage(data: data, format: f, pixelWidth: cg.width, pixelHeight: cg.height, displayWidth: a.w, displayHeight: a.h)
            }
            return ImageCodec.docImage(from: cg, displayWidth: a.w, displayHeight: a.h)
        case .chart(let chart):
            let scale = 3.0
            let pw = Int((a.w * scale).rounded()), ph = Int((a.h * scale).rounded())
            guard pw > 0, ph > 0, pw * ph < 40_000_000,
                  let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            SheetChartPainter(ctx: ctx).draw(chart, in: CGRect(x: 0, y: 0, width: a.w, height: a.h))
            guard let img = ctx.makeImage(), let png = ImageCodec.encode(img, as: .png) else { return nil }
            return DocImage(data: png, format: .png, pixelWidth: pw, pixelHeight: ph, displayWidth: a.w, displayHeight: a.h,
                            altText: chart.title)
        case .shape, .unsupported:
            return nil
        }
    }
}
