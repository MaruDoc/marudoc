import Foundation
import CoreGraphics

// The intermediate representation every conversion goes through:
//   reader (PDF / docx / md / html / ...) -> DocModel -> writer (docx / md / html / pdf / ...)
// Keep it format-neutral. Anything a writer cannot express it simply drops.

public struct DocColor: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// "RRGGBB" without '#', as used by OOXML.
    public var hex: String {
        func c(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    public var isNearlyBlack: Bool { r < 0.15 && g < 0.15 && b < 0.15 }
    public static let black = DocColor(r: 0, g: 0, b: 0)
}

/// A stretch of text with uniform formatting.
public struct DocRun: Hashable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    /// Inline code (monospaced).
    public var code: Bool
    /// Point size. nil = the document's body size.
    public var fontSize: Double?
    /// PostScript or family name as found in the source, if any. Writers may ignore it.
    public var fontName: String?
    public var color: DocColor?
    public var highlight: DocColor?
    /// Hyperlink target (absolute URL string).
    public var link: String?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                strikethrough: Bool = false, code: Bool = false, fontSize: Double? = nil,
                fontName: String? = nil, color: DocColor? = nil, highlight: DocColor? = nil, link: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.underline = underline
        self.strikethrough = strikethrough; self.code = code; self.fontSize = fontSize
        self.fontName = fontName; self.color = color; self.highlight = highlight; self.link = link
    }

    /// True when two runs could be merged without losing formatting.
    public func sameStyle(as o: DocRun) -> Bool {
        bold == o.bold && italic == o.italic && underline == o.underline && strikethrough == o.strikethrough &&
        code == o.code && fontSize == o.fontSize && fontName == o.fontName && color == o.color &&
        highlight == o.highlight && link == o.link
    }
}

public enum DocAlignment: String, Hashable, Sendable { case left, center, right, justify }

public struct DocParagraph: Hashable, Sendable {
    public var runs: [DocRun]
    public var alignment: DocAlignment
    /// Left indent in points (0 = none).
    public var indent: Double

    public init(_ runs: [DocRun], alignment: DocAlignment = .left, indent: Double = 0) {
        self.runs = runs; self.alignment = alignment; self.indent = indent
    }
    public init(text: String, alignment: DocAlignment = .left) {
        self.init([DocRun(text)], alignment: alignment)
    }

    public var plainText: String { runs.map(\.text).joined() }
    public var isEmpty: Bool { plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Merges adjacent runs with identical style.
    public func normalized() -> DocParagraph {
        var out: [DocRun] = []
        for r in runs where !r.text.isEmpty {
            if let last = out.last, last.sameStyle(as: r) { out[out.count - 1].text += r.text } else { out.append(r) }
        }
        var p = self; p.runs = out; return p
    }
}

public enum DocImageFormat: String, Hashable, Sendable { case png, jpeg
    public var fileExtension: String { self == .png ? "png" : "jpeg" }
    public var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
}

public struct DocImage: Hashable, Sendable {
    /// Encoded image bytes (PNG or JPEG).
    public var data: Data
    public var format: DocImageFormat
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Size on the page in points. Writers scale down to fit the text column if larger.
    public var displayWidth: Double
    public var displayHeight: Double
    public var altText: String?

    public init(data: Data, format: DocImageFormat, pixelWidth: Int, pixelHeight: Int,
                displayWidth: Double? = nil, displayHeight: Double? = nil, altText: String? = nil) {
        self.data = data; self.format = format; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.displayWidth = displayWidth ?? Double(pixelWidth) * 72 / 144
        self.displayHeight = displayHeight ?? Double(pixelHeight) * 72 / 144
        self.altText = altText
    }
}

public struct DocListItem: Hashable, Sendable {
    public var ordered: Bool
    /// Nesting depth, 0 = top level.
    public var level: Int
    /// Explicit number for ordered lists when known.
    public var number: Int?
    public var paragraph: DocParagraph
    public init(ordered: Bool, level: Int = 0, number: Int? = nil, paragraph: DocParagraph) {
        self.ordered = ordered; self.level = level; self.number = number; self.paragraph = paragraph
    }
}

public struct DocTableCell: Hashable, Sendable {
    public var paragraphs: [DocParagraph]
    public var colSpan: Int
    public init(_ paragraphs: [DocParagraph], colSpan: Int = 1) { self.paragraphs = paragraphs; self.colSpan = colSpan }
    public init(text: String) { self.init([DocParagraph(text: text)]) }
    public var text: String { paragraphs.map(\.plainText).joined(separator: "\n") }
}

public struct DocTable: Hashable, Sendable {
    public var rows: [[DocTableCell]]
    /// Number of leading rows that are headers.
    public var headerRows: Int
    /// Optional relative column widths (any unit; writers normalise).
    public var columnWidths: [Double]?
    public init(rows: [[DocTableCell]], headerRows: Int = 0, columnWidths: [Double]? = nil) {
        self.rows = rows; self.headerRows = headerRows; self.columnWidths = columnWidths
    }
    public var columnCount: Int { rows.map { $0.reduce(0) { $0 + $1.colSpan } }.max() ?? 0 }
}

public enum DocBlock: Hashable, Sendable {
    case heading(level: Int, DocParagraph)   // level 1...6
    case paragraph(DocParagraph)
    case listItem(DocListItem)
    case quote(DocParagraph)
    case code(String, language: String?)
    case table(DocTable)
    case image(DocImage)
    case pageBreak
    case horizontalRule
}

public struct DocModel: Sendable {
    public var title: String?
    public var blocks: [DocBlock]
    /// Page size in points when the source had one (PDF). nil = A4 portrait.
    public var pageSize: CGSize?
    /// Body text size in points.
    public var bodyFontSize: Double
    /// Font family the source used for body text, if known.
    public var bodyFontName: String?

    public init(title: String? = nil, blocks: [DocBlock] = [], pageSize: CGSize? = nil,
                bodyFontSize: Double = 11, bodyFontName: String? = nil) {
        self.title = title; self.blocks = blocks; self.pageSize = pageSize
        self.bodyFontSize = bodyFontSize; self.bodyFontName = bodyFontName
    }

    public static let a4 = CGSize(width: 595.28, height: 841.89)

    /// All text, one block per line group. Used by "copy text" and plain-text export.
    public var plainText: String {
        var parts: [String] = []
        for b in blocks {
            switch b {
            case .heading(_, let p), .paragraph(let p), .quote(let p): parts.append(p.plainText)
            case .listItem(let li):
                let indent = String(repeating: "  ", count: li.level)
                parts.append(indent + (li.ordered ? "\(li.number ?? 1). " : "・") + li.paragraph.plainText)
            case .code(let s, _): parts.append(s)
            case .table(let t): parts.append(t.rows.map { $0.map(\.text).joined(separator: "\t") }.joined(separator: "\n"))
            case .image(let img): if let alt = img.altText, !alt.isEmpty { parts.append(alt) }
            case .pageBreak: parts.append("")
            case .horizontalRule: parts.append("")
            }
        }
        return parts.joined(separator: "\n\n").replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
    }
}

// MARK: - Spreadsheets

public enum CellValue: Hashable, Sendable {
    case empty
    case text(String)
    case number(Double)
    case bool(Bool)

    public var displayString: String {
        switch self {
        case .empty: return ""
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .number(let d):
            if d.rounded() == d && abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        }
    }

    /// Parses "1,234", "¥1,234", "12.5%", "-3" as numbers; everything else stays text.
    public static func guess(_ raw: String) -> CellValue {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .empty }
        var t = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
        for sym in ["¥", "￥", "$", "€", "£", "円"] { t = t.replacingOccurrences(of: sym, with: "") }
        var percent = false
        if t.hasSuffix("%") { percent = true; t.removeLast() }
        if t.hasPrefix("(") && t.hasSuffix(")") { t = "-" + t.dropFirst().dropLast() }
        t = t.replacingOccurrences(of: "▲", with: "-").replacingOccurrences(of: "△", with: "-")
        guard t.range(of: #"^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
              let d = Double(t) else { return .text(s) }
        // Keep things like zip codes / IDs with leading zeros as text.
        if t.count > 1 && t.hasPrefix("0") && !t.hasPrefix("0.") { return .text(s) }
        return .number(percent ? d / 100 : d)
    }
}

public struct Sheet: Sendable {
    public var name: String
    public var rows: [[CellValue]]
    public init(name: String, rows: [[CellValue]]) { self.name = name; self.rows = rows }
    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

public struct Workbook: Sendable {
    public var sheets: [Sheet]
    public init(sheets: [Sheet]) { self.sheets = sheets }
}
