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

/// Vertical position of a run: superscript and subscript carry meaning ("10⁵", "H₂O"), so they are content.
public enum DocBaseline: String, Hashable, Sendable { case normal, superscript, `subscript` }

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
    public var baseline: DocBaseline
    /// Ruby (furigana) reading of `text`, which is the base text. Writers with real ruby (HTML, Word) show it above
    /// the base; every other target writes the reading after the base in full-width parentheses: 漢字（かんじ）.
    public var ruby: String?
    /// Set on a note reference mark: the `DocNote.id` it points to. `text` is the visible mark ("1", "i").
    public var noteID: Int?
    /// An inline picture (used inside table cells). `text` is its alt text, which targets without pictures print.
    public var image: DocImage?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                strikethrough: Bool = false, code: Bool = false, fontSize: Double? = nil,
                fontName: String? = nil, color: DocColor? = nil, highlight: DocColor? = nil, link: String? = nil,
                baseline: DocBaseline = .normal, ruby: String? = nil, noteID: Int? = nil, image: DocImage? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.underline = underline
        self.strikethrough = strikethrough; self.code = code; self.fontSize = fontSize
        self.fontName = fontName; self.color = color; self.highlight = highlight; self.link = link
        self.baseline = baseline; self.ruby = ruby; self.noteID = noteID; self.image = image
    }

    /// True when two runs could be merged without losing formatting. Ruby groups, note marks and pictures are units of
    /// their own and never merge.
    public func sameStyle(as o: DocRun) -> Bool {
        bold == o.bold && italic == o.italic && underline == o.underline && strikethrough == o.strikethrough &&
        code == o.code && fontSize == o.fontSize && fontName == o.fontName && color == o.color &&
        highlight == o.highlight && link == o.link && baseline == o.baseline &&
        ruby == nil && o.ruby == nil && noteID == nil && o.noteID == nil && image == nil && o.image == nil
    }

    /// The run as plain text, for targets without formatting (text files, copy text, Markdown where noted):
    ///   - ruby: base followed by the reading in full-width parentheses, 漢字（かんじ）;
    ///   - superscript / subscript: Unicode super/subscript characters when every character has one ("10⁵", "H₂O"),
    ///     otherwise "^(…)" / "_(…)" so the meaning never silently changes ("x^(n+1)");
    ///   - note marks: "[1]", matching the "[1] …" notes list at the end;
    ///   - pictures: their alt text.
    public var plainForm: String {
        if noteID != nil { return "[\(text)]" }
        var t = text
        switch baseline {
        case .normal: break
        case .superscript: t = DocRun.scripted(t, DocRun.superscripts, caret: "^")
        case .subscript: t = DocRun.scripted(t, DocRun.subscripts, caret: "_")
        }
        if let r = ruby, !r.isEmpty { t += "（\(r)）" }
        return t
    }

    static func scripted(_ s: String, _ table: [Character: Character], caret: String) -> String {
        if !s.isEmpty, s.allSatisfy({ table[$0] != nil }) { return String(s.map { table[$0]! }) }
        return s.isEmpty ? s : "\(caret)(\(s))"
    }

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
    ]
    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
    ]
}

public enum DocAlignment: String, Hashable, Sendable { case left, center, right, justify }

public struct DocParagraph: Hashable, Sendable {
    public var runs: [DocRun]
    public var alignment: DocAlignment
    /// Left indent in points (0 = none).
    public var indent: Double
    /// Formatting from a source with its own page layout (Word); only the PDF renderer uses it. nil elsewhere.
    public var format: DocParagraphFormat? = nil

    public init(_ runs: [DocRun], alignment: DocAlignment = .left, indent: Double = 0) {
        self.runs = runs; self.alignment = alignment; self.indent = indent
    }
    public init(text: String, alignment: DocAlignment = .left) {
        self.init([DocRun(text)], alignment: alignment)
    }

    public var plainText: String { runs.map(\.text).joined() }
    /// The text with ruby, super/subscripts and note marks spelled out (see `DocRun.plainForm`).
    public var plainForm: String { runs.map(\.plainForm).joined() }
    public var isEmpty: Bool { plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !runs.contains { $0.image != nil } }

    /// Merges adjacent runs with identical style.
    public func normalized() -> DocParagraph {
        var out: [DocRun] = []
        for r in runs where !r.text.isEmpty || r.image != nil {
            if let last = out.last, last.sameStyle(as: r) { out[out.count - 1].text += r.text } else { out.append(r) }
        }
        var p = self; p.runs = out; return p
    }
}

/// A footnote or endnote. The reference mark in the text is a run with `noteID == id` and `text == label`.
public struct DocNote: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case footnote, endnote }
    public var id: Int
    public var kind: Kind
    /// The mark as the source numbers it: "1", "2" for footnotes, "i", "ii" for endnotes (Word's defaults).
    public var label: String
    public var paragraphs: [DocParagraph]
    public init(id: Int, kind: Kind, label: String, paragraphs: [DocParagraph]) {
        self.id = id; self.kind = kind; self.label = label; self.paragraphs = paragraphs
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
    /// The same picture as vector PDF (Word's EMF pictures, which `data` carries as PNG); only the PDF renderer uses it.
    public var vectorPDF: Data? = nil
    /// Where the picture sits in its paragraph's line (Word's inline pictures); only the PDF renderer uses it.
    public var placement: DocImagePlacement? = nil

    public init(data: Data, format: DocImageFormat, pixelWidth: Int, pixelHeight: Int,
                displayWidth: Double? = nil, displayHeight: Double? = nil, altText: String? = nil) {
        self.data = data; self.format = format; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.displayWidth = displayWidth ?? Double(pixelWidth) * 72 / 144
        self.displayHeight = displayHeight ?? Double(pixelHeight) * 72 / 144
        self.altText = altText
    }
}

/// How a numbered list level counts, in OOXML's vocabulary because it is the richest one: `format` is an
/// ST_NumberFormat name ("decimal", "decimalEnclosedCircle", "upperRoman", "iroha", …) and `pattern` the level text
/// with %1…%9 standing for the counters of levels 1…9 ("(%1)", "第%1条", "%1.%2"). Only the Word writer uses it;
/// every other writer prints `DocListItem.marker`.
public struct DocListNumbering: Hashable, Sendable {
    public var format: String
    public var pattern: String
    public init(format: String, pattern: String) { self.format = format; self.pattern = pattern }
}

public struct DocListItem: Hashable, Sendable {
    public var ordered: Bool
    /// Nesting depth, 0 = top level.
    public var level: Int
    /// Explicit number for ordered lists when known.
    public var number: Int?
    public var paragraph: DocParagraph
    /// The marker exactly as the source shows it ("(1)", "①", "Ⅱ.", "a)", "イ.", "第１条", "1.1", "➢").
    /// nil = the writer's default ("1." with `number`, or its own bullet).
    public var marker: String?
    public var numbering: DocListNumbering?
    public init(ordered: Bool, level: Int = 0, number: Int? = nil, paragraph: DocParagraph,
                marker: String? = nil, numbering: DocListNumbering? = nil) {
        self.ordered = ordered; self.level = level; self.number = number; self.paragraph = paragraph
        self.marker = marker; self.numbering = numbering
    }

    /// The marker text: the source's, else "1." for numbered items and `bullet` for the others.
    public func markerText(bullet: String) -> String {
        if let m = marker, !m.isEmpty { return m }
        return ordered ? "\(number ?? 1)." : bullet
    }
}

public struct DocTableCell: Hashable, Sendable {
    public var paragraphs: [DocParagraph]
    public var colSpan: Int
    /// Rows this cell covers (vertical merge). The cells it covers in the rows below stay in `rows` as empty
    /// placeholders, so writers that cannot merge vertically show them as empty cells.
    public var rowSpan: Int
    /// Background colour of the cell (spreadsheet fills); nil = none. Writers without cell shading ignore it.
    public var fill: DocColor? = nil
    public init(_ paragraphs: [DocParagraph], colSpan: Int = 1, rowSpan: Int = 1) {
        self.paragraphs = paragraphs; self.colSpan = colSpan; self.rowSpan = rowSpan
    }
    public init(text: String) { self.init([DocParagraph(text: text)]) }
    public var text: String { paragraphs.map(\.plainText).joined(separator: "\n") }
    var isBlank: Bool { paragraphs.allSatisfy(\.isEmpty) }
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

    /// Vertical merges as writers that merge cells should draw them. `rowSpan[r][i]` is the span of cell i of row r,
    /// clamped so that it only covers empty placeholder cells starting in the same column (a cell with content is
    /// never hidden) and never runs past the table; `covered[r][i]` marks the placeholders such a span covers, which
    /// those writers skip.
    public func verticalSpans() -> (rowSpan: [[Int]], covered: [[Bool]]) {
        var spans = rows.map { $0.map { _ in 1 } }
        var covered = rows.map { $0.map { _ in false } }
        let starts: [[Int]] = rows.map { row in
            var col = 0
            return row.map { c in defer { col += max(c.colSpan, 1) }; return col }
        }
        for r in rows.indices {
            for i in rows[r].indices where rows[r][i].rowSpan > 1 && !covered[r][i] {
                let col = starts[r][i]
                var span = 1
                while span < rows[r][i].rowSpan, r + span < rows.count,
                      let j = starts[r + span].firstIndex(of: col), !covered[r + span][j], rows[r + span][j].isBlank,
                      rows[r + span][j].rowSpan <= 1 {
                    covered[r + span][j] = true
                    span += 1
                }
                spans[r][i] = span
            }
        }
        return (spans, covered)
    }
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
    /// Font family the source used for East Asian body text (Word's eastAsia font, "ＭＳ 明朝"), if known.
    public var bodyEastAsianFontName: String?
    /// Footnotes and endnotes, in the order their marks appear. Marks are runs with `noteID`.
    public var notes: [DocNote]
    /// Sections, headers, footers and paragraph formatting of a source with its own page layout (Word). When set, the
    /// PDF renderer lays the pages out like the source; nil for everything else.
    public var pageLayout: DocPageLayout? = nil

    public init(title: String? = nil, blocks: [DocBlock] = [], pageSize: CGSize? = nil,
                bodyFontSize: Double = 11, bodyFontName: String? = nil, notes: [DocNote] = [], bodyEastAsianFontName: String? = nil) {
        self.title = title; self.blocks = blocks; self.pageSize = pageSize
        self.bodyFontSize = bodyFontSize; self.bodyFontName = bodyFontName; self.notes = notes
        self.bodyEastAsianFontName = bodyEastAsianFontName
    }

    public static let a4 = CGSize(width: 595.28, height: 841.89)

    /// All text, one block per line group. Used by "copy text" and plain-text export. Ruby, super/subscripts and
    /// note marks are spelled out (`DocRun.plainForm`); the notes follow the text as "[1] …" lines, footnotes first.
    public var plainText: String {
        var parts: [String] = []
        for b in blocks {
            switch b {
            case .heading(_, let p), .paragraph(let p), .quote(let p): parts.append(p.plainForm)
            case .listItem(let li):
                let indent = String(repeating: "  ", count: li.level)
                let marker = li.markerText(bullet: "・")
                parts.append(indent + marker + (marker == "・" ? "" : " ") + li.paragraph.plainForm)
            case .code(let s, _): parts.append(s)
            case .table(let t): parts.append(t.rows.map { $0.map { $0.paragraphs.map(\.plainForm).joined(separator: "\n") }.joined(separator: "\t") }.joined(separator: "\n"))
            case .image(let img): if let alt = img.altText, !alt.isEmpty { parts.append(alt) }
            case .pageBreak: parts.append("")
            case .horizontalRule: parts.append("")
            }
        }
        let notes = orderedNotes.map { n in "[\(n.label)] " + n.paragraphs.map(\.plainForm).joined(separator: "\n") }
        if !notes.isEmpty { parts.append(notes.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n").replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
    }

    /// Footnotes, then endnotes, each in mark order: the order every writer lists them in.
    public var orderedNotes: [DocNote] { notes.filter { $0.kind == .footnote } + notes.filter { $0.kind == .endnote } }
}

// MARK: - Spreadsheets

public enum CellValue: Hashable, Sendable {
    case empty
    case text(String)
    /// A number shown in Excel's General format.
    case number(Double)
    case bool(Bool)
    /// A number together with the Excel number format code it is shown with and the text that format shows
    /// ("¥1,500" for 1500 with "\"¥\"#,##0"). Document targets and CSV print `display`; the xlsx writer stores the
    /// number and the format, so the spreadsheet shows the same text.
    case formatted(Double, format: String, display: String)

    public var displayString: String {
        switch self {
        case .empty: return ""
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .number(let d): return d.isFinite ? Self.generalString(d) : String(d)
        case .formatted(_, _, let display): return display
        }
    }

    /// Excel's General format, as far as it does not depend on the column width: integers below 10^15 exactly;
    /// everything else rounded to 15 significant digits (Excel's precision) without trailing zeros, so a stored
    /// 0.30000000000000004 prints "0.3"; scientific notation in Excel's style ("1.23456789012346E+15", "1.2E-10")
    /// from 10^15 and below 10^-9.
    public static func generalString(_ d: Double) -> String {
        guard d.isFinite else { return String(d) }
        if d == 0 { return "0" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        // "%.14e" rounds to 15 significant digits: "-1.23456789012346e+15".
        let e = String(format: "%.14e", d)
        guard let eIndex = e.firstIndex(where: { $0 == "e" || $0 == "E" }), let exp = Int(e[e.index(after: eIndex)...]) else { return String(d) }
        let negative = e.hasPrefix("-")
        var digits = e[..<eIndex].filter(\.isNumber)
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let sign = negative ? "-" : ""
        if exp >= 15 || exp < -9 {
            let mantissa = digits.count > 1 ? "\(digits.first!).\(digits.dropFirst())" : String(digits)
            return sign + mantissa + "E" + (exp < 0 ? "-" : "+") + String(format: "%02d", abs(exp))
        }
        if exp < 0 { return sign + "0." + String(repeating: "0", count: -exp - 1) + digits }
        if digits.count <= exp + 1 { return sign + digits + String(repeating: "0", count: exp + 1 - digits.count) }
        return sign + digits.prefix(exp + 1) + "." + digits.dropFirst(exp + 1)
    }

    /// The cell for a piece of text (a CSV field) that must keep showing exactly that text: `displayString` of the
    /// result is always `text`, so documents print it unchanged. It becomes a number (for Excel output) only when
    /// Excel then shows exactly the same text and nothing is lost:
    ///   - integers: "0", or an optional "-" and 1-11 digits without a leading zero. Longer digit runs stay text:
    ///     Excel's General format shows 12+ digits in scientific notation, and they are codes (JAN, card and account
    ///     numbers), not amounts.
    ///   - decimals: an integer part as above (or "0"), ".", one or more digits. Stored in General when General
    ///     surely prints them as written (at most 11 characters, at least 0.001, no trailing zero: "0.5", "1234.5"),
    ///     otherwise with a fixed-decimals format ("1.10" -> 1.1 shown with "0.00"; "0.00001" with "0.00000").
    ///   - thousands separators only in the unambiguous form: a first group of 1-3 digits, then ",ddd" groups
    ///     ("1,234", "12,345,678.90"), stored with "#,##0…". Never with `decimalComma` (semicolon-separated CSV);
    ///     "1,5", "12,34" and "1,2,3" stay text.
    ///   - "%" at the end ("12.5%" -> 0.125 with "0.0%"); ¥ ￥ $ € £ in front or 円 at the end, with any minus first
    ///     ("-¥1,500"); each stored with the matching number format.
    ///   - at most 15 significant digits (Excel's precision); no "+", no leading zeros ("007"), no "-0", no ".5" or
    ///     "5.", no exponent ("1e5": Excel would show 1.00E+05), no spaces, no full-width digits, no "(1,000)" or
    ///     "▲300"; with `decimalComma` no "." followed by exactly three digits ("1.234" is 1234 in German).
    /// Everything else is text, including dates ("2024/01/15", "2024-02-29", "令和6年3月1日") and TRUE/FALSE, which
    /// MaruDoc has always kept as text.
    /// PDF and Markdown/HTML table cells still use the lenient `guess`.
    public static func typed(_ text: String, decimalComma: Bool = false) -> CellValue {
        number(text, decimalComma: decimalComma) ?? .text(text)
    }

    private static func number(_ field: String, decimalComma: Bool) -> CellValue? {
        let scalars = Array(field.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 64 else { return nil }
        var i = 0, end = scalars.count
        var negative = false, prefix = "", suffix = ""
        if scalars[i] == "-" { negative = true; i += 1 }
        if i < end, "¥￥$€£".unicodeScalars.contains(scalars[i]) { prefix = String(scalars[i]); i += 1 }
        if end > i, scalars[end - 1] == "%" { suffix = "%"; end -= 1 }
        else if end > i, scalars[end - 1] == "円" { suffix = "円"; end -= 1 }
        guard prefix.isEmpty || suffix.isEmpty else { return nil }

        // Integer part: "0" or digits without a leading zero, optionally a first group of 1-3 digits followed by
        // ",ddd" groups.
        func isDigit(_ u: Unicode.Scalar) -> Bool { ("0"..."9").contains(u) }
        var intDigits = "", grouped = false
        while i < end, isDigit(scalars[i]) { intDigits.unicodeScalars.append(scalars[i]); i += 1 }
        if i < end, scalars[i] == ",", !decimalComma, (1...3).contains(intDigits.count), !intDigits.hasPrefix("0") {
            while i < end, scalars[i] == "," {
                guard i + 3 < end, isDigit(scalars[i + 1]), isDigit(scalars[i + 2]), isDigit(scalars[i + 3]) else { return nil }
                for k in 1...3 { intDigits.unicodeScalars.append(scalars[i + k]) }
                i += 4
                grouped = true
            }
        }
        guard !intDigits.isEmpty else { return nil }
        if intDigits.count > 1 && intDigits.hasPrefix("0") { return nil }
        var fracDigits = ""
        var hasPoint = false
        if i < end, scalars[i] == "." {
            hasPoint = true
            i += 1
            while i < end, isDigit(scalars[i]) { fracDigits.unicodeScalars.append(scalars[i]); i += 1 }
            guard !fracDigits.isEmpty else { return nil }
            if decimalComma && fracDigits.count == 3 { return nil }
        }
        guard i == end else { return nil } // a digit after a group ("1,2345"), a second point, letters, spaces …

        let significant = (intDigits + fracDigits).drop { $0 == "0" }.count
        guard significant <= 15 else { return nil }
        // 12+ digit integers without separators are codes; Excel's General shows them in scientific notation.
        if !grouped && !hasPoint && prefix.isEmpty && suffix.isEmpty && intDigits.count > 11 { return nil }

        // The value from the decimal text (percent: the point moves two places), so it is the nearest double.
        var digits = intDigits + fracDigits
        let scale = fracDigits.count + (suffix == "%" ? 2 : 0)
        while digits.count <= scale { digits = "0" + digits }
        let text = (negative ? "-" : "") + String(digits.dropLast(scale)) + (scale > 0 ? "." + String(digits.suffix(scale)) : "")
        guard let v = Double(text), v.isFinite else { return nil }
        if negative && v == 0 { return nil } // "-0": Excel shows 0
        // General when Excel's General format shows exactly the field: up to 11 characters in a standard-width
        // column, and no scientific notation for small values.
        if !grouped, prefix.isEmpty, suffix.isEmpty, field.count <= 11, !hasPoint || abs(v) >= 0.001,
           generalString(v) == field { return .number(v) }

        var code = grouped ? "#,##0" : "0"
        if hasPoint { code += "." + String(repeating: "0", count: fracDigits.count) }
        switch suffix {
        case "%": code += "%"
        case "円": code += "\"円\""
        default: break
        }
        if !prefix.isEmpty { code = "\"" + prefix + "\"" + code }
        return .formatted(v, format: code, display: field)
    }

    /// Parses "1,234", "¥1,234", "12.5%", "-3" as numbers; everything else stays text.
    /// Lenient on purpose: it drops every comma and currency sign and reads "12.5%" as 0.125, so it is a "does this
    /// look numeric" test (PDF table detection) and a best-effort typing for tables recovered from PDF, Markdown and
    /// HTML. It changes what such cells show ("1,5" becomes 15); CSV input uses `typed` instead.
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
