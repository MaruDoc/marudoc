import Foundation
import CoreGraphics
import EnsoDoc

// What a sheet looks like on paper: cell text as shown, styles, column widths, row heights, merges, page setup and
// anchored pictures and charts. XlsxLayoutReader fills it from an .xlsx, `PrintSheet.csv` from a CSV, and
// SheetPrinter draws it onto PDF pages. Positions are 0-based (row 0 = Excel row 1, column 0 = A); sizes in points.

public struct SheetFont: Hashable, Sendable {
    /// The family the file names ("Calibri", "游ゴシック"); nil = the workbook's default font.
    public var name: String?
    public var size: Double
    public var bold = false
    public var italic = false
    /// 0 none, 1 single, 2 double.
    public var underline = 0
    public var strike = false
    /// nil = automatic (black).
    public var color: DocColor?
    public var baseline: DocBaseline = .normal

    public init(name: String? = nil, size: Double = 11) { self.name = name; self.size = size }
}

public enum SheetBorderStyle: String, Sendable {
    case hair, thin, medium, thick, double, dotted, dashed, mediumDashed, dashDot, mediumDashDot, dashDotDot, mediumDashDotDot, slantDashDot

    /// Rank used when two neighbouring cells give the same edge different lines: the heavier one is drawn.
    var weight: Int {
        switch self {
        case .hair: return 1
        case .dotted, .dashed, .dashDot, .dashDotDot: return 2
        case .thin: return 3
        case .mediumDashed, .mediumDashDot, .mediumDashDotDot, .slantDashDot: return 4
        case .medium: return 5
        case .thick: return 6
        case .double: return 7
        }
    }
}

public struct SheetBorderLine: Hashable, Sendable {
    public var style: SheetBorderStyle
    public var color: DocColor?
}

public struct SheetBorders: Hashable, Sendable {
    public var left: SheetBorderLine?
    public var right: SheetBorderLine?
    public var top: SheetBorderLine?
    public var bottom: SheetBorderLine?
    public var diagonalDown: SheetBorderLine?
    public var diagonalUp: SheetBorderLine?
    public var isEmpty: Bool { left == nil && right == nil && top == nil && bottom == nil && diagonalDown == nil && diagonalUp == nil }
}

public enum SheetHAlign: String, Sendable { case general, left, center, right, fill, justify, centerContinuous, distributed }
public enum SheetVAlign: String, Sendable { case top, center, bottom, justify, distributed }

public struct SheetCellStyle: Hashable, Sendable {
    public var font = SheetFont()
    public var fill: DocColor?
    public var borders = SheetBorders()
    public var hAlign: SheetHAlign = .general
    public var vAlign: SheetVAlign = .bottom
    public var indent = 0
    public var wrap = false
    public var shrink = false
    /// Degrees counter-clockwise (-90...90), or 255 for stacked vertical text.
    public var rotation = 0
    public init() {}
}

public enum SheetCellKind: Sendable { case text, number, bool, error }

/// A stretch of rich text in a cell with its own font.
public struct SheetRun: Sendable {
    public var text: String
    public var font: SheetFont
}

public struct SheetCell: Sendable {
    /// The text the cell shows (number formats applied). Empty for cells that only carry a style.
    public var text: String
    public var kind: SheetCellKind
    public var style: Int
    /// Rich text runs (shared strings with <r>); nil for plain cells.
    public var runs: [SheetRun]?
    /// Text colour from the number format ("[Red]").
    public var formatColor: DocColor?
    /// The number behind a numeric cell, for charts that have no cached values.
    public var number: Double?
    public init(text: String, kind: SheetCellKind = .text, style: Int = 0) { self.text = text; self.kind = kind; self.style = style }
}

/// A block of cells, inclusive on both ends.
public struct SheetRange: Hashable, Sendable {
    public var r0: Int, c0: Int, r1: Int, c1: Int
    public init(r0: Int, c0: Int, r1: Int, c1: Int) {
        self.r0 = min(r0, r1); self.r1 = max(r0, r1); self.c0 = min(c0, c1); self.c1 = max(c0, c1)
    }
    public func contains(_ r: Int, _ c: Int) -> Bool { r >= r0 && r <= r1 && c >= c0 && c <= c1 }
    public func intersects(_ o: SheetRange) -> Bool { r0 <= o.r1 && o.r0 <= r1 && c0 <= o.c1 && o.c0 <= c1 }
}

public struct SheetPageSetup: Sendable {
    /// ECMA-376 paper size code (9 = A4); nil when the file names none.
    public var paperSize: Int?
    /// paperWidth / paperHeight, when the file gives the paper's size instead of a code.
    public var paperSizeMM: CGSize?
    /// "portrait" / "landscape"; nil when the file does not say.
    public var orientation: String?
    /// Percent; nil when not given.
    public var scale: Int?
    /// sheetPr/pageSetUpPr fitToPage: fitToWidth / fitToHeight apply (0 = no limit in that direction).
    public var fitToPage = false
    public var fitToWidth = 1
    public var fitToHeight = 1
    /// Inches: left, right, top, bottom, header, footer. nil = Excel's defaults.
    public var margins: [Double]?
    public var gridLines = false
    public var headings = false
    public var centerHorizontally = false
    public var centerVertically = false
    public var overThenDown = false
    public var firstPageNumber: Int?
    public var printAreas: [SheetRange] = []
    public var titleRows: ClosedRange<Int>?
    public var titleColumns: ClosedRange<Int>?
    /// Rows / columns that start a new page (manual breaks).
    public var rowBreaks: Set<Int> = []
    public var columnBreaks: Set<Int> = []
    public var oddHeader: String?, oddFooter: String?, evenHeader: String?, evenFooter: String?, firstHeader: String?, firstFooter: String?
    public var differentFirst = false
    public var differentOddEven = false
    public var scaleWithDoc = true
    public var alignWithMargins = true
    public init() {}
}

/// Where a picture or chart sits: a cell corner plus an offset in points, and either the opposite corner or a size.
public struct SheetAnchor: Sendable {
    public var fromCol = 0, fromRow = 0
    public var fromColOffset = 0.0, fromRowOffset = 0.0
    public var toCol: Int?, toRow: Int?
    public var toColOffset = 0.0, toRowOffset = 0.0
    /// Size for oneCellAnchor / absoluteAnchor.
    public var size: CGSize?
    /// Position on the sheet for absoluteAnchor.
    public var absolute: CGPoint?
    public init() {}
}

public enum SheetChartKind: String, Sendable { case column, bar, line, area, pie, doughnut, scatter, other }

public struct SheetChartSeries: Sendable {
    public var name: String
    public var categories: [String]
    public var values: [Double?]
    public var color: DocColor?
}

public struct SheetChart: Sendable {
    public var kind: SheetChartKind = .column
    /// The chart type element when `kind` is .other ("radarChart", "bubbleChart", …).
    public var otherType: String?
    public var stacked = false
    public var percentStacked = false
    public var title: String?
    public var series: [SheetChartSeries] = []
    public var legend: String? = "r"
    public var valueMin: Double?, valueMax: Double?
    public var valueFormat: String?
    /// Series colours from the workbook theme (accent 1-6), for series without their own.
    public var palette: [DocColor] = []
    public init() {}
}

public enum SheetDrawingContent: Sendable {
    case picture(Data)
    case chart(SheetChart)
    /// A shape or text box: fill, outline and its text.
    case shape(fill: DocColor?, line: DocColor?, text: String)
    /// Something not drawn (EMF picture, SmartArt, group, ...): its description for the report.
    case unsupported(String)
}

public struct SheetDrawing: Sendable {
    public var anchor: SheetAnchor
    public var content: SheetDrawingContent
}

public final class PrintSheet: @unchecked Sendable {
    public var name: String
    /// cells[row][col]; rows shorter than the sheet hold no more cells.
    public var cells: [[SheetCell?]] = []
    public var styles: [SheetCellStyle] = [SheetCellStyle()]
    /// Column widths in points for the columns that have their own; the rest use `defaultColumnWidth`.
    public var columnWidths: [Int: Double] = [:]
    public var defaultColumnWidth = 48.0
    public var hiddenColumns = Set<Int>()
    /// Every column from this one on is hidden ("hide the rest of the sheet").
    public var hiddenFrom: Int?
    public var columnStyles: [Int: Int] = [:]
    /// Row heights in points from the file (`ht`), and whether the author fixed them.
    public var rowHeights: [Int: Double] = [:]
    public var customRowHeights = Set<Int>()
    public var hiddenRows = Set<Int>()
    public var rowStyles: [Int: Int] = [:]
    public var defaultRowHeight = 15.0
    /// Rows hidden unless they say otherwise (sheetFormatPr zeroHeight).
    public var rowsHiddenByDefault = false
    public var merges: [SheetRange] = []
    public var pageSetup = SheetPageSetup()
    /// Rows / columns frozen at the top / left of the window.
    public var frozenRows = 0
    public var frozenColumns = 0
    public var drawings: [SheetDrawing] = []
    /// Maximum digit width of the default font in pixels at 96 dpi (Excel's column width unit).
    public var maxDigitWidth = 7.0
    /// CSV input: no styling of its own, so every cell gets a light grid.
    public var isCSV = false
    /// The worksheet's drawing part (pictures, charts), while reading.
    var drawingRelID: String?
    /// Things in the file this renderer does not draw ("conditional formatting", "EMF picture"), for reports.
    public var notDrawn: [String] = []

    public init(name: String) { self.name = name }

    public var rowCount: Int { cells.count }
    public var columnCount: Int { cells.reduce(0) { max($0, $1.count) } }

    @inline(__always) public func cell(_ r: Int, _ c: Int) -> SheetCell? {
        guard r >= 0, r < cells.count, c >= 0 else { return nil }
        let row = cells[r]
        return c < row.count ? row[c] : nil
    }

    func set(_ cell: SheetCell, _ r: Int, _ c: Int) {
        if r >= cells.count { cells.append(contentsOf: Array(repeating: [], count: r - cells.count + 1)) }
        if c >= cells[r].count { cells[r].append(contentsOf: Array(repeating: nil, count: c - cells[r].count + 1)) }
        cells[r][c] = cell
    }

    /// The style a cell is drawn with: its own, else its row's, else its column's.
    @inline(__always) public func styleIndex(_ r: Int, _ c: Int) -> Int {
        if let cell = cell(r, c) { return cell.style }
        if let s = rowStyles[r] { return s }
        return columnStyles[c] ?? 0
    }

    public func style(_ r: Int, _ c: Int) -> SheetCellStyle {
        let i = styleIndex(r, c)
        return i >= 0 && i < styles.count ? styles[i] : styles[0]
    }

    public func isHiddenRow(_ r: Int) -> Bool {
        if hiddenRows.contains(r) { return true }
        return rowsHiddenByDefault && rowHeights[r] == nil && (r >= cells.count || cells[r].isEmpty)
    }

    public func columnWidth(_ c: Int) -> Double {
        if hiddenColumns.contains(c) || (hiddenFrom.map { c >= $0 } ?? false) { return 0 }
        return columnWidths[c] ?? defaultColumnWidth
    }
}

public final class PrintWorkbook: @unchecked Sendable {
    public var sheets: [PrintSheet]
    /// The workbook's default font (the Normal style).
    public var defaultFont: SheetFont
    public init(sheets: [PrintSheet], defaultFont: SheetFont = SheetFont()) { self.sheets = sheets; self.defaultFont = defaultFont }
}

// MARK: - CSV

extension PrintSheet {
    /// Font size CSV pages are set in.
    public static let csvFontSize = 10.0

    /// A sheet for printing CSV / TSV: every value exactly as written, numbers right-aligned, a thin light-grey grid,
    /// column widths from the measured text (long text columns capped and wrapped). The first row is an ordinary row.
    public static func csv(_ sheet: Sheet, measure: (String, SheetFont) -> Double) -> PrintSheet {
        let p = PrintSheet(name: sheet.name)
        p.isCSV = true
        var base = SheetCellStyle()
        base.font = SheetFont(name: "Helvetica Neue", size: csvFontSize)
        // Top-aligned, so a row with one multi-line value still reads across.
        base.vAlign = .top
        var wrapped = base
        wrapped.wrap = true
        p.styles = [base, wrapped]
        p.defaultRowHeight = (csvFontSize * 1.36 / 0.75).rounded() * 0.75
        p.pageSetup.gridLines = true
        let padding = 6.0, minWidth = 24.0, cap = 300.0
        var widths: [Double] = []
        p.cells.reserveCapacity(sheet.rows.count)
        for row in sheet.rows {
            var line: [SheetCell?] = []
            line.reserveCapacity(row.count)
            for (c, v) in row.enumerated() {
                let text = v.displayString
                if text.isEmpty { line.append(nil); continue }
                var kind = SheetCellKind.text
                switch v {
                case .number, .formatted: kind = .number
                default: break
                }
                line.append(SheetCell(text: text, kind: kind, style: 0))
                while widths.count <= c { widths.append(minWidth) }
                // A value is measured only when it could be wider than the column so far (no character is wider
                // than about 1 em).
                let longestLine = text.contains("\n") ? text.split(separator: "\n").map(String.init).max { $0.utf16.count < $1.utf16.count } ?? text : text
                if Double(longestLine.utf16.count) * csvFontSize * 1.05 + padding > widths[c] {
                    let w = measure(longestLine, base.font) + padding
                    if w > widths[c] { widths[c] = min(w, cap) }
                }
            }
            while line.last.map({ $0 == nil }) == true { line.removeLast() }
            p.cells.append(line)
        }
        for (c, w) in widths.enumerated() { p.columnWidths[c] = w.rounded(.up) }
        // Text longer than its capped column wraps; so does text with line breaks.
        for r in p.cells.indices {
            for c in p.cells[r].indices {
                guard let cell = p.cells[r][c], cell.kind == .text else { continue }
                if cell.text.contains("\n") || (widths[c] >= cap && measure(cell.text, base.font) + padding > cap) {
                    p.cells[r][c]?.style = 1
                }
            }
        }
        return p
    }
}
