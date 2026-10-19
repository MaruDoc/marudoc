import Foundation
import EnsoDoc

/// SpreadsheetML (.xlsx / .xlsm) -> Workbook. Formulas yield their cached values; date-formatted numbers
/// become "yyyy-MM-dd" (plus " HH:mm[:ss]" when they carry a time) text.
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
        var dateKinds: [DateKind?] = []
        if let r = rels.first(where: { $0.isType("styles") }), zip.contains(r.target) {
            dateKinds = styleDateKinds(try XNode.parse(try zip.data(r.target), part: r.target))
        }

        var sheets: [Sheet] = []
        for s in wb.child("x:sheets")?.children("x:sheet") ?? [] {
            guard let id = s["r:id"], let rel = relById[id], rel.isType("worksheet"), zip.contains(rel.target) else { continue }
            let name = s["name"] ?? "Sheet\(sheets.count + 1)"
            let rows = try sheetRows(try zip.data(rel.target), part: rel.target, shared: shared, dateKinds: dateKinds, date1904: date1904)
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

    static func styleDateKinds(_ root: XNode) -> [DateKind?] {
        var custom: [Int: String] = [:]
        for f in root.child("x:numFmts")?.children("x:numFmt") ?? [] {
            if let id = OOXMLValue.int(f["numFmtId"]) { custom[id] = f["formatCode"] ?? "" }
        }
        return (root.child("x:cellXfs")?.children("x:xf") ?? []).map { xf in
            let id = OOXMLValue.int(xf["numFmtId"]) ?? 0
            return dateKind(numFmtId: id, code: custom[id])
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

    static func sheetRows(_ data: Data, part: String, shared: [String], dateKinds: [DateKind?], date1904: Bool) throws -> [[CellValue]] {
        var cells: [Int: [Int: CellValue]] = [:]
        var row = 0, col = -1
        var type = "n", style = 0
        var value = "", inline = ""
        var inValue = false, inInline = false, inInlineText = false, phonetic = 0, inCell = false

        try OOXMLSAX.run(data, part: part) { sax in
            sax.onStart = { tag, attrs in
                switch tag {
                case "x:row":
                    row = OOXMLValue.int(attrs["r"]).flatMap { (1...XlsxWriter.maxRows).contains($0) ? $0 : nil } ?? min(row + 1, XlsxWriter.maxRows + 1)
                    col = -1
                case "x:c":
                    if let r = attrs["r"], let ref = parseRef(r) { col = ref.col; row = ref.row } else { col += 1 }
                    if row == 0 { row = 1 }
                    type = attrs["t"] ?? "n"
                    style = OOXMLValue.int(attrs["s"]) ?? 0
                    value = ""; inline = ""; inCell = true
                case "x:v": inValue = inCell
                case "x:is": inInline = inCell
                case "x:rPh": phonetic += 1
                case "x:t": inInlineText = inInline && phonetic == 0
                default: break
                }
            }
            sax.onEnd = { tag in
                switch tag {
                case "x:v": inValue = false
                case "x:t": inInlineText = false
                case "x:rPh": phonetic -= 1
                case "x:is": inInline = false
                case "x:c":
                    inCell = false
                    guard row >= 1, row <= XlsxWriter.maxRows, col >= 0, col < XlsxWriter.maxColumns else { return }
                    let kind = style >= 0 && style < dateKinds.count ? dateKinds[style] : nil
                    let v = cellValue(type: type, value: value, inline: inline, shared: shared, dateKind: kind, date1904: date1904)
                    if v != .empty { cells[row, default: [:]][col] = v }
                default: break
                }
            }
            sax.onText = { s in
                if inValue { value += s } else if inInlineText { inline += s }
            }
        }

        guard let maxRow = cells.keys.max() else { return [] }
        var rows: [[CellValue]] = Array(repeating: [], count: maxRow)
        for (r, dict) in cells {
            guard let maxCol = dict.keys.max() else { continue }
            var line = Array(repeating: CellValue.empty, count: maxCol + 1)
            for (c, v) in dict { line[c] = v }
            rows[r - 1] = line
        }
        return rows
    }

    static func cellValue(type: String, value: String, inline: String, shared: [String], dateKind: DateKind?, date1904: Bool) -> CellValue {
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
            if let kind = dateKind, let s = formatSerial(d, kind: kind, date1904: date1904) { return .text(s) }
            return .number(d)
        }
    }
}
