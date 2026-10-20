import Foundation
import AppKit
import PDFKit
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

/// Checks for the second security review: links, Markdown export, CSV formulas, hostile numbers, quadratic paths,
/// the request gate, and the descriptor-based image read.
extension SelfTest {

    func smallPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// A PNG whose header declares `w` x `h` pixels but which has almost no pixel data.
    func pngClaiming(_ w: UInt32, _ h: UInt32) -> Data {
        let ihdr = be32(w) + be32(h) + [8, 6, 0, 0, 0]
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(UInt32(body.count)) + Array(type.utf8) + body + be32(crc32(Array(type.utf8) + body)) }
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IEND", []))
    }

    /// One-page PDF with the given content stream (xref table computed).
    func rawPDF(content: String) -> Data {
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func obj(_ n: Int, _ body: String) {
            offsets.append(out.count)
            out.append(Data("\(n) 0 obj\n\(body)\nendobj\n".utf8))
        }
        obj(1, "<</Type/Catalog/Pages 2 0 R>>")
        obj(2, "<</Type/Pages/Kids[3 0 R]/Count 1>>")
        obj(3, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>")
        obj(4, "<</Length \(content.utf8.count)>>\nstream\n\(content)\nendstream")
        obj(5, "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        let xref = out.count
        var table = "xref\n0 6\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<</Root 1 0 R/Size 6>>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }

    func testSecurityRound2() async {
        let d = fresh("security2")
        let fm = FileManager.default

        // F1 / F5: links. Only http, https and mailto survive; the text stays.
        let md = "[a](file:///Applications/Calculator.app) [b](https://example.com/x) [c](smb://h/s) [d](mailto:a@b.c) [e](javascript:alert(1))"
        let mdModel = MarkdownReader.model(from: md)
        var links: [String: String?] = [:]
        var allText = ""
        for block in mdModel.blocks { if case .paragraph(let p) = block { for r in p.runs { links[r.text.trimmingCharacters(in: .whitespaces)] = r.link; allText += r.text } } }
        check("markdown reader drops file:, smb: and javascript: links", links["a"] == .some(nil) && links["c"] == .some(nil) && links["e"] == .some(nil), "\(links)")
        check("markdown reader keeps http(s) and mailto links", links["b"] == .some("https://example.com/x") && links["d"] == .some("mailto:a@b.c"), "\(links)")
        check("markdown reader keeps the text of dropped links", ["a", "c", "e"].allSatisfy { allText.contains($0) })
        let runs = [DocRun("bad", link: "file:///etc/passwd"), DocRun("smb", link: "smb://h/s"), DocRun("good", link: "https://example.com/"), DocRun("mail", link: "mailto:x@y.z")]
        let attributed = AttributedConverter.attributedString(from: DocModel(title: nil, blocks: [.paragraph(DocParagraph(runs))], pageSize: CGSize(width: 600, height: 800)))
        var linked: [String] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { v, r, _ in
            if v != nil { linked.append((attributed.string as NSString).substring(with: r)) }
        }
        check("attributed converter links only web and mail targets", linked.contains("good") && linked.contains("mail") && !linked.contains("bad") && !linked.contains("smb"), "\(linked)")
        check("attributed converter keeps the text of dropped links", attributed.string.contains("bad") && attributed.string.contains("smb"))

        // F2: Markdown export never reuses an existing "<name>_images" folder, nor follows a symlink inside it.
        do {
            let victimDir = fresh("security2/victim")
            let victim = victimDir.appendingPathComponent("target.txt")
            try "SAFE".write(to: victim, atomically: true, encoding: .utf8)
            let png = smallPNG()
            let html = "<html><body><p>hello</p><img src=\"data:image/png;base64,\(png.base64EncodedString())\" alt=\"pic\"></body></html>"

            // (a) the folder exists and holds a symlink with the name the export would use
            let a = fresh("security2/a")
            let inputA = a.appendingPathComponent("report.html")
            try html.write(to: inputA, atomically: true, encoding: .utf8)
            let planted = a.appendingPathComponent("report_images", isDirectory: true)
            try fm.createDirectory(at: planted, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: planted.appendingPathComponent("image-001.png"), withDestinationURL: victim)
            let ra = await run("to.md", [inputA])
            switch ra {
            case .success(let r):
                check("md export: file behind a planted symlink is not touched", (try? String(contentsOf: victim, encoding: .utf8)) == "SAFE")
                let dirs = r.outputs.filter { $0.hasDirectoryPath }
                check("md export: a fresh image folder is used when the name is taken", dirs.count == 1 && dirs[0].lastPathComponent == "report_images 2", "\(dirs.map(\.lastPathComponent))")
                check("md export: the planted folder is left as it was", ((try? fm.contentsOfDirectory(atPath: planted.path)) ?? []) == ["image-001.png"])
                let mdText = (try? String(contentsOf: r.outputs[0], encoding: .utf8)) ?? ""
                check("md export: the Markdown refers to the folder actually used", mdText.contains("report_images%202/image-001.png"), mdText)
                check("md export: image written in the new folder", dirs.first.map { fm.fileExists(atPath: $0.appendingPathComponent("image-001.png").path) } ?? false)
            case .failure(let e): check("md export with a planted symlink", false, errText(e))
            }

            // (b) the folder name is itself a symlink to another folder
            let b = fresh("security2/b")
            let inputB = b.appendingPathComponent("report.html")
            try html.write(to: inputB, atomically: true, encoding: .utf8)
            let elsewhere = fresh("security2/elsewhere")
            try fm.createSymbolicLink(at: b.appendingPathComponent("report_images"), withDestinationURL: elsewhere)
            let rb = await run("to.md", [inputB])
            switch rb {
            case .success(let r):
                check("md export: a symlinked image folder is not written through", ((try? fm.contentsOfDirectory(atPath: elsewhere.path)) ?? ["x"]).isEmpty)
                check("md export: a symlinked image folder is replaced by a new folder", r.outputs.contains { $0.lastPathComponent == "report_images 2" })
            case .failure(let e): check("md export with a symlinked image folder", false, errText(e))
            }

            // (c) a dangling symlink with the folder's name
            let c = fresh("security2/c")
            let inputC = c.appendingPathComponent("report.html")
            try html.write(to: inputC, atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(at: c.appendingPathComponent("report_images"), withDestinationURL: c.appendingPathComponent("nowhere"))
            let rc = await run("to.md", [inputC])
            switch rc {
            case .success(let r):
                check("md export: a dangling symlink is not used as the image folder", r.outputs.contains { $0.lastPathComponent == "report_images 2" } && !fm.fileExists(atPath: c.appendingPathComponent("nowhere").path))
            case .failure(let e): check("md export with a dangling symlink", false, errText(e))
            }

            // (d) the normal case still uses the plain name
            let n = fresh("security2/n")
            let inputN = n.appendingPathComponent("report.html")
            try html.write(to: inputN, atomically: true, encoding: .utf8)
            if case .success(let r) = await run("to.md", [inputN]) {
                check("md export: plain folder name when it is free", r.outputs.contains { $0.lastPathComponent == "report_images" })
            } else { check("md export plain case", false) }
        } catch { check("md export symlink scenario", false, "\(error)") }

        // F4 / F7: Markdown output cannot start an HTML block from a code span or from alt text.
        do {
            var code = DocRun("x\n<script>alert(1)</script>"); code.code = true
            var code2 = DocRun("y\r<script>z</script>\u{2028}<iframe>"); code2.code = true
            let img = DocImage(data: smallPNG(), format: .png, pixelWidth: 4, pixelHeight: 4, altText: "a\n<script>alert(1)</script>\r<b>x</b>")
            let out = MarkdownWriter.string(from: DocModel(title: nil, blocks: [
                .paragraph(DocParagraph([DocRun("text "), code])), .paragraph(DocParagraph([code2])), .image(img),
                .heading(level: 2, DocParagraph([code])), .listItem(DocListItem(ordered: false, level: 0, number: nil, paragraph: DocParagraph([code]))),
            ], pageSize: CGSize(width: 600, height: 800)), imageDirectoryName: "d")
            let lines = out.text.components(separatedBy: CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}"))
            check("markdown writer: no line starts an HTML block (code spans, alt text)", !lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("<") }, out.text)
            check("markdown writer: alt text stays on one line", lines.contains { $0.hasPrefix("![") && $0.contains("script") && $0.hasSuffix(")") }, out.text)
            check("markdown writer: code text is kept", out.text.contains("`x <script>alert(1)</script>`"), out.text)
        }

        // F6: CSV formula prefixing; real numbers are untouched.
        do {
            let row: [CellValue] = [.text("=1+1"), .text("-5"), .text("+1.5"), .number(-5), .text("@SUM(A1)"), .text("-cmd|' /C calc'!A0"), .text("\tx"), .text("plain"), .text("=HYPERLINK(\"u\",\"c\")"), .text("-"), .text("\rx")]
            let csv = String(decoding: CSVCodec.encode(Sheet(name: "s", rows: [row]), bom: false), as: UTF8.self)
            let line = csv.trimmingCharacters(in: .whitespacesAndNewlines)
            check("csv: formula text gets a leading quote", line.hasPrefix("'=1+1,"), line)
            check("csv: text that is a plain number is left alone", line.contains(",-5,+1.5,-5,"), line)
            check("csv: @ and - formulas are prefixed", line.contains(",'@SUM(A1),") && line.contains("'-cmd|"), line)
            check("csv: tab, CR and a lone minus are prefixed", line.contains("'\tx") && line.contains(",'-,") && line.contains("\"'\rx\""), line)
            check("csv: ordinary text is untouched", line.contains(",plain,"), line)
            check("csv: quoted formula with commas keeps its quote", line.contains("\"'=HYPERLINK(\"\"u\"\",\"\"c\"\")\""), line)
            check("csv: negative number cells are untouched", CSVCodec.neutralizingFormula("-5") == "-5" && CSVCodec.neutralizingFormula("+1.5") == "+1.5")
        }

        // F3: absurd column widths do not trap in the Word writer.
        do {
            func cell(_ s: String) -> DocTableCell { DocTableCell(text: s) }
            for widths in [[1e305, 1e305, 1], [Double.greatestFiniteMagnitude, 1], [1e-320, 1e-320], [1e305, 1e-305]] {
                let n = widths.count
                let table = DocTable(rows: [Array(repeating: cell("a"), count: n), Array(repeating: cell("b"), count: n)], headerRows: 1, columnWidths: widths)
                let out = d.appendingPathComponent("widths-\(widths[0]).docx")
                do {
                    try DocxWriter.write(DocModel(title: nil, blocks: [.table(table)], pageSize: CGSize(width: 595, height: 842)), to: out)
                    let back = try DocxReader.read(out)
                    check("docx writer survives column widths \(widths)", back.blocks.contains { if case .table = $0 { return true }; return false })
                } catch { check("docx writer survives column widths \(widths)", false, "\(error)") }
            }
        }

        // F11: a PDF whose rules end up at infinity converts without trapping.
        do {
            let cm = String(repeating: "1 0 0 1000000000000000000 0 0 cm\n", count: 17)
            let content = "BT /F1 12 Tf 72 700 Td (Cell) Tj ET\nq\n\(cm)0 -100 100 200 re S\n0 -100 100 200 re f\nQ\n"
                + "q 72 500 m 300 500 l S 72 560 m 300 560 l S 72 500 m 72 560 l S 300 500 m 300 560 l S Q\n"
            let url = d.appendingPathComponent("inf-rules.pdf")
            try rawPDF(content: content).write(to: url)
            check("hostile PDF fixture opens", PDFDocument(url: url) != nil)
            for target in ["to.docx", "to.md", "to.xlsx"] {
                _ = await run(target, [url])
                check("pdf with infinite rule coordinates converts to \(target) without trapping", true)
            }
        } catch { check("pdf with infinite rule coordinates", false, "\(error)") }

        // F13: an attachment that declares 60000 x 60000 pixels is skipped.
        do {
            let huge = pngClaiming(60000, 60000)
            let att = NSTextAttachment(data: huge, ofType: "public.png")
            let s = NSMutableAttributedString(string: "before\n")
            s.append(NSAttributedString(attachment: att))
            s.append(NSAttributedString(string: "\nafter"))
            let model = AttributedConverter.model(from: s)
            let hasImage = model.blocks.contains { if case .image = $0 { return true }; return false }
            check("attachment images beyond the pixel limit are skipped", !hasImage)
            check("pixel limit check reads the declared size from the header", !ImageCodec.isWithinLimits(huge) && ImageCodec.isWithinLimits(smallPNG()))
            let ok = NSMutableAttributedString(string: "x\n")
            ok.append(NSAttributedString(attachment: NSTextAttachment(data: smallPNG(), ofType: "public.png")))
            let okModel = AttributedConverter.model(from: ok)
            check("normal attachment images are still read", okModel.blocks.contains { if case .image = $0 { return true }; return false })
        }

        // F9 / F10: no quadratic time.
        do {
            // HYPERLINK with a huge run of switches, inside a docx complex field.
            let instr = "HYPERLINK " + String(repeating: "\\a", count: 500_000)
            let field = "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\">\(instr)</w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>link text</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
            let good = "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> HYPERLINK \\o \"tip\" \"https://example.com/ok\" </w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>fine</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
            let url = d.appendingPathComponent("hyperlink-switches.docx")
            try docxPackage(document: "<?xml version=\"1.0\"?><w:document __NS__><w:body>\(field)\(good)</w:body></w:document>").write(to: url)
            let t0 = Date()
            let model = try DocxReader.read(url)
            check("docx HYPERLINK with 500k switches is handled in linear time", Date().timeIntervalSince(t0) < 5, "\(Date().timeIntervalSince(t0))s")
            var okLink = false
            for b in model.blocks { if case .paragraph(let p) = b { for r in p.runs where r.text == "fine" && r.link == "https://example.com/ok" { okLink = true } } }
            check("docx HYPERLINK with a leading switch still yields its URL", okLink)

            // Many fields, each with a long run of switches that stays within the instruction limit.
            let within = "HYPERLINK " + String(repeating: "\\a", count: 4000)
            let one = "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\">\(within)</w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>t</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
            let url2 = d.appendingPathComponent("hyperlink-switches2.docx")
            try docxPackage(document: "<?xml version=\"1.0\"?><w:document __NS__><w:body>\(String(repeating: one, count: 200))</w:body></w:document>").write(to: url2)
            let t1 = Date()
            _ = try DocxReader.read(url2)
            check("200 HYPERLINK fields with 4000 switches each are handled quickly", Date().timeIntervalSince(t1) < 5, "\(Date().timeIntervalSince(t1))s")
        } catch { check("docx HYPERLINK switches", false, "\(error)") }
        do {
            // 50,000 PAGE fields in a header.
            let one = "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText>PAGE</w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
            let header = "<?xml version=\"1.0\"?><w:hdr __NS__><w:p>" + String(repeating: one, count: 50_000) + "</w:p></w:hdr>"
            let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
            let rels = "<Relationship Id=\"rId30\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>"
            let body = "<?xml version=\"1.0\"?><w:document __NS__><w:body><w:p><w:r><w:t>body</w:t></w:r></w:p><w:sectPr><w:headerReference w:type=\"default\" r:id=\"rId30\"/></w:sectPr></w:body></w:document>"
            let url = d.appendingPathComponent("header-fields.docx")
            try docxPackage(document: body, rels: rels, extra: [("word/header1.xml", Data(header.replacingOccurrences(of: "__NS__", with: ns).utf8))]).write(to: url)
            let doc = try DocxDocument(url: url)
            let t0 = Date()
            var length = 0
            for page in 1...20 { length = doc.headerFooter?.header(page: page, of: 20)?.length ?? -1 }
            let elapsed = Date().timeIntervalSince(t0)
            check("header with 50k PAGE fields is filled in linear time (20 pages)", elapsed < 5 && length > 0, "\(elapsed)s length \(length)")
            let sample = doc.headerFooter?.header(page: 7, of: 20)?.string ?? ""
            check("header page numbers are replaced", sample.hasPrefix("7") && !sample.contains("\u{E010}"), String(sample.prefix(20)))
        } catch { check("docx header fields", false, "\(error)") }

        // F14 / F15 / F19: what a marudoc:// request may do.
        do {
            let all = ActionCatalog.allActionIDs
            check("gate: in-place actions are all menu actions", ActionCatalog.inPlaceActionIDs.isSubset(of: Set(all)))
            check("gate: token holders run menu actions", ActionCatalog.admission(for: Act.toDOCX, authenticated: true) == .run
                  && ActionCatalog.admission(for: Act.imgRotateLeft, authenticated: true) == .run
                  && ActionCatalog.admission(for: Act.copyText, authenticated: true) == .run
                  && ActionCatalog.admission(for: Act.openSettings, authenticated: true) == .run)
            check("gate: internal ids are refused even with a token", [Act.pdfDecrypt, Act.pdfEncrypt, Act.pdfFlatten, Act.pdfWatermark, Act.imgResizeCustom, "nonsense", "edit.nothing", ""]
                .allSatisfy { ActionCatalog.admission(for: $0, authenticated: true) == .refuse })
            check("gate: unknown ids are refused without a token", ActionCatalog.admission(for: "nonsense", authenticated: false) == .refuse)
            check("gate: without a token the clipboard action is refused", ActionCatalog.admission(for: Act.copyText, authenticated: false) == .refuse)
            check("gate: without a token no action rewrites the original",
                  ActionCatalog.inPlaceActionIDs.allSatisfy { ActionCatalog.admission(for: $0, authenticated: false) == .refuse })
            check("gate: without a token other menu actions need the user's confirmation",
                  [Act.toDOCX, Act.pdfMerge, Act.pdfSplit, Act.pdfCompressStandard, Act.editOpen].allSatisfy { ActionCatalog.admission(for: $0, authenticated: false) == .askUser })
            check("gate: opening Settings needs no confirmation (it touches no files)", ActionCatalog.admission(for: Act.openSettings, authenticated: false) == .run)
            // Every id the Finder extension can send is accepted with a token.
            let sendable = Set(all)
            let menuIDs = Set(["a.pdf", "a.png", "a.docx", "a.md", "a.xlsx", "a.csv", "a.pptx", "a.rtf"].flatMap { name in
                ActionCatalog.menu(for: [URL(fileURLWithPath: "/tmp/" + name)]).flatMap(flatten)
            })
            check("gate: every action in the Finder menu is accepted with a token", menuIDs.allSatisfy { sendable.contains($0) && ActionCatalog.admission(for: $0, authenticated: true) == .run })
        }

        // F12: the opened descriptor, not the path, decides where the read happens.
        do {
            let inside = fresh("security2/inside"), outside = fresh("security2/outside")
            try smallPNG().write(to: inside.appendingPathComponent("ok.png"))
            try smallPNG().write(to: outside.appendingPathComponent("secret.png"))
            try fm.createSymbolicLink(at: inside.appendingPathComponent("d"), withDestinationURL: outside)
            check("image read: a regular file inside the folder is read", HTMLReader.readOpenedFile(inside.appendingPathComponent("ok.png"), inside: inside) != nil)
            // The state after a folder was swapped for a symlink: the path still looks like it is inside.
            check("image read: a path that now leads outside through a symlinked folder is refused", HTMLReader.readOpenedFile(inside.appendingPathComponent("d/secret.png"), inside: inside) == nil)
            try fm.createSymbolicLink(at: inside.appendingPathComponent("link.png"), withDestinationURL: inside.appendingPathComponent("ok.png"))
            check("image read: a symlink as the last component is refused (O_NOFOLLOW)", HTMLReader.readOpenedFile(inside.appendingPathComponent("link.png"), inside: inside) == nil)
            check("image read: a directory is refused", HTMLReader.readOpenedFile(inside, inside: inside) == nil)
            check("image read: a file whose size is over the limit is refused", HTMLReader.readOpenedFile(inside.appendingPathComponent("ok.png"), inside: inside, limit: 10) == nil)
            let model = MarkdownReader.model(from: "![a](ok.png)\n\n![b](d/secret.png)\n\n![c](link.png)", baseURL: inside)
            let images = model.blocks.filter { if case .image = $0 { return true }; return false }.count
            check("markdown images: inside files load, symlinks out of the folder do not", images == 2, "\(images)")
            let images2 = MarkdownReader.model(from: "![b](d/secret.png)", baseURL: inside).blocks.filter { if case .image = $0 { return true }; return false }.count
            check("markdown image behind a symlinked folder is not embedded", images2 == 0)
        } catch { check("image read scenario", false, "\(error)") }
    }

    private func flatten(_ node: MenuNode) -> [String] {
        (node.action.map { [$0] } ?? []) + node.children.flatMap(flatten)
    }
}
