import Foundation
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

/// Checks for the 2026-11-12 Excel / CSV audit: hidden sheets, rows and columns (XL-08), CSV values shown and typed
/// without reinterpretation (XL-01 / XL-03), CSV formula prefixing that keeps ordinary data (XL-04), formulas without
/// cached values (XL-14) and number formats (XL-07). Only public API that also existed before the fix is used, so the
/// same checks can be run against the 1.0.5 source to show they fail there.
extension SelfTest {

    /// A minimal .xlsx: worksheets given as their inner XML (inside <worksheet>), optional sheet state, optional
    /// styles (inside <styleSheet>). Cells use inline strings, so no shared-string part is needed.
    func auditXlsx(_ sheets: [(name: String, state: String?, xml: String)], styles: String? = nil) throws -> Data {
        let x = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let sml = "application/vnd.openxmlformats-officedocument.spreadsheetml"
        let z = ZipWriter()
        var types = "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"\(sml).sheet.main+xml\"/>"
        var wb = "<?xml version=\"1.0\"?><workbook xmlns=\"\(x)\" xmlns:r=\"\(r)\"><sheets>"
        var rels = "<?xml version=\"1.0\"?><Relationships xmlns=\"\(pkg)\">"
        for (i, s) in sheets.enumerated() {
            types += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"\(sml).worksheet+xml\"/>"
            wb += "<sheet name=\"\(s.name)\" sheetId=\"\(i + 1)\"\(s.state.map { " state=\"\($0)\"" } ?? "") r:id=\"rId\(i + 1)\"/>"
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(r)/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
            try z.add(path: "xl/worksheets/sheet\(i + 1).xml", text: "<?xml version=\"1.0\"?><worksheet xmlns=\"\(x)\">\(s.xml)</worksheet>")
        }
        if let styles {
            types += "<Override PartName=\"/xl/styles.xml\" ContentType=\"\(sml).styles+xml\"/>"
            rels += "<Relationship Id=\"rIdStyles\" Type=\"\(r)/styles\" Target=\"styles.xml\"/>"
            try z.add(path: "xl/styles.xml", text: "<?xml version=\"1.0\"?><styleSheet xmlns=\"\(x)\">\(styles)</styleSheet>")
        }
        try z.add(path: "[Content_Types].xml", text: types + "</Types>")
        try z.add(path: "_rels/.rels", text: "<?xml version=\"1.0\"?><Relationships xmlns=\"\(pkg)\"><Relationship Id=\"rId1\" Type=\"\(r)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        try z.add(path: "xl/workbook.xml", text: wb + "</sheets></workbook>")
        try z.add(path: "xl/_rels/workbook.xml.rels", text: rels + "</Relationships>")
        return try z.finalize()
    }

    func inlineCell(_ ref: String, _ text: String) -> String { "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>" }

    func testAuditSheet() async {
        let d = fresh("audit-sheet")
        func displayRows(_ s: Sheet) -> [[String]] {
            s.rows.map { row in
                var r = row.map(\.displayString)
                while r.last == "" { r.removeLast() }
                return r
            }
        }

        // XL-08: hidden and very hidden sheets, hidden rows (plain, outline-collapsed, filtered; "1" and "true") and
        // hidden columns (one column, and a range to the end of the sheet) are left out of every output.
        do {
            let c = inlineCell
            let visible = "<cols><col min=\"2\" max=\"2\" width=\"0\" hidden=\"1\"/><col min=\"5\" max=\"16384\" hidden=\"true\"/></cols><sheetData>"
                + "<row r=\"1\">\(c("A1", "h1"))\(c("B1", "secret-col"))\(c("C1", "h3"))\(c("D1", "h4"))</row>"
                + "<row r=\"2\"><c r=\"A2\"><v>1</v></c><c r=\"B2\"><v>666</v></c><c r=\"C2\"><v>3</v></c><c r=\"D2\"><v>4</v></c></row>"
                + "<row r=\"3\" hidden=\"1\">\(c("A3", "secret-row"))</row>"
                + "<row r=\"4\" hidden=\"1\" outlineLevel=\"1\">\(c("A4", "secret-outline"))</row>"
                + "<row r=\"5\" collapsed=\"1\">\(c("A5", "total"))<c r=\"C5\"><v>7</v></c></row>"
                + "<row r=\"6\" hidden=\"true\">\(c("A6", "secret-filter"))</row>"
                + "<row r=\"7\">\(c("A7", "last"))\(c("F7", "secret-far"))</row></sheetData>"
            let secretSheet = "<sheetData><row r=\"1\">\(c("A1", "secret-sheet"))</row></sheetData>"
            let data = try auditXlsx([("表", nil, visible), ("社外秘", "hidden", secretSheet), ("vh", "veryHidden", secretSheet)])
            let wb = try XlsxReader.read(data: data)
            check("xlsx hidden: hidden and very hidden sheets are left out", wb.sheets.map(\.name) == ["表"], "\(wb.sheets.map(\.name))")
            let rows = wb.sheets.first.map(displayRows) ?? []
            check("xlsx hidden: hidden rows and columns are left out and the rest closes up",
                  rows == [["h1", "h3", "h4"], ["1", "3", "4"], ["total", "7"], ["last"]], "\(rows)")

            let url = d.appendingPathComponent("hidden.xlsx")
            try data.write(to: url)
            func clean(_ text: String) -> Bool { !text.contains("secret") && !text.contains("666") }
            for target in ["csv", "md", "html", "pdf", "docx"] {
                let copy = d.appendingPathComponent("hidden-\(target).xlsx")
                try? FileManager.default.copyItem(at: url, to: copy)
                switch await run("to.\(target)", [copy]) {
                case .success(let r):
                    guard let out = r.outputs.first else { check("xlsx hidden: \(target) leaves hidden content out", false, "no output"); continue }
                    let text: String
                    switch target {
                    case "pdf": text = pdfText(out)
                    case "docx": text = textutil(out)
                    default: text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
                    }
                    var ok = clean(text) && text.contains("total") && text.contains("h4")
                    if target == "csv" { ok = ok && text.replacingOccurrences(of: "\u{FEFF}", with: "") == "h1,h3,h4\r\n1,3,4\r\ntotal,7\r\nlast\r\n" }
                    check("xlsx hidden: \(target) leaves hidden content out", ok, String(text.prefix(300)))
                case .failure(let e): check("xlsx hidden: \(target) leaves hidden content out", false, errText(e))
                }
            }
            switch await run(Act.copyText, [url]) {
            case .success(let r): check("xlsx hidden: copied text leaves hidden content out", clean(r.clipboardText ?? "secret") && (r.clipboardText ?? "").contains("last"), r.clipboardText ?? "")
            case .failure(let e): check("xlsx hidden: copied text leaves hidden content out", false, errText(e))
            }
        } catch { check("xlsx hidden: fixture", false, "\(error)") }

        // XL-01 / XL-03: CSV fields are shown exactly as written; only safe forms become numbers for Excel.
        let fields = ["00123", "+81-90-1234-5678", "1,234", "12.5%", "¥1,500", "4901234567894", "1234567890123456", "1.10",
                      "+819012345678", "9876543210987654321", "1e5", "-500", "3%", "(2,000)", "2.0", "0", "-", "12,345,678.90",
                      "$1,284.00", "1,500円", "-¥1,500", "-3.4%", "99999999999", "123456789012", "0.5", ".5", "5.", "-0", "1,2,3", "12,34", "1,5", "4,50"]
        let csvText = "a," + fields.dropFirst().indices.map { "c\($0)" }.joined(separator: ",") + "\r\n"
            + fields.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ",") + "\r\n"
        do {
            let sheet = try CSVCodec.read(data: Data(csvText.utf8), name: "t")
            let shown = sheet.rows.count > 1 ? sheet.rows[1].map(\.displayString) : []
            check("csv values: every field is shown exactly as written", shown == fields, "\(zip(fields, shown).filter { $0 != $1 })")
            func isText(_ s: String) -> Bool {
                guard let i = fields.firstIndex(of: s), sheet.rows.count > 1, i < sheet.rows[1].count else { return false }
                if case .text = sheet.rows[1][i] { return true }
                return false
            }
            let mustStayText = ["00123", "+81-90-1234-5678", "4901234567894", "1234567890123456", "+819012345678", "9876543210987654321",
                                "1e5", "(2,000)", "-", "123456789012", ".5", "5.", "-0", "1,2,3", "12,34", "1,5", "4,50"]
            let mustBeNumbers = ["1,234", "12.5%", "¥1,500", "1.10", "-500", "3%", "2.0", "0", "12,345,678.90", "$1,284.00", "1,500円",
                                 "-¥1,500", "-3.4%", "99999999999", "0.5"]
            check("csv values: codes, phone numbers, long digit runs, exponents and list commas stay text",
                  mustStayText.allSatisfy(isText), "\(mustStayText.filter { !isText($0) })")
            check("csv values: plain, grouped, percent and currency amounts become numbers",
                  mustBeNumbers.allSatisfy { !isText($0) }, "\(mustBeNumbers.filter(isText))")

            // Through Excel: the same text comes back for every field, from cells that are numbers where allowed.
            let back = try XlsxReader.read(data: try XlsxWriter.data(Workbook(sheets: [sheet])))
            let backShown = back.sheets.first.map { $0.rows.count > 1 ? $0.rows[1].map(\.displayString) : [] } ?? []
            check("csv → xlsx: every cell shows the CSV text (number formats written)", backShown == fields, "\(zip(fields, backShown).filter { $0 != $1 })")
            let backNumbers = mustBeNumbers.filter { f in
                guard let i = fields.firstIndex(of: f), let row = back.sheets.first?.rows[1], i < row.count else { return false }
                if case .text = row[i] { return false }
                return true
            }
            check("csv → xlsx: amounts are stored as numbers", backNumbers == mustBeNumbers, "\(backNumbers)")
        } catch { check("csv values: read", false, "\(error)") }

        // Semicolon files: "," is the decimal comma, so nothing with a comma (or a three-digit ".ddd") becomes a number.
        do {
            let sheet = try CSVCodec.read(data: Data("Artikel;Preis;Menge;Summe;x\r\nKaffee;1,5;3;4,50;1.234\r\nTee;1.234,56;2;\"1,2,3\";1.5\r\n".utf8))
            let rows = displayRows(sheet)
            check("csv values: semicolon file keeps decimal commas as written",
                  rows == [["Artikel", "Preis", "Menge", "Summe", "x"], ["Kaffee", "1,5", "3", "4,50", "1.234"], ["Tee", "1.234,56", "2", "1,2,3", "1.5"]], "\(rows)")
            let texts = [sheet.rows[1][1], sheet.rows[1][3], sheet.rows[1][4], sheet.rows[2][1], sheet.rows[2][3]].allSatisfy { if case .text = $0 { return true }; return false }
            check("csv values: semicolon file types only unambiguous numbers", texts && sheet.rows[1][2] == .number(3), "\(sheet.rows)")
        } catch { check("csv values: semicolon file", false, "\(error)") }

        // The same through the engine: CSV → Markdown and copied text print the fields unchanged.
        do {
            let csv = d.appendingPathComponent("values.csv")
            try csvText.write(to: csv, atomically: true, encoding: .utf8)
            switch await run("to.md", [csv]) {
            case .success(let r):
                let md = (try? String(contentsOf: r.outputs[0], encoding: .utf8)) ?? ""
                let missing = ["1,234", "12.5%", "¥1,500", "1.10", "+819012345678", "9876543210987654321", "1234567890123456", "1e5", "2.0", "1,2,3"].filter { !md.contains("| \($0) |") }
                check("csv → md: fields are printed as written", missing.isEmpty, "missing \(missing)")
            case .failure(let e): check("csv → md: fields are printed as written", false, errText(e))
            }
            switch await run(Act.copyText, [csv]) {
            case .success(let r):
                let t = r.clipboardText ?? ""
                check("csv → copied text: fields are copied as written", t.contains("12.5%\t¥1,500") && t.contains("9876543210987654321") && !t.contains("0.125"), t)
            case .failure(let e): check("csv → copied text: fields are copied as written", false, errText(e))
            }
        } catch { check("csv → md: fixture", false, "\(error)") }

        // XL-04: CSV → xlsx → CSV keeps ordinary data byte for byte; real formula payloads are still neutralised.
        do {
            let original = "\u{FEFF}区分,電話,金額,割合,備考\r\n-,+81-90-1234-5678,\"1,234\",12.5%,-abc\r\n-500,+1 (555) 123-4567,\"¥1,500\",3%,@mention\r\n"
            let csv = d.appendingPathComponent("roundtrip.csv")
            try Data(original.utf8).write(to: csv)
            if case .success(let r) = await run("to.xlsx", [csv]), let x = r.outputs.first {
                let moved = d.appendingPathComponent("rt-back.xlsx")
                try? FileManager.default.moveItem(at: x, to: moved)
                if case .success(let r2) = await run("to.csv", [moved]), let back = r2.outputs.first {
                    let text = String(decoding: (try? Data(contentsOf: back)) ?? Data(), as: UTF8.self)
                    check("csv round trip: \"-\", phone numbers, amounts and @/- text come back unchanged", text == original, text)
                } else { check("csv round trip: \"-\", phone numbers, amounts and @/- text come back unchanged", false, "xlsx → csv failed") }
            } else { check("csv round trip: \"-\", phone numbers, amounts and @/- text come back unchanged", false, "csv → xlsx failed") }
        } catch { check("csv round trip: fixture", false, "\(error)") }
        do {
            let dangerous = ["=cmd|' /C calc'!A0", "+SUM(1,2)", "-2+3+cmd|' /C calc'!A0", "@SUM(A1)", "=HYPERLINK(\"http://x\",\"y\")",
                             " =1+1", "\t=1+1", "\r=1+1", "\n=1+1", " +SUM(1)", "\t@SUM(A1)", "\r-2+3+cmd|' /C calc'!A0",
                             "-HYPERLINK(\"http://x\")", "+cmd|' /C calc'!A0", "@ SUM(1)", "-1+'[book.xlsx]Sheet1'!A1", "=1+1"]
            let unsafe = dangerous.filter { !CSVCodec.neutralizingFormula($0).hasPrefix("'") }
            check("csv formulas: payloads are prefixed (also after spaces, tab, CR, LF)", unsafe.isEmpty, "\(unsafe)")
            let ordinary = ["-", "-5", "+1.5", "+81-90-1234-5678", "+819012345678", "+1 (555) 123-4567", "+81 (0)90-1234-5678",
                            "-abc", "@mention", "- 備考", "--", "+", "@", "=", "-(注)", "\tx", "\rx", "plain"]
            let changed = ordinary.filter { CSVCodec.neutralizingFormula($0) != $0 }
            check("csv formulas: ordinary data is left unchanged", changed.isEmpty, "\(changed)")
            let line = String(decoding: CSVCodec.encode(Sheet(name: "s", rows: [dangerous.prefix(4).map { CellValue.text($0) } + [.text("-"), .number(-5)]]), bom: false), as: UTF8.self)
            check("csv formulas: encoded payloads keep their quote prefix",
                  line.hasPrefix("'=cmd|' /C calc'!A0,\"'+SUM(1,2)\",'-2+3+cmd|' /C calc'!A0,'@SUM(A1),-,-5"), line)
        }

        // XL-14: formulas without a cached value show their text instead of a silent blank.
        do {
            let c = inlineCell
            let xml = "<sheetData>"
                + "<row r=\"1\"><c r=\"A1\"><v>2</v></c><c r=\"B1\"><v>300</v></c><c r=\"C1\"><f>A1*B1</f><v/></c></row>"
                + "<row r=\"2\"><c r=\"A2\"><v>5</v></c><c r=\"B2\"><v>120</v></c><c r=\"C2\"><f t=\"shared\" ref=\"C2:C3\" si=\"0\">A2*B2</f></c></row>"
                + "<row r=\"3\"><c r=\"A3\"><v>1</v></c><c r=\"B3\"><v>1</v></c><c r=\"C3\"><f t=\"shared\" si=\"0\"/></c></row>"
                + "<row r=\"4\">\(c("A4", "sum"))<c r=\"C4\"><f>SUM(C1:C3)</f><v>1801</v></c><c r=\"D4\" t=\"str\"><f>IF(1,\"\",\"x\")</f><v></v></c><c r=\"E4\" t=\"str\"><f>\"a\"&amp;\"b\"</f></c></row>"
                + "<row r=\"5\"><c r=\"F5\"><f t=\"shared\" ref=\"F5:G6\" si=\"1\">$A5*B$1+LOG10(A5)+'My Sheet'!A5&amp;\"A1\"</f></c></row>"
                + "<row r=\"6\"><c r=\"G6\"><f t=\"shared\" si=\"1\"/></c></row></sheetData>"
            let wb = try XlsxReader.read(data: try auditXlsx([("f", nil, xml)]))
            let rows = wb.sheets.first.map(displayRows) ?? []
            func cell(_ r: Int, _ col: Int) -> String { r < rows.count && col < rows[r].count ? rows[r][col] : "" }
            check("xlsx formulas: no cached value shows the formula", cell(0, 2) == "=A1*B1" && cell(1, 2) == "=A2*B2" && cell(3, 4) == "=\"a\"&\"b\"", "\(rows)")
            check("xlsx formulas: shared formulas are moved to their cell", cell(2, 2) == "=A3*B3" && cell(5, 6) == "=$A6*C$1+LOG10(B6)+'My Sheet'!B6&\"A1\"", "\(rows)")
            check("xlsx formulas: cached values and cached empty strings are kept", cell(3, 2) == "1801" && cell(3, 3) == "", "\(rows)")
        } catch { check("xlsx formulas: fixture", false, "\(error)") }

        // XL-07: numbers print as Excel shows them.
        do {
            let codes = ["0.0%", "\"¥\"#,##0;[Red]-\"¥\"#,##0", "#,##0,\"千円\"", "yyyy\"年\"m\"月\"d\"日\"", "yyyy/m/d(aaa)", "[h]:mm", "# ?/?",
                         "#,##0;(#,##0)", "_-\"¥\"* #,##0_-;-\"¥\"* #,##0_-;_-\"¥\"* \"-\"_-;_-@_-", "\\¥#,##0", "[$$-409]#,##0.00", "yyyy/mm/dd hh:mm:ss",
                         "h:mm AM/PM", "General\"円\""]
            let builtins = [14, 1, 11, 2, 4, 10]
            var styles = "<numFmts count=\"\(codes.count)\">"
            for (i, code) in codes.enumerated() {
                let esc = code.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                styles += "<numFmt numFmtId=\"\(164 + i)\" formatCode=\"\(esc)\"/>"
            }
            styles += "</numFmts><cellXfs count=\"\(1 + codes.count + builtins.count)\"><xf numFmtId=\"0\"/>"
            for i in codes.indices { styles += "<xf numFmtId=\"\(164 + i)\" applyNumberFormat=\"1\"/>" }
            for b in builtins { styles += "<xf numFmtId=\"\(b)\" applyNumberFormat=\"1\"/>" }
            styles += "</cellXfs>"
            func style(_ code: String) -> Int { (codes.firstIndex(of: code) ?? -1) + 1 }
            func builtin(_ id: Int) -> Int { 1 + codes.count + (builtins.firstIndex(of: id) ?? 0) }
            let cases: [(Int, String, String)] = [
                (0, "0.30000000000000004", "0.3"),
                (0, "1234567890123456", "1.23456789012346E+15"),
                (0, "-0.5", "-0.5"),
                (builtin(1), "1234567890123456", "1234567890123460"),
                (style("0.0%"), "0.3", "30.0%"),
                (style("0.0%"), "-0.034", "-3.4%"),
                (style("\"¥\"#,##0;[Red]-\"¥\"#,##0"), "-1500", "-¥1,500"),
                (style("#,##0,\"千円\""), "12345678", "12,346千円"),
                (style("yyyy\"年\"m\"月\"d\"日\""), "45566", "2024年10月1日"),
                (style("yyyy/m/d(aaa)"), "45608", "2024/11/12(火)"),
                (style("[h]:mm"), "1.5", "36:00"),
                (style("# ?/?"), "2.75", "2 3/4"),
                (style("#,##0;(#,##0)"), "-9876", "(9,876)"),
                (style("_-\"¥\"* #,##0_-;-\"¥\"* #,##0_-;_-\"¥\"* \"-\"_-;_-@_-"), "-1234.5", "-¥1,235"),
                (style("_-\"¥\"* #,##0_-;-\"¥\"* #,##0_-;_-\"¥\"* \"-\"_-;_-@_-"), "0", "¥-"),
                (style("\\¥#,##0"), "980", "¥980"),
                (style("[$$-409]#,##0.00"), "1234.56", "$1,234.56"),
                (style("yyyy/mm/dd hh:mm:ss"), "45473.99999537037", "2024/07/01 00:00:00"), // 23:59:59.6 rounds up
                (style("h:mm AM/PM"), "0.78125", "6:45 PM"),
                (style("General\"円\""), "1500", "1500円"),
                (builtin(14), "45566", "2024-10-01"),
                (builtin(11), "0.0000123", "1.23E-05"),
                (builtin(2), "2.675", "2.68"),
                (builtin(4), "1234.5", "1,234.50"),
                (builtin(10), "0.15833333333333333", "15.83%"),
            ]
            var xml = "<sheetData>"
            for (i, t) in cases.enumerated() { xml += "<row r=\"\(i + 1)\"><c r=\"A\(i + 1)\" s=\"\(t.0)\"><v>\(t.1)</v></c></row>" }
            xml += "</sheetData>"
            let wb = try XlsxReader.read(data: try auditXlsx([("n", nil, xml)], styles: styles))
            let shown = wb.sheets.first?.rows.map { $0.first?.displayString ?? "" } ?? []
            let wrong = cases.enumerated().filter { i, t in i >= shown.count || shown[i] != t.2 }.map { i, t in "\(t.1) → \(i < shown.count ? shown[i] : "nil") (want \(t.2))" }
            check("xlsx number formats: General, percent, currency, thousands, scaling, dates and times print as in Excel", wrong.isEmpty, "\(wrong)")
            check("general numbers: 15 significant digits, no binary noise, no \".0\"",
                  CellValue.number(0.1 + 0.2).displayString == "0.3" && !CellValue.number(1234567890123456).displayString.hasSuffix(".0")
                  && CellValue.number(1.0 / 3).displayString == "0.333333333333333", CellValue.number(0.1 + 0.2).displayString)
        } catch { check("xlsx number formats: fixture", false, "\(error)") }

        // PDF / Markdown / HTML tables → Excel still use the lenient guess (unchanged).
        check("guess: PDF and Markdown table typing is unchanged", CellValue.guess("1,234") == .number(1234) && CellValue.guess("12.5%") == .number(0.125) && CellValue.guess("007") == .text("007"))
    }
}
