import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

/// Checks for the 2026-11-12 Word / HTML / Markdown / text audit fixes (WD-01…10, 12, 13, 15, 16, 20, 21, 22, 28,
/// and quotes in Dark Mode).
/// Every document is generated here. The checks go through the engine's actions and public readers and writers only,
/// so the same file also builds against the unfixed source, where each of them fails.
extension SelfTest {

    // MARK: Fixtures

    private static let wordNS = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\""

    struct WordParts {
        var body: String
        var numbering: String?
        var footnotes: String?
        var endnotes: String?
        var footnoteRels = ""
        var media: [(String, Data)] = []
        var styles: String?
    }

    /// A minimal .docx: document, optional numbering / footnotes / endnotes parts, pictures as rIdImg1….
    func wordDocx(_ p: WordParts) throws -> Data {
        let ns = SelfTest.wordNS, rns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        func rels(_ inner: String) -> String {
            "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(inner)</Relationships>"
        }
        let z = ZipWriter()
        try z.add(path: "[Content_Types].xml", text: "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>")
        try z.add(path: "_rels/.rels", text: rels("<Relationship Id=\"rId1\" Type=\"\(rns)/officeDocument\" Target=\"word/document.xml\"/>"))
        try z.add(path: "word/document.xml", text: "<?xml version=\"1.0\"?><w:document \(ns)><w:body>\(p.body)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/></w:sectPr></w:body></w:document>")
        var r = ""
        if let n = p.numbering {
            r += "<Relationship Id=\"rIdN\" Type=\"\(rns)/numbering\" Target=\"numbering.xml\"/>"
            try z.add(path: "word/numbering.xml", text: "<?xml version=\"1.0\"?><w:numbering \(ns)>\(n)</w:numbering>")
        }
        if let f = p.footnotes {
            r += "<Relationship Id=\"rIdF\" Type=\"\(rns)/footnotes\" Target=\"footnotes.xml\"/>"
            try z.add(path: "word/footnotes.xml", text: "<?xml version=\"1.0\"?><w:footnotes \(ns)><w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>\(f)</w:footnotes>")
            if !p.footnoteRels.isEmpty { try z.add(path: "word/_rels/footnotes.xml.rels", text: rels(p.footnoteRels)) }
        }
        if let e = p.endnotes {
            r += "<Relationship Id=\"rIdE\" Type=\"\(rns)/endnotes\" Target=\"endnotes.xml\"/>"
            try z.add(path: "word/endnotes.xml", text: "<?xml version=\"1.0\"?><w:endnotes \(ns)><w:endnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:endnote>\(e)</w:endnotes>")
        }
        if let st = p.styles {
            r += "<Relationship Id=\"rIdS\" Type=\"\(rns)/styles\" Target=\"styles.xml\"/>"
            try z.add(path: "word/styles.xml", text: "<?xml version=\"1.0\"?><w:styles \(ns)>\(st)</w:styles>")
        }
        for (i, m) in p.media.enumerated() {
            r += "<Relationship Id=\"rIdImg\(i + 1)\" Type=\"\(rns)/image\" Target=\"media/\(m.0)\"/>"
            try z.add(path: "word/media/\(m.0)", data: m.1)
        }
        try z.add(path: "word/_rels/document.xml.rels", text: rels(r))
        return try z.finalize()
    }

    func wP(_ inner: String, pPr: String = "") -> String { "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + inner + "</w:p>" }
    func wR(_ text: String, rPr: String = "") -> String {
        "<w:r>" + (rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>") + "<w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
    }
    func wDrawing(_ rid: String, descr: String = "") -> String {
        "<w:r><w:drawing><wp:inline><wp:extent cx=\"381000\" cy=\"381000\"/><wp:docPr id=\"1\" name=\"P\" descr=\"\(descr)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"1\" name=\"p.png\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(rid)\"/></pic:blipFill><pic:spPr/></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    func pngData(_ image: CGImage) -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Runs `action` on `file`; the first output, read as text (PDF: its text; .docx: word/document.xml).
    func outputText(_ action: String, _ file: URL) async -> (url: URL?, text: String) {
        guard case .success(let r) = await run(action, [file]), let u = r.outputs.first else { return (nil, "") }
        switch u.pathExtension.lowercased() {
        case "pdf": return (u, PDFDocument(url: u)?.string ?? "")
        case "docx": return (u, docxPart(u, "word/document.xml"))
        default: return (u, (try? String(contentsOf: u, encoding: .utf8)) ?? "")
        }
    }

    func docxPart(_ url: URL, _ part: String) -> String {
        guard let z = try? ZipReader(url: url), let d = try? z.data(part) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    func write(_ data: Data, _ name: String, in dir: URL) -> URL {
        let u = dir.appendingPathComponent(name)
        try? data.write(to: u)
        return u
    }

    // MARK: Checks

    func testAuditWord() async {
        await auditWordRuby()
        await auditWordScripts()
        await auditWordSymbols()
        await auditWordNotes()
        await auditWordMath()
        await auditWordCellImages()
        await auditWordLists()
        await auditWordRowSpan()
        await auditWordIframe()
        await auditWordPageBreaks()
        await auditWordMarkdownHTML()
        await auditWordFrontMatter()
        await auditWordEncodings()
        await auditWordFonts()
        await auditWordGFM()
        auditWordPaperColors()
    }

    /// The BaseFont names of the fonts a PDF's pages use.
    func pdfFontNames(_ url: URL) -> Set<String> {
        var names = Set<String>()
        guard let doc = CGPDFDocument(url as CFURL) else { return names }
        for i in 1...max(doc.numberOfPages, 1) {
            guard let page = doc.page(at: i), let dict = page.dictionary else { continue }
            var res: CGPDFDictionaryRef?, fonts: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res, CGPDFDictionaryGetDictionary(res, "Font", &fonts), let fonts else { continue }
            CGPDFDictionaryApplyBlock(fonts, { _, obj, _ in
                var fd: CGPDFDictionaryRef?
                var name: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(obj, .dictionary, &fd), let fd, CGPDFDictionaryGetName(fd, "BaseFont", &name), let name {
                    names.insert(String(cString: name))
                }
                return true
            }, nil)
        }
        return names
    }

    // WD-13: a Century + ＭＳ 明朝 document prints in Mincho (the editor's stand-in), not in Gothic.
    func auditWordFonts() async {
        let d = fresh("audit-word-fonts")
        let styles = "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Century\" w:eastAsia=\"ＭＳ 明朝\" w:hAnsi=\"Century\"/><w:sz w:val=\"21\"/></w:rPr></w:rPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style>"
        let body = wP(wR("明朝の本文です。Century text.")) + wP(wR("太字の見出し", rPr: "<w:b/>"))
        guard let data = try? wordDocx(WordParts(body: body, styles: styles)) else { check("fonts fixture", false); return }
        if let u = await outputText(Act.toPDF, write(data, "mincho.docx", in: d)).url {
            let fonts = pdfFontNames(u)
            let japanese = fonts.filter { $0.contains("HiraMin") || $0.contains("YuMin") || $0.contains("HiraginoSans") || $0.contains("YuGo") }
            check("WD-13 fonts: Century + ＭＳ 明朝 prints Japanese in Mincho", !japanese.isEmpty && japanese.allSatisfy { $0.contains("Min") }, "\(fonts)")
            check("WD-13 fonts: bold Japanese stays bold in Mincho", fonts.contains { $0.contains("HiraMinProN-W6") || $0.contains("YuMin-Demibold") }, "\(fonts)")
            check("WD-13 fonts: Century prints in a serif stand-in", fonts.contains { $0.contains("Times") }, "\(fonts)")
        } else { check("WD-13 fonts: Century + ＭＳ 明朝 prints Japanese in Mincho", false, "no PDF") }
    }

    // WD-22 / WD-21 / WD-28: GFM task lists, footnotes and column alignment; links styled in PDF.
    func auditWordGFM() async {
        let d = fresh("audit-word-gfm")
        let md = """
        - [x] 完了 DONE-TASK
        - [ ] 未完了 TODO-TASK

        本文に脚注[^n1] FOOTNOTE-REF と [リンク](https://example.com/x)。

        | 左 | 中央 | 右 |
        |:---|:----:|---:|
        | L | C-CELL | R-CELL |

        [^n1]: 脚注の本文 FOOTNOTE-TEXT。

        """
        let m = write(Data(md.utf8), "gfm.md", in: d)
        let txt = await outputText(Act.toTXT, m).text
        check("WD-22 GFM: task items show ☑ / ☐", txt.contains("☑ 完了 DONE-TASK") && txt.contains("☐ 未完了 TODO-TASK") && !txt.contains("[x]"), txt)
        check("WD-22 GFM: footnotes become notes", txt.contains("本文に脚注[1] FOOTNOTE-REF") && txt.contains("[1] 脚注の本文 FOOTNOTE-TEXT。") && !txt.contains("[^n1]"), txt)
        // Markdown to Markdown is not an action; the reader and writer directly.
        let back = MarkdownWriter.string(from: MarkdownReader.model(from: md)).text
        check("WD-22 GFM: Markdown round trip keeps tasks and footnotes",
              back.contains("- [x] 完了 DONE-TASK") && back.contains("- [ ] 未完了 TODO-TASK") && back.contains("脚注[^1]") && back.contains("[^1]: 脚注の本文 FOOTNOTE-TEXT。"), back)
        check("WD-21 GFM: Markdown round trip keeps column alignment", back.contains("| --- | :---: | ---: |"), back)
        let docx = await outputText(Act.toDOCX, m).text
        check("WD-21 GFM: Word cells keep centre / right alignment",
              docx.range(of: #"<w:jc w:val="center"/></w:pPr><w:r>(<w:rPr>(?:(?!</w:rPr>).)*</w:rPr>)?<w:t xml:space="preserve">C-CELL"#, options: .regularExpression) != nil
              && docx.range(of: #"<w:jc w:val="right"/></w:pPr><w:r>(<w:rPr>(?:(?!</w:rPr>).)*</w:rPr>)?<w:t xml:space="preserve">R-CELL"#, options: .regularExpression) != nil, docx)
        let html = await outputText(Act.toHTML, m).text
        check("WD-21 GFM: HTML cells keep alignment", html.contains("<td style=\"text-align:center\">C-CELL</td>") && html.contains("<td style=\"text-align:right\">R-CELL</td>"), html)
        let model = MarkdownReader.model(from: md)
        let attr = AttributedConverter.attributedString(from: model)
        let ns = attr.string as NSString
        let c = ns.range(of: "C-CELL")
        let ps = c.location == NSNotFound ? nil : attr.attribute(.paragraphStyle, at: c.location, effectiveRange: nil) as? NSParagraphStyle
        check("WD-21 GFM: PDF table cells keep alignment", ps?.alignment == .center, "\(String(describing: ps?.alignment.rawValue))")
        let l = ns.range(of: "リンク")
        let color = l.location == NSNotFound ? nil : (attr.attribute(.foregroundColor, at: l.location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        let underline = l.location == NSNotFound ? nil : attr.attribute(.underlineStyle, at: l.location, effectiveRange: nil) as? Int
        check("WD-28 links: PDF draws links blue and underlined", color.map { $0.blueComponent > 0.6 && $0.redComponent < 0.2 } == true && underline == NSUnderlineStyle.single.rawValue,
              "\(String(describing: color)) \(String(describing: underline))")
    }

    // Quotes are drawn in a fixed grey: a dynamic system colour turned them near-white on the white page in Dark Mode.
    func auditWordPaperColors() {
        let attr = AttributedConverter.attributedString(from: DocModel(blocks: [.quote(DocParagraph(text: "QUOTE-TEXT"))]))
        var luminance: CGFloat = 1
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            if let c = (attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB) {
                luminance = (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) * c.alphaComponent + (1 - c.alphaComponent)
            }
        }
        check("quotes stay readable on the white page in Dark Mode", luminance < 0.6, "luminance \(luminance)")
    }

    // WD-02: ruby inside a run keeps its base text everywhere; the reading is ruby in HTML / Word, (…) elsewhere.
    func auditWordRuby() async {
        let d = fresh("audit-word-ruby")
        let ruby = "<w:r><w:ruby><w:rubyPr><w:rubyAlign w:val=\"distributeSpace\"/><w:hps w:val=\"10\"/><w:hpsRaise w:val=\"18\"/><w:hpsBaseText w:val=\"21\"/><w:lid w:val=\"ja-JP\"/></w:rubyPr><w:rt><w:r><w:t>かんじ</w:t></w:r></w:rt><w:rubyBase><w:r><w:t>漢字</w:t></w:r></w:rubyBase></w:ruby></w:r>"
        guard let data = try? wordDocx(WordParts(body: wP(wR("ルビ: ") + ruby + wR(" の後ろ")))) else { check("ruby fixture", false); return }
        let f = write(data, "ruby.docx", in: d)
        let txt = await outputText(Act.toTXT, f).text
        check("WD-02 ruby: text keeps the base and the reading in parentheses", txt.contains("ルビ: 漢字（かんじ） の後ろ"), txt)
        let md = await outputText(Act.toMD, f).text
        check("WD-02 ruby: Markdown keeps base（reading）", md.contains("漢字（かんじ）"), md)
        let html = await outputText(Act.toHTML, f).text
        check("WD-02 ruby: HTML has real <ruby>", html.contains("<ruby>漢字<rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby>"), String(html.suffix(400)))
        let pdf = await outputText(Act.toPDF, f).text
        check("WD-02 ruby: PDF shows the base text", pdf.contains("漢字"), pdf)
        let docx = await outputText(Act.toDOCX, f).text
        check("WD-02 ruby: Word output keeps w:ruby with base and reading",
              docx.contains("<w:rubyBase>") && docx.contains("漢字") && docx.contains("<w:rt>") && docx.contains("かんじ"))
        // HTML input <ruby> follows the same rule.
        let h = write(Data("<p><ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>です</p>".utf8), "ruby.html", in: d)
        let htxt = await outputText(Act.toTXT, h).text
        check("WD-02 ruby: HTML <ruby> input reads as base（reading）", htxt.contains("漢字（かんじ）です"), htxt)
    }

    // WD-03: superscript / subscript survive from docx and HTML into every target.
    func auditWordScripts() async {
        let d = fresh("audit-word-scripts")
        let sup = "<w:vertAlign w:val=\"superscript\"/>", sub = "<w:vertAlign w:val=\"subscript\"/>"
        let body = wP(wR("H") + wR("2", rPr: sub) + wR("O と E=mc") + wR("2", rPr: sup) + wR(" と 10") + wR("5", rPr: sup) + wR(" 円、4") + wR("th", rPr: sup))
        guard let data = try? wordDocx(WordParts(body: body)) else { check("scripts fixture", false); return }
        let f = write(data, "scripts.docx", in: d)
        let txt = await outputText(Act.toTXT, f).text
        check("WD-03 scripts: text uses Unicode super/subscripts", txt.contains("H₂O と E=mc² と 10⁵ 円"), txt)
        check("WD-03 scripts: text marks scripts without a Unicode form", txt.contains("4^(th)"), txt)
        if case .success(let r) = await run(Act.copyText, [f]) {
            check("WD-03 scripts: copy text keeps 10⁵", r.clipboardText?.contains("10⁵") == true, r.clipboardText ?? "")
        } else { check("WD-03 scripts: copy text keeps 10⁵", false, "copy failed") }
        let md = await outputText(Act.toMD, f).text
        check("WD-03 scripts: Markdown writes <sup>/<sub>", md.contains("E=mc<sup>2</sup>") && md.contains("H<sub>2</sub>O"), md)
        let html = await outputText(Act.toHTML, f).text
        check("WD-03 scripts: HTML writes <sup>/<sub>", html.contains("mc<sup>2</sup>") && html.contains("H<sub>2</sub>O"))
        let docx = await outputText(Act.toDOCX, f).text
        check("WD-03 scripts: Word output keeps w:vertAlign",
              docx.contains("<w:vertAlign w:val=\"superscript\"/>") && docx.contains("<w:vertAlign w:val=\"subscript\"/>"))
        let rtf = await outputText(Act.toRTF, f).text
        check("WD-03 scripts: RTF writes \\super and \\sub", rtf.contains("\\super") && rtf.contains("\\sub"), rtf)
        // PDF: the "2" of mc2 is drawn as a superscript (smaller, raised).
        if let model = try? DocxReader.read(data: data) {
            let attr = AttributedConverter.attributedString(from: model)
            let r = (attr.string as NSString).range(of: "mc2")
            let v = r.location == NSNotFound ? nil : attr.attribute(.superscript, at: r.location + 2, effectiveRange: nil) as? Int
            check("WD-03 scripts: PDF/RTF layout raises the superscript", v == 1, "\(String(describing: v))")
        } else { check("WD-03 scripts: PDF/RTF layout raises the superscript", false, "read failed") }
        // HTML and Markdown input.
        let h = write(Data("<p>H<sub>2</sub>O x<sup>2</sup></p>".utf8), "scripts.html", in: d)
        let htxt = await outputText(Act.toTXT, h).text
        check("WD-03 scripts: HTML <sup>/<sub> input survives to text", htxt.contains("H₂O x²"), htxt)
        let m = write(Data("E=mc<sup>2</sup> and H<sub>2</sub>O\n".utf8), "scripts.md", in: d)
        let mtxt = await outputText(Act.toTXT, m).text
        check("WD-03 scripts: Markdown <sup>/<sub> input survives to text", mtxt.contains("E=mc² and H₂O"), mtxt)
    }

    // WD-10: w:sym and text in symbol fonts become their Unicode characters; unknown codes a visible placeholder.
    func auditWordSymbols() async {
        let d = fresh("audit-word-symbols")
        func sym(_ font: String, _ char: String) -> String { "<w:r><w:sym w:font=\"\(font)\" w:char=\"\(char)\"/></w:r>" }
        let body = wP(wR("A:") + sym("Wingdings", "F0FC") + wR(" B:") + sym("Wingdings 2", "F052") + wR(" C:") + sym("Symbol", "F061")
                      + wR(" D:") + sym("Wingdings", "F0A8") + wR(" E:") + sym("Wingdings", "F0B0") + wR(" F:") + sym("Segoe UI Symbol", "2713")
                      + wR(" G:") + wR("ü", rPr: "<w:rFonts w:ascii=\"Wingdings\" w:hAnsi=\"Wingdings\"/>") + wR(" END"))
        guard let data = try? wordDocx(WordParts(body: body)) else { check("symbols fixture", false); return }
        let f = write(data, "symbols.docx", in: d)
        let txt = await outputText(Act.toTXT, f).text
        check("WD-10 symbols: Wingdings check mark", txt.contains("A:✓"), txt)
        check("WD-10 symbols: Wingdings 2 checked box", txt.contains("B:☑"), txt)
        check("WD-10 symbols: Symbol alpha", txt.contains("C:α"), txt)
        check("WD-10 symbols: Wingdings empty box", txt.contains("D:◻"), txt)
        check("WD-10 symbols: unknown code shows a placeholder", txt.contains("E:\u{FFFD}"), txt)
        check("WD-10 symbols: a Unicode code in another font is kept", txt.contains("F:✓"), txt)
        check("WD-10 symbols: text set in Wingdings is mapped", txt.contains("G:✓"), txt)
        let pdf = await outputText(Act.toPDF, f).text
        check("WD-10 symbols: PDF shows the check mark", pdf.contains("✓"), pdf)
    }

    // WD-01: footnotes and endnotes keep their marks and text in every target.
    func auditWordNotes() async {
        let d = fresh("audit-word-notes")
        let fref = "<w:vertAlign w:val=\"superscript\"/>"
        func note(_ tag: String, _ id: Int, _ text: String) -> String {
            "<w:\(tag) w:id=\"\(id)\"><w:p><w:r><w:rPr>\(fref)</w:rPr><w:\(tag)Ref/></w:r>\(wR(" " + text))</w:p></w:\(tag)>"
        }
        let link = "<w:hyperlink r:id=\"rIdL\"><w:r><w:t>出典リンク</w:t></w:r></w:hyperlink>"
        let fn = note("footnote", 1, "注一本文 NOTE-ONE")
            + "<w:footnote w:id=\"2\"><w:p><w:r><w:rPr>\(fref)</w:rPr><w:footnoteRef/></w:r>\(wR(" 注二 NOTE-TWO "))\(link)</w:p></w:footnote>"
        let en = note("endnote", 1, "後注本文 ENDNOTE-ONE")
        let body = wP(wR("本文") + "<w:r><w:rPr>\(fref)</w:rPr><w:footnoteReference w:id=\"1\"/></w:r>" + wR("と続き")
                      + "<w:r><w:rPr>\(fref)</w:rPr><w:footnoteReference w:id=\"2\"/></w:r>" + wR("、後注")
                      + "<w:r><w:rPr>\(fref)</w:rPr><w:endnoteReference w:id=\"1\"/></w:r>" + wR("。"))
            + wP(wR("二段落目 SECOND-PARA"))
        let parts = WordParts(body: body, footnotes: fn, endnotes: en,
                              footnoteRels: "<Relationship Id=\"rIdL\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"https://example.com/source\" TargetMode=\"External\"/>")
        guard let data = try? wordDocx(parts) else { check("notes fixture", false); return }
        let f = write(data, "notes.docx", in: d)
        let txt = await outputText(Act.toTXT, f).text
        check("WD-01 notes: text has numbered marks", txt.contains("本文[1]と続き[2]、後注[i]。"), txt)
        check("WD-01 notes: text lists the notes after the body",
              txt.contains("[1] 注一本文 NOTE-ONE") && txt.contains("[2] 注二 NOTE-TWO 出典リンク") && txt.contains("[i] 後注本文 ENDNOTE-ONE"), txt)
        let md = await outputText(Act.toMD, f).text
        check("WD-01 notes: Markdown footnotes", md.contains("本文[^1]と続き[^2]") && md.contains("[^1]: 注一本文 NOTE-ONE")
              && md.contains("[^i]: 後注本文 ENDNOTE-ONE") && md.contains("[出典リンク](<https://example.com/source>)"), md)
        let html = await outputText(Act.toHTML, f).text
        check("WD-01 notes: HTML links marks and notes", html.contains("<a href=\"#fn-1\">1</a>") && html.contains("id=\"fn-1\"")
              && html.contains("注一本文 NOTE-ONE") && html.contains("href=\"https://example.com/source\""), String(html.suffix(600)))
        let rtf = await outputText(Act.toRTF, f).text
        check("WD-01 notes: RTF lists the notes", rtf.contains("NOTE-ONE") && rtf.contains("ENDNOTE-ONE"))
        // Word: real footnotes and endnotes, with the link in the notes part's own relationships.
        let (docxURL, docx) = await outputText(Act.toDOCX, f)
        if let u = docxURL {
            let foot = docxPart(u, "word/footnotes.xml"), end = docxPart(u, "word/endnotes.xml")
            let types = docxPart(u, "[Content_Types].xml"), rels = docxPart(u, "word/_rels/document.xml.rels")
            check("WD-01 notes: Word output has real footnotes and endnotes",
                  docx.contains("<w:footnoteReference w:id=\"1\"/>") && docx.contains("<w:endnoteReference w:id=\"1\"/>")
                  && foot.contains("NOTE-ONE") && foot.contains("<w:footnoteRef/>") && end.contains("ENDNOTE-ONE")
                  && types.contains("footnotes+xml") && rels.contains("footnotes.xml") && rels.contains("endnotes.xml"))
            check("WD-01 notes: a link in a note uses the notes part's relationships",
                  docxPart(u, "word/_rels/footnotes.xml.rels").contains("https://example.com/source"))
            let back = await outputText(Act.toTXT, u).text
            check("WD-01 notes: Word output reads back with the notes", back.contains("[2] 注二 NOTE-TWO 出典リンク") && back.contains("本文[1]"), back)
        } else { check("WD-01 notes: Word output has real footnotes and endnotes", false, "no output") }
        // PDF: footnotes at the foot of the mark's page, endnotes after the text.
        if let u = await outputText(Act.toPDF, f).url, let doc = PDFDocument(url: u), let page = doc.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let hit = doc.findString("注一本文", withOptions: []).first
            let y = hit.map { $0.bounds(for: page).minY } ?? -1
            check("WD-01 notes: PDF sets the footnote at the foot of its page", hit?.pages.first == page && y > 0 && y < box.height * 0.25,
                  "y \(y) of \(box.height)")
            check("WD-01 notes: PDF lists the endnote", (doc.string ?? "").contains("ENDNOTE-ONE"))
        } else { check("WD-01 notes: PDF sets the footnote at the foot of its page", false, "no PDF") }

        // A footnote longer than the space at the foot continues on the next page; nothing is lost.
        let long = (1...400).map { "長い脚注の文その\($0)。" }.joined()
        let longParts = WordParts(body: wP(wR("短い本文") + "<w:r><w:rPr>\(fref)</w:rPr><w:footnoteReference w:id=\"1\"/></w:r>"),
                                  footnotes: note("footnote", 1, long + "脚注はここまで"))
        if let ld = try? wordDocx(longParts), let u = await outputText(Act.toPDF, write(ld, "longnote.docx", in: d)).url, let doc = PDFDocument(url: u) {
            let all = (doc.string ?? "").components(separatedBy: .whitespacesAndNewlines).joined()
            check("WD-01 notes: a long footnote continues on the next page, complete",
                  doc.pageCount == 2 && all.contains("その400。脚注はここまで") && all.contains("その1。長い脚注の文その2。"), "pages \(doc.pageCount)")
        } else { check("WD-01 notes: a long footnote continues on the next page, complete", false, "no PDF") }
    }

    // WD-04: equations come out as linear text where they stand.
    func auditWordMath() async {
        let d = fresh("audit-word-math")
        func r(_ t: String) -> String { "<m:r><m:t>\(t)</m:t></m:r>" }
        func e(_ x: String) -> String { "<m:e>\(x)</m:e>" }
        let frac = r("a") + r("=") + "<m:f><m:num>\(r("b"))</m:num><m:den>\(r("c"))</m:den></m:f>"
        let frac2 = "<m:f><m:num>\(r("a+b"))</m:num><m:den>\(r("c+d"))</m:den></m:f>"
        let sup = "<m:sSup>\(e(r("x")))<m:sup>\(r("2"))</m:sup></m:sSup>"
        let sub = "<m:sSub>\(e(r("x")))<m:sub>\(r("i"))</m:sub></m:sSub>"
        let rad = "<m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/>\(e(r("x+1")))</m:rad>"
        let sum = "<m:nary><m:naryPr><m:chr m:val=\"∑\"/></m:naryPr><m:sub>\(r("i=1"))</m:sub><m:sup>\(r("n"))</m:sup>\(e(sub))</m:nary>"
        let matrix = "<m:d>\(e("<m:m><m:mr>\(e(r("1")))\(e(r("0")))</m:mr><m:mr>\(e(r("0")))\(e(r("1")))</m:mr></m:m>"))</m:d>"
        let body = wP(wR("数式: ") + "<m:oMath>\(frac)</m:oMath>" + wR(" 後 AFTER-MATH"))
            + wP("<m:oMathPara><m:oMath>\(frac2)</m:oMath></m:oMathPara>")
            + wP("<m:oMath>\(sup)</m:oMath>" + wR(" , ") + "<m:oMath>\(rad)</m:oMath>" + wR(" , ") + "<m:oMath>\(sum)</m:oMath>" + wR(" , ") + "<m:oMath>\(matrix)</m:oMath>")
        guard let data = try? wordDocx(WordParts(body: body)) else { check("math fixture", false); return }
        let f = write(data, "math.docx", in: d)
        let txt = await outputText(Act.toTXT, f).text
        check("WD-04 math: inline fraction", txt.contains("数式: a=b/c 後 AFTER-MATH"), txt)
        check("WD-04 math: display fraction with parentheses", txt.contains("(a+b)/(c+d)"), txt)
        check("WD-04 math: superscript, root, sum with limits, matrix",
              txt.contains("x^2 , √(x+1) , ∑_(i=1)^n x_i , (1, 0; 0, 1)"), txt)
        let pdf = await outputText(Act.toPDF, f).text
        check("WD-04 math: PDF shows the equation", pdf.contains("a=b/c"), pdf)
    }

    // WD-05: a picture in a table cell stays in the cell.
    func auditWordCellImages() async {
        let d = fresh("audit-word-cellimg")
        let png = pngData(pattern(width: 40, height: 40, alpha: false))
        let tc = { (inner: String) in "<w:tc><w:tcPr><w:tcW w:w=\"3000\" w:type=\"dxa\"/></w:tcPr>\(inner)</w:tc>" }
        let body = "<w:tbl><w:tblGrid><w:gridCol w:w=\"3000\"/><w:gridCol w:w=\"3000\"/></w:tblGrid><w:tr>"
            + tc(wP(wR("セル内画像 IMG-IN-CELL:") + wDrawing("rIdImg1", descr: "CELL-ALT"))) + tc(wP(wR("隣 NEXT"))) + "</w:tr></w:tbl>"
        guard let data = try? wordDocx(WordParts(body: body, media: [("cell.png", png)])) else { check("cell image fixture", false); return }
        let f = write(data, "cellimg.docx", in: d)
        let html = await outputText(Act.toHTML, f).text
        check("WD-05 cell image: HTML has the picture in the cell",
              html.range(of: #"<td>[^<]*IMG-IN-CELL:<br><img src="data:image/(png|jpeg);base64,[^"]+" width="\d+" alt="CELL-ALT"></td>"#, options: .regularExpression) != nil)
        if case .success(let r) = await run(Act.toMD, [f]), let mdURL = r.outputs.first {
            let md = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
            check("WD-05 cell image: Markdown references the picture inside the cell",
                  md.range(of: #"\| セル内画像 IMG-IN-CELL:<br>!\[CELL-ALT\]\(cellimg_images/image-001\.(png|jpeg)\) \|"#, options: .regularExpression) != nil
                  && r.outputs.count == 2, md)
        } else { check("WD-05 cell image: Markdown references the picture inside the cell", false) }
        if let u = await outputText(Act.toDOCX, f).url {
            let xml = docxPart(u, "word/document.xml")
            let cell = xml.range(of: #"<w:tc>(?:(?!</w:tc>).)*<w:drawing>"#, options: .regularExpression)
            check("WD-05 cell image: Word output has the drawing in the cell", cell != nil && docxPart(u, "word/_rels/document.xml.rels").contains("media/image1"))
        } else { check("WD-05 cell image: Word output has the drawing in the cell", false) }
        if let model = try? DocxReader.read(data: data) {
            let attr = AttributedConverter.attributedString(from: model)
            var inCell = false
            attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
                guard v != nil, let ps = attr.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle else { return }
                if ps.textBlocks.contains(where: { $0 is NSTextTableBlock }) { inCell = true }
            }
            check("WD-05 cell image: PDF layout puts the picture in the table cell", inCell)
        }
        // HTML input: <td><img></td>
        let h = write(Data("<table><tr><td>H-CELL <img src=\"data:image/png;base64,\(png.base64EncodedString())\" alt=\"H-ALT\"></td><td>x</td></tr></table>".utf8), "htmlcell.html", in: d)
        let hmd = await outputText(Act.toMD, h).text
        check("WD-05 cell image: an HTML cell picture stays in the cell", hmd.contains("| H-CELL<br>![H-ALT](htmlcell_images/image-001."), hmd)
    }

    // WD-06: the list marker the document specifies reaches every target.
    func auditWordLists() async {
        let d = fresh("audit-word-lists")
        func lvl(_ i: Int, _ fmt: String, _ text: String, start: Int = 1) -> String {
            "<w:lvl w:ilvl=\"\(i)\"><w:start w:val=\"\(start)\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"\(text)\"/></w:lvl>"
        }
        let numbering = "<w:abstractNum w:abstractNumId=\"1\">\(lvl(0, "decimalEnclosedCircle", "%1"))</w:abstractNum>"
            + "<w:abstractNum w:abstractNumId=\"2\">\(lvl(0, "decimal", "(%1)"))</w:abstractNum>"
            + "<w:abstractNum w:abstractNumId=\"3\">\(lvl(0, "upperRoman", "%1."))\(lvl(1, "lowerLetter", "%2)"))</w:abstractNum>"
            + "<w:abstractNum w:abstractNumId=\"4\">\(lvl(0, "irohaFullWidth", "%1."))</w:abstractNum>"
            + "<w:abstractNum w:abstractNumId=\"5\">\(lvl(0, "decimalFullWidth", "第%1条"))\(lvl(1, "decimal", "%1.%2"))</w:abstractNum>"
            + "<w:abstractNum w:abstractNumId=\"6\">\(lvl(0, "bullet", "\u{F0FC}"))</w:abstractNum>"
            + (1...6).map { "<w:num w:numId=\"\($0)\"><w:abstractNumId w:val=\"\($0)\"/></w:num>" }.joined()
        func item(_ num: Int, _ ilvl: Int, _ text: String) -> String {
            wP(wR(text), pPr: "<w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"\(num)\"/></w:numPr>")
        }
        let body = item(1, 0, "丸一") + item(1, 0, "丸二") + item(2, 0, "括弧一") + item(2, 0, "括弧二")
            + item(3, 0, "ローマ一") + item(3, 0, "ローマ二") + item(3, 1, "英小一") + item(4, 0, "いろは一") + item(4, 0, "いろは二")
            + item(5, 0, "条一") + item(5, 1, "項一") + item(5, 1, "項二") + item(5, 0, "条二")
        let numbering6 = numbering.replacingOccurrences(of: "<w:lvlText w:val=\"\u{F0FC}\"/>", with: "<w:lvlText w:val=\"\u{F0FC}\"/><w:rPr><w:rFonts w:ascii=\"Wingdings\" w:hAnsi=\"Wingdings\"/></w:rPr>")
        guard let data = try? wordDocx(WordParts(body: body + item(6, 0, "済み"), numbering: numbering6)) else { check("lists fixture", false); return }
        let f = write(data, "lists.docx", in: d)
        let txt = await outputText(Act.toTXT, f).text
        let expected = ["① 丸一", "② 丸二", "(1) 括弧一", "(2) 括弧二", "I. ローマ一", "II. ローマ二", "  a) 英小一", "イ. いろは一", "ロ. いろは二",
                        "第１条 条一", "  １.1 項一", "  １.2 項二", "第２条 条二", "✓ 済み"]
        let missing = expected.filter { !txt.contains($0) }
        check("WD-06 lists: text shows the document's markers", missing.isEmpty, "missing \(missing) in \(txt)")
        let md = await outputText(Act.toMD, f).text
        check("WD-06 lists: Markdown keeps the marker in a list item", md.contains("- ① 丸一") && md.contains("- 第１条 条一") && md.contains("    - １.1 項一"), md)
        let html = await outputText(Act.toHTML, f).text
        check("WD-06 lists: HTML uses the marker", html.contains("list-style-type:&#39;①") || html.contains("list-style-type:'①"), html)
        let pdf = await outputText(Act.toPDF, f).text
        check("WD-06 lists: PDF shows the markers", pdf.contains("①") && pdf.contains("(2)") && pdf.contains("第１条") && pdf.contains("１.2"), pdf)
        if let u = await outputText(Act.toDOCX, f).url {
            let num = docxPart(u, "word/numbering.xml"), doc = docxPart(u, "word/document.xml")
            check("WD-06 lists: Word output numbers with the source's formats",
                  num.contains("<w:numFmt w:val=\"decimalEnclosedCircle\"/><w:lvlText w:val=\"%1\"/>") && num.contains("<w:lvlText w:val=\"(%1)\"/>")
                  && num.contains("<w:numFmt w:val=\"decimalFullWidth\"/><w:lvlText w:val=\"第%1条\"/>"))
            // "%1.%2" shows level 1 in its own format (full-width here), as Word does; written as text with a tab.
            check("WD-06 lists: Word output writes a multi-level marker as text", doc.contains(">１.2</w:t><w:tab/>"), doc)
        } else { check("WD-06 lists: Word output numbers with the source's formats", false) }
        // A numbered list that restarts at 10 right after one ending at 2 keeps its numbers in Word.
        let items = [1, 2, 10, 11].map { DocBlock.listItem(DocListItem(ordered: true, number: $0, paragraph: DocParagraph(text: "item \($0)"))) }
        if let data = try? DocxWriter.data(DocModel(blocks: items)) {
            let u = write(data, "restart.docx", in: d)
            let num = docxPart(u, "word/numbering.xml"), doc = docxPart(u, "word/document.xml")
            let ids = doc.components(separatedBy: "<w:numId w:val=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
            check("WD-06 lists: Word output keeps a list restarting at 10", ids.count == 4 && ids[0] == ids[1] && ids[2] == ids[3] && ids[1] != ids[2]
                  && num.contains("<w:start w:val=\"10\"/>"), "\(ids)")
        }
    }

    // WD-07: vertical merges land in the right columns and are kept through the model.
    func auditWordRowSpan() async {
        let d = fresh("audit-word-rowspan")
        let html = "<table><tr><th>見出しA</th><th colspan=\"2\">結合 COLSPAN</th></tr><tr><td rowspan=\"2\">縦 ROWSPAN</td><td>B2</td><td>C2</td></tr><tr><td>B3</td><td>C3</td></tr></table>"
        let h = write(Data(html.utf8), "rowspan.html", in: d)
        let md = await outputText(Act.toMD, h).text
        check("WD-07 rowspan: HTML cells after a rowspan keep their columns", md.contains("|  | B3 | C3 |"), md)
        let hh = await outputText(Act.toPDF, h)
        check("WD-07 rowspan: HTML to PDF keeps all cells", hh.text.contains("B3") && hh.text.contains("C3"))
        if let m = try? HTMLReader.model(from: Data(html.utf8)) {
            let out = HTMLWriter.string(from: m)
            check("WD-07 rowspan: HTML round trip writes rowspan", out.contains("<td rowspan=\"2\">縦 ROWSPAN</td><td>B2</td><td>C2</td></tr><tr><td>B3</td><td>C3</td>"), out)
        }
        // docx w:vMerge
        let tc = { (inner: String, pr: String) in "<w:tc><w:tcPr><w:tcW w:w=\"2000\" w:type=\"dxa\"/>\(pr)</w:tcPr>\(inner)</w:tc>" }
        let restart = "<w:vMerge w:val=\"restart\"/>", cont = "<w:vMerge/>"
        var rows = "<w:tr>" + tc(wP(wR("縦結合 VMERGED")), restart) + tc(wP(wR("R1C2")), "") + "</w:tr>"
        for r in 2...3 { rows += "<w:tr>" + tc(wP(""), cont) + tc(wP(wR("R\(r)C2")), "") + "</w:tr>" }
        let body = "<w:tbl><w:tblGrid><w:gridCol w:w=\"2000\"/><w:gridCol w:w=\"2000\"/></w:tblGrid>\(rows)</w:tbl>"
        guard let data = try? wordDocx(WordParts(body: body)) else { check("vmerge fixture", false); return }
        let f = write(data, "vmerge.docx", in: d)
        let dh = await outputText(Act.toHTML, f).text
        check("WD-07 rowspan: docx vMerge becomes rowspan in HTML", dh.contains("<td rowspan=\"3\">縦結合 VMERGED</td><td>R1C2</td></tr><tr><td>R2C2</td></tr>"), dh)
        let dx = await outputText(Act.toDOCX, f).text
        check("WD-07 rowspan: Word output keeps w:vMerge", dx.contains("<w:vMerge w:val=\"restart\"/>") && dx.components(separatedBy: "<w:vMerge/>").count == 3)
        if let model = try? DocxReader.read(data: data) {
            let attr = AttributedConverter.attributedString(from: model)
            var span = 0
            if let ps = attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
               let b = ps.textBlocks.first as? NSTextTableBlock { span = b.rowSpan }
            check("WD-07 rowspan: PDF layout merges the cell over its rows", span == 3, "rowSpan \(span)")
        }
        // pptx rowSpan
        let cell = { (attrs: String, text: String) in "<a:tc \(attrs)><a:txBody><a:bodyPr/><a:p>\(text.isEmpty ? "" : "<a:r><a:t>\(text)</a:t></a:r>")</a:p></a:txBody></a:tc>" }
        let tbl = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"4\" name=\"T\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"914400\" cy=\"914400\"/></p:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblGrid><a:gridCol w=\"914400\"/><a:gridCol w=\"914400\"/></a:tblGrid>"
            + "<a:tr h=\"370840\">\(cell("rowSpan=\"2\"", "PPT-MERGED"))\(cell("", "P1"))</a:tr><a:tr h=\"370840\">\(cell("vMerge=\"1\"", ""))\(cell("", "P2"))</a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        if let deck = try? pptxDeck([PptxSlide(body: tbl)]), let model = try? PptxReader.read(data: deck) {
            let out = HTMLWriter.string(from: model)
            check("WD-07 rowspan: pptx rowSpan reaches the model", out.contains("<td rowspan=\"2\">PPT-MERGED</td>"), out)
        } else { check("WD-07 rowspan: pptx rowSpan reaches the model", false, "fixture") }
    }

    // WD-09: an iframe after an unclosed inline element no longer swallows the rest of the page.
    func auditWordIframe() async {
        let d = fresh("audit-word-iframe")
        let h = write(Data("<html><body><p>A <b>bold\n<iframe src=\"x.html\"></iframe>\n<p>B-LAST</p></body></html>".utf8), "v4.html", in: d)
        let txt = await outputText(Act.toTXT, h).text
        check("WD-09 iframe: text after the iframe survives", txt.contains("A bold") && txt.contains("B-LAST"), txt)
        let b = write(Data("<html><body><p>A <i>it\n<button>Go</button>\n<p>AFTER-BUTTON</p></body></html>".utf8), "button.html", in: d)
        let btxt = await outputText(Act.toTXT, b).text
        check("WD-09 iframe: the same for a button", btxt.contains("AFTER-BUTTON") && !btxt.contains("Go"), btxt)
        let fb = write(Data("<p>before</p><iframe src=\"y\"><p>FALLBACK-TEXT</p></iframe><p>END-AFTER</p>".utf8), "fallback.html", in: d)
        let ftxt = await outputText(Act.toTXT, fb).text
        check("WD-09 iframe: only the iframe itself is skipped", ftxt.contains("END-AFTER") && !ftxt.contains("FALLBACK-TEXT"), ftxt)
    }

    // WD-12: every explicit page break breaks the page, including one around a single paragraph.
    func auditWordPageBreaks() async {
        let model = DocModel(blocks: [.paragraph(DocParagraph(text: "P-ONE")), .pageBreak, .paragraph(DocParagraph(text: "P-TWO")),
                                      .pageBreak, .paragraph(DocParagraph(text: "P-THREE"))])
        let doc = PDFDocument(data: PDFRenderer.pdfData(from: model))
        check("WD-12 page breaks: a one-paragraph page stays its own page", doc?.pageCount == 3 && doc?.page(at: 1)?.string?.contains("P-TWO") == true
              && doc?.page(at: 2)?.string?.contains("P-THREE") == true, "pages \(doc?.pageCount ?? 0)")
        let d = fresh("audit-word-pagebreaks")
        let br = "<w:r><w:br w:type=\"page\"/></w:r>"
        guard let data = try? wordDocx(WordParts(body: wP(wR("表紙 COVER") + br) + wP(wR("目次 TOC") + br) + wP(wR("本文 BODY")))) else { return }
        if let u = await outputText(Act.toPDF, write(data, "breaks.docx", in: d)).url, let pdf = PDFDocument(url: u) {
            check("WD-12 page breaks: docx with two breaks gives three pages", pdf.pageCount == 3, "pages \(pdf.pageCount)")
        } else { check("WD-12 page breaks: docx with two breaks gives three pages", false) }
    }

    // WD-16 / WD-08: <br> in Markdown table cells round-trips; HTML blocks keep their text; inline tags apply.
    func auditWordMarkdownHTML() async {
        let d = fresh("audit-word-mdhtml")
        let md = """
        a <span style="color:red">RED-SPAN</span> <kbd>Cmd</kbd> <u>UL</u> <mark>MK</mark> \\<br\\> lit `<br>` code

        | a | b |
        |---|---|
        | L1<br>L2 | z |

        <div align="center">
        BLOCK-HTML
        </div>

        after AFTER-BLOCK

        """
        let m = write(Data(md.utf8), "inline.md", in: d)
        let txt = await outputText(Act.toTXT, m).text
        check("WD-08 markdown HTML: inline tags go, their text stays", txt.contains("a RED-SPAN Cmd UL MK") && !txt.contains("<span") && !txt.contains("<kbd>"), txt)
        check("WD-08 markdown HTML: escaped and code <br> stay literal", txt.contains("<br> lit <br> code"), txt)
        check("WD-08 markdown HTML: an HTML block keeps its text", txt.contains("BLOCK-HTML") && txt.contains("AFTER-BLOCK"), txt)
        check("WD-16 markdown <br>: a line break in a table cell is read as one", txt.contains("L1\nL2") && !txt.contains("L1<br>L2"), txt)
        let html = await outputText(Act.toHTML, m).text
        check("WD-08 markdown HTML: <kbd>, <u>, <mark> are applied", html.contains("<code>Cmd</code>") && html.contains("<u>UL</u>") && html.contains("background:#FFFF00"), html)
        // docx with a line break in a cell -> Markdown -> Word: no literal <br>.
        let cellBody = "<w:tbl><w:tblGrid><w:gridCol w:w=\"3000\"/></w:tblGrid><w:tr><w:tc>\(wP(wR("平成27年") + "<w:r><w:br/></w:r>" + wR("（大法廷）")))</w:tc></w:tr><w:tr><w:tc>\(wP(wR("x")))</w:tc></w:tr></w:tbl>"
        guard let data = try? wordDocx(WordParts(body: cellBody)) else { return }
        let f = write(data, "cellbr.docx", in: d)
        if case .success(let r) = await run(Act.toMD, [f]), let mdURL = r.outputs.first {
            let back = await outputText(Act.toDOCX, mdURL).text
            check("WD-16 markdown <br>: docx → md → docx keeps the break, not the tag",
                  back.contains("平成27年</w:t><w:br/><w:t xml:space=\"preserve\">（大法廷）") && !back.contains("&lt;br&gt;"), back)
        } else { check("WD-16 markdown <br>: docx → md → docx keeps the break, not the tag", false) }
    }

    // WD-15: YAML front matter is metadata, not body text.
    func auditWordFrontMatter() async {
        let d = fresh("audit-word-frontmatter")
        let m = write(Data("---\ntitle: \"FM-TITLE\"\nauthor: テスト\ntags: [a, b]\n---\n\n# Heading\n\nbody FM-BODY\n".utf8), "fm.md", in: d)
        let txt = await outputText(Act.toTXT, m).text
        check("WD-15 front matter: not printed as text", !txt.contains("title:") && !txt.contains("author") && !txt.contains("FM-TITLE") && txt.contains("FM-BODY"), txt)
        let html = await outputText(Act.toHTML, m).text
        check("WD-15 front matter: its title is the document title", html.contains("<title>FM-TITLE</title>"), html)
        let pdf = await outputText(Act.toPDF, m)
        check("WD-15 front matter: PDF has no front matter heading", !pdf.text.contains("author") && pdf.text.contains("FM-BODY"), pdf.text)
        // Not front matter: left alone.
        let plain = write(Data("---\nJust a sentence here.\n---\n\nPara PLAIN-PARA\n".utf8), "notfm.md", in: d)
        let ptxt = await outputText(Act.toTXT, plain).text
        check("WD-15 front matter: a document that only starts with a rule is unchanged", ptxt.contains("Just a sentence here.") && ptxt.contains("PLAIN-PARA"), ptxt)
    }

    // WD-20: encoding detection picks the right one among UTF-8, Shift_JIS, EUC-JP, ISO-2022-JP and UTF-16 LE/BE.
    func auditWordEncodings() async {
        let kana = "テストです。カタカナとかなの文章。"
        let text = "日本語のテキストです。\nSecond line 二行目。\n"
        let cases: [(String, Data?, String)] = [
            ("EUC-JP, kana only", kana.data(using: .japaneseEUC), kana),
            ("UTF-16BE without BOM", text.data(using: .utf16BigEndian), text),
            ("UTF-16LE without BOM", text.data(using: .utf16LittleEndian), text),
            ("ISO-2022-JP", text.data(using: .iso2022JP), text),
        ]
        for (name, data, expected) in cases {
            guard let data else { check("WD-20 encoding fixture \(name)", false); continue }
            let got = PlainTextReader.decode(data)
            check("WD-20 encoding: \(name)", got == expected, got.debugDescription)
        }
        // Stays right: UTF-8, Shift_JIS with CP932 characters, short Shift_JIS, half-width katakana, EUC-JP kanji.
        let keep: [(String, Data?, String)] = [
            ("UTF-8", Data("日本語 ① 髙\n".utf8), "日本語 ① 髙\n"),
            ("Shift_JIS with ① 髙 ～", "「かぎ括弧」～ ① 髙 END\n".data(using: .shiftJIS), "「かぎ括弧」～ ① 髙 END\n"),
            ("short Shift_JIS", "テスト".data(using: .shiftJIS), "テスト"),
            ("Shift_JIS half-width katakana", "ｶﾀｶﾅ".data(using: .shiftJIS), "ｶﾀｶﾅ"),
            ("EUC-JP kanji", "東京都千代田区の住所録。担当者一覧表。".data(using: .japaneseEUC), "東京都千代田区の住所録。担当者一覧表。"),
        ]
        for (name, data, expected) in keep {
            guard let data else { check("WD-20 encoding fixture \(name)", false); continue }
            let got = PlainTextReader.decode(data)
            check("WD-20 encoding stays right: \(name)", got == expected, got.debugDescription)
        }
        // End to end: a kana-heavy EUC-JP text file to Markdown.
        let d = fresh("audit-word-encoding")
        if let data = kana.data(using: .japaneseEUC) {
            let md = await outputText(Act.toMD, write(data, "euc.txt", in: d)).text
            check("WD-20 encoding: EUC-JP text file converts correctly", md.contains(kana), md)
        }
    }
}
