import Foundation
import CoreText
import CoreGraphics
import EnsoDoc

/// Geometry of one sheet: where every column and row starts (hidden ones are zero wide / high), row heights grown
/// for wrapped text and larger fonts as Excel does, and which cells merged blocks cover.
final class SheetLayout {
    let sheet: PrintSheet
    /// colStart[c] = left edge of column c; colStart.count = lastCol + 2.
    private(set) var colStart: [Double] = [0]
    private(set) var rowStart: [Double] = [0]
    /// Cell key -> index into sheet.merges, for every cell a merged block covers.
    private(set) var mergeAt: [Int: Int] = [:]
    let lastRow: Int, lastCol: Int
    /// Text padding inside a cell (Excel leaves about 2 px each side).
    static let padding = 2.0

    @inline(__always) static func key(_ r: Int, _ c: Int) -> Int { r &* 16_384 &+ c }

    init(_ sheet: PrintSheet, lastRow: Int, lastCol: Int) {
        self.sheet = sheet
        self.lastRow = lastRow
        self.lastCol = lastCol
        colStart.reserveCapacity(lastCol + 2)
        var x = 0.0
        for c in 0...max(lastCol, 0) { x += sheet.columnWidth(c); colStart.append(x) }
        for (i, m) in sheet.merges.enumerated() where m.r0 <= lastRow && m.c0 <= lastCol {
            // Huge merges (whole rows or columns) are capped to what can print.
            for r in m.r0...min(m.r1, lastRow) { for c in m.c0...min(m.c1, lastCol) { mergeAt[SheetLayout.key(r, c)] = i } }
        }
        rowStart.reserveCapacity(lastRow + 2)
        var y = 0.0
        for r in 0...max(lastRow, 0) { y += height(of: r); rowStart.append(y) }
    }

    @inline(__always) func x(_ c: Int) -> Double { c <= lastCol + 1 ? colStart[max(c, 0)] : colStart[lastCol + 1] + Double(c - lastCol - 1) * sheet.defaultColumnWidth }
    @inline(__always) func width(_ c: Int) -> Double { c <= lastCol ? colStart[c + 1] - colStart[c] : sheet.columnWidth(c) }
    @inline(__always) func y(_ r: Int) -> Double { r <= lastRow + 1 ? rowStart[max(r, 0)] : rowStart[lastRow + 1] + Double(r - lastRow - 1) * sheet.defaultRowHeight }
    @inline(__always) func height(_ r: Int) -> Double { r <= lastRow ? rowStart[r + 1] - rowStart[r] : sheet.defaultRowHeight }

    func merge(_ r: Int, _ c: Int) -> SheetRange? { mergeAt[SheetLayout.key(r, c)].map { sheet.merges[$0] } }

    // MARK: Row heights

    /// Excel's row height: the author's when fixed, else tall enough for the largest font and wrapped text in the
    /// row (merged cells do not count, as in Excel).
    private func height(of r: Int) -> Double {
        if sheet.isHiddenRow(r) { return 0 }
        let stored = sheet.rowHeights[r]
        var needed = 0.0
        var wrapNeeded = 0.0
        // A height from the file grows by one line when wrapped text needs exactly one line more than it holds
        // (the app that saved it measured with other fonts); more than that and the text is clipped.
        var oneLineShort = 0.0
        if r < sheet.cells.count {
            for (c, cell) in sheet.cells[r].enumerated() {
                guard let cell, !cell.text.isEmpty, sheet.columnWidth(c) > 0 else { continue }
                let st = sheet.style(r, c)
                if let mi = mergeAt[SheetLayout.key(r, c)] {
                    // Merged cells do not size rows (as in Excel), except that a one-row block of wrapped text that
                    // is one line short of the file's height gets that line.
                    let m = sheet.merges[mi]
                    if let stored, m.r0 == r, m.r1 == r, m.c0 == c, st.wrap, st.rotation == 0 {
                        let lh = SheetFonts.lineHeight(st.font)
                        let inner = max((m.c0...min(m.c1, lastCol)).reduce(0.0) { $0 + width($1) } - 2 * SheetLayout.padding, 1)
                        let lines = SheetText.lineCount(cell, style: st, width: inner)
                        if lines > 1, lines == Int((stored + 0.25) / lh) + 1 { oneLineShort = max(oneLineShort, lh) }
                    }
                    continue
                }
                let fonts = cell.runs?.map(\.font) ?? [st.font]
                let lh = fonts.map(SheetFonts.lineHeight).max() ?? SheetFonts.lineHeight(st.font)
                needed = max(needed, lh)
                if st.wrap || st.hAlign == .justify || st.hAlign == .distributed, st.rotation == 0 {
                    let inner = max(width(c) - 2 * SheetLayout.padding, 1)
                    let lines = SheetText.lineCount(cell, style: st, width: inner)
                    wrapNeeded = max(wrapNeeded, Double(lines) * lh)
                    if let stored, lines > 1, lines == Int((stored + 0.25) / lh) + 1 { oneLineShort = max(oneLineShort, lh) }
                } else if st.rotation != 0 {
                    // Rotated text needs the text's length as height.
                    let w = SheetFonts.measure(cell.text, st.font)
                    let a = Double(st.rotation == 255 ? 90 : abs(st.rotation)) * .pi / 180
                    let rotated = st.rotation == 255 ? Double(cell.text.count) * lh : w * sin(a) + lh * cos(a)
                    wrapNeeded = max(wrapNeeded, rotated + 2)
                }
            }
        }
        if let stored { return stored + oneLineShort }
        return max(sheet.defaultRowHeight, ((max(needed, wrapNeeded)) / 0.75).rounded(.up) * 0.75)
    }
}

/// Cell text as it is laid out: single lines and wrapped paragraphs.
enum SheetText {
    /// The text a cell shows on one line: Excel does not break lines in cells without wrap.
    static func singleLine(_ s: String) -> String {
        guard s.contains("\n") || s.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
    }

    static func attributed(_ cell: SheetCell, style: SheetCellStyle, color: CGColor, sizeScale: CGFloat = 1) -> NSAttributedString {
        if let runs = cell.runs {
            return SheetFonts.attributed(runs.map { ($0.text, $0.font, $0.font.color.map(SheetText.cg) ?? color) }, sizeScale: sizeScale)
        }
        return SheetFonts.attributed([(cell.text, style.font, color)], sizeScale: sizeScale)
    }

    /// Lines of wrapped text within `width` (CoreText's breaking: at spaces and between Japanese characters, never
    /// inside a word unless the word alone is wider than the cell).
    static func lines(_ attr: NSAttributedString, width: Double) -> [CTLine] {
        guard attr.length > 0 else { return [] }
        let ts = CTTypesetterCreateWithAttributedString(attr)
        var out: [CTLine] = []
        var start = 0
        let ns = attr.string as NSString
        while start < attr.length && out.count < 2000 {
            var count = CTTypesetterSuggestLineBreak(ts, start, max(width, 1))
            if count <= 0 { count = 1 }
            var len = count
            // Drop the line break itself from the line.
            while len > 0, let last = UnicodeScalar(ns.character(at: start + len - 1)), last == "\n" || last == "\r" || last == "\u{2028}" { len -= 1 }
            out.append(CTTypesetterCreateLine(ts, CFRange(location: start, length: len)))
            start += count
        }
        return out
    }

    static func lineCount(_ cell: SheetCell, style: SheetCellStyle, width: Double) -> Int {
        if cell.runs == nil, !cell.text.contains("\n"), let w = SheetFace.face(style.font).simpleWidth(cell.text), w <= width { return 1 }
        return max(1, lines(attributed(cell, style: style, color: CGColor(gray: 0, alpha: 1)), width: width).count)
    }

    static func cg(_ c: DocColor) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
}
