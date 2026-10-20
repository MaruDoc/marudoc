import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

/// End-to-end checks of the engine on generated fixtures. Prints PASS / FAIL / SKIP lines and a summary.
final class SelfTest {
    let root: URL
    var passed = 0, failed = 0, skipped = 0
    var failures: [String] = []

    init(root: URL) { self.root = root }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; failures.append(name); print("FAIL  \(name) \(detail)") }
    }
    func skip(_ name: String, _ why: String) { skipped += 1; print("SKIP  \(name) — \(why)") }

    func fresh(_ name: String) -> URL {
        let d = root.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: d.path) {
            let trash = root.appendingPathComponent(".old-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: d, to: trash)
        }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func run(_ action: String, _ files: [URL], options: EngineOptions = EngineOptions()) async -> Result<EngineResult, Error> {
        let e = Engine(); e.options = options
        do { return .success(try await e.run(action, files: files)) } catch { return .failure(error) }
    }

    func errText(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }

    // MARK: Fixtures

    let markdown = """
    # 月次報告書

    これは **MaruDoc** の変換テスト用の文書です。日本語と English が混ざった段落が、折り返しても正しく一つの段落として扱われるかを確かめます。長めの文章を書いておくと、PDF にしたときに複数行になります。

    ## 1. 売上の概要

    - 東京店の売上が前月比 *12%* 増えました
    - 大阪店は横ばいです
        - 新商品の投入は来月です
    1. 原因を調べる
    2. 対策を決める

    | 店舗 | 売上 | 前月比 |
    | --- | --- | --- |
    | 東京 | 1,234 | 12.5% |
    | 大阪 | 987 | 0.0% |

    > 引用: 数字は速報値です。

    ```
    let total = 1234 + 987
    ```

    ## 2. 次の一手

    リンク [Apple](https://www.apple.com) を含む段落。最後の段落です。
    """

    func makeFixtures(_ d: URL) throws -> (md: URL, pdf: URL, png: URL, jpg: URL, ocr: URL, big: URL) {
        let md = d.appendingPathComponent("報告書.md")
        try markdown.write(to: md, atomically: true, encoding: .utf8)

        // 3-page PDF from the same content.
        var model = MarkdownReader.model(from: markdown)
        let blocks = model.blocks
        model.blocks = blocks + [.pageBreak] + blocks + [.pageBreak] + blocks
        let pdf = d.appendingPathComponent("報告書.pdf")
        try PDFRenderer.pdfData(from: model).write(to: pdf)

        // PNG with transparency and an asymmetric pattern (red top-left quadrant).
        let png = d.appendingPathComponent("図.png")
        try writeImage(pattern(width: 400, height: 300, alpha: true), to: png, type: .png, extra: [:])

        // JPEG stored sideways (EXIF orientation 6) with a GPS tag.
        let jpg = d.appendingPathComponent("写真.jpg")
        let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.68, kCGImagePropertyGPSLatitudeRef: "N",
                                                                     kCGImagePropertyGPSLongitude: 139.76, kCGImagePropertyGPSLongitudeRef: "E"],
                                    kCGImagePropertyOrientation: 6]
        try writeImage(pattern(width: 300, height: 400, alpha: false), to: jpg, type: .jpeg, extra: gps)

        // Text image for OCR.
        let ocr = d.appendingPathComponent("請求書.png")
        try writeImage(textImage("請求書\n合計金額 12,345円\nMaruDoc Invoice Test"), to: ocr, type: .png, extra: [:])

        // A PDF with a large photo-like image, for compression.
        // Drawn through a PDF context the image is stored losslessly (Flate), like scans from many apps.
        let big = d.appendingPathComponent("写真入り.pdf")
        let noisy = noise(width: 2400, height: 1800)
        var box = CGRect(x: 0, y: 0, width: 600, height: 450)
        if let ctx = CGContext(big as CFURL, mediaBox: &box, nil) {
            ctx.beginPDFPage(nil); ctx.draw(noisy, in: box); ctx.endPDFPage(); ctx.closePDF()
        }
        return (md, pdf, png, jpg, ocr, big)
    }

    func pattern(width: Int, height: Int, alpha: Bool) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
        if alpha { ctx.clear(CGRect(x: 0, y: 0, width: width, height: height)) } else {
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        // Red quadrant at the visual top-left (CG origin is bottom-left).
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    func noise(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 12345
        for i in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 1664525 &+ 1013904223
            let v = UInt8((seed >> 24) & 0xFF)
            let x = (i / 4) % width
            bytes[i] = UInt8((x * 255) / width) &+ v / 8; bytes[i + 1] = v; bytes[i + 2] = UInt8(255 - (x * 255) / width); bytes[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func textImage(_ text: String) -> CGImage {
        let w = 900, h = 420
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "HiraginoSans-W6", size: 52)!, .foregroundColor: NSColor.black]
        (text as NSString).draw(in: CGRect(x: 40, y: 20, width: w - 80, height: h - 40), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    func writeImage(_ img: CGImage, to url: URL, type: UTType, extra: [CFString: Any]) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props = extra
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DocIOError.writeFailed(url.lastPathComponent) }
    }

    /// Colour of the visual top-left area after applying EXIF orientation.
    func topLeftIsRed(_ url: URL) -> Bool? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 400]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return pixel(img, x: img.width / 5, yFromTop: img.height / 5).r > 200
    }

    func pixel(_ img: CGImage, x: Int, yFromTop: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - yFromTop), width: img.width, height: img.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }

    func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
    func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    func pdfText(_ u: URL) -> String { PDFDocument(url: u)?.string ?? "" }
    func textutil(_ u: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", "txt", "-stdout", u.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    // MARK: Runs

    func runAll() async -> Int {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("MaruDoc self-test in \(root.path)")
        testNaming()
        testGeometry()
        testCatalog()
        testRadialSession()
        testSecurity()
        testHardening()
        await testSecurityRound2()
        let d = fresh("fixtures")
        guard let fx = try? makeFixtures(d) else { check("fixtures", false); return 1 }
        await testDocuments(fx.md, fx.pdf)
        await testPDFOps(fx.pdf, fx.big, fx.png)
        await testMergeAndSplit()
        await testImages(fx.png, fx.jpg, fx.ocr)
        await testSheets()
        await testInkAnnotation()
        await testSpeed()
        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        if !failures.isEmpty { print("Failed: " + failures.joined(separator: ", ")) }
        return failed
    }

    func testNaming() {
        let d = fresh("naming")
        let a = d.appendingPathComponent("Report.pdf")
        FileManager.default.createFile(atPath: a.path, contents: Data())
        check("naming: new extension", OutputNamer.file(for: a, ext: "docx").lastPathComponent == "Report.docx")
        FileManager.default.createFile(atPath: d.appendingPathComponent("Report.docx").path, contents: Data())
        check("naming: numbered when taken", OutputNamer.file(for: a, ext: "docx").lastPathComponent == "Report 2.docx")
        FileManager.default.createFile(atPath: d.appendingPathComponent("Report 2.docx").path, contents: Data())
        check("naming: next number", OutputNamer.file(for: a, ext: "docx").lastPathComponent == "Report 3.docx")
        check("naming: tag", OutputNamer.file(for: a, ext: "pdf", tag: "圧縮").lastPathComponent == "Report (圧縮).pdf")
        check("naming: numbered pages", OutputNamer.numbered("A", index: 3, count: 12, ext: "png") == "A-03.png")
    }

    func testGeometry() {
        var ok = true
        for n in 1...8 {
            for i in 0..<n {
                let a = RadialGeometry.innerCenter(index: i, count: n) * .pi / 180
                let dx = CGFloat(sin(a)) * 80, dy = CGFloat(-cos(a)) * 80
                if RadialGeometry.hit(dx: dx, dy: dy, childCounts: Array(repeating: 0, count: n), openParent: nil) != .inner(i) { ok = false; print("  inner n=\(n) i=\(i)") }
                // Flicked far out with no children still picks the same item.
                if RadialGeometry.hit(dx: dx * 4, dy: dy * 4, childCounts: Array(repeating: 0, count: n), openParent: nil) != .inner(i) { ok = false; print("  flick n=\(n) i=\(i)") }
            }
        }
        check("radial: inner hit for 1–8 items, incl. flick", ok)
        ok = true
        for n in [4, 6, 8] {
            for kids in 1...6 {
                var counts = Array(repeating: 0, count: n); counts[1] = kids
                let centers = RadialGeometry.childCenters(parentAngle: RadialGeometry.innerCenter(index: 1, count: n), count: kids)
                for (c, ang) in centers.enumerated() {
                    let a = ang * .pi / 180
                    let hit = RadialGeometry.hit(dx: CGFloat(sin(a)) * 160, dy: CGFloat(-cos(a)) * 160, childCounts: counts, openParent: 1)
                    if hit != .outer(parent: 1, child: c) { ok = false; print("  outer n=\(n) kids=\(kids) c=\(c) got \(hit)") }
                }
            }
        }
        check("radial: outer fan hit for 1–6 children", ok)
        check("radial: hub", RadialGeometry.hit(dx: 10, dy: 10, childCounts: [0, 0, 0], openParent: nil) == .hub)
        check("radial: angle 0 is up", abs(RadialGeometry.angle(dx: 0, dy: -10)) < 0.001 && abs(RadialGeometry.angle(dx: 10, dy: 0) - 90) < 0.001)
    }

    /// Gesture scenarios on the PDF menu (Office at 12 o'clock with Word/Excel/PowerPoint children).
    func testRadialSession() {
        let nodes = ActionCatalog.menu(for: [URL(fileURLWithPath: "/tmp/a.pdf")])
        let c = CGPoint(x: 1000, y: 600)
        func at(_ angle: Double, _ r: CGFloat) -> CGPoint {
            let a = angle * .pi / 180
            return CGPoint(x: c.x + CGFloat(sin(a)) * r, y: c.y - CGFloat(cos(a)) * r)
        }
        var s = RadialSession(nodes: nodes, center: c)
        s.move(to: at(0, 40)); s.move(to: at(0, 85))
        check("gesture: slide up and release → Word (inner segment default)", s.release(at: at(0, 85)) == .choose(Act.toDOCX))

        s = RadialSession(nodes: nodes, center: c)
        for r in stride(from: 20.0, through: 160.0, by: 20.0) { s.move(to: at(0, CGFloat(r))) }
        s.move(to: at(0, 158))
        let excel = s.release(at: at(0, 158))
        check("gesture: slide past the ring → outer middle child (Excel)", excel == .choose(Act.toXLSX), "\(excel)")

        s = RadialSession(nodes: nodes, center: c)
        s.move(to: at(0, 90)); s.move(to: at(0, 150)); s.move(to: at(40, 155))
        check("gesture: swing within the fan → PowerPoint", s.release(at: at(40, 155)) == .choose(Act.toPPTX))

        s = RadialSession(nodes: nodes, center: c)
        let keep = s.release(at: c)
        let crop = nodes.firstIndex { $0.action == Act.editCrop }!
        let cropAngle = RadialGeometry.innerCenter(index: crop, count: nodes.count)
        check("gesture: release in the centre keeps the menu open", keep == .keepOpen && s.sticky)
        check("gesture: then a click on トリミング chooses it", s.contains(at(cropAngle, 80)) && s.release(at: at(cropAngle, 80)) == .choose(Act.editCrop))

        s = RadialSession(nodes: nodes, center: c)
        s.move(to: at(90, 90)); s.move(to: at(90, 10))
        check("gesture: back in the centre shows キャンセル", s.showsCancel)
        check("gesture: out and back to the centre cancels", s.release(at: at(90, 10)) == .cancel)

        s = RadialSession(nodes: nodes, center: c)
        s.move(to: at(0, 10))
        check("gesture: right after the press the centre shows no キャンセル", !s.showsCancel)
        s.move(to: at(0, 85))
        check("gesture: on an item no キャンセル", !s.showsCancel)

        s = RadialSession(nodes: nodes, center: c)
        let more = nodes.firstIndex { $0.action == nil }!
        let moreAngle = RadialGeometry.innerCenter(index: more, count: nodes.count)
        let r1 = s.release(at: at(moreAngle, 80))
        check("gesture: その他 (no default) opens its children and stays", r1 == .keepOpen && s.openParent == more)
        let kids = RadialGeometry.childCenters(parentAngle: moreAngle, count: nodes[more].children.count)
        check("gesture: then a click on its first child chooses it", s.release(at: at(kids[0], 158)) == .choose(nodes[more].children[0].action!))

        s = RadialSession(nodes: nodes, center: c)
        s.move(to: at(0, 80))
        check("gesture: resting on Office reveals its children", s.dwell(on: 0) && s.openParent == 0)
        check("gesture: far outside is not on the menu", !s.contains(at(200, 260)))
        let edge = RadialSession.clampedCenter(for: CGPoint(x: 5, y: 5))
        check("gesture: menu near a screen corner is moved fully on screen", edge.x >= RadialGeometry.outerEnd && edge.y >= RadialGeometry.outerEnd)

        // Ring moved inward from a press at the screen corner; the pointer stays at the corner.
        let corner = CGPoint(x: c.x - 180, y: c.y - 200)
        s = RadialSession(nodes: nodes, center: c, origin: corner)
        check("edge: pointer left where it was does not hover anything", !s.move(to: CGPoint(x: corner.x + 3, y: corner.y + 2)) && s.hit == .hub)
        check("edge: releasing the long press keeps the menu open", s.release(at: CGPoint(x: corner.x + 3, y: corner.y + 2)) == .keepOpen && s.sticky)
        check("edge: then a click on トリミング chooses it", s.contains(at(cropAngle, 80)) && s.release(at: at(cropAngle, 80)) == .choose(Act.editCrop))

        s = RadialSession(nodes: nodes, center: c, origin: corner)
        s.move(to: CGPoint(x: corner.x + 20, y: corner.y + 20))
        check("edge: moving off the ring is no flick", s.hit == .hub)
        check("edge: off the ring is not the centre (no キャンセル)", !s.showsCancel)
        s.move(to: c)
        check("edge: moving onto the centre shows キャンセル", s.showsCancel)
        s.move(to: CGPoint(x: corner.x + 20, y: corner.y + 20))
        check("edge: released off the ring stays open", s.release(at: CGPoint(x: corner.x + 20, y: corner.y + 20)) == .keepOpen)

        s = RadialSession(nodes: nodes, center: c, origin: corner)
        s.move(to: at(315, 150)); s.move(to: at(0, 85))
        check("edge: dragging onto an item and releasing chooses it", s.release(at: at(0, 85)) == .choose(Act.toDOCX))
    }

    func testCatalog() {
        let kinds = ["a.pdf", "a.png", "a.docx", "a.rtf", "a.md", "a.txt", "a.html", "a.xlsx", "a.csv", "a.pptx"]
        var ok = true
        for k in kinds {
            let nodes = ActionCatalog.menu(for: [URL(fileURLWithPath: "/tmp/" + k)])
            if nodes.isEmpty || nodes.count > 8 { ok = false; print("  \(k): \(nodes.count) items") }
            for n in nodes where n.children.count > 6 { ok = false; print("  \(k)/\(n.id): \(n.children.count) children") }
        }
        check("catalog: 1–8 ring items, ≤6 children for every kind", ok)
        let ids = ActionCatalog.allActionIDs
        check("catalog: tags round-trip", ids.allSatisfy { ActionCatalog.action(forTag: ActionCatalog.tag(for: $0)) == $0 })
    }

    func testDocuments(_ md: URL, _ pdf: URL) async {
        // Markdown structure
        let model = MarkdownReader.model(from: markdown)
        let tables = model.blocks.compactMap { b -> DocTable? in if case .table(let t) = b { return t }; return nil }
        let t = tables.first
        check("md: table parsed as 3×3 with header", tables.count == 1 && t?.rows.count == 3 && t?.rows.first?.map(\.text) == ["店舗", "売上", "前月比"] && t?.headerRows == 1,
              "\(t?.rows.map { $0.map(\.text) } ?? [])")
        let headings = model.blocks.compactMap { b -> Int? in if case .heading(let l, _) = b { return l }; return nil }
        check("md: headings 1,2,2", headings == [1, 2, 2], "\(headings)")
        let lists = model.blocks.compactMap { b -> DocListItem? in if case .listItem(let li) = b { return li }; return nil }
        check("md: list items (2 bullets, 1 nested, 2 numbered)", lists.count == 5 && lists.filter(\.ordered).count == 2 && lists.contains { $0.level == 1 },
              "\(lists.map { ($0.ordered, $0.level, $0.paragraph.plainText) })")

        // Markdown out
        for target in ["pdf", "docx", "html", "txt", "rtf"] {
            switch await run("to.\(target)", [md]) {
            case .success(let r):
                let out = r.outputs.first!
                var ok = exists(out) && size(out) > 100
                if target == "pdf" { ok = ok && pdfText(out).contains("月次報告書") }
                if target == "docx" { ok = ok && textutil(out).contains("売上の概要") }
                if target == "html" { ok = ok && ((try? String(contentsOf: out, encoding: .utf8)) ?? "").contains("<table>") }
                if target == "rtf" { ok = ok && textutil(out).contains("東京") }
                check("md → \(target)", ok, out.lastPathComponent)
            case .failure(let e): check("md → \(target)", false, errText(e))
            }
        }
        // PDF out
        for target in ["docx", "md", "txt", "html", "rtf", "xlsx", "pptx", "png", "jpeg", "heic", "tiff"] {
            let t0 = Date()
            switch await run("to.\(target)", [pdf]) {
            case .success(let r):
                let out = r.outputs.first!
                var ok = exists(out)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: out.path, isDirectory: &isDir)
                if ["png", "jpeg", "heic", "tiff"].contains(target) {
                    let n = (try? FileManager.default.contentsOfDirectory(atPath: out.path).count) ?? 0
                    ok = ok && isDir.boolValue && n == 3
                }
                if target == "docx" { ok = ok && textutil(out).contains("売上") }
                if target == "md" {
                    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
                    // Whole paragraph survives (no line lost to header/footer removal), structure kept.
                    ok = ok && text.contains("売上") && text.contains("日本語と English が混ざった段落") && text.contains("# 月次報告書")
                        && text.contains("| 東京 |") && text.contains("1. 原因を調べる")
                }
                check("pdf → \(target) (\(String(format: "%.2fs", Date().timeIntervalSince(t0))))", ok, out.lastPathComponent)
            case .failure(let e): check("pdf → \(target)", false, errText(e))
            }
        }
        // docx we produced → pdf / md
        let docx = md.deletingLastPathComponent().appendingPathComponent("報告書.docx")
        for target in ["pdf", "md", "html"] {
            switch await run("to.\(target)", [docx]) {
            case .success(let r): check("docx → \(target)", exists(r.outputs[0]) && size(r.outputs[0]) > 100)
            case .failure(let e): check("docx → \(target)", false, errText(e))
            }
        }
        // html → md, rtf → docx
        let html = md.deletingLastPathComponent().appendingPathComponent("報告書.html")
        switch await run("to.md", [html]) {
        case .success(let r): check("html → md", ((try? String(contentsOf: r.outputs[0], encoding: .utf8)) ?? "").contains("東京"))
        case .failure(let e): check("html → md", false, errText(e))
        }
        // Remote resources in HTML are never fetched (the reader doesn't use WebKit).
        let remote = md.deletingLastPathComponent().appendingPathComponent("remote.html")
        try? "<html><head><meta charset=\"utf-8\"><link rel=stylesheet href=\"https://example.invalid/a.css\"></head><body><h1>見出し</h1><p>本文 <img src=\"https://example.invalid/x.png\"></p><ol start=3><li>三</li><li>四</li></ol></body></html>".write(to: remote, atomically: true, encoding: .utf8)
        let t0 = Date()
        switch await run("to.md", [remote]) {
        case .success(let r):
            let text = (try? String(contentsOf: r.outputs[0], encoding: .utf8)) ?? ""
            check("html with remote image: no fetch, text kept, list starts at 3", text.contains("# 見出し") && text.contains("3. 三") && !text.contains("![") && Date().timeIntervalSince(t0) < 1, text)
        case .failure(let e): check("html with remote image", false, errText(e))
        }
        // XHTML with an XML declaration and non-ASCII text.
        let xhtml = "\u{FEFF}\n<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>題</title></head><body><h1>見出し</h1><p>東京は晴れ</p></body></html>"
        if let hm = try? HTMLReader.model(from: Data(xhtml.utf8)) {
            check("xhtml with xml declaration reads back", hm.plainText.contains("見出し") && hm.plainText.contains("東京は晴れ") && !hm.plainText.contains("<?xml"), hm.plainText)
        } else { check("xhtml with xml declaration reads back", false, "throws") }
        // Markdown table with an empty middle cell keeps columns aligned.
        let gaps = MarkdownReader.model(from: "| A | B | C |\n|---|---|---|\n| 1 |  | 3 |\n| 4 | 5 | 6 |\n")
        let gapTable = gaps.blocks.compactMap { b -> DocTable? in if case .table(let t) = b { return t }; return nil }.first
        check("md: empty middle cell keeps columns aligned", gapTable?.rows.map { $0.map(\.text) } == [["A", "B", "C"], ["1", "", "3"], ["4", "5", "6"]],
              "\(gapTable?.rows.map { $0.map(\.text) } ?? [])")
        let rtf = md.deletingLastPathComponent().appendingPathComponent("報告書.rtf")
        switch await run("to.docx", [rtf]) {
        case .success(let r): check("rtf → docx", textutil(r.outputs[0]).contains("大阪"))
        case .failure(let e): check("rtf → docx", false, errText(e))
        }
        // Copy text
        switch await run(Act.copyText, [pdf]) {
        case .success(let r): check("copy text from pdf", (r.clipboardText ?? "").contains("月次報告書"))
        case .failure(let e): check("copy text from pdf", false, errText(e))
        }
        // pptx made from the PDF → text extraction of images
        let pptx = pdf.deletingLastPathComponent().appendingPathComponent("報告書.pptx")
        switch await run(Act.pdfExtractImages, [pptx]) {
        case .success(let r): check("pptx → extract images", (try? FileManager.default.contentsOfDirectory(atPath: r.outputs[0].path).count) == 3)
        case .failure(let e): check("pptx → extract images", false, errText(e))
        }
    }

    func testPDFOps(_ pdf: URL, _ big: URL, _ png: URL) async {
        let d = fresh("pdfops")
        let src = d.appendingPathComponent("doc.pdf")
        try? FileManager.default.copyItem(at: pdf, to: src)

        switch await run(Act.pdfRotateRight, [src]) {
        case .success(let r):
            check("pdf rotate right (in place)", PDFDocument(url: src)?.page(at: 0)?.rotation == 90 && r.backups.count == 1)
            try? SafeWrite.restore(r.backups[0])
            check("pdf rotate undo", PDFDocument(url: src)?.page(at: 0)?.rotation == 0)
        case .failure(let e): check("pdf rotate right", false, errText(e))
        }
        switch await run(Act.pdfSplit, [src]) {
        case .success(let r): check("pdf split", (try? FileManager.default.contentsOfDirectory(atPath: r.outputs[0].path).count) == 3)
        case .failure(let e): check("pdf split", false, errText(e))
        }
        let pngCopy = d.appendingPathComponent("z.png")
        try? FileManager.default.copyItem(at: png, to: pngCopy)
        switch await run(Act.combineToPDF, [src, pngCopy]) {
        case .success(let r): check("combine pdf + image", PDFDocument(url: r.outputs[0])?.pageCount == 4)
        case .failure(let e): check("combine pdf + image", false, errText(e))
        }
        let bigCopy = d.appendingPathComponent("big.pdf")
        try? FileManager.default.copyItem(at: big, to: bigCopy)
        for (a, name) in [(Act.pdfCompressLight, "light"), (Act.pdfCompressStandard, "standard"), (Act.pdfCompressStrong, "strong")] {
            switch await run(a, [bigCopy]) {
            case .success(let r): check("pdf compress \(name): \(r.detail ?? "")", size(r.outputs[0]) < size(bigCopy))
            case .failure(let e):
                if case EngineError.noGain = e { skip("pdf compress \(name)", "no gain on this file") } else { check("pdf compress \(name)", false, errText(e)) }
            }
        }
        var o = EngineOptions(); o.password = "pw1234"
        switch await run(Act.pdfEncrypt, [src], options: o) {
        case .success(let r):
            let doc = PDFDocument(url: r.outputs[0])
            check("pdf encrypt", doc?.isEncrypted == true && doc?.isLocked == true && doc?.unlock(withPassword: "pw1234") == true)
            switch await run(Act.pdfDecrypt, [r.outputs[0]], options: o) {
            case .success(let r2): check("pdf decrypt", PDFDocument(url: r2.outputs[0])?.isLocked == false)
            case .failure(let e): check("pdf decrypt", false, errText(e))
            }
            var bad = EngineOptions(); bad.password = "nope"
            if case .failure = await run(Act.pdfDecrypt, [r.outputs[0]], options: bad) { check("pdf decrypt wrong password fails", true) } else { check("pdf decrypt wrong password fails", false) }
        case .failure(let e): check("pdf encrypt", false, errText(e))
        }
        switch await run(Act.pdfPageNumbers, [src]) {
        case .success(let r): check("pdf page numbers", pdfText(r.outputs[0]).contains("2 / 3"))
        case .failure(let e): check("pdf page numbers", false, errText(e))
        }
        var w = EngineOptions(); w.watermarkText = "社外秘"
        switch await run(Act.pdfWatermark, [src], options: w) {
        case .success(let r): check("pdf watermark", pdfText(r.outputs[0]).contains("社外秘") && pdfText(r.outputs[0]).contains("月次報告書"))
        case .failure(let e): check("pdf watermark", false, errText(e))
        }
        switch await run(Act.pdfFlatten, [src]) {
        case .success(let r): check("pdf flatten", PDFDocument(url: r.outputs[0])?.pageCount == 3)
        case .failure(let e): check("pdf flatten", false, errText(e))
        }
        // Scanned PDF: a page that is only an image → OCR.
        let scan = d.appendingPathComponent("scan.pdf")
        let sd = PDFDocument()
        if let page = PDFPage(image: NSImage(cgImage: textImage("請求書\n合計金額 12,345円"), size: NSSize(width: 600, height: 280))) { sd.insert(page, at: 0) }
        sd.write(to: scan)
        switch await run(Act.pdfOCR, [scan]) {
        case .success(let r): check("pdf OCR makes text searchable", pdfText(r.outputs[0]).contains("請求書"), pdfText(r.outputs[0]))
        case .failure(let e):
            if case EngineError.unsupported = e { skip("pdf OCR", "EnsoPDF not linked yet") } else { check("pdf OCR", false, errText(e)) }
        }
        switch await run(Act.copyText, [scan]) {
        case .success(let r): check("copy text from scanned pdf (OCR)", (r.clipboardText ?? "").contains("請求書"))
        case .failure(let e): check("copy text from scanned pdf (OCR)", false, errText(e))
        }
    }

    func testImages(_ png: URL, _ jpg: URL, _ ocr: URL) async {
        let d = fresh("images")
        let p = d.appendingPathComponent("図.png"), j = d.appendingPathComponent("写真.jpg"), t = d.appendingPathComponent("請求書.png")
        for (a, b) in [(png, p), (jpg, j), (ocr, t)] { try? FileManager.default.copyItem(at: a, to: b) }

        check("fixture: jpeg displays upright with red top-left", topLeftIsRed(j) == false || topLeftIsRed(j) == true)
        let before = topLeftIsRed(j)
        for target in ["jpeg", "heic", "tiff", "pdf", "png"] {
            switch await run("to.\(target)", [p]) {
            case .success(let r): check("png → \(target)", exists(r.outputs[0]) && size(r.outputs[0]) > 100, r.outputs[0].lastPathComponent)
            case .failure(let e): check("png → \(target)", false, errText(e))
            }
        }
        switch await run("to.png", [j]) {
        case .success(let r): check("jpeg → png keeps orientation", topLeftIsRed(r.outputs[0]) == before)
        case .failure(let e): check("jpeg → png", false, errText(e))
        }
        // Rotate right four times returns to the start; once moves red from top-left.
        switch await run(Act.imgRotateRight, [p]) {
        case .success: check("png rotate right changes orientation", topLeftIsRed(p) == false)
        case .failure(let e): check("png rotate right", false, errText(e))
        }
        for _ in 0..<3 { _ = await run(Act.imgRotateRight, [p]) }
        check("png rotate right ×4 is identity", topLeftIsRed(p) == true)
        _ = await run(Act.imgFlipH, [p])
        check("png flip horizontal moves red to the right", topLeftIsRed(p) == false)
        _ = await run(Act.imgFlipH, [p])
        check("png flip horizontal twice is identity", topLeftIsRed(p) == true)
        _ = await run(Act.imgFlipV, [p]); _ = await run(Act.imgFlipV, [p])
        check("png flip vertical twice is identity", topLeftIsRed(p) == true)
        _ = await run(Act.imgRotateLeft, [j]); _ = await run(Act.imgRotateRight, [j])
        check("jpeg rotate left then right is identity", topLeftIsRed(j) == before)

        await testOrientationMatrix(d)

        switch await run(Act.imgResize50, [j]) {
        case .success(let r):
            let src = CGImageSourceCreateWithURL(r.outputs[0] as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            check("jpeg resize 50% (\(w)×\(h))", max(w, h) == 200 && topLeftIsRed(r.outputs[0]) == before)
        case .failure(let e): check("jpeg resize 50%", false, errText(e))
        }
        switch await run(Act.imgStripMetadata, [j]) {
        case .success:
            let src = CGImageSourceCreateWithURL(j as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            check("jpeg strip metadata removes GPS", props[kCGImagePropertyGPSDictionary] == nil && topLeftIsRed(j) == before)
        case .failure(let e): check("jpeg strip metadata", false, errText(e))
        }
        switch await run(Act.imgCompressStandard, [j]) {
        case .success(let r): check("jpeg compress: \(r.detail ?? "")", size(r.outputs[0]) < size(j))
        case .failure(let e): if case EngineError.noGain = e { skip("jpeg compress", "already small") } else { check("jpeg compress", false, errText(e)) }
        }
        switch await run(Act.imgOCR, [t]) {
        case .success(let r):
            let text = (try? String(contentsOf: r.outputs[0], encoding: .utf8)) ?? ""
            check("image OCR (Japanese)", text.contains("請求書") && text.contains("12,345"), text)
        case .failure(let e): check("image OCR", false, errText(e))
        }
        // A real subject: one of the system's account pictures, if present.
        let pics = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/User Pictures/Animals")) ?? []
        if let pic = pics.first(where: { $0.hasSuffix(".heic") || $0.hasSuffix(".png") || $0.hasSuffix(".jpg") || $0.hasSuffix(".tif") }) {
            let animal = d.appendingPathComponent("animal." + (pic as NSString).pathExtension)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/Library/User Pictures/Animals/" + pic).resolvingSymlinksInPath(), to: animal)
            switch await run(Act.imgRemoveBackground, [animal]) {
            case .success(let r):
                // Corners should now be transparent.
                let src = CGImageSourceCreateWithURL(r.outputs[0] as CFURL, nil)
                let img = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                let corner = img.map { pixel($0, x: 2, yFromTop: 2).a } ?? 255
                check("remove background (\(pic)) → transparent corners", corner < 20, "alpha \(corner)")
            case .failure(let e): check("remove background (\(pic))", false, errText(e))
            }
        } else {
            skip("remove background", "no sample photo with a subject")
        }
        // Several images → one PDF
        switch await run(Act.combineToPDF, [p, j]) {
        case .success(let r): check("images → one PDF", PDFDocument(url: r.outputs[0])?.pageCount == 2)
        case .failure(let e): check("images → one PDF", false, errText(e))
        }
    }

    /// Every stored orientation × every operation, checked on pixels of the displayed result.
    func testOrientationMatrix(_ d: URL) async {
        func quads(_ url: URL) -> String? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 200]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            func c(_ x: Int, _ y: Int) -> String {
                let p = pixel(img, x: x, yFromTop: y)
                return p.r > 150 && p.g < 100 ? "R" : p.g > 150 && p.r < 100 && p.b < 100 ? "G" : p.b > 150 && p.r < 100 ? "B" : "W"
            }
            let w = img.width, h = img.height
            return c(w / 4, h / 4) + c(3 * w / 4, h / 4) + c(w / 4, 3 * h / 4) + c(3 * w / 4, 3 * h / 4) // TL TR BL BR
        }
        func expected(_ q: String, _ op: String) -> String {
            let a = Array(q) // TL TR BL BR
            switch op {
            case Act.imgRotateRight: return String([a[2], a[0], a[3], a[1]])
            case Act.imgRotateLeft: return String([a[1], a[3], a[0], a[2]])
            case Act.imgFlipH: return String([a[1], a[0], a[3], a[2]])
            default: return String([a[2], a[3], a[0], a[1]])
            }
        }
        // Stored pixels: red TL, green TR, blue BL, white BR (CG origin bottom-left).
        let w = 120, h = 80
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        let stored = ctx.makeImage()!
        var bad: [String] = []
        for o in 1...8 {
            for op in [Act.imgRotateRight, Act.imgRotateLeft, Act.imgFlipH, Act.imgFlipV] {
                for ext in ["jpg", "png"] {
                    let f = d.appendingPathComponent("o\(o)-\(op).\(ext)")
                    try? FileManager.default.removeItem(at: f)
                    try? writeImage(stored, to: f, type: ext == "jpg" ? .jpeg : .png, extra: [kCGImagePropertyOrientation: o])
                    guard let before = quads(f) else { bad.append("read o\(o)"); continue }
                    _ = await run(op, [f])
                    let after = quads(f) ?? "?"
                    if after != expected(before, op) { bad.append("\(ext) o\(o) \(op): \(before)→\(after) want \(expected(before, op))") }
                }
            }
        }
        check("orientation: 8 orientations × 4 operations × JPEG/PNG", bad.isEmpty, bad.prefix(6).joined(separator: "; "))
    }

    func testSheets() async {
        let d = fresh("sheets")
        let csv = d.appendingPathComponent("売上.csv")
        try? "店舗,売上,前月比\n東京,\"1,234\",12.5%\n大阪,987,0%\n\"名古屋, 本店\",500,-3%\n".write(to: csv, atomically: true, encoding: .utf8)
        switch await run("to.xlsx", [csv]) {
        case .success(let r):
            check("csv → xlsx", exists(r.outputs[0]))
            for target in ["csv", "pdf", "md", "html", "docx"] {
                switch await run("to.\(target)", [r.outputs[0]]) {
                case .success(let r2):
                    var ok = exists(r2.outputs[0])
                    if target == "md" { ok = ok && ((try? String(contentsOf: r2.outputs[0], encoding: .utf8)) ?? "").contains("名古屋, 本店") }
                    if target == "pdf" { ok = ok && pdfText(r2.outputs[0]).contains("東京") }
                    check("xlsx → \(target)", ok)
                case .failure(let e): check("xlsx → \(target)", false, errText(e))
                }
            }
        case .failure(let e): check("csv → xlsx", false, errText(e))
        }
    }

    /// Ink paths must be stored relative to the annotation origin (checked by rendering).
    func testInkAnnotation() async {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
        let strokes: [[CGPoint]] = [[CGPoint(x: 120, y: 120), CGPoint(x: 180, y: 180)]]
        let all = strokes.flatMap { $0 }
        let bounds = CGRect(x: all.map(\.x).min()!, y: all.map(\.y).min()!, width: 60, height: 60).insetBy(dx: -4, dy: -4)
        let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        a.color = .red
        let b = PDFBorder(); b.lineWidth = 4; a.border = b
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 120 - bounds.minX, y: 120 - bounds.minY))
        path.line(to: CGPoint(x: 180 - bounds.minX, y: 180 - bounds.minY))
        a.add(path)
        page.addAnnotation(a)
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        page.draw(with: .mediaBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        let img = ctx.makeImage()!
        let onLine = pixel(img, x: 150, yFromTop: 50)     // (150,150) in PDF space
        let offLine = pixel(img, x: 60, yFromTop: 140)
        check("ink annotation drawn where the stroke was", onLine.r > 150 && onLine.g < 120 && offLine.g > 200, "\(onLine) \(offLine)")
    }

    // MARK: Security

    func docxPackage(document: String, rels: String = "", extra: [(String, Data)] = []) throws -> Data {
        let z = ZipWriter()
        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        try z.add(path: "[Content_Types].xml", text: "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>")
        try z.add(path: "_rels/.rels", text: "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>")
        try z.add(path: "word/document.xml", text: document.replacingOccurrences(of: "__NS__", with: ns))
        try z.add(path: "word/_rels/document.xml.rels", text: "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>")
        for (path, data) in extra { try z.add(path: path, data: data) }
        return try z.finalize()
    }

    func testSecurity() {
        let d = fresh("security")
        // DOCTYPE in an OOXML part is refused (docx and xlsx).
        let evil = "<?xml version=\"1.0\"?><!DOCTYPE w:document [<!ENTITY x SYSTEM \"file:///etc/hosts\">]><w:document __NS__><w:body><w:p><w:r><w:t>&x;</w:t></w:r></w:p></w:body></w:document>"
        do {
            let url = d.appendingPathComponent("doctype.docx")
            try docxPackage(document: evil).write(to: url)
            do { _ = try DocxDocument(url: url); check("docx with DOCTYPE is rejected", false) } catch { check("docx with DOCTYPE is rejected", true) }
            let lower = evil.replacingOccurrences(of: "DOCTYPE", with: "doctype")
            let url2 = d.appendingPathComponent("doctype2.docx")
            try docxPackage(document: lower).write(to: url2)
            do { _ = try DocxDocument(url: url2); check("docx with lower-case doctype is rejected", false) } catch { check("docx with lower-case doctype is rejected", true) }
        } catch { check("docx with DOCTYPE is rejected", false, "\(error)") }
        do {
            let z = ZipWriter()
            try z.add(path: "xl/workbook.xml", text: "<?xml version=\"1.0\"?><!DOCTYPE workbook [<!ENTITY x \"y\">]><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheets/></workbook>")
            do { _ = try XlsxReader.read(data: try z.finalize()); check("xlsx with DOCTYPE is rejected", false) } catch { check("xlsx with DOCTYPE is rejected", true) }
        } catch { check("xlsx with DOCTYPE is rejected", false, "\(error)") }

        // Hyperlinks: only http/https/mailto become clickable; the relationship id is kept for saving.
        do {
            let body = "<?xml version=\"1.0\"?><w:document __NS__><w:body><w:p><w:hyperlink r:id=\"rId10\"><w:r><w:t>local</w:t></w:r></w:hyperlink><w:r><w:t> </w:t></w:r><w:hyperlink r:id=\"rId11\"><w:r><w:t>web</w:t></w:r></w:hyperlink></w:p></w:body></w:document>"
            let rels = "<Relationship Id=\"rId10\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"file:///etc/passwd\" TargetMode=\"External\"/><Relationship Id=\"rId11\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"https://example.com/\" TargetMode=\"External\"/>"
            let url = d.appendingPathComponent("links.docx")
            try docxPackage(document: body, rels: rels).write(to: url)
            let doc = try DocxDocument(url: url)
            let text = doc.attributed.string as NSString
            let local = doc.attributed.attributes(at: text.range(of: "local").location, effectiveRange: nil)
            let web = doc.attributed.attributes(at: text.range(of: "web").location, effectiveRange: nil)
            check("docx hyperlink to file:// gets no .link", local[.link] == nil)
            check("docx file:// hyperlink keeps its relationship id", (local[.docxLinkID] as? String) == "rId10")
            check("docx https hyperlink gets a .link", (web[.link] as? URL)?.absoluteString == "https://example.com/")
        } catch { check("docx hyperlink schemes", false, "\(error)") }
        check("LinkPolicy: http/https/mailto only",
              LinkPolicy.openableURL("mailto:a@b.c") != nil && LinkPolicy.openableURL("HTTP://x.y") != nil
              && LinkPolicy.openableURL("smb://h/s") == nil && LinkPolicy.openableURL("javascript:alert(1)") == nil && LinkPolicy.openableURL("file:///etc/passwd") == nil)

        do {
            let md = "[rel](docs/a.html) [top](#top) [web](https://example.com/) [file](file:///etc/passwd) [js](javascript:alert(1))"
            let html = HTMLWriter.string(from: MarkdownReader.model(from: md))
            check("markdown to html keeps relative and fragment links",
                  html.contains("href=\"docs/a.html\"") && html.contains("href=\"#top\"") && html.contains("href=\"https://example.com/\""))
            check("markdown to html still drops file: and javascript: links", !html.contains("file:") && !html.contains("javascript:"))
        }

        // HTML: images outside the document's folder are not embedded.
        do {
            let sub = d.appendingPathComponent("site", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let png = rep.representation(using: .png, properties: [:])!
            let secret = d.appendingPathComponent("secret.png")
            try png.write(to: secret)
            try png.write(to: sub.appendingPathComponent("ok.png"))
            func images(_ html: String) -> Int {
                guard let m = try? HTMLReader.model(from: Data(html.utf8), baseURL: sub) else { return -1 }
                return m.blocks.reduce(0) { n, b in if case .image = b { return n + 1 }; return n }
            }
            check("html: local image in the same folder is embedded", images("<html><body><img src=\"ok.png\"></body></html>") == 1)
            check("html: ../ image is not embedded", images("<html><body><img src=\"../secret.png\"></body></html>") == 0)
            check("html: absolute path outside the folder is not embedded", images("<html><body><img src=\"\(secret.path)\"><img src=\"file://\(secret.path)\"><img src=\"/etc/hosts\"></body></html>") == 0)
        } catch { check("html image confinement", false, "\(error)") }

        // Markdown: local images follow the same confinement as HTML.
        do {
            let sub = d.appendingPathComponent("mdsite", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let png = rep.representation(using: .png, properties: [:])!
            let secret = d.appendingPathComponent("secret.png")
            try png.write(to: secret)
            try png.write(to: sub.appendingPathComponent("ok.png"))
            try FileManager.default.createSymbolicLink(at: sub.appendingPathComponent("link.png"), withDestinationURL: secret)
            func mdImages(_ md: String) -> Int {
                MarkdownReader.model(from: md, baseURL: sub).blocks.reduce(0) { n, b in if case .image = b { return n + 1 }; return n }
            }
            check("markdown: local image in the same folder is embedded", mdImages("![](ok.png)") == 1)
            check("markdown: ../ image is not embedded", mdImages("![](../secret.png)") == 0)
            check("markdown: file:// image is not embedded", mdImages("![](file:///etc/hosts)") == 0 && mdImages("![](file://\(secret.path))") == 0)
            check("markdown: absolute path and symlink out of the folder are not embedded", mdImages("![](\(secret.path))") == 0 && mdImages("![](link.png)") == 0)
            check("markdown: images without a base folder are not embedded", MarkdownReader.model(from: "![](\(secret.path))").blocks.allSatisfy { if case .image = $0 { return false }; return true })
        } catch { check("markdown image confinement", false, "\(error)") }

        // HTML export: dangerous link schemes are dropped, the text stays.
        let linkModel = DocModel(title: nil, blocks: [.paragraph(DocParagraph([
            DocRun("bad", link: "javascript:alert(1)"), DocRun("ugly", link: "java\nscript:alert(1)"), DocRun("data", link: "data:text/html,x"),
            DocRun("web", link: "https://example.com/a"), DocRun("rel", link: "docs/a.html"), DocRun("frag", link: "#top"),
        ]))], pageSize: CGSize(width: 595, height: 842))
        let html = HTMLWriter.string(from: linkModel)
        check("html writer drops javascript:/data: links, keeps text", !html.contains("javascript") && !html.contains("java\nscript") && !html.contains("data:text") && html.contains("bad") && html.contains("ugly"))
        check("html writer keeps http, relative and fragment links", html.contains("href=\"https://example.com/a\"") && html.contains("href=\"docs/a.html\"") && html.contains("href=\"#top\""))

        // marudoc:// token handling.
        let req = Bridge.Request(action: "to.pdf", files: [URL(fileURLWithPath: "/tmp/a.pdf")], mouse: nil, token: "abc")
        check("bridge url carries the token", Bridge.url(for: req).flatMap(Bridge.request(from:))?.token == "abc")
        // One fixed throwaway domain, emptied before and removed after. cfprefsd keeps an empty plist even after the
        // domain is removed, so the file is deleted too and a run leaves nothing in ~/Library/Preferences.
        let tokenDomain = "app.marudoc.selftest"
        UserDefaults.standard.removePersistentDomain(forName: tokenDomain)
        Bridge.testGroupOverride = tokenDomain
        defer {
            Bridge.testGroupOverride = nil
            UserDefaults.standard.removePersistentDomain(forName: tokenDomain)
            CFPreferencesAppSynchronize(tokenDomain as CFString)
            let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(tokenDomain).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        if let t0 = Bridge.prepareToken() {
            let t0req = Bridge.Request(action: "to.pdf", files: [], token: t0)
            let now = Date()
            check("bridge accepts the stored token", Bridge.isAuthentic(t0req, now: now))
            check("bridge rotates the token after accepting a request", Bridge.authenticateAndRotate(t0req, now: now) && Bridge.storedToken() != t0 && Bridge.storedToken() != nil)
            check("bridge still accepts the previous token within 5 seconds", Bridge.isAuthentic(t0req, now: now.addingTimeInterval(4)))
            check("bridge rejects the previous token after 5 seconds", !Bridge.isAuthentic(t0req, now: now.addingTimeInterval(6)))
            let t1 = Bridge.storedToken()
            check("bridge does not rotate again for a previous-token request", Bridge.authenticateAndRotate(t0req, now: now.addingTimeInterval(1)) && Bridge.storedToken() == t1)
        } else { skip("bridge token rotation", "no App Group defaults here") }
        check("bridge request without token is not authentic", !Bridge.isAuthentic(Bridge.Request(action: "to.pdf", files: [])))
    }

    // MARK: Hardening against crashes and blow-ups

    func le(_ v: UInt64, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((v >> UInt64(8 * $0)) & 0xFF) } }

    /// One stored entry "a" whose central-directory record carries a hostile ZIP64 size.
    func hostileZip(csize64: UInt64) -> Data {
        var local: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 22) + le(1, 2) + le(0, 2) + [0x61]
        local += [0x78]
        var cd: [UInt8] = [0x50, 0x4B, 0x01, 0x02] + le(20, 2) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2)
        cd += le(0, 4) + le(0xFFFF_FFFF, 4) + le(1, 4) + le(1, 2) + le(12, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4)
        cd += [0x61] + le(1, 2) + le(8, 2) + le(csize64, 8)
        let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + le(0, 2) + le(0, 2) + le(1, 2) + le(1, 2) + le(UInt64(cd.count), 4) + le(UInt64(local.count), 4) + le(0, 2)
        return Data(local + cd + eocd)
    }

    func testHardening() {
        let d = fresh("hardening")
        // ZIP64: locator pointing near Int.max, and a compressed size of Int.max, must throw instead of trapping.
        let locator: [UInt8] = [0x50, 0x4B, 0x06, 0x07] + le(0, 4) + le(0x7FFF_FFFF_FFFF_FFFE, 8) + le(1, 4)
        let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + le(0, 2) + le(0, 2) + le(0xFFFF, 2) + le(0xFFFF, 2) + le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4) + le(0, 2)
        do { _ = try ZipReader(data: Data(locator + eocd)); check("zip64 locator near Int.max is rejected", false) } catch { check("zip64 locator near Int.max is rejected", true) }
        for (name, v) in [("Int.max", UInt64(Int.max)), ("2^40", UInt64(1) << 40)] {
            if let z = try? ZipReader(data: hostileZip(csize64: v)) {
                do { _ = try z.data("a"); check("zip64 compressed size \(name) is rejected", false) } catch { check("zip64 compressed size \(name) is rejected", true) }
            } else { check("zip64 compressed size \(name) is rejected", true) }
        }

        // DOCX: closing </w:body> before <w:body>, runaway ilvl / start / gridSpan, and a quadratic-regex input.
        do {
            let ns = "__NS__"
            let numbering = "<?xml version=\"1.0\"?><w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"9223372036854775807\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/></w:lvl><w:lvl w:ilvl=\"9\"><w:start w:val=\"-9223372036854775808\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"x\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"9223372036854775807\"/></w:lvlOverride></w:num></w:numbering>"
            func para(_ lvl: Int, _ text: String) -> String { "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(lvl)\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
            let table = "<w:tbl><w:tblGrid><w:gridCol w:w=\"1000\"/></w:tblGrid><w:tr><w:tc><w:tcPr><w:gridSpan w:val=\"-5\"/></w:tcPr><w:p><w:r><w:t>neg</w:t></w:r></w:p></w:tc><w:tc><w:tcPr><w:gridSpan w:val=\"9223372036854775807\"/></w:tcPr><w:p><w:r><w:t>huge</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
            let doc = "<?xml version=\"1.0\"?><!-- </w:body> --><w:document \(ns)><w:body>" + para(0, "first") + para(0, "second") + para(9, "deep") + para(-1, "neg") + table + "</w:body></w:document>"
            let z = ZipWriter()
            let ctNS = "http://schemas.openxmlformats.org/package/2006/content-types"
            try z.add(path: "[Content_Types].xml", text: "<?xml version=\"1.0\"?><Types xmlns=\"\(ctNS)\"><Default Extension=\"xml\" ContentType=\"application/xml\"/></Types>")
            try z.add(path: "word/document.xml", text: doc.replacingOccurrences(of: "__NS__", with: "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""))
            try z.add(path: "word/numbering.xml", text: numbering)
            let url = d.appendingPathComponent("hostile.docx")
            try z.finalize().write(to: url)
            let loaded = try? DocxDocument(url: url)
            check("docx with absurd ilvl / start / gridSpan and a stray </w:body> loads without crashing", loaded != nil)
            check("docx list start is clamped to Word's range", loaded?.attributed.string.contains("32768") == true, loaded?.attributed.string ?? "nil")
            let reader = try DocxReader.read(url)
            check("docx reader (DocModel) survives the same numbering", !reader.blocks.isEmpty)
        } catch { check("hostile docx", false, "\(error)") }
        do {
            let junk = String(repeating: "<w:t ", count: 300_000)
            let z = ZipWriter()
            try z.add(path: "word/document.xml", text: "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(junk)</w:body></w:document>")
            let url = d.appendingPathComponent("junk.docx")
            try z.finalize().write(to: url)
            let t0 = Date()
            _ = try? DocxDocument(url: url)
            check("docx with 300k unterminated tags is handled in linear time", Date().timeIntervalSince(t0) < 5)
        } catch { check("docx junk", false, "\(error)") }

        // DOCX: a picture extent of 1e300 EMU, and nan/inf in spacing, must load and save without trapping.
        do {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let png = rep.representation(using: .png, properties: [:])!
            let drawing = "<w:r><w:drawing><wp:inline xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"><wp:extent cx=\"1e300\" cy=\"nan\"/><a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:blipFill><a:blip r:embed=\"rId20\"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
            let body = "<?xml version=\"1.0\"?><w:document __NS__><w:body><w:p><w:pPr><w:spacing w:beforeLines=\"inf\" w:afterLines=\"nan\" w:line=\"1e999\"/><w:ind w:leftChars=\"inf\"/></w:pPr><w:r><w:rPr><w:sz w:val=\"nan\"/></w:rPr><w:t>pic</w:t></w:r>\(drawing)</w:p></w:body></w:document>"
            let rels = "<Relationship Id=\"rId20\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/a.png\"/>"
            let url = d.appendingPathComponent("hugepic.docx")
            try docxPackage(document: body, rels: rels, extra: [("word/media/a.png", png)]).write(to: url)
            let doc = try DocxDocument(url: url)
            var sawImage = false
            doc.attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: doc.attributed.length)) { v, _, _ in if v is DocxImageAttachment { sawImage = true } }
            check("docx with cx=1e300 and nan/inf spacing loads", sawImage)
            try doc.save(doc.attributed, to: d.appendingPathComponent("hugepic-out.docx"))
            check("docx with cx=1e300 saves without crashing", FileManager.default.fileExists(atPath: d.appendingPathComponent("hugepic-out.docx").path))
            // A fresh (non-docx) attachment with an absurd size.
            let att = NSTextAttachment()
            att.image = NSImage(data: png)
            att.bounds = CGRect(x: 0, y: 0, width: 1e300, height: 1e300)
            let edited = NSMutableAttributedString(attributedString: doc.attributed)
            edited.append(NSAttributedString(attachment: att))
            try doc.save(edited, to: d.appendingPathComponent("hugepic-out2.docx"))
            check("docx save with a 1e300-point inserted picture does not crash", FileManager.default.fileExists(atPath: d.appendingPathComponent("hugepic-out2.docx").path))
        } catch { check("docx huge picture extent", false, "\(error)") }

        // HTML: extreme <ol start> values.
        for start in ["-9223372036854775808", "9223372036854775807"] {
            let m = try? HTMLReader.model(from: Data("<html><body><ol start=\"\(start)\"><li>a</li><li>b</li><li>c</li></ol></body></html>".utf8))
            check("html <ol start=\(start)> does not trap", m != nil && !(m?.blocks.isEmpty ?? true))
        }
        // HTML writer: absurd image width.
        let big = DocImage(data: Data([0]), format: .png, pixelWidth: 1, pixelHeight: 1, displayWidth: 1e300, displayHeight: 1)
        check("html writer survives a 1e300 image width", !HTMLWriter.string(from: DocModel(title: nil, blocks: [.image(big)], pageSize: CGSize(width: 1, height: 1))).isEmpty)
        check("SafeInt never traps", SafeInt.floor(1e300) == 1_000_000_000 && SafeInt.floor(-.infinity) == -1_000_000_000 && SafeInt.floor(.nan) == -1_000_000_000 && SafeInt.round(.nan, 0, 7) == 0)
        check("pixel limit rejects huge sizes without overflow", !SafeInt.isReasonablePixelSize(Int.max, 2) && !SafeInt.isReasonablePixelSize(20_000, 20_000) && SafeInt.isReasonablePixelSize(10_000, 10_000))

        // A BMP header that declares 20000 x 20000 pixels (400 MP) is refused before any decoding.
        let bmp = [0x42, 0x4D] as [UInt8] + le(54, 4) + le(0, 4) + le(54, 4) + le(40, 4) + le(20_000, 4) + le(20_000, 4) + le(1, 2) + le(24, 2)
            + le(0, 4) + le(0, 4) + le(2835, 4) + le(2835, 4) + le(0, 4) + le(0, 4) + [UInt8](repeating: 0, count: 3000)
        if let src = CGImageSourceCreateWithData(Data(bmp) as CFData, nil) {
            check("image declaring 400 megapixels is refused", !ImageCodec.isWithinLimits(src) && ImageCodec.decode(Data(bmp)) == nil)
        } else { skip("image declaring 400 megapixels is refused", "ImageIO did not open the header-only BMP") }

        // Markdown export cannot be broken out of.
        let md = MarkdownWriter.string(from: DocModel(title: nil, blocks: [
            .paragraph(DocParagraph([DocRun("a``b <img src=x onerror=alert(1)>", code: true), DocRun(" link", link: "https://e.com/x) <img src=y onerror=1>"), DocRun(" js", link: "javascript:alert(1)")])),
            .code("```\n~~~\n<script>x</script>", language: nil),
        ], pageSize: CGSize(width: 1, height: 1))).text
        check("markdown code span uses a longer delimiter", md.contains("```a``b <img src=x onerror=alert(1)>```"), md)
        check("markdown link destination is wrapped and encoded, javascript: dropped", md.contains("](<https://e.com/x)%20<") == false && md.contains("(<https://e.com/x)%20%3Cimg") && !md.contains("javascript"), md)
        func mdText(_ blocks: [DocBlock]) -> String { MarkdownWriter.string(from: DocModel(title: nil, blocks: blocks, pageSize: CGSize(width: 1, height: 1))).text }
        let esc = mdText([.paragraph(DocParagraph([DocRun("first\n# not heading\n- not list\n+ plus\n2. not ordered\n3) paren\nx ~~gone~~ a & b &amp; ![i](u) | c")])),
                          .quote(DocParagraph([DocRun("q\n# h\n- l")]))])
        check("markdown escapes #, -, +, N. on every line of a paragraph", esc.contains("\n\\# not heading") && esc.contains("\n\\- not list") && esc.contains("\n\\+ plus") && esc.contains("\n2\\. not ordered") && esc.contains("\n3\\) paren"), esc)
        check("markdown escapes ~ & | where they start syntax", esc.contains("\\~\\~gone\\~\\~") && esc.contains("a & b") && esc.contains("\\&amp;") && esc.contains("\\|"), esc)
        check("markdown escapes quoted lines too", esc.contains("> \\# h") && esc.contains("> \\- l"), esc)
        let plain = mdText([.paragraph(DocParagraph([DocRun("Hello, world! Tom & Jerry cost 5-6 yen (a+b). 1.5 times.")]))])
        check("markdown leaves normal text readable", plain == "Hello, world! Tom & Jerry cost 5-6 yen (a+b). 1.5 times.\n", plain)
        let bang = mdText([.paragraph(DocParagraph([DocRun("wow!"), DocRun("site", link: "https://e.com/")]))])
        check("markdown escapes ! before a link", bang.contains("wow\\![site]") , bang)
        let tbl = mdText([.table(DocTable(rows: [[DocTableCell([DocParagraph([DocRun("a|b")])])], [DocTableCell([DocParagraph([DocRun("c")])])]], headerRows: 1))])
        check("markdown table cell pipe is escaped once", tbl.contains("a\\|b") && !tbl.contains("a\\\\|b"), tbl)
        let roundTrip = MarkdownReader.model(from: esc)
        check("escaped markdown reads back as paragraphs, not headings or lists", !roundTrip.blocks.contains { if case .heading = $0 { return true }; if case .listItem = $0 { return true }; return false })
        check("markdown code fence is longer than any backtick run inside", md.contains("````\n```\n~~~"), md)
    }

    func testSpeed() async {
        let d = fresh("speed")
        var model = MarkdownReader.model(from: markdown)
        let blocks = model.blocks
        model.blocks = []
        for _ in 0..<12 { model.blocks += blocks + [.pageBreak] }
        let pdf = d.appendingPathComponent("long.pdf")
        try? PDFRenderer.pdfData(from: model).write(to: pdf)
        let pages = PDFDocument(url: pdf)?.pageCount ?? 0
        let t0 = Date()
        let r = await run("to.docx", [pdf])
        let dt = Date().timeIntervalSince(t0)
        if case .success = r { check("speed: \(pages)-page PDF → Word in \(String(format: "%.2f", dt))s (target < \(max(2, pages / 10 * 2))s)", dt < Double(max(2, pages / 10 * 2))) }
        else { check("speed: long PDF → Word", false) }
    }
}
