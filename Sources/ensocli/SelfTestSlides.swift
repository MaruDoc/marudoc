import Foundation
import AppKit
import PDFKit
import ImageIO
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

/// Checks for 1.0.8's slide renderer (pptx → PDF / images draws each visible slide as it looks). The deck is built
/// here: a theme, a master with a background and graphics, a layout with placeholders, and slides with shapes,
/// a table, a cropped picture, a group, a chart, an EMF picture and dashes in the text. Everything goes through the
/// Engine, so the same checks run against older builds.
extension SelfTest {

    private static let slideNS = "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\""
    private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// EMU for points.
    private func e(_ pt: Double) -> Int { Int(pt * 12700) }

    private func xfrm(_ x: Double, _ y: Double, _ w: Double, _ h: Double, attrs: String = "") -> String {
        "<a:xfrm\(attrs)><a:off x=\"\(e(x))\" y=\"\(e(y))\"/><a:ext cx=\"\(e(w))\" cy=\"\(e(h))\"/></a:xfrm>"
    }

    private func rect(_ id: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double, fill: String, text: String = "") -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"R\(id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm(x, y, w, h))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:solidFill>\(fill)</a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>"
            + "<p:txBody><a:bodyPr/><a:lstStyle/><a:p>\(text.isEmpty ? "" : "<a:r><a:t>\(text)</a:t></a:r>")</a:p></p:txBody></p:sp>"
    }

    private func textBox(_ id: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ paras: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"T\(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm(x, y, w, h))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"square\"/><a:lstStyle/>\(paras)</p:txBody></p:sp>"
    }

    /// 400 x 100 PNG: red, green, blue, yellow stripes.
    private func stripesPNG() -> Data { ImageCodec.encode(stripesImage(), as: .png)! }

    /// An EMF holding one 2 x 2 red bitmap stretched over its whole frame (as Office saves pasted pictures).
    private func redEMF() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bmiSize = 40, bitsSize = 16, sdSize = 80 + bmiSize + bitsSize
        let total = 88 + sdSize + 20
        // EMR_HEADER: bounds 0..99 px, frame 0..1000 (0.01 mm), 1000 x 1000 px device of 100 x 100 mm.
        u32(1); u32(88); i32(0); i32(0); i32(99); i32(99); i32(0); i32(0); i32(1000); i32(1000)
        u32(0x464D4520); u32(0x10000); u32(UInt32(total)); u32(3); u16(1); u16(0); u32(0); u32(0); u32(0)
        i32(1000); i32(1000); i32(100); i32(100)
        // EMR_STRETCHDIBITS onto (0, 0, 100, 100).
        u32(81); u32(UInt32(sdSize)); i32(0); i32(0); i32(99); i32(99)
        i32(0); i32(0); i32(0); i32(0); i32(2); i32(2)
        u32(80); u32(UInt32(bmiSize)); u32(UInt32(80 + bmiSize)); u32(UInt32(bitsSize)); u32(0); u32(0x00CC0020); i32(100); i32(100)
        // BITMAPINFOHEADER: 2 x 2, 24 bit, bottom-up.
        u32(40); i32(2); i32(2); u16(1); u16(24); u32(0); u32(UInt32(bitsSize)); i32(0); i32(0); u32(0); u32(0)
        for _ in 0..<2 { d.append(contentsOf: [0, 0, 255, 0, 0, 255, 0, 0]) }   // BGR red x2, row padded to 8 bytes
        // EMR_EOF
        u32(14); u32(20); u32(0); u32(16); u32(20)
        return d
    }

    /// The fixture deck: 720 x 405 pt, seven slides, slide 2 hidden.
    func slideDeck() throws -> Data {
        let ns = SelfTest.slideNS, rns = SelfTest.rel
        func rels(_ inner: String) -> String { "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(inner)</Relationships>" }
        func r(_ id: String, _ type: String, _ target: String) -> String { "<Relationship Id=\"\(id)\" Type=\"\(rns)/\(type)\" Target=\"\(target)\"/>" }
        let z = ZipWriter()
        try z.add(path: "[Content_Types].xml", text: "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"emf\" ContentType=\"image/x-emf\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/></Types>")
        try z.add(path: "_rels/.rels", text: rels(r("rId1", "officeDocument", "ppt/presentation.xml")))
        let slideCount = 7
        let ids = (0..<slideCount).map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 1)\"/>" }.joined()
        try z.add(path: "ppt/presentation.xml", text: "<?xml version=\"1.0\"?><p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rIdM\"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx=\"\(e(720))\" cy=\"\(e(405))\"/><p:defaultTextStyle><a:lvl1pPr><a:defRPr sz=\"1800\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/></a:defRPr></a:lvl1pPr></p:defaultTextStyle></p:presentation>")
        try z.add(path: "ppt/_rels/presentation.xml.rels", text: rels((0..<slideCount).map { r("rId\($0 + 1)", "slide", "slides/slide\($0 + 1).xml") }.joined() + r("rIdM", "slideMaster", "slideMasters/slideMaster1.xml")))
        // Theme: lt2 is light green so the master's bgRef (bg2 -> lt2) is recognisable.
        let clr = ["dk1": "000000", "lt1": "FFFFFF", "dk2": "1F497D", "lt2": "C6E0B4", "accent1": "4472C4", "accent2": "ED7D31", "accent3": "A5A5A5",
                   "accent4": "FFC000", "accent5": "5B9BD5", "accent6": "70AD47", "hlink": "0563C1", "folHlink": "954F72"]
        let order = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"]
        let scheme = order.map { "<a:\($0)><a:srgbClr val=\"\(clr[$0]!)\"/></a:\($0)>" }.joined()
        let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let ln = "<a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        try z.add(path: "ppt/theme/theme1.xml", text: "<?xml version=\"1.0\"?><a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"T\"><a:themeElements><a:clrScheme name=\"T\">\(scheme)</a:clrScheme><a:fontScheme name=\"T\"><a:majorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"T\"><a:fillStyleLst>\(solid)\(solid)\(solid)</a:fillStyleLst><a:lnStyleLst>\(ln)\(ln)\(ln)</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\(solid)\(solid)\(solid)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>")
        // Master: background from the theme (bg2), a navy bar along the bottom, title and body placeholders.
        let master = "<?xml version=\"1.0\"?><p:sldMaster \(ns)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg2\"/></p:bgRef></p:bg><p:spTree>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Title\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:spPr>\(xfrm(36, 10, 648, 50))</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Body\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr>\(xfrm(36, 70, 648, 280))</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>"
            + rect(4, 0, 385, 720, 20, fill: "<a:srgbClr val=\"1F3864\"/>")
            + "</p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            + "<p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz=\"3200\"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:buNone/><a:defRPr sz=\"2000\"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz=\"1800\"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>"
        try z.add(path: "ppt/slideMasters/slideMaster1.xml", text: master)
        try z.add(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", text: rels(r("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml") + r("rId2", "theme", "../theme/theme1.xml")))
        // Layout: moves the body placeholder to the right half at 30 pt; adds a label of its own.
        let layout = "<?xml version=\"1.0\"?><p:sldLayout \(ns)><p:cSld><p:spTree>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Body\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr>\(xfrm(360, 100, 300, 200))</p:spPr><p:txBody><a:bodyPr lIns=\"0\" tIns=\"0\"/><a:lstStyle><a:lvl1pPr><a:defRPr sz=\"3000\"/></a:lvl1pPr></a:lstStyle><a:p/></p:txBody></p:sp>"
            + textBox(3, 36, 355, 300, 20, "<a:p><a:r><a:rPr sz=\"1000\"/><a:t>LAYOUT-LABEL</a:t></a:r></a:p>")
            + "</p:spTree></p:cSld></p:sldLayout>"
        try z.add(path: "ppt/slideLayouts/slideLayout1.xml", text: layout)
        try z.add(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", text: rels(r("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")))

        let title = { (t: String) in "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"T\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(t)</a:t></a:r></a:p></p:txBody></p:sp>" }
        var slides: [(String, String, String)] = []   // (root attributes, shapes, extra rels)
        // 1: placeholder inheritance, a red rectangle, a theme colour, the slide number.
        slides.append(("", title("TITLE-ONE")
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"B\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>INHERITED-BODY</a:t></a:r></a:p></p:txBody></p:sp>"
            + rect(4, 60, 150, 100, 50, fill: "<a:srgbClr val=\"FF0000\"/>")
            + rect(5, 200, 150, 100, 50, fill: "<a:schemeClr val=\"accent1\"><a:lumMod val=\"75000\"/></a:schemeClr>")
            + textBox(6, 600, 300, 60, 30, "<a:p><a:fld id=\"{1}\" type=\"slidenum\"><a:t>‹#›</a:t></a:fld><a:r><a:t>-SLIDENO</a:t></a:r></a:p>"), ""))
        // 2: hidden.
        slides.append(("show=\"0\"", title("HIDDEN-SLIDE"), ""))
        // 3: a table with 300 / 100 / 100 pt columns in Medium Style 2 (not defined in the file).
        func cell(_ t: String) -> String { "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr sz=\"1200\"/><a:t>\(t)</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>" }
        let table = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"3\" name=\"Tbl\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x=\"\(e(36))\" y=\"\(e(80))\"/><a:ext cx=\"\(e(500))\" cy=\"\(e(60))\"/></p:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblPr firstRow=\"1\" bandRow=\"1\"><a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId></a:tblPr><a:tblGrid><a:gridCol w=\"\(e(300))\"/><a:gridCol w=\"\(e(100))\"/><a:gridCol w=\"\(e(100))\"/></a:tblGrid>"
            + "<a:tr h=\"\(e(30))\">\(cell("A1"))\(cell("B1"))\(cell("C1"))</a:tr><a:tr h=\"\(e(30))\">\(cell("A2"))\(cell("B2"))"
            + "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>C2</a:t></a:r></a:p></a:txBody><a:tcPr><a:lnR w=\"57150\"><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></a:lnR></a:tcPr></a:tc>"
            + "</a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        slides.append(("", title("TABLE-SLIDE") + table, ""))
        // 4: a picture cropped to its blue stripe; a group whose child space is half its size.
        let pic = "<p:pic><p:nvPicPr><p:cNvPr id=\"3\" name=\"P\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rIdImg\"/><a:srcRect l=\"50000\" r=\"25000\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(xfrm(100, 100, 100, 100))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
        let group = "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"4\" name=\"G\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"\(e(400))\" y=\"\(e(100))\"/><a:ext cx=\"\(e(200))\" cy=\"\(e(100))\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"\(e(100))\" cy=\"\(e(50))\"/></a:xfrm></p:grpSpPr>"
            + rect(5, 50, 25, 50, 25, fill: "<a:srgbClr val=\"00FF00\"/>") + "</p:grpSp>"
        slides.append(("", title("PICTURE-SLIDE") + pic + group, r("rIdImg", "image", "../media/stripes.png")))
        // 5: a column chart from cached values.
        let chartFrame = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"3\" name=\"C\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x=\"\(e(60))\" y=\"\(e(70))\"/><a:ext cx=\"\(e(400))\" cy=\"\(e(300))\"/></p:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\"><c:chart r:id=\"rIdC\"/></a:graphicData></a:graphic></p:graphicFrame>"
        slides.append(("", title("CHART-SLIDE") + chartFrame, r("rIdC", "chart", "../charts/chart1.xml")))
        // 6: an EMF picture.
        let emf = "<p:pic><p:nvPicPr><p:cNvPr id=\"3\" name=\"E\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rIdE\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(xfrm(100, 100, 200, 100))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
        slides.append(("", title("EMF-SLIDE") + emf, r("rIdE", "image", "../media/pic.emf")))
        // 7: dashes, wave dash and an ellipsis in Japanese text.
        slides.append(("", title("DASH-SLIDE") + textBox(3, 36, 100, 600, 40, "<a:p><a:r><a:rPr lang=\"ja-JP\"/><a:t>範囲1–2　対比—強調　〜から...まで</a:t></a:r></a:p>"), ""))

        for (i, s) in slides.enumerated() {
            try z.add(path: "ppt/slides/slide\(i + 1).xml", text: "<?xml version=\"1.0\"?><p:sld \(ns) \(s.0)><p:cSld><p:spTree>\(s.1)</p:spTree></p:cSld></p:sld>")
            try z.add(path: "ppt/slides/_rels/slide\(i + 1).xml.rels", text: rels(r("rIdL", "slideLayout", "../slideLayouts/slideLayout1.xml") + s.2))
        }
        try z.add(path: "ppt/media/stripes.png", data: stripesPNG())
        try z.add(path: "ppt/media/pic.emf", data: redEMF())
        let pts = [(0, "A", 10.0), (1, "B", 20.0)]
        let chart = "<?xml version=\"1.0\"?><c:chartSpace \(ns)><c:chart><c:plotArea><c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:ser><c:idx val=\"0\"/><c:order val=\"0\"/>"
            + "<c:cat><c:strLit><c:ptCount val=\"2\"/>" + pts.map { "<c:pt idx=\"\($0.0)\"><c:v>\($0.1)</c:v></c:pt>" }.joined() + "</c:strLit></c:cat>"
            + "<c:val><c:numLit><c:ptCount val=\"2\"/>" + pts.map { "<c:pt idx=\"\($0.0)\"><c:v>\($0.2)</c:v></c:pt>" }.joined() + "</c:numLit></c:val></c:ser><c:axId val=\"1\"/><c:axId val=\"2\"/></c:barChart>"
            + "<c:catAx><c:axId val=\"1\"/><c:delete val=\"0\"/><c:axPos val=\"b\"/><c:crossAx val=\"2\"/></c:catAx><c:valAx><c:axId val=\"2\"/><c:delete val=\"0\"/><c:axPos val=\"l\"/><c:crossAx val=\"1\"/></c:valAx></c:plotArea></c:chart></c:chartSpace>"
        try z.add(path: "ppt/charts/chart1.xml", text: chart)
        return try z.finalize()
    }

    /// The page drawn at `scale` pixels per point, white behind it.
    func rasterize(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let b = page.bounds(for: .mediaBox)
        let w = Int(b.width * scale), h = Int(b.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Colour at slide point (x, y from the top), from a 2x rendering.
    func slidePixel(_ page: PDFPage, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int, a: Int) {
        guard let img = rasterize(page, scale: 2) else { return (-1, -1, -1, -1) }
        return pixel(img, x: Int(x * 2), yFromTop: Int(y * 2))
    }

    func near(_ p: (r: Int, g: Int, b: Int, a: Int), _ hex: String, tol: Int = 12) -> Bool {
        guard let c = DocColor(hex: hex) else { return false }
        return abs(p.r - Int(c.r * 255)) <= tol && abs(p.g - Int(c.g * 255)) <= tol && abs(p.b - Int(c.b * 255)) <= tol
    }

    /// Bounds (y from the top of the page) of the first match of `text`.
    func textBounds(_ doc: PDFDocument, _ page: Int, _ text: String) -> CGRect? {
        guard let p = doc.page(at: page) else { return nil }
        for sel in doc.findString(text, withOptions: []) where sel.pages.contains(p) {
            let b = sel.bounds(for: p), h = p.bounds(for: .mediaBox).height
            return CGRect(x: b.minX, y: h - b.maxY, width: b.width, height: b.height)
        }
        return nil
    }

    // MARK: Tests

    func testSlides() async {
        let d = fresh("slides")
        let url = d.appendingPathComponent("deck.pptx")
        do { try slideDeck().write(to: url) } catch { check("slides fixture", false, "\(error)"); return }

        // The menu says what it does now.
        let menu = ActionCatalog.menu(for: [URL(fileURLWithPath: "/tmp/a.pptx")])
        check("slides: the presentation menu offers plain 「PDF に変換」", menu.first?.action == Act.toPDF && menu.first?.title == L("PDF に変換"), menu.first?.title ?? "")

        guard case .success(let r) = await run(Act.toPDF, [url]), let doc = PDFDocument(url: r.outputs[0]) else {
            check("slides: pptx → pdf", false); return
        }
        check("slides: one page per visible slide (7 slides, 1 hidden → 6 pages)", doc.pageCount == 6, "\(doc.pageCount) pages")
        let size = doc.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
        check("slides: page size is the slide size (720 x 405 pt)", abs(size.width - 720) < 0.5 && abs(size.height - 405) < 0.5, "\(size)")
        let all = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        check("slides: the hidden slide is not in the PDF", !all.joined().contains("HIDDEN-SLIDE") && all.first?.contains("TITLE-ONE") == true)
        check("slides: text is real, one slide per page", doc.pageCount == 6 && all[0].contains("INHERITED-BODY") && all[1].contains("TABLE-SLIDE") && all[2].contains("PICTURE-SLIDE"),
              all.map { String($0.prefix(30)) }.joined(separator: " | "))
        check("slides: the slide number field shows the slide's number", all.first?.filter({ !$0.isWhitespace }).contains("1-SLIDENO") == true, all.first ?? "")
        check("slides: layout graphics (a label) are drawn on the slide", all.first?.contains("LAYOUT-LABEL") == true)

        // Each slide's page is found by its title, so every check below runs (and fails on its own) even when the
        // pages are not one per slide.
        func page(_ marker: String) -> PDFPage? {
            (0..<doc.pageCount).lazy.compactMap { doc.page(at: $0) }.first { ($0.string ?? "").contains(marker) }
        }
        func pixel(_ marker: String, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int, a: Int) {
            guard let p = page(marker) else { return (-1, -1, -1, -1) }
            return slidePixel(p, x, y)
        }
        func bounds(_ marker: String, _ text: String) -> CGRect? {
            guard let p = page(marker) else { return nil }
            return textBounds(doc, doc.index(for: p), text)
        }
        check("slides: master background from the theme (bgRef → bg2 → lt2, light green)", near(pixel("TITLE-ONE", 700, 120), "C6E0B4"), "\(pixel("TITLE-ONE", 700, 120))")
        check("slides: master graphics (navy bar) are drawn", near(pixel("TITLE-ONE", 360, 395), "1F3864"), "\(pixel("TITLE-ONE", 360, 395))")
        check("slides: a filled shape has its colour (FF0000)", near(pixel("TITLE-ONE", 110, 175), "FF0000"), "\(pixel("TITLE-ONE", 110, 175))")
        // accent1 4472C4 with lumMod 75% is Office's "darker 25%": 2F5597.
        check("slides: theme colour with lumMod (accent1 75% → 2F5597)", near(pixel("TITLE-ONE", 250, 175), "2F5597", tol: 6), "\(pixel("TITLE-ONE", 250, 175))")
        if let b = bounds("TITLE-ONE", "INHERITED-BODY") {
            // Layout body: x 360, y 100, no left/top inset, 30 pt.
            check("slides: placeholder position comes from the layout", abs(b.minX - 360) < 4 && b.minY > 98 && b.minY < 125, "\(b)")
            check("slides: placeholder font size comes from the layout (30 pt, not the master's 20)", b.height > 27 && b.height < 45, "\(b.height)")
        } else { check("slides: placeholder inheritance", false, "text not found") }

        if let b1 = bounds("TABLE-SLIDE", "B1"), let c1 = bounds("TABLE-SLIDE", "C1"), let a1 = bounds("TABLE-SLIDE", "A1") {
            // Table at x 36: columns 300 / 100 / 100 pt, 7.2 pt cell margin.
            check("slides: table columns keep their widths (B1 at 343, C1 at 443)", abs(a1.minX - 43.2) < 3 && abs(b1.minX - 343.2) < 3 && abs(c1.minX - 443.2) < 3,
                  "A1 \(a1.minX) B1 \(b1.minX) C1 \(c1.minX)")
        } else { check("slides: table columns keep their widths", false, "text not found") }
        check("slides: table style header row (built-in Medium Style 2, accent1)", near(pixel("TABLE-SLIDE", 200, 88), "4472C4"), "\(pixel("TABLE-SLIDE", 200, 88))")
        check("slides: table style banded row (accent1 tint 40% → CFD5EA)", near(pixel("TABLE-SLIDE", 200, 118), "CFD5EA", tol: 6), "\(pixel("TABLE-SLIDE", 200, 118))")

        // C2's own right border: 4.5 pt red on the table's right edge (x 536).
        check("slides: a cell's own border is drawn (a:lnR)", near(pixel("TABLE-SLIDE", 536, 125), "FF0000"), "\(pixel("TABLE-SLIDE", 536, 125))")

        let left = pixel("PICTURE-SLIDE", 104, 150), mid = pixel("PICTURE-SLIDE", 150, 150), right = pixel("PICTURE-SLIDE", 196, 150)
        check("slides: a cropped picture shows only the cropped part (blue across the frame)", [left, mid, right].allSatisfy { $0.b > 200 && $0.r < 60 && $0.g < 60 }, "\(left) \(mid) \(right)")
        // Group: child (50, 25, 50 x 25) in a 100 x 50 child space scaled onto 200 x 100 at (400, 100).
        check("slides: group transform maps child coordinates (green at 500-600, 150-200)", near(pixel("PICTURE-SLIDE", 550, 175), "00FF00") && !near(pixel("PICTURE-SLIDE", 450, 125), "00FF00"),
              "\(pixel("PICTURE-SLIDE", 550, 175)) \(pixel("PICTURE-SLIDE", 450, 125))")
        // Chart bars in the default series colour (accent1).
        check("slides: a chart is drawn from its cached values (bar in accent1)", near(pixel("CHART-SLIDE", 340, 330), "4472C4"), "\(pixel("CHART-SLIDE", 340, 330))")
        check("slides: an EMF picture (bitmap record) is drawn", near(pixel("EMF-SLIDE", 200, 150), "FF0000"), "\(pixel("EMF-SLIDE", 200, 150))")
        let dash = all.joined().filter { !$0.isWhitespace }
        check("slides: dashes, wave dash and ellipsis read back as typed", dash.contains("範囲1–2") && dash.contains("対比—強調") && dash.contains("〜から...まで"),
              dash.unicodeScalars.filter { $0.value > 0x2000 && $0.value < 0x3100 }.map { String(format: "%04X", $0.value) }.joined(separator: " "))

        // Images: one per visible slide, in the slide's proportions.
        switch await run(Act.toPNG, [url]) {
        case .success(let r):
            let files = ((try? FileManager.default.contentsOfDirectory(at: r.outputs[0], includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "png" }
            let ratios = files.compactMap { u -> Double? in
                guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
                      let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, h > 0 else { return nil }
                return Double(w) / Double(h)
            }
            check("slides: pptx → png gives one image per visible slide at the slide's shape", files.count == 6 && ratios.allSatisfy { abs($0 - 720.0 / 405.0) < 0.01 }, "\(files.count) files \(ratios)")
        case .failure(let e): check("slides: pptx → png", false, errText(e))
        }

        // The document outputs still come from the reader (hidden slide left out, text kept).
        if case .success(let r) = await run(Act.toMD, [url]), let md = try? String(contentsOf: r.outputs[0], encoding: .utf8) {
            check("slides: pptx → md is unchanged (reader output, no hidden slide)", md.contains("TITLE-ONE") && md.contains("INHERITED-BODY") && !md.contains("HIDDEN-SLIDE"), md)
        } else { check("slides: pptx → md", false) }

        // Damaged and empty decks.
        let broken = d.appendingPathComponent("broken.pptx")
        try? Data((try? Data(contentsOf: url))?.prefix(300) ?? Data()).write(to: broken)
        if case .failure = await run(Act.toPDF, [broken]) { check("slides: a damaged deck gives an error, no PDF", !exists(d.appendingPathComponent("broken.pdf"))) } else { check("slides: a damaged deck gives an error", false) }
        let empty = d.appendingPathComponent("empty.pptx")
        if let data = try? pptxDeck([]) {
            try? data.write(to: empty)
            if case .success(let r) = await run(Act.toPDF, [empty]) { check("slides: a deck without slides still gives a (blank) PDF", PDFDocument(url: r.outputs[0])?.pageCount == 1) } else { check("slides: empty deck", false) }
        }

        // Text set in a font this Mac does not have is shrunk to stay in its box; text in an installed font keeps
        // following the file, overflow included.
        do {
            func box(_ id: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double, font: String, wrap: String, _ paras: [String], size: Int) -> String {
                let ps = paras.map { "<a:p><a:r><a:rPr sz=\"\(size)\"><a:latin typeface=\"\(font)\"/></a:rPr><a:t>\($0)</a:t></a:r></a:p>" }.joined()
                return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"B\(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm(x, y, w, h))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"\(wrap)\"/><a:lstStyle/>\(ps)</p:txBody></p:sp>"
            }
            let body = box(2, 50, 50, 200, 80, font: "NoSuchFont Gothic", wrap: "square", ["FIT-1", "FIT-2", "FIT-3", "FIT-LAST"], size: 2000)
                + box(3, 300, 50, 200, 80, font: "Arial", wrap: "square", ["KEEP-1", "KEEP-2", "KEEP-3", "KEEP-LAST"], size: 2000)
                + box(4, 50, 300, 150, 30, font: "NoSuchFont Gothic", wrap: "none", ["WIDE-LABEL"], size: 2400)
                + box(5, 300, 300, 200, 30, font: "NoSuchFont Gothic", wrap: "square", ["OVER-1", "OVER-2", "OVER-3", "OVER-LAST"], size: 2000)
            let fitURL = d.appendingPathComponent("fit.pptx")
            try pptxDeck([PptxSlide(body: body, layout: false)]).write(to: fitURL)
            if case .success(let r) = await run(Act.toPDF, [fitURL]), let fd = PDFDocument(url: r.outputs[0]) {
                let last = textBounds(fd, 0, "FIT-LAST"), keep = textBounds(fd, 0, "KEEP-LAST"), wide = textBounds(fd, 0, "WIDE-LABEL")
                check("slides: wrapped text in a substitute font is shrunk into its box (50-130 pt)", (last?.maxY ?? 999) <= 132 && (last?.height ?? 99) < 22, "\(String(describing: last))")
                check("slides: wrapped text in an installed font keeps its size and overflow", (keep?.maxY ?? 0) > 140, "\(String(describing: keep))")
                check("slides: an unwrapped label in a substitute font is scaled to its box width (50-200 pt)", (wide?.maxX ?? 999) <= 202 && (wide?.minX ?? 0) >= 50, "\(String(describing: wide))")
                // Four 20 pt lines in a 30 pt box cannot fit even at 60 %: the overflow is the author's, drawn as is.
                let over = textBounds(fd, 0, "OVER-LAST")
                check("slides: text that cannot fit even at 60 % keeps its full size (20 pt)", (over?.height ?? 0) >= 19 && (over?.maxY ?? 0) > 380, "\(String(describing: over))")
            } else { check("slides: substitute-font fit", false, "conversion failed") }
        } catch { check("slides: substitute-font fit fixture", false, "\(error)") }

        // Speed: the fixture converts in well under a second.
        let t0 = Date()
        _ = await run(Act.toPDF, [url])
        check("slides: conversion time for a small deck < 1 s", Date().timeIntervalSince(t0) < 1, String(format: "%.2fs", Date().timeIntervalSince(t0)))
    }
}
