import Foundation
import AppKit
import PDFKit
import ImageIO
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

/// Checks for the 2026-11-12 PowerPoint audit fixes (PP-02, 03, 06, 09, 10, 11, 16, 17). Every deck is generated here.
extension SelfTest {

    // MARK: Fixture builder

    private static let pptxNS = "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:p14=\"http://schemas.microsoft.com/office/powerpoint/2010/main\""
    private static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    struct PptxSlide {
        var body: String
        var rootAttrs = ""
        var rels = ""          // extra <Relationship> elements
        var notes: String?     // body placeholder text of the notes page
        var layout = true
    }

    /// A minimal deck: one master (body style lvl1/lvl2 bulleted, a body placeholder) and one layout whose placeholder
    /// idx 1 says "no bullet" at level 1 and placeholder idx 2 sets nothing.
    func pptxDeck(_ slides: [PptxSlide], media: [(String, Data)] = []) throws -> Data {
        let ns = SelfTest.pptxNS, rns = SelfTest.relNS
        func rels(_ inner: String) -> String {
            "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(inner)</Relationships>"
        }
        let z = ZipWriter()
        try z.add(path: "[Content_Types].xml", text: "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/></Types>")
        try z.add(path: "_rels/.rels", text: rels("<Relationship Id=\"rId1\" Type=\"\(rns)/officeDocument\" Target=\"ppt/presentation.xml\"/>"))
        let ids = slides.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 1)\"/>" }.joined()
        try z.add(path: "ppt/presentation.xml", text: "<?xml version=\"1.0\"?><p:presentation \(ns)><p:sldIdLst>\(ids)</p:sldIdLst></p:presentation>")
        try z.add(path: "ppt/_rels/presentation.xml.rels", text: rels(slides.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(rns)/slide\" Target=\"slides/slide\($0 + 1).xml\"/>" }.joined()))
        let master = "<?xml version=\"1.0\"?><p:sldMaster \(ns)><p:cSld><p:spTree>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Body\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>"
            + "</p:spTree></p:cSld><p:txStyles><p:titleStyle/><p:bodyStyle><a:lvl1pPr><a:buChar char=\"•\"/></a:lvl1pPr><a:lvl2pPr><a:buChar char=\"–\"/></a:lvl2pPr></p:bodyStyle><p:otherStyle/></p:txStyles></p:sldMaster>"
        try z.add(path: "ppt/slideMasters/slideMaster1.xml", text: master)
        let layout = "<?xml version=\"1.0\"?><p:sldLayout \(ns)><p:cSld><p:spTree>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"NoBullet\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle><a:lvl1pPr><a:buNone/></a:lvl1pPr></a:lstStyle><a:p/></p:txBody></p:sp>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Plain\"/><p:cNvSpPr/><p:nvPr><p:ph idx=\"2\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>"
            + "</p:spTree></p:cSld></p:sldLayout>"
        try z.add(path: "ppt/slideLayouts/slideLayout1.xml", text: layout)
        try z.add(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", text: rels("<Relationship Id=\"rId1\" Type=\"\(rns)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/>"))
        for (i, s) in slides.enumerated() {
            try z.add(path: "ppt/slides/slide\(i + 1).xml", text: "<?xml version=\"1.0\"?><p:sld \(ns) \(s.rootAttrs)><p:cSld><p:spTree>\(s.body)</p:spTree></p:cSld></p:sld>")
            var r = s.rels
            if s.layout { r += "<Relationship Id=\"rIdL\" Type=\"\(rns)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" }
            if let notes = s.notes {
                r += "<Relationship Id=\"rIdN\" Type=\"\(rns)/notesSlide\" Target=\"../notesSlides/notesSlide\(i + 1).xml\"/>"
                try z.add(path: "ppt/notesSlides/notesSlide\(i + 1).xml", text: "<?xml version=\"1.0\"?><p:notes \(ns)><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Notes\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(notes)</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>")
            }
            try z.add(path: "ppt/slides/_rels/slide\(i + 1).xml.rels", text: rels(r))
        }
        for (name, data) in media { try z.add(path: "ppt/media/\(name)", data: data) }
        return try z.finalize()
    }

    func pptxShape(_ paras: String, ph: String = "", lst: String = "", y: Int = 0) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"9\" name=\"S\"/><p:cNvSpPr/><p:nvPr>\(ph)</p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"0\" y=\"\(y)\"/><a:ext cx=\"914400\" cy=\"914400\"/></a:xfrm></p:spPr><p:txBody><a:bodyPr/><a:lstStyle>\(lst)</a:lstStyle>\(paras)</p:txBody></p:sp>"
    }

    func pptxPara(_ text: String, pPr: String = "", rPr: String = "") -> String {
        "<a:p>\(pPr)<a:r>\(rPr)<a:t>\(text)</a:t></a:r></a:p>"
    }

    /// Picture of `wPt` x `hPt` points at `yPt`; `blip`, `srcRect` and `xfrmAttrs` carry the adjustments.
    func pptxPic(_ rid: String, wPt: Int, hPt: Int, yPt: Int, blip: String = "", srcRect: String = "", xfrmAttrs: String = "") -> String {
        "<p:pic><p:nvPicPr><p:cNvPr id=\"7\" name=\"P\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(rid)\">\(blip)</a:blip>\(srcRect)<a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm \(xfrmAttrs)><a:off x=\"0\" y=\"\(yPt * 12700)\"/><a:ext cx=\"\(wPt * 12700)\" cy=\"\(hPt * 12700)\"/></a:xfrm></p:spPr></p:pic>"
    }

    func imageRel(_ rid: String, _ name: String) -> String {
        "<Relationship Id=\"\(rid)\" Type=\"\(SelfTest.relNS)/image\" Target=\"../media/\(name)\"/>"
    }

    /// 400 x 100 pixels: four vertical stripes A–D = red, green, blue, yellow from left to right.
    func stripesImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, c) in [(1.0, 0.0, 0.0), (0.0, 0.8, 0.0), (0.0, 0.0, 1.0), (1.0, 0.85, 0.0)].enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: i * 100, y: 0, width: 100, height: 100))
        }
        return ctx.makeImage()!
    }

    /// A transparent 40 x 10 image with one opaque stroke of the given colour across the middle.
    func strokeImage(_ r: Double, _ g: Double, _ b: Double) -> Data {
        let ctx = CGContext(data: nil, width: 40, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 40, height: 10))
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 2, y: 4, width: 36, height: 3))
        return ImageCodec.encode(ctx.makeImage()!, as: .png)!
    }

    func cgImage(_ img: DocImage) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(img.data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func images(_ m: DocModel) -> [DocImage] { m.blocks.compactMap { if case .image(let i) = $0 { return i }; return nil } }

    // MARK: Tests

    func testAuditPptx() async {
        let d = fresh("audit-pptx")

        // PP-02 / PP-17: a slide hidden on its root (as PowerPoint writes it) is left out of every output; a slide
        // that yields nothing leaves no doubled rule.
        do {
            let deck = try pptxDeck([
                PptxSlide(body: pptxShape(pptxPara("VISIBLE-ONE"))),
                PptxSlide(body: pptxShape(pptxPara("HIDDEN-SLIDE-TEXT")), rootAttrs: "show=\"0\""),
                PptxSlide(body: pptxShape("<a:p/>")),
                PptxSlide(body: pptxShape(pptxPara("VISIBLE-TWO"))),
            ])
            let model = try PptxReader.read(data: deck)
            check("pptx: hidden slide (<p:sld show=\"0\">) is left out", !model.plainText.contains("HIDDEN") && model.plainText.contains("VISIBLE-TWO"), model.plainText)
            let rules = model.blocks.filter { $0 == .horizontalRule }.count
            check("pptx: an empty slide leaves no doubled rule", rules == 1, "\(rules) rules")
            let url = d.appendingPathComponent("hidden.pptx")
            try deck.write(to: url)
            for action in [Act.toMD, Act.toTXT, Act.toDOCX, Act.toPDF, Act.toHTML] {
                switch await run(action, [url]) {
                case .success(let r):
                    let out = r.outputs[0]
                    let text: String
                    switch out.pathExtension {
                    case "pdf": text = pdfText(out).filter { !$0.isWhitespace }   // slides wrap text inside their boxes
                    case "docx": text = textutil(out)
                    default: text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
                    }
                    check("pptx → \(out.pathExtension): no hidden slide text", text.contains("VISIBLE-TWO") && !text.contains("HIDDEN"), String(text.prefix(200)))
                case .failure(let e): check("pptx → \(action): no hidden slide text", false, errText(e))
                }
            }
            switch await run(Act.copyText, [url]) {
            case .success(let r): check("pptx copy text: no hidden slide text", (r.clipboardText ?? "").contains("VISIBLE-ONE") && !(r.clipboardText ?? "").contains("HIDDEN"))
            case .failure(let e): check("pptx copy text: no hidden slide text", false, errText(e))
            }
        } catch { check("pptx hidden-slide fixture", false, "\(error)") }

        // PP-03: text colours too pale for a white page are replaced; readable ones are kept.
        do {
            func run(_ text: String, _ hex: String, highlight: String = "") -> String {
                let hl = highlight.isEmpty ? "" : "<a:highlight><a:srgbClr val=\"\(highlight)\"/></a:highlight>"
                return "<a:r><a:rPr><a:solidFill><a:srgbClr val=\"\(hex)\"/></a:solidFill>\(hl)</a:rPr><a:t>\(text)</a:t></a:r>"
            }
            let paras = ["WHITE|FFFFFF", "PALEGREY|F2F2F2", "RED|FF0000", "YELLOW|FFFF00", "NAVY|002060", "DARKRED|C00000"]
                .map { s -> String in let p = s.split(separator: "|"); return "<a:p>\(run(String(p[0]), String(p[1])))</a:p>" }.joined()
                + "<a:p>\(run("HILITE", "FFFFFF", highlight: "000000"))</a:p>"
            let deck = try pptxDeck([PptxSlide(body: pptxShape(paras))])
            let model = try PptxReader.read(data: deck)
            var colors: [String: DocColor?] = [:]
            for b in model.blocks { if case .paragraph(let p) = b { for r in p.runs { colors[r.text] = r.color } } }
            check("pptx: white text gets the default (dark) colour", colors["WHITE"].map { $0 == nil } == true, "\(String(describing: colors["WHITE"]))")
            check("pptx: pale grey text gets the default colour", colors["PALEGREY"].map { $0 == nil } == true)
            check("pptx: red, navy and dark red text keep their colour",
                  colors["RED"]??.hex == "FF0000" && colors["NAVY"]??.hex == "002060" && colors["DARKRED"]??.hex == "C00000")
            if let y = colors["YELLOW"] ?? nil {
                let ratio = PptxReaderContrast.onWhite(y)
                check("pptx: yellow text is darkened to ≥ 3:1 and stays yellow", ratio >= 3 && ratio < 3.3 && abs(y.r - y.g) < 0.01 && y.b == 0, "\(y.hex) \(ratio)")
            } else { check("pptx: yellow text is darkened to ≥ 3:1 and stays yellow", false, "no colour") }
            check("pptx: highlighted white text keeps its pairing", colors["HILITE"]??.hex == "FFFFFF")
            let url = d.appendingPathComponent("colours.pptx")
            try deck.write(to: url)
            if case .success(let r) = await self.run(Act.toDOCX, [url]), let z = try? ZipReader(url: r.outputs[0]), let xml = try? z.data("word/document.xml") {
                let s = String(decoding: xml, as: UTF8.self)
                check("pptx → docx: no white text runs (HILITE excepted)", s.components(separatedBy: "w:val=\"FFFFFF\"").count - 1 <= 1 && s.contains("FF0000"))
            } else { check("pptx → docx: no white text runs", false) }
        } catch { check("pptx colour fixture", false, "\(error)") }

        // PP-09: crop, rotation, flip and transparency.
        do {
            let stripes = stripesImage()
            let png = ImageCodec.encode(stripes, as: .png)!, jpg = ImageCodec.encode(stripes, as: .jpeg, quality: 0.95)!
            let body = [
                pptxPic("rIdA", wPt: 200, hPt: 50, yPt: 0),
                pptxPic("rIdA", wPt: 50, hPt: 50, yPt: 100, srcRect: "<a:srcRect l=\"50000\" r=\"25000\"/>"),
                pptxPic("rIdA", wPt: 200, hPt: 50, yPt: 200, xfrmAttrs: "rot=\"5400000\""),
                pptxPic("rIdA", wPt: 200, hPt: 50, yPt: 300, xfrmAttrs: "flipH=\"1\""),
                pptxPic("rIdA", wPt: 200, hPt: 50, yPt: 400, blip: "<a:alphaModFix amt=\"30000\"/>"),
                pptxPic("rIdJ", wPt: 100, hPt: 50, yPt: 500, srcRect: "<a:srcRect r=\"50000\"/>"),
            ].joined()
            let deck = try pptxDeck([PptxSlide(body: body, rels: imageRel("rIdA", "a.png") + imageRel("rIdJ", "j.jpeg"))],
                                    media: [("a.png", png), ("j.jpeg", jpg)])
            let imgs = images(try PptxReader.read(data: deck))
            if imgs.count == 6, let crop = cgImage(imgs[1]), let rot = cgImage(imgs[2]), let flip = cgImage(imgs[3]), let fade = cgImage(imgs[4]) {
                check("pptx picture without adjustments passes through untouched", imgs[0].data == png)
                let l = pixel(crop, x: 5, yFromTop: crop.height / 2), r = pixel(crop, x: crop.width - 5, yFromTop: crop.height / 2)
                check("pptx picture crop shows only the cropped part (C, blue)", l.b > 200 && l.r < 50 && r.b > 200 && r.r < 50 && crop.width == crop.height, "\(l) \(r) \(crop.width)x\(crop.height)")
                let top = pixel(rot, x: rot.width / 2, yFromTop: 5), bottom = pixel(rot, x: rot.width / 2, yFromTop: rot.height - 5)
                check("pptx picture rotated 90° clockwise (A on top, D at the bottom, frame turned)",
                      top.r > 200 && top.g < 50 && bottom.r > 200 && bottom.g > 150 && abs(imgs[2].displayWidth - 50) < 1 && abs(imgs[2].displayHeight - 200) < 1,
                      "\(top) \(bottom) \(imgs[2].displayWidth)x\(imgs[2].displayHeight)")
                let fl = pixel(flip, x: 5, yFromTop: 50), fr = pixel(flip, x: flip.width - 5, yFromTop: 50)
                check("pptx picture flipped horizontally (D left, A right)", fl.r > 200 && fl.g > 150 && fr.r > 200 && fr.g < 50, "\(fl) \(fr)")
                let fa = pixel(fade, x: 50, yFromTop: 50)
                check("pptx picture transparency (alphaModFix 30%) is applied", abs(fa.a - 77) <= 3, "\(fa)")
                check("pptx cropped JPEG stays JPEG at the cropped size", imgs[5].format == .jpeg && imgs[5].pixelWidth == 200 && imgs[5].pixelHeight == 100,
                      "\(imgs[5].format) \(imgs[5].pixelWidth)x\(imgs[5].pixelHeight)")
            } else { check("pptx picture adjustments", false, "\(imgs.count) images") }
        } catch { check("pptx picture fixture", false, "\(error)") }

        // PP-06: ink (p:contentPart) falls back to its picture; white ink is drawn dark so it shows on a white page.
        do {
            let white = strokeImage(1, 1, 1), yellow = strokeImage(1, 0.98, 0)
            func ink(_ rid: String, y: Int) -> String {
                "<mc:AlternateContent><mc:Choice Requires=\"p14\"><p:contentPart p14:bwMode=\"auto\" r:id=\"rIdK\"/></mc:Choice><mc:Fallback>\(pptxPic(rid, wPt: 40, hPt: 10, yPt: y))</mc:Fallback></mc:AlternateContent>"
            }
            let choiceText = "<mc:AlternateContent><mc:Choice Requires=\"p14\">\(pptxShape(pptxPara("CHOICE-TEXT"), y: 2_000_000))</mc:Choice><mc:Fallback>\(pptxShape(pptxPara("CHOICE-TEXT"), y: 2_000_000))</mc:Fallback></mc:AlternateContent>"
            let deck = try pptxDeck([PptxSlide(body: ink("rIdW", y: 0) + ink("rIdY", y: 50) + choiceText,
                                               rels: imageRel("rIdW", "w.png") + imageRel("rIdY", "y.png"))],
                                    media: [("w.png", white), ("y.png", yellow)])
            let model = try PptxReader.read(data: deck)
            let imgs = images(model)
            check("pptx ink: the fallback pictures are used", imgs.count == 2, "\(imgs.count) images")
            if imgs.count == 2, let w = cgImage(imgs[0]) {
                let p = pixel(w, x: w.width / 2, yFromTop: w.height / 2)
                check("pptx ink: white strokes are drawn dark", p.a > 200 && p.r < 30 && p.g < 30 && p.b < 30, "\(p)")
                check("pptx ink: coloured strokes pass through untouched", imgs[1].data == yellow)
            }
            check("pptx: a usable mc:Choice is read once, not also its fallback", model.plainText.components(separatedBy: "CHOICE-TEXT").count == 2)
        } catch { check("pptx ink fixture", false, "\(error)") }

        // PP-11: bullets follow paragraph → shape list style → layout → master placeholder → master body style.
        do {
            let ph1 = "<p:ph type=\"body\" idx=\"1\"/>", ph2 = "<p:ph idx=\"2\"/>"
            let body = pptxShape(pptxPara("NOBULLET") + pptxPara("SUBBULLET", pPr: "<a:pPr lvl=\"1\"/>") + pptxPara("EXPLICIT", pPr: "<a:pPr><a:buChar char=\"•\"/></a:pPr>"), ph: ph1, y: 0)
                + pptxShape(pptxPara("MASTERBULLET"), ph: ph2, y: 1_000_000)
                + pptxShape(pptxPara("OWNBULLET"), lst: "<a:lvl1pPr><a:buChar char=\"•\"/></a:lvl1pPr>", y: 2_000_000)
                + pptxShape(pptxPara("PLAINBOX"), y: 3_000_000)
                + pptxShape(pptxPara("NUMBERED", pPr: "<a:pPr><a:buAutoNum type=\"arabicPeriod\"/></a:pPr>"), ph: ph1, y: 4_000_000)
            let noLayout = pptxShape(pptxPara("NOLAYOUT"), ph: ph1)
            let deck = try pptxDeck([PptxSlide(body: body), PptxSlide(body: noLayout, layout: false)])
            let model = try PptxReader.read(data: deck)
            var kind: [String: String] = [:]
            for b in model.blocks {
                switch b {
                case .listItem(let li): kind[li.paragraph.plainText] = li.ordered ? "num\(li.level)" : "bullet\(li.level)"
                case .paragraph(let p): kind[p.plainText] = "para"
                default: break
                }
            }
            check("pptx bullets: layout buNone wins over the master bullet", kind["NOBULLET"] == "para", kind["NOBULLET"] ?? "missing")
            check("pptx bullets: a level the layout does not set uses the master body style", kind["SUBBULLET"] == "bullet1", kind["SUBBULLET"] ?? "missing")
            check("pptx bullets: an explicit bullet on the paragraph wins", kind["EXPLICIT"] == "bullet0")
            check("pptx bullets: placeholder without layout bullet inherits the master's", kind["MASTERBULLET"] == "bullet0", kind["MASTERBULLET"] ?? "missing")
            check("pptx bullets: a text box's own list style bullet is shown", kind["OWNBULLET"] == "bullet0")
            check("pptx bullets: a plain text box has none", kind["PLAINBOX"] == "para")
            check("pptx bullets: numbering is kept", kind["NUMBERED"] == "num0")
            check("pptx bullets: without a master, body placeholders stay bulleted as before", kind["NOLAYOUT"] == "bullet0", kind["NOLAYOUT"] ?? "missing")
        } catch { check("pptx bullet fixture", false, "\(error)") }

        // PP-10: tables with source column widths keep their proportions in PDF; others are laid out as before.
        do {
            func cells(_ s: [String]) -> [DocTableCell] { s.map { DocTableCell(text: $0) } }
            let rows = [cells(["AAA", "BBB", "CCC", "DDD"]), cells(["a", "b", "c", "d"])]
            let wide = DocModel(title: nil, blocks: [.table(DocTable(rows: rows, headerRows: 1, columnWidths: [6, 2, 2, 2]))])
            let plain = DocModel(title: nil, blocks: [.table(DocTable(rows: rows, headerRows: 1))])
            func x(of text: String, in model: DocModel) -> CGFloat? {
                guard let doc = PDFDocument(data: PDFRenderer.pdfData(from: model)), let page = doc.page(at: 0),
                      let sel = doc.findString(text, withOptions: []).first else { return nil }
                return sel.bounds(for: page).minX
            }
            // A4 content: 60 ... 535 pt. With 6:2:2:2 the second column starts near the middle; evenly near a quarter.
            if let bw = x(of: "BBB", in: wide), let dw = x(of: "DDD", in: wide), let bp = x(of: "BBB", in: plain) {
                check("pdf table uses the source's relative column widths", bw > 280 && bw < 320 && dw > 440, "BBB at \(bw), DDD at \(dw)")
                check("pdf table without widths is laid out as before", bp > 160 && bp < 200, "BBB at \(bp)")
            } else { check("pdf table column widths", false, "text not found") }
            let attr = AttributedConverter.attributedString(from: plain)
            let ps = attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let block = ps?.textBlocks.first as? NSTextTableBlock
            check("table without widths keeps automatic layout and no cell widths",
                  block?.table.layoutAlgorithm == .automaticLayoutAlgorithm && block?.value(for: .width) == 0)
        }

        // PP-16: speaker notes, when asked for, follow each slide as quotes with a label.
        do {
            let deck = try pptxDeck([PptxSlide(body: pptxShape(pptxPara("SLIDE-TEXT")), notes: "NOTE-TEXT")])
            let without = try PptxReader.read(data: deck)
            let with = try PptxReader.read(data: deck, includeNotes: true, notesLabel: "ノート")
            check("pptx notes are not read by default", !without.plainText.contains("NOTE-TEXT"))
            if case .quote(let q)? = with.blocks.last {
                check("pptx notes: a labelled quote after the slide", q.runs.first?.text == "ノート: " && q.runs.first?.bold == true && q.plainText.hasSuffix("NOTE-TEXT"), q.plainText)
                let md = MarkdownWriter.string(from: with).text
                check("pptx notes in Markdown: a blockquote with the label", md.contains("> **ノート:** NOTE-TEXT"), md)
            } else { check("pptx notes: a labelled quote after the slide", false, "\(with.blocks)") }
        } catch { check("pptx notes fixture", false, "\(error)") }
    }
}

/// The WCAG contrast formula, for checking the reader's colour choice independently of its implementation.
enum PptxReaderContrast {
    static func onWhite(_ c: DocColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 1.05 / (0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) + 0.05)
    }
}
