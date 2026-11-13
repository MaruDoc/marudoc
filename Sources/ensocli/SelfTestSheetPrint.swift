import Foundation
import AppKit
import PDFKit
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

/// Checks for printing sheets (1.0.8): Excel / CSV → PDF laid out like the sheet (XL-05), wide sheets (XL-06),
/// speed (XL-13), pictures and charts (XL-16), and Excel → Word tables (XL-05 / XL-12). Inputs are generated here and
/// everything goes through the Engine, so the same checks run against the 1.0.7 source to show they fail there.
/// Geometry uses Excel's column width rule with Calibri's digit width of 7 px: width w → floor((256w + 18) / 256 × 7)
/// px at 96 dpi; margins default to 0.7 in / 0.75 in.
extension SelfTest {

    struct SPSheet {
        var name: String
        var xml: String
        var state: String? = nil
        /// Drawing part XML (inside xdr:wsDr), its media and charts.
        var drawing: String? = nil
        var media: [(name: String, data: Data)] = []
        var charts: [(name: String, xml: String)] = []
    }

    /// A small .xlsx with styles, defined names and optional drawings (pictures, charts).
    func spXlsx(_ sheets: [SPSheet], styles: String? = nil, definedNames: String = "") throws -> Data {
        let x = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let sml = "application/vnd.openxmlformats-officedocument.spreadsheetml"
        let z = ZipWriter()
        var types = "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"\(sml).sheet.main+xml\"/>"
        var wb = "<?xml version=\"1.0\"?><workbook xmlns=\"\(x)\" xmlns:r=\"\(r)\"><sheets>"
        var rels = "<?xml version=\"1.0\"?><Relationships xmlns=\"\(pkg)\">"
        for (i, s) in sheets.enumerated() {
            let n = i + 1
            types += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"\(sml).worksheet+xml\"/>"
            wb += "<sheet name=\"\(s.name)\" sheetId=\"\(n)\"\(s.state.map { " state=\"\($0)\"" } ?? "") r:id=\"rId\(n)\"/>"
            rels += "<Relationship Id=\"rId\(n)\" Type=\"\(r)/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
            var body = s.xml
            if let d = s.drawing {
                body += "<drawing r:id=\"rIdDr\"/>"
                try z.add(path: "xl/worksheets/_rels/sheet\(n).xml.rels", text: "<?xml version=\"1.0\"?><Relationships xmlns=\"\(pkg)\"><Relationship Id=\"rIdDr\" Type=\"\(r)/drawing\" Target=\"../drawings/drawing\(n).xml\"/></Relationships>")
                try z.add(path: "xl/drawings/drawing\(n).xml", text: "<?xml version=\"1.0\"?><xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(r)\" xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\">\(d)</xdr:wsDr>")
                var drels = "<?xml version=\"1.0\"?><Relationships xmlns=\"\(pkg)\">"
                for m in s.media {
                    drels += "<Relationship Id=\"rId\(m.name)\" Type=\"\(r)/image\" Target=\"../media/\(m.name).png\"/>"
                    try z.add(path: "xl/media/\(m.name).png", data: m.data)
                }
                for c in s.charts {
                    drels += "<Relationship Id=\"rId\(c.name)\" Type=\"\(r)/chart\" Target=\"../charts/\(c.name).xml\"/>"
                    try z.add(path: "xl/charts/\(c.name).xml", text: c.xml)
                }
                try z.add(path: "xl/drawings/_rels/drawing\(n).xml.rels", text: drels + "</Relationships>")
            }
            try z.add(path: "xl/worksheets/sheet\(n).xml", text: "<?xml version=\"1.0\"?><worksheet xmlns=\"\(x)\" xmlns:r=\"\(r)\">\(body)</worksheet>")
        }
        if let styles {
            types += "<Override PartName=\"/xl/styles.xml\" ContentType=\"\(sml).styles+xml\"/>"
            rels += "<Relationship Id=\"rIdStyles\" Type=\"\(r)/styles\" Target=\"styles.xml\"/>"
            try z.add(path: "xl/styles.xml", text: "<?xml version=\"1.0\"?><styleSheet xmlns=\"\(x)\">\(styles)</styleSheet>")
        }
        try z.add(path: "[Content_Types].xml", text: types + "</Types>")
        try z.add(path: "_rels/.rels", text: "<?xml version=\"1.0\"?><Relationships xmlns=\"\(pkg)\"><Relationship Id=\"rId1\" Type=\"\(r)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        try z.add(path: "xl/workbook.xml", text: wb + "</sheets>" + (definedNames.isEmpty ? "" : "<definedNames>\(definedNames)</definedNames>") + "</workbook>")
        try z.add(path: "xl/_rels/workbook.xml.rels", text: rels + "</Relationships>")
        return try z.finalize()
    }

    /// A cell: a number when the value is numeric, else an inline string.
    func spC(_ ref: String, _ v: String, s: Int = 0) -> String {
        let style = s > 0 ? " s=\"\(s)\"" : ""
        if Double(v) != nil { return "<c r=\"\(ref)\"\(style)><v>\(v)</v></c>" }
        return "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t>\(v)</t></is></c>"
    }

    func spCol(_ c: Int) -> String {
        var n = c + 1, s = ""
        while n > 0 { let m = (n - 1) % 26; s = String(UnicodeScalar(65 + m)!) + s; n = (n - 1) / 26 }
        return s
    }

    /// Excel's printed width in points of a column `w` characters wide (Calibri 11).
    func spWidth(_ w: Double) -> Double { ((256 * w + 18) / 256 * 7).rounded(.down) * 0.75 }

    func spBounds(_ doc: PDFDocument, _ text: String, page: Int) -> CGRect? {
        guard let p = doc.page(at: page) else { return nil }
        for sel in doc.findString(text, withOptions: [.literal]) where sel.pages.contains(p) { return sel.bounds(for: p) }
        return nil
    }

    /// Number of dark pixels (all channels below 140) in a box given in page points from the top-left.
    func spInk(_ img: CGImage, scale: CGFloat, x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat) -> Int {
        var n = 0
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let p = pixel(img, x: Int(x * scale), yFromTop: Int(y * scale))
                if p.r < 140 && p.g < 140 && p.b < 140 { n += 1 }
                x += 0.5
            }
            y += 0.5
        }
        return n
    }

    static let spStyles = """
    <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/></numFmts>\
    <fonts count="4"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="16"/><name val="Calibri"/></font>\
    <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font><font><sz val="11"/><name val="游ゴシック"/></font></fonts>\
    <fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
    <fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/></patternFill></fill></fills>\
    <borders count="3"><border/><border><left style="thin"/><right style="thin"/><top style="thin"/><bottom style="thin"/></border>\
    <border><left style="thick"><color rgb="FF00B050"/></left><right style="thick"><color rgb="FF00B050"/></right><top style="thick"><color rgb="FF00B050"/></top><bottom style="thick"><color rgb="FF00B050"/></bottom></border></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="7"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>\
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" applyAlignment="1"><alignment horizontal="center"/></xf>\
    <xf numFmtId="0" fontId="2" fillId="2" borderId="1" applyAlignment="1"><alignment horizontal="center"/></xf>\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1"/>\
    <xf numFmtId="164" fontId="0" fillId="0" borderId="1" applyNumberFormat="1"/>\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="2"/>\
    <xf numFmtId="0" fontId="3" fillId="0" borderId="0"/></cellXfs>
    """

    func testSheetPrint() async {
        let d = fresh("sheet-print")
        func pdf(_ name: String, _ data: Data) async -> (URL, PDFDocument)? {
            let url = d.appendingPathComponent(name)
            try? data.write(to: url)
            switch await run(Act.toPDF, [url]) {
            case .success(let r):
                guard let out = r.outputs.first, let doc = PDFDocument(url: out) else { return nil }
                return (out, doc)
            case .failure(let e):
                check("sheet print: \(name) converts", false, errText(e))
                return nil
            }
        }

        // XL-05: a landscape, fit-to-one-page-wide report with a merged title, a filled header row repeated as print
        // title, borders and formatted dates.
        do {
            var xml = "<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr><cols><col min=\"1\" max=\"12\" width=\"14\" customWidth=\"1\"/></cols><sheetData>"
            xml += "<row r=\"1\" ht=\"30\" customHeight=\"1\">\(spC("A1", "SALES REPORT TITLE", s: 1))</row><row r=\"3\">"
            for c in 0..<12 { xml += spC("\(spCol(c))3", "H\(c + 1)", s: 2) }
            xml += "</row>"
            for r in 4...63 {
                xml += "<row r=\"\(r)\">" + spC("A\(r)", "\(45566 + r)", s: 4)
                for c in 1..<12 { xml += spC("\(spCol(c))\(r)", "\(r * 1000 + c + 1)", s: r == 5 && c == 4 ? 5 : 3) }
                xml += "</row>"
            }
            xml += "</sheetData><mergeCells count=\"1\"><mergeCell ref=\"A1:L1\"/></mergeCells>"
            xml += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
            xml += "<pageSetup paperSize=\"9\" orientation=\"landscape\" fitToWidth=\"1\" fitToHeight=\"0\"/>"
            let data = try spXlsx([SPSheet(name: "Sales", xml: xml)], styles: SelfTest.spStyles,
                                  definedNames: "<definedName name=\"_xlnm.Print_Titles\" localSheetId=\"0\">Sales!$3:$3</definedName>")
            if let (_, doc) = await pdf("sales.xlsx", data) {
                let sizes = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.bounds(for: .mediaBox).size }
                check("sheet print: landscape fit-to-width report prints on 2 landscape A4 pages",
                      doc.pageCount == 2 && sizes.allSatisfy { abs($0.width - 841.9) < 1 && abs($0.height - 595.3) < 1 }, "\(sizes)")
                let s = (841.89 - 100.8) / (12 * spWidth(14)), left = 50.4
                let title = spBounds(doc, "SALES REPORT TITLE", page: 0)
                check("sheet print: merged title is centred across its columns", title.map { abs($0.midX - (left + 6 * spWidth(14) * s)) < 4 } ?? false, "\(String(describing: title))")
                // Numbers are right-aligned at their column's right edge (2 pt padding); column edges follow the widths.
                let b4 = spBounds(doc, "4002", page: 0), l4 = spBounds(doc, "4012", page: 0)
                check("sheet print: column positions follow the file's widths; numbers right-aligned",
                      b4.map { abs($0.maxX - (left + 2 * spWidth(14) * s - 2 * s)) < 2 } == true
                      && l4.map { abs($0.maxX - (left + 12 * spWidth(14) * s - 2 * s)) < 2 } == true, "\(String(describing: b4)) \(String(describing: l4))")
                let p2 = doc.page(at: 1)?.string ?? ""
                check("sheet print: print-title row repeats on page 2, the title does not", p2.contains("H7") && !p2.contains("SALES REPORT TITLE"), String(p2.prefix(120)))
                check("sheet print: dates in the file's format, whole", (doc.string ?? "").contains("2024-10-05"), String((doc.string ?? "").prefix(200)))
                if let page = doc.page(at: 0), let img = renderPage(page, scale: 4) {
                    // Header fill at C3 (left of its centred text); thick green border on E5's left edge.
                    let hy = 54 + 45 * s + 7.5 * s
                    let fill = pixel(img, x: Int((left + 2.1 * spWidth(14) * s) * 4), yFromTop: Int(hy * 4))
                    let ey = 54 + 75 * s + 7.5 * s
                    let border = pixel(img, x: Int((left + 4 * spWidth(14) * s) * 4), yFromTop: Int(ey * 4))
                    check("sheet print: header fill colour is printed", abs(fill.r - 31) < 20 && abs(fill.g - 78) < 20 && abs(fill.b - 120) < 20, "\(fill)")
                    check("sheet print: border colour and weight are printed", border.g > 120 && border.r < 80 && border.b < 130, "\(border)")
                } else { check("sheet print: report page renders", false) }
            }
        } catch { check("sheet print: report fixture", false, "\(error)") }

        // XL-06: 40 columns at default width print landscape, shrunk to the 6.5 pt floor, in two column bands;
        // every number stays whole.
        do {
            var xml = "<sheetData><row r=\"1\">"
            for c in 0..<40 { xml += spC("\(spCol(c))1", "C\(c + 1)") }
            xml += "</row>"
            for r in 2...20 {
                xml += "<row r=\"\(r)\">"
                for c in 0..<40 { xml += spC("\(spCol(c))\(r)", "\(r * 1000 + c + 1)") }
                xml += "</row>"
            }
            xml += "</sheetData>"
            if let (_, doc) = await pdf("wide.xlsx", try spXlsx([SPSheet(name: "Wide", xml: xml)])) {
                let p1 = doc.page(at: 0)?.string ?? "", p2 = doc.page(at: 1)?.string ?? ""
                let landscape = (0..<doc.pageCount).allSatisfy { (doc.page(at: $0)?.bounds(for: .mediaBox).width ?? 0) > 800 }
                check("sheet print: 40-column sheet prints as two landscape pages of whole columns",
                      doc.pageCount == 2 && landscape && p1.contains("C26") && !p1.contains("C27") && p2.contains("C40"), "\(doc.pageCount) pages")
                let all = doc.string ?? ""
                check("sheet print: wide sheet keeps every number whole", ["20040", "2001", "11026", "11027"].allSatisfy { all.contains($0) }, String(all.prefix(160)))
            }
        } catch { check("sheet print: wide fixture", false, "\(error)") }

        // Overflow into empty neighbours, clipping at a filled one, numbers shrunk rather than broken.
        do {
            let w = String(repeating: "W", count: 20)
            var xml = "<cols><col min=\"1\" max=\"4\" width=\"10\" customWidth=\"1\"/></cols><sheetData>"
            xml += "<row r=\"1\">\(spC("A1", w))\(spC("D1", "END"))</row>"
            xml += "<row r=\"2\">\(spC("A2", w))\(spC("B2", "7"))\(spC("D2", "END"))</row>"
            xml += "<row r=\"3\">\(spC("C3", "123456789"))</row></sheetData>"
            if let (_, doc) = await pdf("overflow.xlsx", try spXlsx([SPSheet(name: "O", xml: xml)])), let page = doc.page(at: 0),
               let img = renderPage(page, scale: 3) {
                let left = 50.4, cw = spWidth(10)
                let bx0 = CGFloat(left + cw + 8), bx1 = CGFloat(left + 1.7 * cw)
                let row1 = spInk(img, scale: 3, x0: bx0, x1: bx1, y0: 57, y1: 66)
                let row2 = spInk(img, scale: 3, x0: bx0, x1: bx1, y0: 72, y1: 81)
                check("sheet print: text overflows into an empty neighbour and is cut at a filled one", row1 > 10 && row2 == 0, "ink \(row1) / \(row2)")
                check("sheet print: a number too wide for its column is not broken", (doc.string ?? "").contains("123456789"), doc.string ?? "")
            } else { check("sheet print: overflow page renders", false) }
        } catch { check("sheet print: overflow fixture", false, "\(error)") }

        // Frozen top row repeats on every page; print area and manual page breaks are respected.
        do {
            var xml = "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><sheetData>"
            xml += "<row r=\"1\">\(spC("A1", "HDRX"))\(spC("B1", "HDRY"))</row>"
            for r in 2...150 { xml += "<row r=\"\(r)\">\(spC("A\(r)", "\(r)"))\(spC("B\(r)", "row\(r)"))</row>" }
            xml += "</sheetData>"
            if let (_, doc) = await pdf("frozen.xlsx", try spXlsx([SPSheet(name: "F", xml: xml)])) {
                let p2 = doc.page(at: 1)?.string ?? ""
                check("sheet print: frozen header row repeats on page 2", doc.pageCount >= 2 && p2.contains("HDRX") && p2.contains("HDRY"), String(p2.prefix(80)))
            }
            var area = "<sheetData><row r=\"1\">\(spC("A1", "OUTSIDE1"))</row>"
            for r in 2...30 { area += "<row r=\"\(r)\">" + (1...3).map { spC("\(spCol($0))\(r)", "V\(r)x\($0)") }.joined() + "</row>" }
            area += "<row r=\"40\">\(spC("F40", "FAROUT"))</row></sheetData>"
            area += "<rowBreaks count=\"1\" manualBreakCount=\"1\"><brk id=\"10\" max=\"16383\" man=\"1\"/></rowBreaks>"
            let data = try spXlsx([SPSheet(name: "P", xml: area)], definedNames: "<definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">P!$B$2:$D$30</definedName>")
            if let (_, doc) = await pdf("area.xlsx", data) {
                let all = doc.string ?? "", p1 = doc.page(at: 0)?.string ?? "", p2 = doc.page(at: 1)?.string ?? ""
                check("sheet print: only the print area prints", !all.contains("OUTSIDE1") && !all.contains("FAROUT") && all.contains("V30x3"), String(all.prefix(80)))
                check("sheet print: a manual page break starts a new page", doc.pageCount == 2 && p1.contains("V10x1") && !p1.contains("V11x1") && p2.contains("V11x1"), "\(doc.pageCount) pages")
            }
        } catch { check("sheet print: frozen / area fixture", false, "\(error)") }

        // CSV: values exactly as written, numbers right-aligned, the first row an ordinary row (no grey header).
        do {
            let csv = d.appendingPathComponent("values.csv")
            try "amount,x,code\n\"1,234\",a,00123\n12.5%,b,1e5\n".write(to: csv, atomically: true, encoding: .utf8)
            switch await run(Act.toPDF, [csv]) {
            case .success(let r):
                if let doc = r.outputs.first.flatMap({ PDFDocument(url: $0) }) {
                    let t = doc.string ?? ""
                    check("csv print: values exactly as written", ["1,234", "12.5%", "00123", "1e5"].allSatisfy(t.contains) && !t.contains("0.125"), t)
                    let a = spBounds(doc, "1,234", page: 0), b = spBounds(doc, "12.5%", page: 0), h = spBounds(doc, "amount", page: 0)
                    let right = a.flatMap { a in b.map { abs(a.maxX - $0.maxX) < 0.6 && abs(a.minX - $0.minX) > 0.6 } } ?? false
                    check("csv print: numbers right-aligned", right && (h.map { hh in a.map { hh.minX < $0.minX } ?? false } ?? false), "\(String(describing: a)) \(String(describing: b))")
                    if let page = doc.page(at: 0), let img = renderPage(page, scale: 3), let xb = spBounds(doc, "x", page: 0) {
                        let p = pixel(img, x: Int((xb.maxX + 6) * 3), yFromTop: Int((page.bounds(for: .mediaBox).height - xb.midY) * 3))
                        check("csv print: first row is not a shaded header", p.r > 245 && p.g > 245 && p.b > 245, "\(p)")
                    }
                } else { check("csv print: output", false) }
            case .failure(let e): check("csv print: converts", false, errText(e))
            }
        } catch { check("csv print: fixture", false, "\(error)") }

        // A simple conditional format (number below zero → red font, as Numbers writes "[Red]" formats) is applied.
        do {
            let styles = "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"1\"><fill><patternFill patternType=\"none\"/></fill></fills><borders count=\"1\"><border/></borders><cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellXfs><dxfs count=\"1\"><dxf><font><color rgb=\"FFFF0000\"/></font></dxf></dxfs>"
            let xml = "<sheetData><row r=\"1\">\(spC("A1", "-88888"))\(spC("B1", "77777"))</row></sheetData><conditionalFormatting sqref=\"A1:B1\"><cfRule type=\"cellIs\" dxfId=\"0\" priority=\"1\" operator=\"lessThan\"><formula>0</formula></cfRule></conditionalFormatting>"
            if let (_, doc) = await pdf("cf.xlsx", try spXlsx([SPSheet(name: "CF", xml: xml)], styles: styles)), let page = doc.page(at: 0), let img = renderPage(page, scale: 3),
               let a = spBounds(doc, "-88888", page: 0), let b = spBounds(doc, "77777", page: 0) {
                let h = page.bounds(for: .mediaBox).height
                func red(_ r: CGRect) -> Bool {
                    var n = 0
                    for x in stride(from: r.minX, to: r.maxX, by: 0.5) {
                        let p = pixel(img, x: Int(x * 3), yFromTop: Int((h - r.midY) * 3))
                        if p.r > 180 && p.g < 90 && p.b < 90 { n += 1 }
                    }
                    return n > 2
                }
                check("sheet print: conditional format colours a negative number red, not the positive one", red(a) && !red(b), "\(a) \(b)")
            } else { check("sheet print: conditional format page renders", false) }
        } catch { check("sheet print: conditional format fixture", false, "\(error)") }

        // Copied text: "—" from a Japanese font comes back as U+2014, not U+0336.
        do {
            let xml = "<sheetData><row r=\"1\">\(spC("A1", "請求 — 確認", s: 6))\(spC("B1", "x"))</row></sheetData>"
            if let (_, doc) = await pdf("dash.xlsx", try spXlsx([SPSheet(name: "D", xml: xml)], styles: SelfTest.spStyles)) {
                let t = doc.string ?? ""
                check("sheet print: em dash in Japanese text copies as U+2014", t.contains("請求 — 確認") && !t.unicodeScalars.contains("\u{0336}"), t.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))
            }
        } catch { check("sheet print: dash fixture", false, "\(error)") }

        // XL-16: an anchored picture and a chart print on the page (and land in Word).
        do {
            let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:]) ?? Data()
            let xml = "<sheetData><row r=\"1\">\(spC("A1", "Month"))\(spC("B1", "Sales"))</row><row r=\"2\">\(spC("A2", "Apr"))\(spC("B2", "120"))</row><row r=\"3\">\(spC("A3", "May"))\(spC("B3", "150"))</row></sheetData>"
            // Picture: C2 + (0,0) to E6; chart: G2 to N16, with cached values.
            let drawing = "<xdr:twoCellAnchor><xdr:from><xdr:col>2</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>4</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>6</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"2\" name=\"P\"/><xdr:cNvPicPr/></xdr:nvPicPr><xdr:blipFill><a:blip r:embed=\"rIdimg1\"/></xdr:blipFill><xdr:spPr/></xdr:pic><xdr:clientData/></xdr:twoCellAnchor>"
                + "<xdr:twoCellAnchor><xdr:from><xdr:col>6</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>13</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>16</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:graphicFrame><xdr:nvGraphicFramePr><xdr:cNvPr id=\"3\" name=\"C\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\"><c:chart r:id=\"rIdchart1\"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>"
            let chart = "<?xml version=\"1.0\"?><c:chartSpace xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><c:chart><c:title><c:tx><c:rich><a:p><a:r><a:t>SALESCHART</a:t></a:r></a:p></c:rich></c:tx></c:title><c:plotArea><c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:ser><c:idx val=\"0\"/><c:tx><c:v>Sales</c:v></c:tx><c:spPr><a:solidFill><a:srgbClr val=\"0000FF\"/></a:solidFill></c:spPr><c:cat><c:strRef><c:f>S!$A$2:$A$3</c:f><c:strCache><c:ptCount val=\"2\"/><c:pt idx=\"0\"><c:v>Apr</c:v></c:pt><c:pt idx=\"1\"><c:v>May</c:v></c:pt></c:strCache></c:strRef></c:cat><c:val><c:numRef><c:f>S!$B$2:$B$3</c:f><c:numCache><c:ptCount val=\"2\"/><c:pt idx=\"0\"><c:v>120</c:v></c:pt><c:pt idx=\"1\"><c:v>150</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser></c:barChart><c:catAx><c:axId val=\"1\"/></c:catAx><c:valAx><c:axId val=\"2\"/></c:valAx></c:plotArea></c:chart></c:chartSpace>"
            let data = try spXlsx([SPSheet(name: "S", xml: xml, drawing: drawing, media: [("img1", png)], charts: [("chart1", chart)])])
            if let (_, doc) = await pdf("pictures.xlsx", data), let page = doc.page(at: 0), let img = renderPage(page, scale: 2) {
                // The picture covers C2:D6: its middle sits at x = margin + 3 columns, y = margin + 3.5 rows.
                let cw = 48.0, top = 54.0 // default columns: 8 digits + padding = 64 px
                let p = pixel(img, x: Int((50.4 + 3 * cw) * 2), yFromTop: Int((top + 15 * 3.5) * 2))
                check("sheet print: anchored picture is printed where it is anchored", p.r > 200 && p.g < 60 && p.b < 60, "\(p)")
                check("sheet print: chart is printed (title as text)", (doc.string ?? "").contains("SALESCHART"), doc.string ?? "")
            }
            let x = d.appendingPathComponent("pictures-w.xlsx")
            try data.write(to: x)
            if case .success(let r) = await run(Act.toDOCX, [x]), let out = r.outputs.first, let zip = try? ZipReader(data: Data(contentsOf: out)) {
                check("sheet → Word: picture and chart come along as pictures", zip.entries.filter { $0.path.hasPrefix("word/media/") }.count >= 2, "\(zip.entries.map(\.path))")
            } else { check("sheet → Word: pictures fixture converts", false) }
        } catch { check("sheet print: pictures fixture", false, "\(error)") }

        // Empty sheets print nothing; each sheet starts on its own page with a bookmark.
        do {
            let a = "<sheetData><row r=\"1\">\(spC("A1", "first sheet"))</row></sheetData>"
            let b = "<sheetData><row r=\"1\">\(spC("A1", "second sheet"))</row></sheetData>"
            let data = try spXlsx([SPSheet(name: "One", xml: a), SPSheet(name: "Empty", xml: "<sheetData/>"), SPSheet(name: "Two", xml: b)])
            if let (_, doc) = await pdf("multi.xlsx", data) {
                let outline = doc.outlineRoot.map { root in (0..<root.numberOfChildren).compactMap { root.child(at: $0)?.label } } ?? []
                check("sheet print: one page per sheet, empty sheet skipped, bookmarks per sheet",
                      doc.pageCount == 2 && (doc.page(at: 1)?.string ?? "").contains("second sheet") && outline == ["One", "Two"], "\(doc.pageCount) \(outline)")
            }
        } catch { check("sheet print: multi-sheet fixture", false, "\(error)") }

        // XL-05 / XL-12 in Word: the merged title is a centred paragraph, not the table's header; the header row is
        // the real one with its own fill; numbers right-aligned; column widths keep the sheet's proportions; a sheet
        // printed landscape gives a landscape document.
        do {
            var xml = "<cols><col min=\"1\" max=\"1\" width=\"8\" customWidth=\"1\"/><col min=\"2\" max=\"2\" width=\"30\" customWidth=\"1\"/><col min=\"3\" max=\"3\" width=\"12\" customWidth=\"1\"/></cols><sheetData>"
            xml += "<row r=\"1\">\(spC("A1", "WORD TITLE", s: 1))</row>"
            xml += "<row r=\"2\">\(spC("A2", "No", s: 2))\(spC("B2", "Item", s: 2))\(spC("C2", "Amount", s: 2))</row>"
            for r in 3...6 { xml += "<row r=\"\(r)\">\(spC("A\(r)", "\(r - 2)", s: 3))\(spC("B\(r)", "item \(r)", s: 3))\(spC("C\(r)", "\(r * 1250)", s: 3))</row>" }
            xml += "</sheetData><mergeCells count=\"1\"><mergeCell ref=\"A1:C1\"/></mergeCells><pageSetup orientation=\"landscape\"/>"
            let url = d.appendingPathComponent("word.xlsx")
            try spXlsx([SPSheet(name: "W", xml: xml)], styles: SelfTest.spStyles).write(to: url)
            switch await run(Act.toDOCX, [url]) {
            case .success(let r):
                let docXML = (try? ZipReader(data: Data(contentsOf: r.outputs[0])).data("word/document.xml")).map { String(decoding: $0, as: UTF8.self) } ?? ""
                let tableStart = docXML.range(of: "<w:tbl>")?.lowerBound
                let titleAt = docXML.range(of: "WORD TITLE")?.lowerBound
                let firstRow = tableStart.flatMap { s in docXML[s...].range(of: "</w:tr>").map { String(docXML[s..<$0.upperBound]) } } ?? ""
                check("sheet → Word: merged title is a centred paragraph above the table",
                      titleAt != nil && tableStart != nil && titleAt! < tableStart! && docXML[..<tableStart!].contains("<w:jc w:val=\"center\"/>"), String(docXML.prefix(600)))
                check("sheet → Word: header row is the real header with its own fill", firstRow.contains("<w:tblHeader/>") && firstRow.contains("Item") && firstRow.contains("1F4E78"), firstRow)
                var amountCell = ""
                if let hit = docXML.range(of: "3750") {
                    let from = docXML.index(hit.lowerBound, offsetBy: -260, limitedBy: docXML.startIndex) ?? docXML.startIndex
                    amountCell = String(docXML[from..<hit.lowerBound])
                }
                check("sheet → Word: numbers right-aligned", amountCell.contains("<w:jc w:val=\"right\"/>"), amountCell)
                let grid = docXML.components(separatedBy: "<w:gridCol w:w=\"").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
                check("sheet → Word: column widths keep the sheet's proportions", grid.count == 3 && grid[1] > grid[0] * 2 && grid[1] > grid[2], "\(grid)")
                check("sheet → Word: landscape sheet gives a landscape page", docXML.contains("w:orient=\"landscape\""), "")
            case .failure(let e): check("sheet → Word: converts", false, errText(e))
            }
        } catch { check("sheet → Word: fixture", false, "\(error)") }

        // Review round: "portrait" and scale 100 are no print setup; the automatic order is portrait 100 %, portrait
        // shrunk down to 80 %, landscape 100 %, landscape shrunk, then column bands. Landscape alone prints at 100 %.
        do {
            func wide(_ cols: Int, width: Double, setup: String) -> String {
                var xml = "<cols><col min=\"1\" max=\"\(cols)\" width=\"\(width)\" customWidth=\"1\"/></cols><sheetData>"
                for r in 1...10 { xml += "<row r=\"\(r)\">" + (0..<cols).map { spC("\(spCol($0))\(r)", "R\(r)C\($0 + 1)") }.joined() + "</row>" }
                return xml + "</sheetData><pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>" + setup
            }
            func sizes(_ doc: PDFDocument) -> [CGSize] { (0..<doc.pageCount).compactMap { doc.page(at: $0)?.bounds(for: .mediaBox).size } }
            // 40 default-width columns written as portrait / 100 % (LibreOffice, Numbers): automatic → landscape bands.
            let lo = wide(40, width: 8.43, setup: "<pageSetup paperSize=\"9\" scale=\"100\" orientation=\"portrait\"/>")
            if let (_, doc) = await pdf("portrait100.xlsx", try spXlsx([SPSheet(name: "L", xml: lo)])) {
                check("sheet print: orientation=\"portrait\" scale=\"100\" is laid out automatically (landscape bands)",
                      doc.pageCount == 2 && sizes(doc).allSatisfy { $0.width > 800 }, "\(sizes(doc))")
            }
            // 7 columns of 14 characters = 514.5 pt against 494 pt printable: portrait shrunk to about 96 %.
            if let (_, doc) = await pdf("slightlywide.xlsx", try spXlsx([SPSheet(name: "S", xml: wide(7, width: 14, setup: ""))])),
               let last = spBounds(doc, "R1C7", page: 0) {
                let s = (595.28 - 100.8) / (7 * spWidth(14))
                check("sheet print: slightly too wide prints portrait, shrunk to the width",
                      doc.pageCount == 1 && sizes(doc).allSatisfy { $0.width < 600 } && abs(last.minX - (50.4 + 6 * spWidth(14) * s + 2 * s)) < 2, "\(sizes(doc)) \(last)")
            }
            // Landscape set, nothing else: 100 % with column bands (40 × 48 pt over 741 pt printable → 3 pages).
            if let (_, doc) = await pdf("landscape100.xlsx", try spXlsx([SPSheet(name: "W", xml: wide(40, width: 8.43, setup: "<pageSetup orientation=\"landscape\"/>"))])) {
                check("sheet print: landscape without a scale prints at 100 % in column bands", doc.pageCount == 3 && sizes(doc).allSatisfy { $0.width > 800 }, "\(doc.pageCount)")
            }
        } catch { check("sheet print: automatic layout fixtures", false, "\(error)") }

        // Review round: text past the last used column runs on to the printable edge; wrapped text taller than its
        // cell shows its first lines, whole lines only; a file's row height grows by one line when exactly one is
        // missing.
        do {
            let styles = "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"1\"><fill><patternFill patternType=\"none\"/></fill></fills><borders count=\"1\"><border/></borders><cellXfs count=\"3\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" applyAlignment=\"1\"><alignment wrapText=\"1\" vertical=\"bottom\"/></xf><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" applyAlignment=\"1\"><alignment wrapText=\"1\" vertical=\"top\"/></xf></cellXfs>"
            var xml = "<cols><col min=\"1\" max=\"1\" width=\"10\" customWidth=\"1\"/><col min=\"2\" max=\"2\" width=\"30\" customWidth=\"1\"/></cols><sheetData>"
            xml += "<row r=\"1\">\(spC("A1", String(repeating: "W", count: 40)))</row>"
            xml += "<row r=\"2\" ht=\"15\" customHeight=\"1\"><c r=\"A2\" s=\"1\" t=\"inlineStr\"><is><t>TOPW\nMIDW\nENDW</t></is></c>\(spC("B2", "x"))</row>"
            xml += "<row r=\"3\" ht=\"30\" customHeight=\"1\"><c r=\"A3\" s=\"2\" t=\"inlineStr\"><is><t>ONE\nTWO\nTHREE</t></is></c></row>"
            xml += "<row r=\"4\">\(spC("B4", "NEXTROW"))</row>"
            xml += "<row r=\"5\" ht=\"37.5\" customHeight=\"1\"><c r=\"A5\" s=\"2\" t=\"inlineStr\"><is><t>L1W\nL2W\nL3W\nL4W</t></is></c></row>"
            xml += "</sheetData><pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
            if let (_, doc) = await pdf("cells.xlsx", try spXlsx([SPSheet(name: "C", xml: xml)], styles: styles)), let page = doc.page(at: 0),
               let img = renderPage(page, scale: 3) {
                // Columns A and B are 52.5 + 160.5 pt: the W's run past B's right edge (263.4) towards the margin.
                let ink = spInk(img, scale: 3, x0: 300, x1: 420, y0: 57, y1: 66)
                check("sheet print: text past the last used column runs on to the printable edge", ink > 10, "ink \(ink)")
                let t = doc.string ?? ""
                check("sheet print: wrapped text too tall for its row shows its first line", t.contains("TOPW") && !t.contains("ENDW") && !t.contains("MIDW"), t)
                check("sheet print: wrapped text is cut at a whole line", t.contains("L2W") && !t.contains("L3W"), t)
                let next = spBounds(doc, "NEXTROW", page: 0)
                let mid = next.map { page.bounds(for: .mediaBox).height - $0.midY } ?? 0
                // Rows 1-3 = 15 + 15 + 45 (30 grown by one line): row 4 spans 129-144 pt from the top (54 pt margin).
                check("sheet print: a file's row height grows by one line when wrapped text is one line short", t.contains("THREE") && abs(mid - 136.5) < 4, "mid \(mid)")
            } else { check("sheet print: cells fixture renders", false) }
        } catch { check("sheet print: cells fixture", false, "\(error)") }

        // Review round: fraction formats and Japanese era dates in the shared number formatter.
        do {
            let codes = ["# ?/?", "# ??/??", "?/?", "# ?/4", "[$-ja-JP]ggge\"年\"m\"月\"d\"日\"", "ge.m.d", "[$-411]gge\"年\"", "ggg ee\"年\""]
            var styles = "<numFmts count=\"\(codes.count)\">"
            for (i, code) in codes.enumerated() {
                styles += "<numFmt numFmtId=\"\(164 + i)\" formatCode=\"\(code.replacingOccurrences(of: "\"", with: "&quot;"))\"/>"
            }
            styles += "</numFmts><cellXfs count=\"\(codes.count + 1)\"><xf numFmtId=\"0\"/>" + codes.indices.map { "<xf numFmtId=\"\(164 + $0)\" applyNumberFormat=\"1\"/>" }.joined() + "</cellXfs>"
            let cases: [(Int, String, String)] = [
                (1, "2.75", "2 3/4"), (1, "-2.75", "-2 3/4"), (1, "3", "3"), (2, "0.3125", "5/16"), (3, "2.75", "11/4"), (4, "1.3", "1 1/4"),
                (5, "43586", "令和1年5月1日"), (5, "43585", "平成31年4月30日"), (6, "43586", "R1.5.1"), (7, "45566", "令6年"), (8, "32516", "平成 01年"),
            ]
            var xml = "<sheetData>"
            for (i, c) in cases.enumerated() { xml += "<row r=\"\(i + 1)\"><c r=\"A\(i + 1)\" s=\"\(c.0)\"><v>\(c.1)</v></c></row>" }
            // Built-in format 12 ("# ?/?"), as in biz.xlsx's 集計 sheet.
            xml += "<row r=\"\(cases.count + 1)\"><c r=\"A\(cases.count + 1)\" s=\"\(codes.count + 1)\"><v>2.75</v></c></row>"
            styles = styles.replacingOccurrences(of: "</cellXfs>", with: "<xf numFmtId=\"12\" applyNumberFormat=\"1\"/></cellXfs>")
                .replacingOccurrences(of: "<cellXfs count=\"\(codes.count + 1)\">", with: "<cellXfs count=\"\(codes.count + 2)\">")
            let wb = try XlsxReader.read(data: try spXlsx([SPSheet(name: "F", xml: xml + "</sheetData>")], styles: styles))
            let shown = wb.sheets.first?.rows.map { $0.first?.displayString ?? "" } ?? []
            var wrong = cases.enumerated().filter { i, c in i >= shown.count || shown[i] != c.2 }.map { i, c in "\(c.1) → \(i < shown.count ? shown[i] : "nil") (want \(c.2))" }
            if shown.count <= cases.count || shown[cases.count] != "2 3/4" { wrong.append("built-in 12: \(shown.count > cases.count ? shown[cases.count] : "nil")") }
            check("xlsx number formats: fractions and Japanese era dates", wrong.isEmpty, "\(wrong)")
        } catch { check("xlsx number formats: fraction / era fixture", false, "\(error)") }

        // XL-13: 50,000 CSV rows to PDF in seconds, not minutes (bound kept generous for slow machines).
        do {
            var text = "id,date,code,name,qty,price,amount,memo\n"
            text.reserveCapacity(3_000_000)
            for i in 1...50_000 { text += "\(i),2024-\(i % 12 + 1)-\(i % 28 + 1),\(String(format: "%06d", i)),商品\(i),\(i % 97),\(i % 13 * 100),\(i % 97 * (i % 13) * 100),\(i % 10 == 0 ? "メモ, \(i)" : "")\n" }
            let csv = d.appendingPathComponent("big.csv")
            try text.write(to: csv, atomically: true, encoding: .utf8)
            let t0 = Date()
            let r = await run(Act.toPDF, [csv])
            let dt = Date().timeIntervalSince(t0)
            var pages = 0
            if case .success(let res) = r, let doc = res.outputs.first.flatMap({ PDFDocument(url: $0) }) { pages = doc.pageCount }
            check("csv print: 50,000 rows to PDF in \(String(format: "%.1f", dt)) s (bound 45 s)", pages > 500 && dt < 45, "\(pages) pages")
        } catch { check("csv print: big fixture", false, "\(error)") }
    }
}
