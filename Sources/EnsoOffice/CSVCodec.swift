import Foundation
import EnsoDoc

/// RFC 4180 CSV / TSV with the encodings Japanese Excel users actually produce.
public enum CSVCodec {
    public enum Encoding: String, Sendable { case utf8, utf8BOM, utf16LE, utf16BE, shiftJIS, eucJP, latin1 }

    /// Reads a .csv/.tsv/.txt file. `.tsv` is tab-separated; other extensions auto-detect comma, semicolon or tab.
    public static func read(_ url: URL) throws -> Sheet {
        let data = try Data.readOffice(url)
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        return try read(data: data, delimiter: ext == "tsv" || ext == "tab" ? "\t" : nil, name: name.isEmpty ? "Sheet1" : name)
    }

    public static func read(data: Data, delimiter: Character? = nil, name: String = "Sheet1") throws -> Sheet {
        let (text, _) = try decode(data)
        var body = Substring(text)
        var delim = delimiter
        // Excel's "sep=;" hint line.
        if body.lowercased().hasPrefix("sep="), let nl = body.firstIndex(where: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let hint = body.dropFirst(4).prefix(1)
            if let c = hint.first, delim == nil { delim = c }
            body = body[body.index(after: nl)...]
        }
        let d = delim ?? detectDelimiter(body)
        let records = parse(body, delimiter: d)
        let rows = records.map { $0.map { value($0, delimiter: d) } }
        return Sheet(name: name, rows: rows)
    }

    /// UTF-8 with BOM by default so Excel (Windows and Mac) shows Japanese correctly. CRLF line endings.
    public static func write(_ sheet: Sheet, to url: URL, delimiter: Character? = nil, bom: Bool = true) throws {
        let d = delimiter ?? (url.pathExtension.lowercased() == "tsv" ? "\t" : ",")
        try encode(sheet, delimiter: d, bom: bom).writeOffice(to: url)
    }

    public static func encode(_ sheet: Sheet, delimiter: Character = ",", bom: Bool = true) -> Data {
        var out = ""
        for row in sheet.rows {
            var last = row.count - 1
            while last >= 0, row[last] == .empty { last -= 1 }
            if last >= 0 {
                out += row[0...last].map { field($0, delimiter: delimiter) }.joined(separator: String(delimiter))
            }
            out += "\r\n"
        }
        var data = Data(bom ? [0xEF, 0xBB, 0xBF] : [])
        data.append(Data(out.utf8))
        return data
    }

    // MARK: Encoding

    public static func decode(_ data: Data) throws -> (String, Encoding) {
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8BOM)
        }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE, let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return (s, .utf16LE) }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF, let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return (s, .utf16BE) }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        // UTF-16 without BOM: lots of zero bytes on one side.
        if data.count >= 4 {
            let sample = [UInt8](data.prefix(4096))
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let half = sample.count / 2
            if oddZeros > half / 2, evenZeros < half / 10, let s = String(data: data, encoding: .utf16LittleEndian) { return (s, .utf16LE) }
            if evenZeros > half / 2, oddZeros < half / 10, let s = String(data: data, encoding: .utf16BigEndian) { return (s, .utf16BE) }
        }
        // Japanese Excel: CP932 (Shift_JIS with Microsoft extensions), then EUC-JP.
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        if let s = String(data: data, encoding: cp932) { return (s, .shiftJIS) }
        if let s = String(data: data, encoding: .japaneseEUC) { return (s, .eucJP) }
        if let s = String(data: data, encoding: .windowsCP1252) { return (s, .latin1) }
        if let s = String(data: data, encoding: .isoLatin1) { return (s, .latin1) }
        throw OfficeError.invalidDocument("text encoding not recognised")
    }

    // MARK: Parsing (on Unicode scalars: fast, and a delimiter next to a combining mark stays a delimiter)

    /// Picks the candidate that splits the first lines into the most consistent, largest number of fields.
    static func detectDelimiter(_ text: Substring) -> Character {
        var counts: [Unicode.Scalar: [Int]] = [",": [0], "\t": [0], ";": [0]]
        var inQuote = false
        var lines = 0
        var previousCR = false
        for u in text.unicodeScalars {
            if u == "\"" { inQuote.toggle() }
            else if !inQuote, u == "\n" || u == "\r" {
                if u == "\n" && previousCR { previousCR = false; continue }
                previousCR = u == "\r"
                lines += 1
                if lines >= 20 { break }
                for k in Array(counts.keys) { counts[k]?.append(0) }
                continue
            } else if !inQuote, var perLine = counts[u] {
                perLine[perLine.count - 1] += 1
                counts[u] = perLine
            }
            previousCR = false
        }
        var best: (Character, Double) = (",", 0)
        for (cand, perLine) in counts.sorted(by: { $0.key.value < $1.key.value }) {
            var lineCounts = perLine
            if lineCounts.count > 1, lineCounts.last == 0 { lineCounts.removeLast() } // trailing newline
            guard let first = lineCounts.first, lineCounts.contains(where: { $0 > 0 }) else { continue }
            let consistent = Double(lineCounts.filter { $0 == first }.count) / Double(lineCounts.count)
            let score = consistent * Double(first + 1) + (first == 0 ? 0 : 0.5)
            if score > best.1 { best = (Character(cand), score) }
        }
        return best.0
    }

    /// One field: raw text and whether it was quoted.
    struct Field { var text: String; var quoted: Bool }

    static func parse(_ text: Substring, delimiter: Character) -> [[Field]] {
        guard let delim = delimiter.unicodeScalars.first else { return [] }
        var records: [[Field]] = []
        var record: [Field] = []
        var field = String.UnicodeScalarView()
        var quoted = false, inQuotes = false, atFieldStart = true
        var pendingQuote = false // saw a quote inside a quoted field: either an escaped quote or the closing one
        var previousCR = false

        func endField() { record.append(Field(text: String(field), quoted: quoted)); field = .init(); quoted = false; atFieldStart = true }
        func endRecord() { endField(); records.append(record); record = [] }

        for u in text.unicodeScalars {
            if pendingQuote {
                pendingQuote = false
                if u == "\"" { field.append("\""); continue } // "" inside quotes
                inQuotes = false
            }
            if inQuotes {
                if u == "\"" { pendingQuote = true } else { field.append(u) }
                continue
            }
            if u == "\n" && previousCR { previousCR = false; continue }
            previousCR = false
            switch u {
            case "\"" where atFieldStart:
                inQuotes = true; quoted = true; atFieldStart = false
            case delim:
                endField()
            case "\n", "\r":
                previousCR = u == "\r"
                endRecord()
            default:
                field.append(u) // a quote in the middle of an unquoted field is literal
                atFieldStart = false
            }
        }
        if !field.isEmpty || quoted || !record.isEmpty { endRecord() }
        return records
    }

    /// One CSV field as a cell. Every field keeps its exact text for display, so PDF, Word, Markdown, HTML and copied
    /// text show the CSV unchanged; it is typed as a number for Excel only when Excel then shows the same text
    /// (CellValue.typed, which lists the rules). In semicolon-separated files "," is the decimal comma.
    static func value(_ f: Field, delimiter: Character) -> CellValue {
        if f.text.isEmpty { return .empty }
        if f.text.allSatisfy(\.isWhitespace) { return f.quoted ? .text(f.text) : .empty }
        return CellValue.typed(f.text, decimalComma: delimiter == ";")
    }

    /// CSV formula injection (OWASP "CSV Injection"): a text cell that Excel, Numbers or LibreOffice would run as a
    /// formula gets a leading single quote, so it is shown as text.
    /// OWASP's rule prefixes every cell starting with = + - @ tab or CR. Its known drawback is that it corrupts
    /// ordinary data: the quote shows in Numbers, LibreOffice and every non-spreadsheet reader, and a lone "-", a
    /// negative amount or a phone number like "+81-90-1234-5678" no longer round-trips. MaruDoc therefore prefixes,
    /// after any leading whitespace (spaces, tabs, CR/LF, which some readers strip):
    ///   - "=" followed by anything: always a formula;
    ///   - "+", "-" or "@" followed by something that can do harm in a formula: a function call (a name followed by
    ///     "("), a DDE call ("|"), or a reference to another sheet or file ("!").
    /// "-", "-5", "+1.5", "-abc", "@mention" and phone numbers ("+1 (555) 123-4567", "+81-90-1234-5678") are left
    /// alone: at worst a spreadsheet computes or rejects them, exactly as it would with the original CSV.
    public static func neutralizingFormula(_ t: String) -> String {
        let body = t.unicodeScalars.drop { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" || $0 == "\u{3000}" || $0 == "\u{A0}" }
        guard let first = body.first else { return t }
        let rest = body.dropFirst()
        switch first {
        case "=":
            return rest.isEmpty ? t : "'" + t
        case "+", "-", "@":
            return looksLikeFormula(rest) ? "'" + t : t
        default:
            return t
        }
    }

    /// True when the text after a leading + - @ calls a function (a name that starts with a letter or "_",
    /// followed by "("), makes a DDE call ("|") or refers to another sheet or file ("!").
    static func looksLikeFormula(_ s: Substring.UnicodeScalarView) -> Bool {
        var inName = false, nameStartsWithLetter = false
        for u in s {
            switch u {
            case "|", "!": return true
            case "(":
                if inName && nameStartsWithLetter { return true }
                inName = false
            case " ", "\t": continue // "SUM (1)": spaces before "(" do not end the name
            default:
                let nameChar = u.properties.isAlphabetic || u == "_" || u == "." || ("0"..."9").contains(u)
                if nameChar && !inName { nameStartsWithLetter = u.properties.isAlphabetic || u == "_" }
                inName = nameChar
            }
        }
        return false
    }

    static func field(_ v: CellValue, delimiter: Character) -> String {
        let s: String
        switch v {
        case .empty: return ""
        case .text(let t): s = neutralizingFormula(t)
        // Numbers are written as the spreadsheet shows them, as Excel and LibreOffice save CSV: General numbers
        // with at most 15 significant digits, formatted numbers in their format ("¥1,500", "12.5%").
        default: s = v.displayString
        }
        let needsQuotes = s.contains(delimiter) || s.contains("\"") || s.contains("\n") || s.contains("\r") ||
            s.hasPrefix(" ") || s.hasSuffix(" ")
        return needsQuotes ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}
