import Foundation
import AppKit
import PDFKit
import ImageIO
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

/// Checks for Word → PDF page layout (1.0.8): headers, footers and page fields (WD-11), section page size and
/// margins (WD-14), paragraph spacing, line spacing, indents and heading sizes from the document (WD-18), tab stops
/// and leaders (WD-17), and the text layer of dash characters drawn with Japanese fonts. Every document is generated
/// here and goes through the engine's actions only, so the file also builds against the unfixed source.
extension SelfTest {

    func testWordLayout() async {
        await wordLayoutHeaders()
        await wordLayoutSections()
        await wordLayoutParagraphs()
        await wordLayoutTabs()
        await wordLayoutBlankLines()
        await wordLayoutDashes()
        await wordLayoutLongText()
        await wordLayoutPictures()
        await wordLayoutFontWeight()
    }

    // MARK: Fixture

    struct LayoutDocx {
        /// Body content including its final w:sectPr.
        var body: String
        var styles: String?
        var settings: String?
        /// Header and footer parts: relationship id, file name in word/, kind ("header" / "footer"), XML.
        var parts: [(id: String, file: String, kind: String, xml: String)] = []
        /// Pictures: relationship id, file name in word/media/, bytes.
        var media: [(id: String, file: String, data: Data)] = []
    }

    func layoutDocx(_ d: LayoutDocx) throws -> Data {
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\""
        let rns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        func rels(_ inner: String) -> String {
            "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(inner)</Relationships>"
        }
        let z = ZipWriter()
        try z.add(path: "[Content_Types].xml", text: "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"emf\" ContentType=\"image/x-emf\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>")
        try z.add(path: "_rels/.rels", text: rels("<Relationship Id=\"rId1\" Type=\"\(rns)/officeDocument\" Target=\"word/document.xml\"/>"))
        try z.add(path: "word/document.xml", text: "<?xml version=\"1.0\"?><w:document \(w)><w:body>\(d.body)</w:body></w:document>")
        var r = ""
        if let st = d.styles {
            r += "<Relationship Id=\"rIdS\" Type=\"\(rns)/styles\" Target=\"styles.xml\"/>"
            try z.add(path: "word/styles.xml", text: "<?xml version=\"1.0\"?><w:styles \(w)>\(st)</w:styles>")
        }
        if let se = d.settings {
            r += "<Relationship Id=\"rIdSet\" Type=\"\(rns)/settings\" Target=\"settings.xml\"/>"
            try z.add(path: "word/settings.xml", text: "<?xml version=\"1.0\"?><w:settings \(w)>\(se)</w:settings>")
        }
        for p in d.parts {
            r += "<Relationship Id=\"\(p.id)\" Type=\"\(rns)/\(p.kind)\" Target=\"\(p.file)\"/>"
            let root = p.kind == "header" ? "w:hdr" : "w:ftr"
            try z.add(path: "word/\(p.file)", text: "<?xml version=\"1.0\"?><\(root) \(w)>\(p.xml)</\(root)>")
        }
        for m in d.media {
            r += "<Relationship Id=\"\(m.id)\" Type=\"\(rns)/image\" Target=\"media/\(m.file)\"/>"
            try z.add(path: "word/media/\(m.file)", data: m.data)
        }
        try z.add(path: "word/_rels/document.xml.rels", text: rels(r))
        return try z.finalize()
    }

    /// A4 portrait with one-inch margins and half-inch header and footer distances, plus extra section properties.
    func a4Section(_ extra: String = "", landscape: Bool = false, left: Int = 1440) -> String {
        let size = landscape ? "<w:pgSz w:w=\"16838\" w:h=\"11906\" w:orient=\"landscape\"/>" : "<w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
        return "<w:sectPr>\(extra)\(size)<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"\(left)\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
    }

    func pageField(_ name: String, cached: String) -> String {
        "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> \(name) </w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>\(cached)</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
    }

    var pageBreakRun: String { "<w:r><w:br w:type=\"page\"/></w:r>" }

    /// Converts the generated docx to PDF through the engine.
    func layoutPDF(_ d: LayoutDocx, _ name: String, in dir: URL) async -> PDFDocument? {
        guard let data = try? layoutDocx(d) else { return nil }
        let src = write(data, name, in: dir)
        guard case .success(let r) = await run(Act.toPDF, [src]), let u = r.outputs.first else { return nil }
        return PDFDocument(url: u)
    }

    /// Bounds of the first occurrence of `text` on the page, in PDF coordinates (origin bottom left).
    func textBounds(_ text: String, on page: PDFPage?) -> CGRect? {
        guard let page, let s = page.string else { return nil }
        let r = (s as NSString).range(of: text)
        guard r.location != NSNotFound, let sel = page.selection(for: r) else { return nil }
        return sel.bounds(for: page)
    }

    /// The line boxes of the text from marker `start` to marker `end` (a wrapped paragraph), top to bottom.
    func lineBounds(from start: String, to end: String, on page: PDFPage?) -> [CGRect] {
        guard let page, let s = page.string as NSString? else { return [] }
        let a = s.range(of: start), b = s.range(of: end)
        guard a.location != NSNotFound, b.location != NSNotFound, NSMaxRange(b) > a.location,
              let sel = page.selection(for: NSRange(location: a.location, length: NSMaxRange(b) - a.location)) else { return [] }
        return sel.selectionsByLine().map { $0.bounds(for: page) }.sorted { $0.maxY > $1.maxY }
    }

    func fontSize(of text: String, on page: PDFPage?) -> CGFloat? {
        guard let a = page?.attributedString else { return nil }
        let r = (a.string as NSString).range(of: text)
        guard r.location != NSNotFound else { return nil }
        return (a.attribute(.font, at: r.location + r.length / 2, effectiveRange: nil) as? NSFont)?.pointSize
    }

    func near(_ a: CGFloat?, _ b: CGFloat, _ tol: CGFloat) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

    // MARK: WD-11 headers, footers, page fields

    func wordLayoutHeaders() async {
        let d = fresh("word-layout-headers")
        let header = "<w:p><w:pPr><w:jc w:val=\"right\"/></w:pPr><w:r><w:t>HDR-RIGHT</w:t></w:r></w:p>"
        // The cached results ("9") are what Word last showed; the PDF must count the pages itself.
        let footer = "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r><w:t xml:space=\"preserve\">Page </w:t></w:r>" + pageField("PAGE", cached: "9")
            + "<w:r><w:t xml:space=\"preserve\"> of </w:t></w:r><w:fldSimple w:instr=\" NUMPAGES \"><w:r><w:t>9</w:t></w:r></w:fldSimple></w:p>"
        let body = wP(wR("BODY-ONE") + pageBreakRun) + wP(wR("BODY-TWO") + pageBreakRun) + wP(wR("BODY-THREE"))
            + a4Section("<w:headerReference w:type=\"default\" r:id=\"rIdH\"/><w:footerReference w:type=\"default\" r:id=\"rIdF\"/>")
        let doc = LayoutDocx(body: body, parts: [("rIdH", "header1.xml", "header", header), ("rIdF", "footer1.xml", "footer", footer)])
        guard let pdf = await layoutPDF(doc, "headers.docx", in: d) else { check("WD-11 header/footer fixture converts", false); return }
        let pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        check("WD-11 the header is on every page", pages.count == 3 && pages.allSatisfy { $0.contains("HDR-RIGHT") }, "\(pages)")
        check("WD-11 PAGE and NUMPAGES are counted per page, not the stored result",
              pages.count == 3 && (0..<3).allSatisfy { pages[$0].contains("Page \($0 + 1) of 3") }, "\(pages)")
        let page = pdf.page(at: 0)
        let h = textBounds("HDR-RIGHT", on: page), f = textBounds("Page 1 of 3", on: page)
        // Header 36 pt from the top, right-aligned at the right margin (595 - 72); footer centred, 36 pt from the bottom.
        check("WD-11 header sits in the top margin, right-aligned", h.map { 842 - $0.maxY < 60 && 842 - $0.maxY > 30 && abs($0.maxX - 523.3) < 6 } ?? false, "\(String(describing: h))")
        check("WD-11 footer sits in the bottom margin, centred", f.map { $0.minY > 30 && $0.minY < 60 && abs($0.midX - 297.6) < 8 } ?? false, "\(String(describing: f))")

        // Body text keeps the document's margins: one inch from the left and the top.
        let b = textBounds("BODY-ONE", on: page)
        check("WD-18 body starts at the document's margins", b.map { abs($0.minX - 72) < 3 && 842 - $0.maxY < 90 && 842 - $0.maxY > 70 } ?? false, "\(String(describing: b))")

        // Other outputs do not take the header or footer text.
        let src = d.appendingPathComponent("headers.docx")
        var clean = true
        for action in [Act.toMD, Act.toTXT, Act.toHTML] {
            let t = await outputText(action, src).text
            if t.isEmpty || t.contains("HDR-RIGHT") || t.contains("Page ") { clean = false }
        }
        check("WD-11 Markdown, text and HTML output stay without header and footer", clean)
    }

    // MARK: WD-14 sections: size, orientation, margins, first-page header, numbering restart

    func wordLayoutSections() async {
        let d = fresh("word-layout-sections")
        func hp(_ t: String) -> String { "<w:p><w:r><w:t>\(t)</w:t></w:r></w:p>" }
        let footer = "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r><w:t xml:space=\"preserve\">No.</w:t></w:r>" + pageField("PAGE", cached: "1") + "</w:p>"
        let s1 = a4Section("<w:headerReference w:type=\"default\" r:id=\"rIdD\"/><w:headerReference w:type=\"first\" r:id=\"rIdP\"/><w:footerReference w:type=\"default\" r:id=\"rIdF\"/><w:titlePg/><w:pgNumType w:start=\"5\"/>")
        // The second section has no header of its own (it shows the first section's) and a 2-inch left margin.
        let s2 = a4Section(landscape: true, left: 2880)
        let body = wP(wR("SEC1-PAGE-A") + pageBreakRun) + "<w:p><w:pPr>\(s1)</w:pPr><w:r><w:t>SEC1-PAGE-B</w:t></w:r></w:p>"
            + wP(wR("SEC2-LANDSCAPE")) + s2
        let doc = LayoutDocx(body: body, parts: [("rIdD", "header1.xml", "header", hp("DEF-HEAD")), ("rIdP", "header2.xml", "header", hp("FIRST-HEAD")),
                                                 ("rIdF", "footer1.xml", "footer", footer)])
        guard let pdf = await layoutPDF(doc, "sections.docx", in: d) else { check("WD-14 section fixture converts", false); return }
        let sizes = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.bounds(for: .mediaBox).size }.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
        check("WD-14 a landscape section gives landscape pages", sizes == ["595x842", "595x842", "842x595"], "\(sizes)")
        let text = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        check("WD-11 different first page: page 1 has the first-page header",
              text.count == 3 && text[0].contains("FIRST-HEAD") && !text[0].contains("DEF-HEAD") && text[1].contains("DEF-HEAD"), "\(text)")
        check("WD-11 a section without its own header shows the previous section's", text.count == 3 && text[2].contains("DEF-HEAD"), "\(text)")
        // Page 1 shows the first-page footer, which this document leaves empty; numbering starts at 5 there.
        check("WD-11 page numbering restarts at the section's start value", text.count == 3 && !text[0].contains("No.") && text[1].contains("No.6") && text[2].contains("No.7"), "\(text)")
        let b = textBounds("SEC2-LANDSCAPE", on: pdf.page(at: 2))
        check("WD-14 each section keeps its own margins", b.map { abs($0.minX - 144) < 3 } ?? false, "\(String(describing: b))")

        // Pictures of the pages follow the same layout.
        let src = d.appendingPathComponent("sections.docx")
        if case .success(let r) = await run(Act.toPNG, [src]), let out = r.outputs.first {
            let files = ((try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [out])
                .filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let dims = files.compactMap { u -> (Int, Int)? in
                guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
                      let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
                return (w, h)
            }
            check("WD-14 page images: the landscape page is wider than tall", dims.count == 3 && dims[0].0 < dims[0].1 && dims[2].0 > dims[2].1,
                  "\(dims)")
        } else { check("WD-14 page images: the landscape page is wider than tall", false) }
    }

    // MARK: WD-18 spacing, line spacing, indents, heading size

    func wordLayoutParagraphs() async {
        let d = fresh("word-layout-paragraphs")
        let styles = """
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman"/><w:sz w:val="20"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="0"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>
        """
        let long = String(repeating: "word ", count: 60)
        let body = "<w:p><w:pPr><w:pStyle w:val=\"Heading1\"/></w:pPr><w:r><w:t>HEADING-ONE</w:t></w:r></w:p>"
            + wP(wR("EXACT " + long + "EXACT-END"), pPr: "<w:spacing w:line=\"480\" w:lineRule=\"exact\"/>")
            + wP(wR("SINGLE " + long + "SINGLE-END"))
            + wP(wR("DOUBLE " + long + "DOUBLE-END"), pPr: "<w:spacing w:line=\"480\" w:lineRule=\"auto\"/>")
            + wP(wR("FIRSTLINE " + long + "FIRSTLINE-END"), pPr: "<w:ind w:firstLine=\"720\"/>")
            + wP(wR("HANGING " + long + "HANGING-END"), pPr: "<w:ind w:left=\"1440\" w:hanging=\"720\"/>")
            + wP(wR("SPACED-A"), pPr: "<w:spacing w:after=\"480\"/>") + wP(wR("SPACED-B"), pPr: "<w:spacing w:before=\"240\"/>")
            + a4Section()
        guard let pdf = await layoutPDF(LayoutDocx(body: body, styles: styles), "paragraphs.docx", in: d), let page = pdf.page(at: 0) else {
            check("WD-18 paragraph fixture converts", false); return
        }
        let hs = fontSize(of: "HEADING-ONE", on: page)
        check("WD-18 heading size comes from the heading style (14 pt)", near(hs, 14, 0.6), "\(String(describing: hs))")
        let exact = lineBounds(from: "EXACT", to: "EXACT-END", on: page)
        let exactStep = exact.count >= 3 ? exact[0].maxY - exact[1].maxY : 0
        check("WD-18 exact line spacing (24 pt)", exact.count >= 3 && abs(exactStep - 24) < 1, "\(exactStep)")
        let single = lineBounds(from: "SINGLE", to: "SINGLE-END", on: page), double = lineBounds(from: "DOUBLE", to: "DOUBLE-END", on: page)
        let s1 = single.count >= 2 ? single[0].maxY - single[1].maxY : 0, s2 = double.count >= 2 ? double[0].maxY - double[1].maxY : 0
        check("WD-18 double line spacing is twice single", s1 > 8 && abs(s2 - 2 * s1) < 1.5, "single \(s1) double \(s2)")
        let fl = lineBounds(from: "FIRSTLINE", to: "FIRSTLINE-END", on: page)
        check("WD-18 first-line indent (0.5 in)", fl.count >= 2 && abs(fl[0].minX - 108) < 2 && abs(fl[1].minX - 72) < 2, "\(fl.map(\.minX))")
        let hg = lineBounds(from: "HANGING", to: "HANGING-END", on: page)
        check("WD-18 hanging indent (left 1 in, hanging 0.5 in)", hg.count >= 2 && abs(hg[0].minX - 108) < 2 && abs(hg[1].minX - 144) < 2, "\(hg.map(\.minX))")
        // Between two paragraphs Word leaves the larger of the space after and the space before (24 pt here).
        let a = textBounds("SPACED-A", on: page), b = textBounds("SPACED-B", on: page)
        let gap = (a?.maxY ?? 0) - (b?.maxY ?? 0)
        check("WD-18 paragraph spacing before and after", gap > 24 + s1 - 2 && gap < 24 + s1 + 2, "gap \(gap), line \(s1)")
    }

    // MARK: WD-17 tab stops and leaders

    func wordLayoutTabs() async {
        let d = fresh("word-layout-tabs")
        let tab = "<w:r><w:tab/></w:r>"
        let body = wP(wR("TOC-ENTRY") + tab + wR("123"), pPr: "<w:tabs><w:tab w:val=\"right\" w:leader=\"dot\" w:pos=\"7200\"/></w:tabs>")
            + wP(tab + wR("CENTERED"), pPr: "<w:tabs><w:tab w:val=\"center\" w:pos=\"4320\"/></w:tabs>")
            + wP(wR("L") + tab + wR("LEFTSTOP"), pPr: "<w:tabs><w:tab w:val=\"left\" w:pos=\"2880\"/></w:tabs>")
            + wP(tab + wR("1234.5"), pPr: "<w:tabs><w:tab w:val=\"decimal\" w:pos=\"5760\"/></w:tabs>")
            + wP(wR("A") + tab + wR("DEFAULTSTOP"))
            + a4Section()
        let settings = "<w:defaultTabStop w:val=\"1440\"/>"
        guard let pdf = await layoutPDF(LayoutDocx(body: body, settings: settings), "tabs.docx", in: d), let page = pdf.page(at: 0) else {
            check("WD-17 tab fixture converts", false); return
        }
        let right = textBounds("123", on: page)
        check("WD-17 right tab: text ends at the stop", right.map { abs($0.maxX - 432) < 3 } ?? false, "\(String(describing: right))")
        let center = textBounds("CENTERED", on: page)
        check("WD-17 centre tab: text centred on the stop", center.map { abs($0.midX - 288) < 3 } ?? false, "\(String(describing: center))")
        let left = textBounds("LEFTSTOP", on: page)
        check("WD-17 left tab: text starts at the stop", left.map { abs($0.minX - 216) < 2 } ?? false, "\(String(describing: left))")
        var point: CGRect?
        if let s = page.string {
            let r = (s as NSString).range(of: "1234.5")
            if r.location != NSNotFound { point = page.selection(for: NSRange(location: r.location + 4, length: 1))?.bounds(for: page) }
        }
        check("WD-17 decimal tab: the decimal point sits at the stop", point.map { abs($0.minX - 360) < 3 } ?? false, "\(String(describing: point))")
        let def = textBounds("DEFAULTSTOP", on: page)
        check("WD-17 default tab interval from the document (1 in)", def.map { abs($0.minX - 144) < 2 } ?? false, "\(String(describing: def))")

        // The dot leader: ink between the entry and the page number, on the text's baseline.
        if let entry = textBounds("TOC-ENTRY", on: page), let num = right {
            let scale: CGFloat = 3
            let box = page.bounds(for: .mediaBox)
            let w = Int(box.width * scale), h = Int(box.height * scale)
            var ink = 0
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                if let px = ctx.data?.assumingMemoryBound(to: UInt8.self) {
                    let x0 = Int((entry.maxX + 6) * scale), x1 = Int((num.minX - 6) * scale)
                    let y0 = Int(entry.minY * scale), y1 = Int((entry.minY + entry.height * 0.5) * scale)
                    for y in max(0, y0)..<min(h, max(y0 + 1, y1)) {
                        let row = (h - 1 - y) * w * 4
                        for x in max(0, x0)..<min(w, max(x0 + 1, x1)) where px[row + x * 4] < 128 { ink += 1 }
                    }
                }
            }
            check("WD-17 dot leader drawn up to the page number", ink > 40, "dark pixels \(ink)")
        } else { check("WD-17 dot leader drawn up to the page number", false) }
    }

    // MARK: Blank lines

    func wordLayoutBlankLines() async {
        let d = fresh("word-layout-blank")
        let exact = "<w:spacing w:line=\"400\" w:lineRule=\"exact\"/>"
        let empty = "<w:p><w:pPr>\(exact)</w:pPr></w:p>"
        let body = wP(wR("BEFORE-BLANK"), pPr: exact) + empty + empty + empty + wP(wR("AFTER-BLANK"), pPr: exact) + a4Section()
        guard let pdf = await layoutPDF(LayoutDocx(body: body), "blank.docx", in: d), let page = pdf.page(at: 0) else {
            check("WD-18 blank-line fixture converts", false); return
        }
        let a = textBounds("BEFORE-BLANK", on: page), b = textBounds("AFTER-BLANK", on: page)
        let step = (a?.maxY ?? 0) - (b?.maxY ?? 0)
        check("WD-18 empty paragraphs keep their height (3 blank lines of 20 pt)", abs(step - 80) < 2, "step \(step)")
    }

    // MARK: Text layer of dashes drawn with Hiragino / Yu fonts

    func wordLayoutDashes() async {
        let d = fresh("word-layout-dashes")
        let sample = "語—語、1–2、マイナス−3、波〜線"
        let md = write(Data("# 見出し\n\n\(sample)\n".utf8), "dash.md", in: d)
        let mdText = await outputText(Act.toPDF, md).text
        check("PDF text layer: — – − 〜 copy back as themselves (Markdown)", mdText.contains(sample),
              mdText.unicodeScalars.filter { $0.value > 0x2000 && $0.value < 0x3100 }.map { String(format: "%04X", $0.value) }.joined(separator: " "))
        let body = wP(wR(sample)) + a4Section()
        guard let data = try? layoutDocx(LayoutDocx(body: body)) else { return }
        let text = await outputText(Act.toPDF, write(data, "dash.docx", in: d)).text
        check("PDF text layer: — – − 〜 copy back as themselves (Word)", text.contains(sample),
              text.unicodeScalars.filter { $0.value > 0x2000 && $0.value < 0x3100 }.map { String(format: "%04X", $0.value) }.joined(separator: " "))
    }

    // MARK: WD-34 very long plain text

    func wordLayoutLongText() async {
        let d = fresh("word-layout-longtext")
        let line = "これは非常に長いテキストファイルの行です。Line of a long text file. "
        var text = ""
        for i in 0..<6000 { text += "\(i) " + String(repeating: line, count: 3) + "\n" }
        text += "LAST-LINE-OF-TEXT\n"
        let src = write(Data(text.utf8), "long.txt", in: d)
        let t0 = Date()
        let (url, _) = await outputText(Act.toPDF, src)
        let seconds = Date().timeIntervalSince(t0)
        let doc = url.flatMap { PDFDocument(url: $0) }
        let last = doc.flatMap { $0.page(at: $0.pageCount - 1)?.string } ?? ""
        check("WD-34 1.6 MB of plain text becomes a PDF in under 5 s, complete", seconds < 5 && (doc?.pageCount ?? 0) > 400 && last.contains("LAST-LINE-OF-TEXT"),
              String(format: "%.1fs, %d pages", seconds, doc?.pageCount ?? 0))
    }

    // MARK: Follow-up: EMF pictures, inline pictures on one line, text boxes before a page break, font weight

    /// An inline picture of `w` x `h` points.
    func inlinePicture(_ rid: String, w: Double, h: Double) -> String {
        let cx = Int(w * 12700), cy = Int(h * 12700)
        return "<w:r><w:drawing><wp:inline><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"1\" name=\"P\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"1\" name=\"p\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(rid)\"/></pic:blipFill><pic:spPr/></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    /// The smallest EMF the slide renderer's player draws: a header (100 x 100 px at 96 dpi), the black stock brush,
    /// one filled rectangle, end of file.
    func tinyEMF() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        u32(1); u32(88); i32(0); i32(0); i32(99); i32(99); i32(0); i32(0); i32(2646); i32(2646)
        u32(0x464D_4520); u32(0x10000); u32(0); u32(4); d.append(contentsOf: [1, 0, 0, 0])
        u32(0); u32(0); u32(0); i32(1920); i32(1080); i32(508); i32(286)
        u32(37); u32(12); u32(0x8000_0004)
        u32(43); u32(24); i32(5); i32(5); i32(95); i32(95)
        u32(14); u32(20); u32(0); u32(16); u32(20)
        let n = UInt32(d.count).littleEndian
        withUnsafeBytes(of: n) { d.replaceSubrange(48..<52, with: $0) }
        return d
    }

    /// Dark pixels of the page inside `rect` (PDF points, origin top left).
    func ink(_ page: PDFPage?, in rect: CGRect) -> Int {
        guard let page else { return 0 }
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width), h = Int(box.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        page.draw(with: .mediaBox, to: ctx)
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var n = 0
        for y in max(0, Int(rect.minY))..<min(h, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(w, Int(rect.maxX)) where px[(y * w + x) * 4] < 100 { n += 1 }
        }
        return n
    }

    func wordLayoutPictures() async {
        let d = fresh("word-layout-pictures")
        // An EMF picture (macOS cannot decode EMF) at the top of the page, then a marker paragraph.
        let emfBody = wP(inlinePicture("rIdE", w: 100, h: 100)) + wP(wR("AFTER-EMF")) + a4Section()
        let emfDoc = LayoutDocx(body: emfBody, media: [("rIdE", "chart.emf", tinyEMF())])
        if let pdf = await layoutPDF(emfDoc, "emf.docx", in: d), let page = pdf.page(at: 0) {
            let marker = textBounds("AFTER-EMF", on: page)
            let top = marker.map { 842 - $0.maxY } ?? 0
            let dark = ink(page, in: CGRect(x: 72, y: 72, width: 451, height: max(top - 76, 1)))
            check("EMF picture in Word drawn in the PDF", dark > 3000 && top > 160, "dark \(dark), marker at \(top)")
        } else { check("EMF picture in Word drawn in the PDF", false, "no PDF") }
        if case .success(let r) = await run(Act.toMD, [d.appendingPathComponent("emf.docx")]) {
            let pngs = r.outputs.filter { $0.hasDirectoryPath || $0.pathExtension.isEmpty }
                .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
                .filter { $0.pathExtension == "png" }
            check("EMF picture in Word carried to Markdown as PNG", !pngs.isEmpty, "\(r.outputs.map(\.lastPathComponent))")
        } else { check("EMF picture in Word carried to Markdown as PNG", false) }

        // Two inline pictures in one paragraph share a line when they fit (200 + 200 pt in a 451 pt column).
        guard let cg = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        cg.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        guard let img = cg.makeImage() else { return }
        let png = pngData(img)
        let pairBody = wP(inlinePicture("rIdA", w: 200, h: 150) + inlinePicture("rIdB", w: 200, h: 150)) + wP(wR("AFTER-PAIR")) + a4Section()
        let pairDoc = LayoutDocx(body: pairBody, media: [("rIdA", "a.png", png), ("rIdB", "b.png", png)])
        if let pdf = await layoutPDF(pairDoc, "pair.docx", in: d), let page = pdf.page(at: 0) {
            let top = textBounds("AFTER-PAIR", on: page).map { 842 - $0.maxY } ?? 0
            check("inline pictures of one paragraph share a line", top > 72 + 150 && top < 72 + 150 + 60, "marker at \(top)")
        } else { check("inline pictures of one paragraph share a line", false, "no PDF") }

        // A text box anchored in a paragraph that then breaks the page stays on the first page.
        let box = "<w:r><w:drawing><wp:anchor><wp:extent cx=\"1270000\" cy=\"381000\"/><wp:wrapNone/><wp:docPr id=\"2\" name=\"T\"/><a:graphic><a:graphicData uri=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\"><wps:wsp><wps:spPr/><wps:txbx><w:txbxContent><w:p><w:r><w:t>BOX-ON-PAGE-ONE</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>"
        let boxBody = wP(wR("PAGE-ONE-TEXT") + box + pageBreakRun) + wP(wR("PAGE-TWO-TEXT")) + a4Section()
        if let pdf = await layoutPDF(LayoutDocx(body: boxBody), "boxbreak.docx", in: d), pdf.pageCount == 2 {
            check("a text box before a page break in its paragraph stays on that page",
                  pdf.page(at: 0)?.string?.contains("BOX-ON-PAGE-ONE") == true && pdf.page(at: 1)?.string?.contains("PAGE-TWO-TEXT") == true,
                  "\((0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" })")
        } else { check("a text box before a page break in its paragraph stays on that page", false, "no PDF or wrong page count") }
    }

    func wordLayoutFontWeight() async {
        let d = fresh("word-layout-fontweight")
        // ＭＳ ゴシック maps to Hiragino Sans; NSFont(name: "Hiragino Sans") is the hairline W0 face.
        let run = "<w:r><w:rPr><w:rFonts w:ascii=\"ＭＳ ゴシック\" w:hAnsi=\"ＭＳ ゴシック\" w:eastAsia=\"ＭＳ ゴシック\"/></w:rPr><w:t>ゴシック本文 GOTHIC-TEXT</w:t></w:r>"
        guard let pdf = await layoutPDF(LayoutDocx(body: wP(run) + a4Section()), "gothic.docx", in: d),
              let a = pdf.page(at: 0)?.attributedString else { check("ＭＳ ゴシック prints in a regular weight, not the hairline face", false); return }
        let r = (a.string as NSString).range(of: "GOTHIC-TEXT")
        let name = r.location == NSNotFound ? "" : ((a.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)?.fontName ?? "")
        check("ＭＳ ゴシック prints in a regular weight, not the hairline face", name.hasPrefix("HiraginoSans") && !name.hasSuffix("-W0"), name)
    }
}
