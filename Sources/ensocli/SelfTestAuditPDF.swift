import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import EnsoShared
import EnsoDoc
import EnsoCore

/// Checks for the PDF defects of the 2026-11-12 audit (PDF-01, 02, 03, 04, 10, 13 and IMG-07). They only use the
/// engine's existing entry points, so the same file also builds against 1.0.5 and shows the failures there.
extension SelfTest {

    // MARK: Fixtures and helpers

    /// Rotation of each page of `auditRotationFixture`, and whether it has a crop box (not starting at 0,0).
    static let auditRotationPages: [(rotation: Int, cropped: Bool)] = [(0, false), (90, false), (180, false), (270, false), (0, true), (90, true)]

    /// Pages with every /Rotate, some with a crop box. Each has a red square at the visible top-left and a blue one at
    /// the visible bottom-right (unrotated), plus a square annotation and a link in the middle.
    func auditRotationFixture(_ url: URL) {
        let doc = PDFDocument()
        for (i, cfg) in Self.auditRotationPages.enumerated() {
            let media = CGRect(x: 0, y: 0, width: 400, height: 600)
            let v = cfg.cropped ? CGRect(x: 60, y: 120, width: 240, height: 260) : media
            let data = NSMutableData()
            var box = media
            guard let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            if cfg.cropped {   // outside the crop box: must never show
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: v.minX, height: media.height))
            }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: v.minX + v.width * 0.02, y: v.maxY - v.height * 0.22, width: v.width * 0.2, height: v.height * 0.2))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: v.maxX - v.width * 0.22, y: v.minY + v.height * 0.02, width: v.width * 0.2, height: v.height * 0.2))
            ctx.endPDFPage(); ctx.closePDF()
            guard let page = PDFDocument(data: data as Data)?.page(at: 0) else { return }
            if cfg.cropped { page.setBounds(v, for: .cropBox) }
            page.rotation = cfg.rotation
            let sq = PDFAnnotation(bounds: CGRect(x: v.midX - 30, y: v.midY - 15, width: 60, height: 30), forType: .square, withProperties: nil)
            sq.color = .systemGreen
            page.addAnnotation(sq)
            let link = PDFAnnotation(bounds: CGRect(x: v.midX - 30, y: v.midY + 30, width: 60, height: 20), forType: .link, withProperties: nil)
            link.url = URL(string: "https://example.com/p\(i + 1)")
            page.addAnnotation(link)
            doc.insert(page, at: doc.pageCount)
        }
        // An internal link on page 1 to page 3.
        if let first = doc.page(at: 0), let third = doc.page(at: 2) {
            let link = PDFAnnotation(bounds: CGRect(x: 170, y: 250, width: 60, height: 20), forType: .link, withProperties: nil)
            link.action = PDFActionGoTo(destination: PDFDestination(page: third, at: CGPoint(x: 0, y: 600)))
            first.addAnnotation(link)
        }
        doc.write(to: url)
    }

    /// Where the red and the blue square must appear (fraction of width, fraction of height from the top) once the
    /// page is shown turned clockwise by `rotation`.
    func auditCorners(_ rotation: Int) -> (red: (Double, Double), blue: (Double, Double)) {
        switch rotation {
        case 90: return ((0.88, 0.12), (0.12, 0.88))
        case 180: return ((0.88, 0.88), (0.12, 0.12))
        case 270: return ((0.12, 0.88), (0.88, 0.12))
        default: return ((0.12, 0.12), (0.88, 0.88))
        }
    }

    /// True when `img` shows the fixture page with `rotation` the way a viewer does.
    func auditShowsUpright(_ img: CGImage, rotation: Int, cropped: Bool) -> Bool {
        let c = auditCorners(rotation)
        func at(_ p: (Double, Double)) -> String { colorLetter(pixel(img, x: Int(Double(img.width) * p.0), yFromTop: Int(Double(img.height) * p.1))) }
        let visible = cropped ? CGSize(width: 240, height: 260) : CGSize(width: 400, height: 600)
        let landscape = rotation % 180 == 0 ? visible.width > visible.height : visible.height > visible.width
        return at(c.red) == "R" && at(c.blue) == "B" && (img.width > img.height) == landscape
    }

    /// Renders a page with CoreGraphics alone (crop box, /Rotate), independent of the PDFKit drawing under test.
    /// Annotations are not drawn.
    func auditRender(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        let crop = ref.getBoxRect(.cropBox)
        let rot = ((Int(ref.rotationAngle) % 360) + 360) % 360
        let size = rot % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: crop)
        ctx.drawPDFPage(ref)
        return ctx.makeImage()
    }

    /// True when some pixel in the region (fractions of the image, y from the top) is darker than `limit`.
    func auditHasInk(_ img: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>, limit: Int = 170, step: Int = 1) -> Bool {
        let x0 = Int(Double(img.width) * x.lowerBound), x1 = Int(Double(img.width) * x.upperBound) - 1
        let y0 = Int(Double(img.height) * y.lowerBound), y1 = Int(Double(img.height) * y.upperBound) - 1
        guard x1 >= x0, y1 >= y0, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return false }
        let bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
        for yy in stride(from: y0, through: y1, by: step) {
            for xx in stride(from: x0, through: x1, by: step) {
                let i = yy * bpr + xx * bpp
                if Int(p[i]) < limit && Int(p[i + 1]) < limit && Int(p[i + 2]) < limit { return true }
            }
        }
        return false
    }

    /// Image XObjects on a page: filter name, whether it has a soft mask, and the raw bytes when stored as JPEG.
    func auditPageImages(_ url: URL, page n: Int) -> [(filter: String, smask: Bool, jpeg: Data?)] {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: n + 1), let dict = page.dictionary else { return [] }
        var res: CGPDFDictionaryRef?, xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res, CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return [] }
        var out: [(filter: String, smask: Bool, jpeg: Data?)] = []
        CGPDFDictionaryApplyBlock(xo, { _, obj, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let sd = CGPDFStreamGetDictionary(stream) else { return true }
            var sub: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(sd, "Subtype", &sub), let sub, String(cString: sub) == "Image" else { return true }
            var name: UnsafePointer<CChar>?, arr: CGPDFArrayRef?
            var filter = ""
            if CGPDFDictionaryGetName(sd, "Filter", &name), let name { filter = String(cString: name) }
            else if CGPDFDictionaryGetArray(sd, "Filter", &arr), let arr, CGPDFArrayGetName(arr, 0, &name), let name { filter = String(cString: name) }
            var mask: CGPDFStreamRef?
            let smask = CGPDFDictionaryGetStream(sd, "SMask", &mask)
            var format = CGPDFDataFormat.raw
            let bytes = CGPDFStreamCopyData(stream, &format) as Data?
            out.append((filter, smask, format == .jpegEncoded ? bytes : nil))
            return true
        }, nil)
        return out
    }

    func auditFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// The same picture turned a quarter to the left, so that /Rotate 90 shows it upright.
    func auditTurnedLeft(_ img: CGImage) -> CGImage {
        let ctx = CGContext(data: nil, width: img.height, height: img.width, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.translateBy(x: CGFloat(img.height), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()!
    }

    // MARK: Checks

    func testAuditPDF() async {
        let d = fresh("audit-pdf")
        let fm = FileManager.default
        let rotated = d.appendingPathComponent("回転.pdf")
        auditRotationFixture(rotated)
        let pages = Self.auditRotationPages

        // PDF-01: rotated and cropped pages as images.
        switch await run("to.png", [rotated]) {
        case .success(let r):
            let folder = r.outputs[0]
            let names = auditFiles(folder).filter { $0.hasSuffix(".png") }
            var bad: [Int] = []
            for (i, name) in names.enumerated() where i < pages.count {
                guard let src = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      auditShowsUpright(img, rotation: pages[i].rotation, cropped: pages[i].cropped) else { bad.append(i + 1); continue }
            }
            check("audit PDF-01: PDF → PNG draws /Rotate 0/90/180/270 and crop boxes like a viewer", names.count == pages.count && bad.isEmpty, "wrong pages \(bad)")
        case .failure(let e): check("audit PDF-01: PDF → PNG of rotated pages", false, errText(e))
        }

        // PDF-01: copy text falls back to OCR of the rendered page; a scan stored sideways with /Rotate 90.
        let scan = d.appendingPathComponent("横向きスキャン.pdf")
        let upright = textImage("請求書\n合計金額 12,345円")
        let sideways = auditTurnedLeft(upright)
        if let page = PDFPage(image: NSImage(cgImage: sideways, size: NSSize(width: sideways.width, height: sideways.height))) {
            page.rotation = 90
            let sd = PDFDocument(); sd.insert(page, at: 0); sd.write(to: scan)
        }
        switch await run(Act.copyText, [scan]) {
        // Vision reads sideways text too, so the whole line (cut off when the page was drawn wrong) is required.
        case .success(let r): check("audit PDF-01: copy text OCRs a /Rotate 90 scan upright", (r.clipboardText ?? "").contains("請求書") && (r.clipboardText ?? "").contains("12,345"), r.clipboardText ?? "")
        case .failure(let e): check("audit PDF-01: copy text OCRs a /Rotate 90 scan upright", false, errText(e))
        }

        // PDF-02: page numbers and watermark keep rotation, look, and annotations; the number sits at the bottom
        // centre of the page as displayed.
        var wm = EngineOptions(); wm.watermarkText = "社外秘"
        for (action, options, name) in [(Act.pdfPageNumbers, EngineOptions(), "page numbers"), (Act.pdfWatermark, wm, "watermark")] {
            switch await run(action, [rotated], options: options) {
            case .success(let r):
                guard let src = PDFDocument(url: rotated), let out = PDFDocument(url: r.outputs[0]) else { check("audit PDF-02: \(name) output opens", false); continue }
                var rot: [Int] = [], look: [Int] = [], annots: [Int] = [], links: [Int] = [], stampPos: [Int] = []
                for i in 0..<min(src.pageCount, out.pageCount) {
                    guard let a = src.page(at: i), let b = out.page(at: i) else { continue }
                    if a.rotation != b.rotation { rot.append(i + 1) }
                    if let img = auditRender(b) {
                        if !auditShowsUpright(img, rotation: pages[i].rotation, cropped: pages[i].cropped) { look.append(i + 1) }
                        if action == Act.pdfPageNumbers {
                            let bottom = auditHasInk(img, x: 0.35...0.65, y: 0.85...1.0), top = auditHasInk(img, x: 0.35...0.65, y: 0.0...0.15)
                            if !bottom || top { stampPos.append(i + 1) }
                        } else if !auditHasInk(img, x: 0.3...0.7, y: 0.3...0.7, limit: 245) { stampPos.append(i + 1) }
                    } else { look.append(i + 1) }
                    if b.annotations.count != a.annotations.count { annots.append(i + 1) }
                    if !b.annotations.contains(where: { ($0.url ?? ($0.action as? PDFActionURL)?.url)?.absoluteString == "https://example.com/p\(i + 1)" }) { links.append(i + 1) }
                }
                check("audit PDF-02: \(name) keeps every page's /Rotate", out.pageCount == src.pageCount && rot.isEmpty, "changed on pages \(rot)")
                check("audit PDF-02: \(name) keeps rotated and cropped pages' content in place", look.isEmpty, "wrong on pages \(look)")
                check("audit PDF-02: \(name) keeps annotations on rotated pages", annots.isEmpty, "lost on pages \(annots)")
                let goTo = out.page(at: 0)?.annotations.compactMap { ($0.action as? PDFActionGoTo)?.destination.page }.first
                check("audit PDF-02: \(name) keeps working links (web and to another page)", links.isEmpty && goTo.map { out.index(for: $0) } == 2,
                      "no web link on pages \(links), page link goes to index \(goTo.map { out.index(for: $0) } ?? -1)")
                check("audit PDF-02: \(name) stamp sits where the displayed page shows it", stampPos.isEmpty, "misplaced on pages \(stampPos)")
            case .failure(let e): check("audit PDF-02: \(name) on rotated pages", false, errText(e))
            }
        }

        // PDF-03: a password the encryption cannot take is refused and nothing is written; an ASCII one really locks.
        let plain = d.appendingPathComponent("文書.pdf")
        try? fm.copyItem(at: rotated, to: plain)
        for pw in ["日本", "pässwörd", "ａｂｃ"] {
            let before = auditFiles(d)
            var o = EngineOptions(); o.password = pw
            switch await run(Act.pdfEncrypt, [plain], options: o) {
            case .success(let r):
                check("audit PDF-03: non-ASCII password \"\(pw)\" is refused", false, "wrote \(r.outputs.first?.lastPathComponent ?? "") encrypted=\(PDFDocument(url: r.outputs[0])?.isEncrypted ?? false)")
            case .failure(let e):
                check("audit PDF-03: non-ASCII password \"\(pw)\" is refused and nothing is written", auditFiles(d) == before && errText(e).contains(L("パスワードに使えるのは半角の英字・数字・記号とスペースだけです")), errText(e))
            }
        }
        var ascii = EngineOptions(); ascii.password = "Abc 12#x"
        switch await run(Act.pdfEncrypt, [plain], options: ascii) {
        case .success(let r):
            let locked = PDFDocument(url: r.outputs[0]), open = PDFDocument(url: r.outputs[0])
            check("audit PDF-03: ASCII password with a space locks the file and opens with it",
                  locked?.isEncrypted == true && locked?.isLocked == true && locked?.unlock(withPassword: "") == false && open?.unlock(withPassword: "Abc 12#x") == true)
        case .failure(let e): check("audit PDF-03: ASCII password with a space", false, errText(e))
        }

        // PDF-04: rotating an owner-protected PDF is refused and leaves the file byte-identical and protected.
        let owner = d.appendingPathComponent("編集不可.pdf")
        PDFDocument(url: rotated)?.write(to: owner, withOptions: [.ownerPasswordOption: "owner-secret",
                                                                  .accessPermissionsOption: PDFAccessPermissions.allowsLowQualityPrinting.rawValue])
        let ownerBytes = try? Data(contentsOf: owner)
        let fixtureOK = PDFDocument(url: owner).map { $0.isEncrypted && !$0.isLocked } ?? false
        switch await run(Act.pdfRotateRight, [owner]) {
        case .success:
            check("audit PDF-04: rotate on an owner-protected PDF is refused", false,
                  "fixture ok=\(fixtureOK), still encrypted=\(PDFDocument(url: owner)?.isEncrypted ?? false), rotation=\(PDFDocument(url: owner)?.page(at: 0)?.rotation ?? -1)")
        case .failure(let e):
            check("audit PDF-04: rotate on an owner-protected PDF is refused, file byte-identical",
                  fixtureOK && ownerBytes != nil && (try? Data(contentsOf: owner)) == ownerBytes && PDFDocument(url: owner)?.isEncrypted == true, errText(e))
        }

        // PDF-13: OCR on a PDF that already has text writes nothing and says so.
        let texty = d.appendingPathComponent("文字あり.pdf")
        try? PDFRenderer.pdfData(from: MarkdownReader.model(from: markdown)).write(to: texty)
        let beforeOCR = auditFiles(d)
        switch await run(Act.pdfOCR, [texty]) {
        case .success(let r): check("audit PDF-13: OCR of a text PDF writes nothing", false, "wrote \(r.outputs.first?.lastPathComponent ?? "")")
        case .failure(let e):
            check("audit PDF-13: OCR of a text PDF writes nothing and says it is already searchable",
                  auditFiles(d) == beforeOCR && errText(e) == L("この PDF はすでに文字を検索できます"), errText(e))
        }

        // IMG-07: combining pictures stores HEIC photos as JPEG, keeps alpha, passes JPEGs through, and leaves
        // lossless pictures lossless.
        let md = fresh("audit-pdf-merge")
        let jpg = md.appendingPathComponent("a.jpg"), heic = md.appendingPathComponent("b.heic"), png = md.appendingPathComponent("c.png")
        let tiff = md.appendingPathComponent("d.tiff"), turned = md.appendingPathComponent("e.heic")
        try? writeImage(pattern(width: 300, height: 400, alpha: false), to: jpg, type: .jpeg, extra: [kCGImagePropertyOrientation: 6])
        try? writeImage(noise(width: 1200, height: 900), to: heic, type: .heic, extra: [:])
        try? writeImage(pattern(width: 400, height: 300, alpha: true), to: png, type: .png, extra: [:])
        try? writeImage(quadrantImage(width: 400, height: 300), to: tiff, type: .tiff, extra: [kCGImagePropertyOrientation: 6])
        try? writeImage(quadrantImage(width: 400, height: 300), to: turned, type: .heic, extra: [kCGImagePropertyOrientation: 6])
        /// The page shows the picture as displayed (EXIF orientation applied): compare the four quadrants.
        func shownUpright(_ out: URL, page n: Int, _ picture: URL) -> Bool {
            guard let page = PDFDocument(url: out)?.page(at: n), let img = auditRender(page, scale: 1),
                  let src = CGImageSourceCreateWithURL(picture as CFURL, nil),
                  let shown = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary) else { return false }
            let dw = CGFloat(shown.width), dh = CGFloat(shown.height)
            let s = min(CGFloat(img.width) / dw, CGFloat(img.height) / dh)
            let x0 = (CGFloat(img.width) - dw * s) / 2, y0 = (CGFloat(img.height) - dh * s) / 2
            return [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].allSatisfy { u, v in
                colorLetter(pixel(img, x: Int(x0 + u * dw * s), yFromTop: Int(y0 + v * dh * s))) == colorLetter(pixel(shown, x: Int(u * dw), yFromTop: Int(v * dh)))
            }
        }
        switch await run(Act.pdfMerge, [jpg, heic, png, tiff, turned]) {
        case .success(let r):
            let out = r.outputs[0]
            let p = (0..<5).map { auditPageImages(out, page: $0) }
            check("audit IMG-07: HEIC photo is stored as JPEG", p[1].count == 1 && p[1][0].filter == "DCTDecode", "\(p[1].map(\.filter)) \(size(out)) bytes")
            check("audit IMG-07: JPEG passes through byte for byte", p[0].count == 1 && p[0][0].jpeg == (try? Data(contentsOf: jpg)))
            check("audit IMG-07: PNG with alpha stays lossless with its soft mask", p[2].count == 1 && p[2][0].smask && p[2][0].filter != "DCTDecode", "\(p[2])")
            check("audit IMG-07: TIFF (EXIF orientation 6) stays lossless and upright", p[3].count == 1 && p[3][0].filter != "DCTDecode" && shownUpright(out, page: 3, tiff), "\(p[3].map(\.filter))")
            check("audit IMG-07: re-encoded HEIC (EXIF orientation 6) is JPEG and upright", p[4].count == 1 && p[4][0].filter == "DCTDecode" && shownUpright(out, page: 4, turned), "\(p[4].map(\.filter))")
        case .failure(let e): check("audit IMG-07: combine pictures to PDF", false, errText(e))
        }

        // PDF-10: ligature code points are spelled out in copied and converted text.
        let lig = d.appendingPathComponent("合字.pdf")
        let ld = NSMutableData()
        var lbox = CGRect(x: 0, y: 0, width: 400, height: 200)
        if let ctx = CGContext(consumer: CGDataConsumer(data: ld as CFMutableData)!, mediaBox: &lbox, nil), let font = NSFont(name: "Times-Roman", size: 20) {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("The Oﬃce sells a waﬄe." as NSString).draw(at: CGPoint(x: 20, y: 100), withAttributes: [.font: font])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage(); ctx.closePDF()
            try? (ld as Data).write(to: lig)
        }
        let ligFixture = (PDFDocument(url: lig)?.string ?? "").contains("\u{FB03}")
        func noLigatures(_ s: String) -> Bool { s.contains("Office") && s.contains("waffle") && !s.unicodeScalars.contains { (0xFB00...0xFB06).contains($0.value) } }
        switch await run(Act.copyText, [lig]) {
        case .success(let r): check("audit PDF-10: copy text spells out ligatures (Office, waffle)", ligFixture && noLigatures(r.clipboardText ?? ""), r.clipboardText ?? "")
        case .failure(let e): check("audit PDF-10: copy text spells out ligatures", false, errText(e))
        }
        switch await run("to.txt", [lig]) {
        case .success(let r):
            let t = (try? String(contentsOf: r.outputs[0], encoding: .utf8)) ?? ""
            check("audit PDF-10: PDF → text spells out ligatures (Office, waffle)", ligFixture && noLigatures(t), t)
        case .failure(let e): check("audit PDF-10: PDF → text spells out ligatures", false, errText(e))
        }
    }
}
