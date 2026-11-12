import Foundation
import EnsoDoc

/// SpreadsheetML (.xlsx / .xlsm) -> Workbook, holding what Excel would print: hidden and very hidden sheets, hidden
/// rows (also rows hidden by a collapsed outline or an autofilter, which Excel marks hidden) and hidden columns are
/// left out. Formulas yield their cached values, or their text ("=SUM(A1:A3)") when the file has none. Numbers keep
/// the text their number format shows (see ExcelNumberFormat); date-formatted numbers become text in the cell's own
/// custom format, or "yyyy-MM-dd" (plus " HH:mm[:ss]") for built-in formats whose look depends on the user's locale.
public enum XlsxReader {
    public static func read(_ url: URL) throws -> Workbook {
        try read(data: try Data.readOffice(url))
    }

    public static func read(data: Data) throws -> Workbook {
        let zip = try ZipReader(data: data)
        let main = try OPC.mainPart(zip, fallback: "xl/workbook.xml")
        let wb = try XNode.parse(try zip.data(main), part: main)
        guard wb.tag == "x:workbook" else { throw OfficeError.invalidDocument("\(main) is not an Excel workbook") }
        let rels = try OPC.relationships(zip, for: main)
        let relById = Dictionary(rels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let date1904 = OOXMLValue.onOff(wb.child("x:workbookPr")?["date1904"] ?? "0")

        var shared: [String] = []
        if let r = rels.first(where: { $0.isType("sharedStrings") }), zip.contains(r.target) {
            shared = try sharedStrings(try zip.data(r.target), part: r.target)
        }
        var formats: [CellFormat] = []
        if let r = rels.first(where: { $0.isType("styles") }), zip.contains(r.target) {
            formats = styleFormats(try XNode.parse(try zip.data(r.target), part: r.target))
        }

        var sheets: [Sheet] = []
        for s in wb.child("x:sheets")?.children("x:sheet") ?? [] {
            // Hidden sheets are not printed by Excel or Numbers and often hold what the author did not want to share.
            let state = (s["state"] ?? "visible").lowercased()
            if state == "hidden" || state == "veryhidden" { continue }
            guard let id = s["r:id"], let rel = relById[id], rel.isType("worksheet"), zip.contains(rel.target) else { continue }
            let name = s["name"] ?? "Sheet\(sheets.count + 1)"
            let rows = try sheetRows(try zip.data(rel.target), part: rel.target, shared: shared, formats: formats, date1904: date1904)
            sheets.append(Sheet(name: name, rows: rows))
        }
        return Workbook(sheets: sheets)
    }

    // MARK: Shared strings

    static func sharedStrings(_ data: Data, part: String) throws -> [String] {
        var out: [String] = []
        var current = ""
        var inSI = false, collecting = false, phonetic = 0
        try OOXMLSAX.run(data, part: part) { sax in
            sax.onStart = { tag, _ in
                switch tag {
                case "x:si": inSI = true; current = ""
                case "x:rPh": phonetic += 1          // furigana runs are not cell text
                case "x:t": collecting = inSI && phonetic == 0
                default: break
                }
            }
            sax.onEnd = { tag in
                switch tag {
                case "x:si": out.append(decodeEscapes(current)); inSI = false
                case "x:rPh": phonetic -= 1
                case "x:t": collecting = false
                default: break
                }
            }
            sax.onText = { s in if collecting { current += s } }
        }
        return out
    }

    /// Decodes Excel's "_xHHHH_" character escapes.
    static func decodeEscapes(_ s: String) -> String {
        guard s.contains("_x") else { return s }
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            if u[i] == "_", i + 6 < u.count, u[i + 1] == "x", u[i + 6] == "_",
               let v = UInt32(String(String.UnicodeScalarView(u[(i + 2)..<(i + 6)])), radix: 16), let scalar = Unicode.Scalar(v) {
                out.append(scalar)
                i += 7
                continue
            }
            out.append(u[i])
            i += 1
        }
        return String(out)
    }

    // MARK: Styles / dates

    enum DateKind { case date, time, dateTime, elapsed }

    /// The number format of one cell style (one entry of cellXfs).
    struct CellFormat {
        var dateKind: DateKind?
        /// The format code to render numbers with: the file's own code, or Excel's code for the built-in formats that
        /// look the same in every locale. nil for General and for locale-dependent built-ins (currency 5-8,
        /// accounting 41-44, the dates and times 14-22 / 27-36 / 45-47 / 50-58), which keep the plain forms.
        var code: String?
    }

    /// Built-in formats (ECMA-376 18.8.30) that do not depend on the locale. 37-40 are written without Excel's
    /// trailing alignment space ("#,##0 ;(#,##0)"), which would only add a blank to every printed value.
    static let builtinCodes: [Int: String] = [
        1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 9: "0%", 10: "0.00%", 11: "0.00E+00",
        37: "#,##0_);(#,##0)", 38: "#,##0_);[Red](#,##0)", 39: "#,##0.00_);(#,##0.00)", 40: "#,##0.00_);[Red](#,##0.00)",
    ]

    static func styleFormats(_ root: XNode) -> [CellFormat] {
        var custom: [Int: String] = [:]
        for f in root.child("x:numFmts")?.children("x:numFmt") ?? [] {
            if let id = OOXMLValue.int(f["numFmtId"]) { custom[id] = f["formatCode"] ?? "" }
        }
        return (root.child("x:cellXfs")?.children("x:xf") ?? []).map { xf in
            let id = OOXMLValue.int(xf["numFmtId"]) ?? 0
            return CellFormat(dateKind: dateKind(numFmtId: id, code: custom[id]), code: custom[id] ?? builtinCodes[id])
        }
    }

    static func dateKind(numFmtId: Int, code: String?) -> DateKind? {
        if let code { return dateKind(formatCode: code) }
        switch numFmtId {
        case 14...17, 27...36, 50...58: return .date
        case 18...21, 45, 47: return .time
        case 46: return .elapsed
        case 22: return .dateTime
        default: return nil
        }
    }

    /// Looks for y/m/d/h/s outside quoted text, escapes and [colour]/[locale] brackets, in the first section.
    static func dateKind(formatCode code: String) -> DateKind? {
        var s = ""
        var inQuote = false, skipNext = false, inBracket = false
        var bracket = ""
        var elapsed = false
        for ch in code {
            if skipNext { skipNext = false; continue }
            if inQuote { if ch == "\"" { inQuote = false }; continue }
            if inBracket {
                if ch == "]" {
                    inBracket = false
                    let b = bracket.lowercased()
                    if !b.isEmpty, b.allSatisfy({ "hms".contains($0) }) { elapsed = true; s += b }
                    bracket = ""
                } else { bracket.append(ch) }
                continue
            }
            switch ch {
            case "\"": inQuote = true
            case "\\", "_", "*": skipNext = true
            case "[": inBracket = true
            case ";": break
            default: s.append(ch)
            }
            if ch == ";" { break }
        }
        let l = s.lowercased().replacingOccurrences(of: "am/pm", with: "").replacingOccurrences(of: "a/p", with: "")
        if l.contains("general") || l == "@" { return nil }
        let hasTime = l.contains("h") || l.contains("s")
        let hasDate = l.contains("y") || l.contains("d") || (l.contains("m") && !hasTime)
        if hasDate && hasTime { return .dateTime }
        if hasDate { return .date }
        if hasTime { return elapsed ? .elapsed : .time }
        return nil
    }

    static func formatSerial(_ serial: Double, kind: DateKind, date1904: Bool) -> String? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
        var days = Int(serial.rounded(.down))
        var secs = Int(((serial - Double(days)) * 86400).rounded())
        if secs >= 86400 { days += 1; secs -= 86400 }
        let hh = secs / 3600, mm = (secs % 3600) / 60, ss = secs % 60
        let time = ss == 0 ? String(format: "%02d:%02d", hh, mm) : String(format: "%02d:%02d:%02d", hh, mm, ss)

        switch kind {
        case .time: return time
        case .elapsed:
            let totalHours = days * 24 + hh
            return ss == 0 ? String(format: "%d:%02d", totalHours, mm) : String(format: "%d:%02d:%02d", totalHours, mm, ss)
        case .date, .dateTime:
            let date: String
            if !date1904 && days == 60 {
                date = "1900-02-29" // Lotus 1-2-3 leap-year bug that Excel keeps
            } else {
                let unixDays = date1904 ? days - 24107 : (days < 60 ? days - 25568 : days - 25569)
                let (y, m, d) = civil(fromDays: unixDays)
                date = String(format: "%04d-%02d-%02d", y, m, d)
            }
            return kind == .dateTime ? date + " " + time : date
        }
    }

    /// Days since 1970-01-01 -> proleptic Gregorian date (Howard Hinnant's algorithm).
    static func civil(fromDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    // MARK: Sheet data

    /// "AB12" -> (column 27, row 12) with 0-based column and 1-based row.
    static func parseRef(_ ref: String) -> (col: Int, row: Int)? {
        var col = 0, row = 0
        var sawLetter = false, sawDigit = false
        for u in ref.utf8 {
            switch u {
            case 65...90, 97...122:
                guard !sawDigit else { return nil }
                col = col * 26 + Int((u & 0xDF) - 64)
                sawLetter = true
                if col > XlsxWriter.maxColumns { return nil }
            case 48...57:
                row = row * 10 + Int(u - 48)
                sawDigit = true
                if row > XlsxWriter.maxRows { return nil }
            case 36: continue // "$A$1"
            default: return nil
            }
        }
        guard sawLetter, sawDigit, row > 0 else { return nil }
        return (col - 1, row)
    }

    static func sheetRows(_ data: Data, part: String, shared: [String], formats: [CellFormat], date1904: Bool) throws -> [[CellValue]] {
        var cells: [Int: [Int: CellValue]] = [:]
        var row = 0, col = -1
        var type = "n", style = 0
        var value = "", inline = "", formula = "", formulaType = "", formulaIndex = ""
        var inValue = false, sawValue = false, inInline = false, inInlineText = false, inFormula = false, phonetic = 0, inCell = false
        // Hidden rows and columns are left out, as Excel and Numbers leave them out when printing. Rows hidden by a
        // collapsed outline group or filtered out by an autofilter carry the same hidden flag.
        var hiddenRows = Set<Int>()
        var hiddenColumns: [ClosedRange<Int>] = []
        // Shared formulas: the master cell carries the text, the others only the group index.
        var sharedFormulas: [String: (text: String, row: Int, col: Int)] = [:]

        try OOXMLSAX.run(data, part: part) { sax in
            sax.onStart = { tag, attrs in
                switch tag {
                case "x:col":
                    if let h = attrs["hidden"], OOXMLValue.onOff(h),
                       let lo = OOXMLValue.int(attrs["min"]), let hi = OOXMLValue.int(attrs["max"]), lo >= 1, hi >= lo {
                        hiddenColumns.append((lo - 1)...min(hi - 1, XlsxWriter.maxColumns - 1))
                    }
                case "x:row":
                    row = OOXMLValue.int(attrs["r"]).flatMap { (1...XlsxWriter.maxRows).contains($0) ? $0 : nil } ?? min(row + 1, XlsxWriter.maxRows + 1)
                    col = -1
                    if let h = attrs["hidden"], OOXMLValue.onOff(h) { hiddenRows.insert(row) }
                case "x:c":
                    if let r = attrs["r"], let ref = parseRef(r) { col = ref.col; row = ref.row } else { col += 1 }
                    if row == 0 { row = 1 }
                    type = attrs["t"] ?? "n"
                    style = OOXMLValue.int(attrs["s"]) ?? 0
                    value = ""; inline = ""; formula = ""; formulaType = ""; formulaIndex = ""; sawValue = false; inCell = true
                case "x:v": inValue = inCell; sawValue = sawValue || inCell
                case "x:f":
                    inFormula = inCell
                    formulaType = attrs["t"] ?? ""; formulaIndex = attrs["si"] ?? ""
                case "x:is": inInline = inCell
                case "x:rPh": phonetic += 1
                case "x:t": inInlineText = inInline && phonetic == 0
                default: break
                }
            }
            sax.onEnd = { tag in
                switch tag {
                case "x:v": inValue = false
                case "x:f": inFormula = false
                case "x:t": inInlineText = false
                case "x:rPh": phonetic -= 1
                case "x:is": inInline = false
                case "x:c":
                    inCell = false
                    guard row >= 1, row <= XlsxWriter.maxRows, col >= 0, col < XlsxWriter.maxColumns else { return }
                    if formulaType == "shared", !formulaIndex.isEmpty {
                        if !formula.isEmpty { sharedFormulas[formulaIndex] = (formula, row, col) }
                        else if let master = sharedFormulas[formulaIndex] {
                            formula = shiftFormula(master.text, rows: row - master.row, columns: col - master.col)
                        }
                    }
                    guard !hiddenRows.contains(row), !hiddenColumns.contains(where: { $0.contains(col) }) else { return }
                    let format = style >= 0 && style < formats.count ? formats[style] : CellFormat()
                    var v = cellValue(type: type, value: value, inline: inline, shared: shared, format: format, date1904: date1904)
                    // No cached result (files written by openpyxl and other generators that do not calculate): show
                    // the formula rather than a blank that looks like real data. A string formula whose cached
                    // result is an empty string has an empty <v> and stays blank.
                    if v == .empty, !formula.isEmpty, value.isEmpty, !(type == "str" && sawValue) {
                        v = .text("=" + formula)
                    }
                    if v != .empty { cells[row, default: [:]][col] = v }
                default: break
                }
            }
            sax.onText = { s in
                if inValue { value += s } else if inInlineText { inline += s } else if inFormula { formula += s }
            }
        }

        guard let maxRow = cells.keys.max() else { return [] }
        // Close the gaps that hidden rows and columns leave.
        let skippedRows = hiddenRows.filter { $0 < maxRow }.sorted()
        let columnGaps = mergedRanges(hiddenColumns)
        func newRow(_ r: Int) -> Int { r - 1 - countBelow(r, in: skippedRows) }
        func newColumn(_ c: Int) -> Int { c - hiddenCount(before: c, in: columnGaps) }
        var rows: [[CellValue]] = Array(repeating: [], count: newRow(maxRow) + 1)
        for (r, dict) in cells {
            guard let maxCol = dict.keys.max() else { continue }
            var line = Array(repeating: CellValue.empty, count: newColumn(maxCol) + 1)
            for (c, v) in dict { line[newColumn(c)] = v }
            rows[newRow(r)] = line
        }
        return rows
    }

    /// Number of elements of the sorted array that are smaller than `value`.
    static func countBelow(_ value: Int, in sorted: [Int]) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < value { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// Sorted, non-overlapping ranges with the number of hidden columns before each one.
    static func mergedRanges(_ ranges: [ClosedRange<Int>]) -> [(range: ClosedRange<Int>, before: Int)] {
        var out: [(range: ClosedRange<Int>, before: Int)] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.range.upperBound + 1 {
                out[out.count - 1].range = last.range.lowerBound...max(last.range.upperBound, r.upperBound)
            } else {
                out.append((r, out.last.map { $0.before + $0.range.count } ?? 0))
            }
        }
        return out
    }

    static func hiddenCount(before column: Int, in gaps: [(range: ClosedRange<Int>, before: Int)]) -> Int {
        var lo = 0, hi = gaps.count
        while lo < hi { let mid = (lo + hi) / 2; if gaps[mid].range.lowerBound < column { lo = mid + 1 } else { hi = mid } }
        guard lo > 0 else { return 0 }
        let g = gaps[lo - 1]
        return g.before + min(column, g.range.upperBound + 1) - g.range.lowerBound
    }

    /// The formula of a shared-formula cell: the master's text with its relative A1 references moved by the offset.
    /// Absolute parts ($A, $1), text in quotes, sheet names in quotes and structured references stay as they are;
    /// a reference moved off the sheet becomes #REF!, as in Excel.
    static func shiftFormula(_ f: String, rows dr: Int, columns dc: Int) -> String {
        let s = Array(f.unicodeScalars)
        var out = String.UnicodeScalarView()
        func isWord(_ u: Unicode.Scalar) -> Bool { u.properties.isAlphabetic || ("0"..."9").contains(u) || u == "_" || u == "." || u == "\\" }
        func isLetter(_ u: Unicode.Scalar) -> Bool { ("A"..."Z").contains(u) || ("a"..."z").contains(u) }
        func isDigit(_ u: Unicode.Scalar) -> Bool { ("0"..."9").contains(u) }
        var i = 0
        while i < s.count {
            let u = s[i]
            if u == "\"" || u == "'" || u == "[" {
                // Copy a string literal, a quoted sheet name or a structured reference unchanged.
                let close: Unicode.Scalar = u == "[" ? "]" : u
                out.append(u); i += 1
                while i < s.count {
                    out.append(s[i])
                    if s[i] == close { if close != "]", i + 1 < s.count, s[i + 1] == close { i += 1; out.append(s[i]) } else { i += 1; break } }
                    i += 1
                }
                continue
            }
            if (u == "$" || isLetter(u)) && (i == 0 || !isWord(s[i - 1]) || s[i - 1] == "$") {
                // Try "$?COL$?ROW" not followed by a word character or "(" (that would be a name or a function).
                var j = i
                let colAbs = s[j] == "$"; if colAbs { j += 1 }
                let colStart = j
                while j < s.count, isLetter(s[j]), j - colStart < 3 { j += 1 }
                let colEnd = j
                let rowAbs = j < s.count && s[j] == "$"; if rowAbs { j += 1 }
                let rowStart = j
                while j < s.count, isDigit(s[j]), j - rowStart < 7 { j += 1 }
                if colEnd > colStart, j > rowStart, j == s.count || !(isWord(s[j]) || s[j] == "(" || s[j] == "$"),
                   let ref = parseRef(String(String.UnicodeScalarView(s[colStart..<colEnd])) + String(String.UnicodeScalarView(s[rowStart..<j]))) {
                    let c = colAbs ? ref.col : ref.col + dc
                    let r = rowAbs ? ref.row : ref.row + dr
                    if c < 0 || c >= XlsxWriter.maxColumns || r < 1 || r > XlsxWriter.maxRows {
                        out.append(contentsOf: "#REF!".unicodeScalars)
                    } else {
                        out.append(contentsOf: ((colAbs ? "$" : "") + XlsxWriter.columnName(c) + (rowAbs ? "$" : "") + String(r)).unicodeScalars)
                    }
                    i = j
                    continue
                }
                // Not a reference: copy the whole word so its tail is not read as one.
                out.append(u); i += 1
                while i < s.count, isWord(s[i]) { out.append(s[i]); i += 1 }
                continue
            }
            out.append(u); i += 1
        }
        return String(out)
    }

    static func cellValue(type: String, value: String, inline: String, shared: [String], format: CellFormat, date1904: Bool) -> CellValue {
        switch type {
        case "s":
            guard let i = Int(value.trimmingCharacters(in: .whitespaces)), i >= 0, i < shared.count else { return .empty }
            return shared[i].isEmpty ? .empty : .text(shared[i])
        case "inlineStr":
            let t = decodeEscapes(inline.isEmpty ? value : inline)
            return t.isEmpty ? .empty : .text(t)
        case "str", "e":
            let t = decodeEscapes(value)
            return t.isEmpty ? .empty : .text(t)
        case "b":
            let t = value.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? .empty : .bool(t == "1" || t.lowercased() == "true")
        case "d":
            let t = value.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("T00:00:00") || t.hasSuffix("T00:00:00Z") { return .text(String(t.prefix(10))) }
            return t.isEmpty ? .empty : .text(t.replacingOccurrences(of: "T", with: " "))
        default:
            let t = value.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return .empty }
            guard let d = Double(t) else { return .text(t) }
            if let kind = format.dateKind {
                if let code = format.code, let s = ExcelNumberFormat.renderDate(d, code: code, date1904: date1904) { return .text(s) }
                if let s = formatSerial(d, kind: kind, date1904: date1904) { return .text(s) }
                return .number(d)
            }
            if let code = format.code, let s = ExcelNumberFormat.render(d, code: code) { return .formatted(d, format: code, display: s) }
            return .number(d)
        }
    }
}

/// The text Excel shows for a number in a given number format, for the formats people actually use.
///
/// Supported: General (also inside literals, as in `"¥"General`); digit placeholders 0 # ? with a decimal point,
/// thousands separators and trailing scaling commas (`#,##0,"千円"`); % (any number of them); scientific notation
/// with one integer digit (0.00E+00, 0.0e-0); literal text ("…", \x, and unquoted symbols such as ¥ $ € £ - + ( ) :
/// / and spaces); [$¥-411]-style currency tags; [Red] / [ColorN] (ignored); _x padding and *x fill (dropped); up to
/// four sections (positive;negative;zero;text). Rounding is half away from zero on the 15-digit decimal value, as in
/// Excel.
/// Dates and times (renderDate): y yy yyyy, m mm mmm mmmm mmmmm, d dd ddd dddd, aaa aaaa (日 / 日曜日), h hh,
/// m mm (minutes after h or before s), s ss with .0-.000 fractions, AM/PM and A/P, [h] [m] [s] elapsed time.
/// Not supported, so the caller falls back to General (numbers) or yyyy-MM-dd (dates): fractions (# ?/?),
/// conditions ([>=100]), [DBNum] numerals, engineering notation (##0.0E+0), Japanese era years (g, e), Buddhist
/// years (b), system date tags ([$-F800]) and month or weekday names under a non-English locale tag.
enum ExcelNumberFormat {

    /// Splits a format code into its sections at ";" outside quotes, escapes and brackets.
    static func sections(_ code: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false, inBracket = false, escape = false
        for ch in code {
            if escape { cur.append(ch); escape = false; continue }
            if inQuote { cur.append(ch); if ch == "\"" { inQuote = false }; continue }
            if inBracket { cur.append(ch); if ch == "]" { inBracket = false }; continue }
            switch ch {
            case "\"": inQuote = true; cur.append(ch)
            case "[": inBracket = true; cur.append(ch)
            case "\\", "_", "*": escape = true; cur.append(ch)
            case ";": out.append(cur); cur = ""
            default: cur.append(ch)
            }
        }
        out.append(cur)
        return out
    }

    private enum Token: Equatable {
        case literal(String), digit(Character), point, comma, percent, exponent(upper: Bool, plus: Bool, digits: Int), general
    }

    /// Tokens of one number section, or nil when it uses something unsupported.
    private static func tokens(_ section: String) -> [Token]? {
        let c = Array(section)
        var out: [Token] = []
        var i = 0
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "\"":
                var lit = ""
                i += 1
                while i < c.count, c[i] != "\"" { lit.append(c[i]); i += 1 }
                out.append(.literal(lit))
            case "\\":
                if i + 1 < c.count { out.append(.literal(String(c[i + 1]))); i += 1 }
            case "_", "*":
                i += 1 // padding to the width of the next character / fill with it: nothing to print
            case "[":
                var tag = ""
                i += 1
                while i < c.count, c[i] != "]" { tag.append(c[i]); i += 1 }
                if tag.hasPrefix("$") {
                    let symbol = tag.dropFirst().prefix { $0 != "-" }
                    if !symbol.isEmpty { out.append(.literal(String(symbol))) }
                } else if !isColor(tag) {
                    return nil // conditions, [DBNum], elapsed time in a number section
                }
            case "0", "#", "?": out.append(.digit(ch))
            case ".": out.append(.point)
            case ",": out.append(.comma)
            case "%": out.append(.percent)
            case "E", "e":
                guard i + 1 < c.count, c[i + 1] == "+" || c[i + 1] == "-" else { return nil }
                let plus = c[i + 1] == "+"
                var n = 0
                i += 2
                while i < c.count, "0#?".contains(c[i]) { n += 1; i += 1 }
                guard n > 0 else { return nil }
                out.append(.exponent(upper: ch == "E", plus: plus, digits: n))
                continue
            case "G", "g":
                guard String(c[i...].prefix(7)).lowercased() == "general" else { return nil }
                out.append(.general)
                i += 7
                continue
            case "/", "@": return nil // fractions; text placeholder in a number section
            default:
                if ch.isLetter && ch.isASCII { return nil } // date/time codes or unknown codes
                out.append(.literal(String(ch)))
            }
            i += 1
        }
        return out
    }

    private static func isColor(_ tag: String) -> Bool {
        let t = tag.lowercased()
        return ["black", "blue", "cyan", "green", "magenta", "red", "white", "yellow"].contains(t)
            || (t.hasPrefix("color") && Int(t.dropFirst(5)) != nil)
    }

    /// The text for `value`, or nil for General and unsupported codes (the caller then prints General).
    static func render(_ value: Double, code: String) -> String? {
        guard value.isFinite, abs(value) < 1e100 else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty || trimmed == "general" || trimmed == "@" { return nil }
        let secs = sections(code)
        guard secs.count <= 4 else { return nil }
        // positive;negative;zero;text. Only a single-section format adds the minus itself.
        let section: String
        switch secs.count {
        case 1: section = secs[0]
        case 2: section = value < 0 ? secs[1] : secs[0]
        default: section = value > 0 ? secs[0] : (value < 0 ? secs[1] : secs[2])
        }
        guard let toks = tokens(section), let body = renderSection(abs(value), toks) else { return nil }
        return secs.count == 1 && value < 0 ? "-" + body : body
    }

    private static func renderSection(_ magnitude: Double, _ toks: [Token]) -> String? {
        var a = magnitude
        let digitCount = toks.filter { if case .digit = $0 { return true }; return false }.count
        if digitCount == 0 {
            // Only literals (and perhaps General): "\"-\"" for zero in accounting formats, or "\"¥\"General".
            return toks.map { t -> String in
                switch t {
                case .literal(let s): return s
                case .general: return CellValue.generalString(a)
                case .percent: return "%"
                default: return ""
                }
            }.joined()
        }
        if toks.contains(.general) { return nil }
        for t in toks where t == .percent { a *= 100 }

        let pointIndex = toks.firstIndex(of: .point)
        let expIndex = toks.firstIndex { if case .exponent = $0 { return true }; return false }
        let numericEnd = expIndex ?? toks.count
        let intEnd = min(pointIndex ?? numericEnd, numericEnd)
        let lastDigit = toks[..<numericEnd].lastIndex { if case .digit = $0 { return true }; return false } ?? -1
        let firstIntDigit = toks[..<intEnd].firstIndex { if case .digit = $0 { return true }; return false }
        let lastIntDigit = toks[..<intEnd].lastIndex { if case .digit = $0 { return true }; return false }

        // Commas right after the last digit placeholder divide by 1000 each; commas between integer placeholders
        // switch on thousands separators.
        var grouping = false, scale = 0
        for (i, t) in toks.enumerated() where t == .comma {
            if i > lastDigit, i < numericEnd { scale += 1 }
            else if let f = firstIntDigit, let l = lastIntDigit, i > f, i < l { grouping = true }
        }
        for _ in 0..<scale { a /= 1000 }

        let intPlaceholders: [Character] = toks[..<intEnd].compactMap { if case .digit(let c) = $0 { return c }; return nil }
        let fracPlaceholders: [Character] = pointIndex.map { p in
            toks[(p + 1)..<numericEnd].compactMap { if case .digit(let c) = $0 { return c }; return nil }
        } ?? []

        var intDigits: String, fracDigits: String
        var exponentText = ""
        if let e = expIndex, case .exponent(let upper, let plus, let expDigits) = toks[e] {
            guard intPlaceholders.count == 1 else { return nil } // engineering notation
            guard let m = scientific(a, decimals: fracPlaceholders.count) else { return nil }
            intDigits = m.int; fracDigits = m.frac
            let ex = String(abs(m.exponent))
            exponentText = (upper ? "E" : "e") + (m.exponent < 0 ? "-" : (plus ? "+" : ""))
                + String(repeating: "0", count: max(0, expDigits - ex.count)) + ex
        } else {
            guard let f = fixed(a, decimals: fracPlaceholders.count) else { return nil }
            intDigits = f.int; fracDigits = f.frac
        }

        // Integer part.
        var intText: [Int: String] = [:] // token index -> text for integer placeholders
        let intTokenIndices = toks[..<intEnd].indices.filter { if case .digit = toks[$0] { return true }; return false }
        if grouping {
            let minDigits = intPlaceholders.filter { $0 == "0" }.count
            var digits = intDigits
            if digits.count < minDigits { digits = String(repeating: "0", count: minDigits - digits.count) + digits }
            var grouped = ""
            for (n, ch) in digits.reversed().enumerated() {
                if n > 0 && n % 3 == 0 { grouped.append(",") }
                grouped.append(ch)
            }
            if let first = intTokenIndices.first { intText[first] = String(grouped.reversed()) }
        } else {
            var remaining = Array(intDigits)
            for (k, idx) in intTokenIndices.enumerated().reversed() {
                let ph = intPlaceholders[k]
                if k == 0 {
                    intText[idx] = remaining.isEmpty ? (ph == "0" ? "0" : (ph == "?" ? " " : "")) : String(remaining)
                } else if let d = remaining.popLast() {
                    intText[idx] = String(d)
                } else {
                    intText[idx] = ph == "0" ? "0" : (ph == "?" ? " " : "")
                }
            }
        }

        // Decimal part: trailing zeros under # disappear, under ? become spaces.
        var fracText = Array(fracDigits).map(String.init)
        var j = fracText.count - 1
        while j >= 0, fracPlaceholders[j] != "0", fracText[j] == "0" {
            fracText[j] = fracPlaceholders[j] == "?" ? " " : ""
            j -= 1
        }

        var out = ""
        var fracIndex = 0
        for (i, t) in toks.enumerated() {
            switch t {
            case .literal(let s): out += s
            case .percent: out += "%"
            case .point: out += "."
            case .comma: if !grouping && i < intEnd && firstIntDigit.map({ i < $0 }) == true { out += "," }
            case .digit:
                if i < intEnd { out += intText[i] ?? "" }
                else if i < numericEnd, fracIndex < fracText.count { out += fracText[fracIndex]; fracIndex += 1 }
            case .exponent: out += exponentText
            case .general: break
            }
        }
        return out
    }

    /// Digits of `a` (>= 0) rounded half up at `decimals` places, from its 15-significant-digit decimal form.
    static func fixed(_ a: Double, decimals: Int) -> (int: String, frac: String)? {
        guard decimals <= 30 else { return nil }
        var k: [UInt8]
        if a == 0 {
            k = [0]
        } else {
            guard let (digits, exp) = significant(a) else { return nil }
            let keep = exp + 1 + decimals
            if keep < 0 {
                k = [0]
            } else if keep >= digits.count {
                k = digits + Array(repeating: 0, count: keep - digits.count)
            } else {
                k = Array(digits[..<keep])
                if digits[keep] >= 5 { k = increment(k) }
                if k.isEmpty { k = [0] }
            }
        }
        while k.count < decimals + 1 { k.insert(0, at: 0) }
        let intPart = k[..<(k.count - decimals)].drop { $0 == 0 }
        return (intPart.map { String($0) }.joined(), k[(k.count - decimals)...].map { String($0) }.joined())
    }

    /// Mantissa (one integer digit) and exponent of `a` (>= 0) rounded half up at `decimals` places.
    static func scientific(_ a: Double, decimals: Int) -> (int: String, frac: String, exponent: Int)? {
        guard decimals <= 30 else { return nil }
        if a == 0 { return ("0", String(repeating: "0", count: decimals), 0) }
        guard var (digits, exp) = significant(a) else { return nil }
        let keep = 1 + decimals
        var k: [UInt8]
        if keep >= digits.count {
            k = digits + Array(repeating: 0, count: keep - digits.count)
        } else {
            k = Array(digits[..<keep])
            if digits[keep] >= 5 { k = increment(k) }
            if k.count > keep { k.removeLast(); exp += 1 }
        }
        digits = k
        return (String(digits[0]), digits.dropFirst().map { String($0) }.joined(), exp)
    }

    /// The 15 significant decimal digits of `a` (> 0) and the power of ten of the first one.
    private static func significant(_ a: Double) -> ([UInt8], Int)? {
        let e = String(format: "%.14e", a)
        guard let eIndex = e.firstIndex(where: { $0 == "e" || $0 == "E" }), let exp = Int(e[e.index(after: eIndex)...]) else { return nil }
        let digits = e[..<eIndex].compactMap { $0.wholeNumberValue.map(UInt8.init) }
        return digits.isEmpty ? nil : (digits, exp)
    }

    /// Adds one to a big-endian decimal digit array ([9, 9] -> [1, 0, 0]); [] counts as zero.
    private static func increment(_ d: [UInt8]) -> [UInt8] {
        var d = d
        var i = d.count - 1
        while i >= 0 {
            if d[i] == 9 { d[i] = 0; i -= 1 } else { d[i] += 1; return d }
        }
        return [1] + d
    }

    // MARK: Dates

    private enum DatePart {
        case literal(String), year(Int), monthOrMinute(Int), month(Int), minute(Int), day(Int), weekdayJa(Int)
        case hour(Int), second(Int), fraction(Int), ampm(upper: Bool, short: Bool), elapsed(Character, Int)
        var isCode: Bool { if case .literal = self { return false }; return true }
        var isSeconds: Bool {
            switch self { case .second, .elapsed("s", _): return true; default: return false }
        }
    }

    /// The text for a date/time serial in a custom date format, or nil when the format is not supported.
    static func renderDate(_ serial: Double, code: String, date1904: Bool) -> String? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466, let section = sections(code).first else { return nil }
        let c = Array(section)
        var parts: [DatePart] = []
        var foreignLocale = false
        var i = 0
        func run(_ ch: Character) -> Int {
            var n = 0
            while i + n < c.count, c[i + n].lowercased() == String(ch) { n += 1 }
            return n
        }
        while i < c.count {
            let ch = c[i]
            let lower = Character(ch.lowercased())
            switch lower {
            case "\"":
                var lit = ""
                i += 1
                while i < c.count, c[i] != "\"" { lit.append(c[i]); i += 1 }
                parts.append(.literal(lit)); i += 1
            case "\\":
                if i + 1 < c.count { parts.append(.literal(String(c[i + 1]))) }
                i += 2
            case "_", "*": i += 2
            case "[":
                var tag = ""
                i += 1
                while i < c.count, c[i] != "]" { tag.append(c[i]); i += 1 }
                i += 1
                let t = tag.lowercased()
                if let f = t.first, "hms".contains(f), t.allSatisfy({ $0 == f }) {
                    parts.append(.elapsed(f, t.count))
                } else if t.hasPrefix("$") {
                    let locale = t.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    if locale.hasPrefix("f") || locale.contains("sys") { return nil } // system long date / time
                    if !locale.isEmpty, locale != "409", locale != "en-us" { foreignLocale = true }
                    let symbol = t.dropFirst().prefix { $0 != "-" }
                    if !symbol.isEmpty { parts.append(.literal(String(tag.dropFirst().prefix(symbol.count)))) }
                } else if !isColor(tag) {
                    return nil
                }
            case "y": let n = run("y"); parts.append(.year(n)); i += n
            case "m": let n = run("m"); parts.append(n <= 2 ? .monthOrMinute(n) : .month(n)); i += n
            case "d": let n = run("d"); parts.append(.day(n)); i += n
            case "h": let n = run("h"); parts.append(.hour(n)); i += n
            case "s": let n = run("s"); parts.append(.second(n)); i += n
            case "a":
                let rest = String(c[i...]).lowercased()
                if rest.hasPrefix("am/pm") { parts.append(.ampm(upper: ch == "A", short: false)); i += 5 }
                else if rest.hasPrefix("a/p") { parts.append(.ampm(upper: ch == "A", short: true)); i += 3 }
                else {
                    let n = run("a")
                    guard n >= 3 else { return nil }
                    parts.append(.weekdayJa(n)); i += n
                }
            case ".":
                // Fractional seconds right after a seconds code.
                var n = 0
                while i + 1 + n < c.count, c[i + 1 + n] == "0" { n += 1 }
                if n > 0, let last = parts.last(where: \.isCode), last.isSeconds {
                    parts.append(.fraction(n)); i += 1 + n
                } else {
                    parts.append(.literal(".")); i += 1
                }
            case "g", "e", "b", "r", "0", "#", "?", "@", "%":
                return nil // era years, Buddhist years, numbers mixed into a date
            default:
                parts.append(.literal(String(ch))); i += 1
            }
        }

        // "m" / "mm" is minutes right after an hour code or right before a seconds code.
        let codeIndices = parts.indices.filter { parts[$0].isCode }
        for (k, idx) in codeIndices.enumerated() {
            guard case .monthOrMinute(let n) = parts[idx] else { continue }
            var minute = false
            if k > 0 {
                switch parts[codeIndices[k - 1]] { case .hour, .elapsed("h", _): minute = true; default: break }
            }
            if k + 1 < codeIndices.count {
                switch parts[codeIndices[k + 1]] { case .second, .elapsed("s", _): minute = true; default: break }
            }
            parts[idx] = minute ? .minute(n) : .month(n)
        }
        let twelveHour = parts.contains { if case .ampm = $0 { return true }; return false }
        if foreignLocale, parts.contains(where: {
            switch $0 { case .month(let n) where n >= 3: return true; case .day(let n) where n >= 3: return true; case .ampm: return true; default: return false }
        }) { return nil }

        // Round to the shown precision of the seconds, as Excel does (23:59:59.6 shown as hh:mm:ss is the next day).
        let fractionDigits = parts.compactMap { if case .fraction(let n) = $0 { return n }; return nil }.first ?? 0
        guard fractionDigits <= 3 else { return nil }
        var unit: Int64 = 1
        for _ in 0..<fractionDigits { unit *= 10 }
        let total = Int64((serial * 86400 * Double(unit)).rounded())
        let days = Int(total / (86400 * unit))
        let daySeconds = Int((total % (86400 * unit)) / unit)
        let fraction = Int(total % unit)
        let hour = daySeconds / 3600, minute = (daySeconds % 3600) / 60, second = daySeconds % 60

        let (y, mo, d): (Int, Int, Int)
        let unixDays: Int
        if !date1904 && days == 60 {
            (y, mo, d) = (1900, 2, 29) // Lotus 1-2-3 leap-year bug that Excel keeps
            unixDays = -25509
        } else {
            unixDays = date1904 ? days - 24107 : (days < 60 ? days - 25568 : days - 25569)
            (y, mo, d) = XlsxReader.civil(fromDays: unixDays)
        }
        let weekday = ((unixDays % 7) + 7 + 4) % 7 // 1970-01-01 was a Thursday; 0 = Sunday
        let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let dayNamesJa = ["日", "月", "火", "水", "木", "金", "土"]
        func pad(_ v: Int, _ n: Int) -> String { n >= 2 ? String(format: "%0\(n)d", v) : String(v) }

        var out = ""
        for p in parts {
            switch p {
            case .literal(let s): out += s
            case .year(let n): out += n <= 2 ? String(format: "%02d", y % 100) : String(format: "%04d", y)
            case .month(let n):
                switch n {
                case 1, 2: out += pad(mo, n)
                case 3: out += String(monthNames[mo - 1].prefix(3))
                case 5: out += String(monthNames[mo - 1].prefix(1))
                default: out += monthNames[mo - 1]
                }
            case .minute(let n), .monthOrMinute(let n): out += pad(minute, min(n, 2))
            case .day(let n):
                switch n {
                case 1, 2: out += pad(d, n)
                case 3: out += String(dayNames[weekday].prefix(3))
                default: out += dayNames[weekday]
                }
            case .weekdayJa(let n): out += dayNamesJa[weekday] + (n >= 4 ? "曜日" : "")
            case .hour(let n): out += pad(twelveHour ? (hour % 12 == 0 ? 12 : hour % 12) : hour, min(n, 2))
            case .second(let n): out += pad(second, min(n, 2))
            case .fraction(let n): out += "." + String(format: "%0\(n)d", fraction)
            case .ampm(let upper, let short):
                let s = hour < 12 ? (short ? "A" : "AM") : (short ? "P" : "PM")
                out += upper ? s : s.lowercased()
            case .elapsed(let unitChar, let n):
                let seconds = days * 86400 + daySeconds
                let v = unitChar == "h" ? seconds / 3600 : (unitChar == "m" ? seconds / 60 : seconds)
                out += pad(v, n)
            }
        }
        return out
    }
}
