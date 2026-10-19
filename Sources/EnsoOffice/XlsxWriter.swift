import Foundation
import EnsoDoc

/// Workbook -> SpreadsheetML (.xlsx).
public enum XlsxWriter {
    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    static let maxCellText = 32_767

    public static func write(_ workbook: Workbook, to url: URL) throws {
        try data(workbook).writeOffice(to: url)
    }

    public static func data(_ workbook: Workbook) throws -> Data {
        var sheets = workbook.sheets
        if sheets.isEmpty { sheets = [Sheet(name: "Sheet1", rows: [])] }
        for s in sheets {
            if s.rows.count > maxRows { throw OfficeError.tooLarge("sheet \"\(s.name)\" has \(s.rows.count) rows; Excel allows \(maxRows)") }
            if s.columnCount > maxColumns { throw OfficeError.tooLarge("sheet \"\(s.name)\" has \(s.columnCount) columns; Excel allows \(maxColumns)") }
        }
        let names = sanitizedSheetNames(sheets.map(\.name))
        let cjk = sheets.contains { $0.rows.contains { $0.contains { if case .text(let t) = $0 { return t.unicodeScalars.contains { $0.value >= 0x3000 } }; return false } } }

        var strings = SharedStrings()
        var sheetXML: [String] = []
        for s in sheets { sheetXML.append(worksheet(s, strings: &strings, first: sheetXML.isEmpty)) }

        let zip = ZipWriter()
        let sml = "application/vnd.openxmlformats-officedocument.spreadsheetml"
        var overrides: [(String, String)] = [("xl/workbook.xml", "\(sml).sheet.main+xml")]
        for i in sheets.indices { overrides.append(("xl/worksheets/sheet\(i + 1).xml", "\(sml).worksheet+xml")) }
        overrides += [("xl/sharedStrings.xml", "\(sml).sharedStrings+xml"), ("xl/styles.xml", "\(sml).styles+xml"),
                      ("docProps/core.xml", OPC.coreContentType), ("docProps/app.xml", OPC.appContentType)]
        try zip.add(path: "[Content_Types].xml", text: OPC.contentTypes(defaults: [], overrides: overrides))
        try zip.add(path: "_rels/.rels", text: OPC.packageRels(main: "xl/workbook.xml"))
        try zip.add(path: "docProps/core.xml", text: OPC.coreProperties(title: nil))
        try zip.add(path: "docProps/app.xml", text: OPC.appProperties())

        var rels = OPC.RelsBuilder()
        var wb = xmlHeader + "<workbook xmlns=\"\(NS.x)\" xmlns:r=\"\(NS.r)\"><bookViews><workbookView activeTab=\"0\"/></bookViews><sheets>"
        for (i, name) in names.enumerated() {
            let id = rels.add(RelType.worksheet, "worksheets/sheet\(i + 1).xml")
            wb += "<sheet name=\"\(XMLEsc.attr(name))\" sheetId=\"\(i + 1)\" r:id=\"\(id)\"/>"
        }
        wb += "</sheets></workbook>"
        _ = rels.add(RelType.sharedStrings, "sharedStrings.xml")
        _ = rels.add(RelType.styles, "styles.xml")

        try zip.add(path: "xl/workbook.xml", text: wb)
        try zip.add(path: "xl/_rels/workbook.xml.rels", text: rels.xml)
        for (i, xml) in sheetXML.enumerated() { try zip.add(path: "xl/worksheets/sheet\(i + 1).xml", text: xml) }
        try zip.add(path: "xl/sharedStrings.xml", text: strings.xml)
        try zip.add(path: "xl/styles.xml", text: styles(font: cjk ? "Yu Gothic" : "Arial", cjk: cjk))
        return try zip.finalize()
    }

    /// Excel's sheet-name rules: no []:*?/\, not empty, no leading/trailing apostrophe, at most 31 UTF-16 units,
    /// unique case-insensitively, and "History" is reserved.
    public static func sanitizedSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        var out: [String] = []
        for (i, raw) in names.enumerated() {
            var s = String(raw.unicodeScalars.map { "[]:*?/\\".unicodeScalars.contains($0) || $0.value < 0x20 ? "_" : Character($0) })
            s = s.trimmingCharacters(in: .whitespaces)
            while s.hasPrefix("'") { s.removeFirst() }
            while s.hasSuffix("'") { s.removeLast() }
            if s.isEmpty { s = "Sheet\(i + 1)" }
            if s.lowercased() == "history" { s += "_" }
            s = truncate(s, to: 31)
            var candidate = s
            var n = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(n))"
                candidate = truncate(s, to: 31 - suffix.utf16.count) + suffix
                n += 1
            }
            used.insert(candidate.lowercased())
            out.append(candidate)
        }
        return out
    }

    static func truncate(_ s: String, to utf16Units: Int) -> String {
        var out = ""
        var count = 0
        for ch in s {
            let n = ch.utf16.count
            if count + n > utf16Units { break }
            out.append(ch); count += n
        }
        return out
    }

    // MARK: Sheet

    /// Header heuristic: at least two rows and a first row made only of distinct, short text cells.
    static func looksLikeHeader(_ rows: [[CellValue]]) -> Bool {
        guard rows.count >= 2, let first = rows.first else { return false }
        var seen = Set<String>()
        var nonEmpty = 0
        for v in first {
            switch v {
            case .empty: continue
            case .text(let t):
                let key = t.trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty, key.count <= 60, seen.insert(key).inserted else { return false }
                nonEmpty += 1
            default: return false
            }
        }
        return nonEmpty > 0
    }

    static func worksheet(_ sheet: Sheet, strings: inout SharedStrings, first: Bool) -> String {
        let rows = sheet.rows
        let header = looksLikeHeader(rows)
        let lastRow = rows.lastIndex { $0.contains { $0 != .empty } } ?? -1
        let lastCol = rows.map { r in r.lastIndex { $0 != .empty } ?? -1 }.max() ?? -1

        var s = xmlHeader + "<worksheet xmlns=\"\(NS.x)\" xmlns:r=\"\(NS.r)\">"
        s += "<dimension ref=\"\(lastRow >= 0 && lastCol >= 0 ? "A1:\(columnName(lastCol))\(lastRow + 1)" : "A1")\"/>"
        s += "<sheetViews><sheetView workbookViewId=\"0\"\(first ? " tabSelected=\"1\"" : "")>"
        if header && lastRow >= 1 {
            s += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/><selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/>"
        }
        s += "</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/>"

        if lastCol >= 0 {
            s += "<cols>"
            for (i, w) in columnWidths(rows, columns: lastCol + 1, header: header).enumerated() {
                s += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(String(format: "%.2f", w))\" customWidth=\"1\"/>"
            }
            s += "</cols>"
        }

        s += "<sheetData>"
        if lastRow >= 0 {
            for r in 0...lastRow {
                let row = rows[r]
                guard row.contains(where: { $0 != .empty }) else { continue }
                s += "<row r=\"\(r + 1)\">"
                for (c, v) in row.enumerated() {
                    let bold = header && r == 0
                    let ref = "\(columnName(c))\(r + 1)"
                    switch v {
                    case .empty: continue
                    case .number(let d) where d.isFinite:
                        s += "<c r=\"\(ref)\"\(bold ? " s=\"1\"" : "")><v>\(numberString(d))</v></c>"
                    case .number(let d):
                        s += textCell(ref, d.isNaN ? "NaN" : (d > 0 ? "∞" : "-∞"), bold: bold, strings: &strings)
                    case .bool(let b):
                        s += "<c r=\"\(ref)\" t=\"b\"\(bold ? " s=\"1\"" : "")><v>\(b ? 1 : 0)</v></c>"
                    case .text(let t):
                        s += textCell(ref, t, bold: bold, strings: &strings)
                    }
                }
                s += "</row>"
            }
        }
        s += "</sheetData><pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/></worksheet>"
        return s
    }

    private static func textCell(_ ref: String, _ text: String, bold: Bool, strings: inout SharedStrings) -> String {
        let wrap = text.contains("\n") || text.contains("\r")
        let style = (bold ? 1 : 0) + (wrap ? 2 : 0)
        let idx = strings.index(of: text)
        return "<c r=\"\(ref)\" t=\"s\"\(style > 0 ? " s=\"\(style)\"" : "")><v>\(idx)</v></c>"
    }

    static func numberString(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// Width in Excel character units from the longest line per column (wide characters count double).
    static func columnWidths(_ rows: [[CellValue]], columns: Int, header: Bool) -> [Double] {
        var widths = Array(repeating: 0, count: columns)
        for (r, row) in rows.enumerated() {
            for (c, v) in row.enumerated() where c < columns {
                let text: String
                switch v {
                case .empty: continue
                case .number(let d): text = numberString(d)
                default: text = v.displayString
                }
                var w = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { TextWidth.columns(String($0)) }.max() ?? 0
                if header && r == 0 { w = Int((Double(w) * 1.1).rounded(.up)) }
                widths[c] = max(widths[c], w)
            }
        }
        return widths.map { min(max(Double($0) + 2, 8.43), 80) }
    }

    // MARK: Styles

    static func styles(font: String, cjk: Bool) -> String {
        let fontAttrs = cjk ? "<family val=\"3\"/><charset val=\"128\"/>" : "<family val=\"2\"/>"
        var s = xmlHeader + "<styleSheet xmlns=\"\(NS.x)\">"
        s += "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"\(font)\"/>\(fontAttrs)</font><font><b/><sz val=\"11\"/><name val=\"\(font)\"/>\(fontAttrs)</font></fonts>"
        s += "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
        s += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        s += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        s += "<cellXfs count=\"4\">"
        s += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        s += "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
        s += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf>"
        s += "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf>"
        s += "</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        s += "<dxfs count=\"0\"/><tableStyles count=\"0\" defaultTableStyle=\"TableStyleMedium2\" defaultPivotStyle=\"PivotStyleLight16\"/>"
        return s + "</styleSheet>"
    }
}

struct SharedStrings {
    private var index: [String: Int] = [:]
    private var list: [String] = []
    private var references = 0

    mutating func index(of raw: String) -> Int {
        references += 1
        let s = XlsxWriter.truncate(XMLEsc.sanitized(raw), to: XlsxWriter.maxCellText)
        if let i = index[s] { return i }
        index[s] = list.count
        list.append(s)
        return list.count - 1
    }

    var xml: String {
        var s = xmlHeader + "<sst xmlns=\"\(NS.x)\" count=\"\(references)\" uniqueCount=\"\(list.count)\">"
        for t in list { s += "<si><t xml:space=\"preserve\">\(XMLEsc.text(SharedStrings.escapeUnderscores(t)))</t></si>" }
        return s + "</sst>"
    }

    /// Excel reads "_xHHHH_" as an escaped character; literal occurrences need their underscore escaped.
    static func escapeUnderscores(_ s: String) -> String {
        guard s.contains("_x") else { return s }
        return s.replacingOccurrences(of: "_(x[0-9A-Fa-f]{4}_)", with: "_x005F_$1", options: .regularExpression)
    }
}
