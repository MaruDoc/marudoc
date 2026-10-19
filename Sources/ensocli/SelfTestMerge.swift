import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import EnsoShared
import EnsoCore

/// Merge order and image pages, page-range parsing, splitting by ranges / N pages, selection order bookkeeping.
extension SelfTest {

    /// A PDF whose pages have the given sizes, so the page order can be read back from the media boxes.
    func makePDF(_ url: URL, pages sizes: [CGSize]) {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { return }
        for s in sizes {
            var box = CGRect(origin: .zero, size: s)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    func pageSizes(_ url: URL) -> [CGSize] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.bounds(for: .mediaBox).size }
    }

    func renderPage(_ page: PDFPage, scale: CGFloat = 1) -> CGImage? {
        let b = page.bounds(for: .mediaBox)
        let w = Int(b.width * scale), h = Int(b.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Four colour blocks (top-left red, top-right green, bottom-left blue, bottom-right yellow).
    func quadrantImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ x: Int, _ y: Int) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: width / 2, height: height / 2))
        }
        fill(1, 0, 0, 0, height / 2); fill(0, 1, 0, width / 2, height / 2); fill(0, 0, 1, 0, 0); fill(1, 1, 0, width / 2, 0)
        return ctx.makeImage()!
    }

    func colorLetter(_ p: (r: Int, g: Int, b: Int, a: Int)) -> String {
        if p.r > 150 && p.g < 100 && p.b < 100 { return "R" }
        if p.g > 150 && p.r < 100 && p.b < 100 { return "G" }
        if p.b > 150 && p.r < 100 && p.g < 100 { return "B" }
        if p.r > 150 && p.g > 150 && p.b < 100 { return "Y" }
        if p.r > 235 && p.g > 235 && p.b > 235 { return "W" }
        return "?"
    }

    func testMergeAndSplit() async {
        let d = fresh("merge")

        // 1. Merge keeps the order it is given (c, a, b is not alphabetical).
        let a = d.appendingPathComponent("a.pdf"), b = d.appendingPathComponent("b.pdf"), c = d.appendingPathComponent("c.pdf")
        makePDF(a, pages: [CGSize(width: 300, height: 300)])
        makePDF(b, pages: [CGSize(width: 400, height: 400), CGSize(width: 410, height: 410)])
        makePDF(c, pages: [CGSize(width: 500, height: 500)])
        switch await run(Act.pdfMerge, [c, a, b]) {
        case .success(let r):
            let w = pageSizes(r.outputs[0]).map { Int($0.width) }
            check("merge keeps the given order (c, a, b)", w == [500, 300, 400, 410], "\(w)")
            check("merge output sits next to the first file, named after it", r.outputs[0].deletingLastPathComponent().standardizedFileURL.path == c.deletingLastPathComponent().standardizedFileURL.path && r.outputs[0].lastPathComponent.hasPrefix("c ほか 2 件 ("), r.outputs[0].lastPathComponent)
        case .failure(let e): check("merge keeps the given order", false, errText(e))
        }
        switch await run(Act.pdfMerge, [b, a]) {
        case .success(let r):
            check("merge of two is named \"b と a (…)\"", r.outputs[0].lastPathComponent.hasPrefix("b と a ("), r.outputs[0].lastPathComponent)
            check("merge of two keeps the order (b, a)", pageSizes(r.outputs[0]).map { Int($0.width) } == [400, 410, 300])
        case .failure(let e): check("merge of two", false, errText(e))
        }
        switch await run(Act.combineToPDF, [a, b]) {
        case .success(let r): check("legacy combine id still merges in order", pageSizes(r.outputs[0]).map { Int($0.width) } == [300, 400, 410])
        case .failure(let e): check("legacy combine id", false, errText(e))
        }

        // 2. PDF + landscape image + portrait image: A4 pages in the right orientation.
        let land = d.appendingPathComponent("land.png"), port = d.appendingPathComponent("port.jpg")
        try? writeImage(pattern(width: 400, height: 300, alpha: false), to: land, type: .png, extra: [:])
        try? writeImage(pattern(width: 300, height: 400, alpha: false), to: port, type: .jpeg, extra: [:])
        switch await run(Act.pdfMerge, [a, land, port]) {
        case .success(let r):
            let s = pageSizes(r.outputs[0])
            check("merge PDF + landscape + portrait image: 3 pages", s.count == 3, "\(s)")
            if s.count == 3 {
                check("merge: PDF page kept as it was", Int(s[0].width) == 300 && Int(s[0].height) == 300)
                check("merge: landscape image → A4 landscape (842×595)", Int(s[1].width) == 842 && Int(s[1].height) == 595, "\(s[1])")
                check("merge: portrait image → A4 portrait (595×842)", Int(s[2].width) == 595 && Int(s[2].height) == 842, "\(s[2])")
            }
            if let page = PDFDocument(url: r.outputs[0])?.page(at: 1), let img = renderPage(page) {
                // 400×300 on 842×595: scale 1.983, so the picture is 793 wide, centred: margins of about 24 pt.
                check("merge: image is centred with white side margins", colorLetter(pixel(img, x: 6, yFromTop: img.height / 2)) == "W" && colorLetter(pixel(img, x: img.width / 2, yFromTop: img.height / 2)) != "W")
            } else { check("merge: image page renders", false) }
        case .failure(let e): check("merge PDF + images", false, errText(e))
        }

        // 3. EXIF orientation 1–8: the merged page shows what the picture displays.
        var orientationOK = true, detail = ""
        for o in 1...8 {
            let url = d.appendingPathComponent("o\(o).jpg")
            let img = quadrantImage(width: 400, height: 240)
            try? writeImage(img, to: url, type: .jpeg, extra: [kCGImagePropertyOrientation: o])
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let ref = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary) else { orientationOK = false; continue }
            func quad(_ im: CGImage, _ fx: Double, _ fy: Double, in rect: CGRect) -> String {
                colorLetter(pixel(im, x: Int(rect.minX + rect.width * fx), yFromTop: Int(rect.minY + rect.height * fy)))
            }
            let want = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { quad(ref, $0.0, $0.1, in: CGRect(x: 0, y: 0, width: ref.width, height: ref.height)) }.joined()
            switch await run(Act.pdfMerge, [a, url]) {
            case .success(let r):
                guard let page = PDFDocument(url: r.outputs[0])?.page(at: 1), let pg = renderPage(page) else { orientationOK = false; continue }
                // The picture fills the page along one axis and is centred on the other.
                let dw = Double(ref.width), dh = Double(ref.height)
                let s = min(Double(pg.width) / dw, Double(pg.height) / dh)
                let rect = CGRect(x: (Double(pg.width) - dw * s) / 2, y: (Double(pg.height) - dh * s) / 2, width: dw * s, height: dh * s)
                let got = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { quad(pg, $0.0, $0.1, in: rect) }.joined()
                if got != want { orientationOK = false; detail += " o\(o): want \(want) got \(got);" }
            case .failure: orientationOK = false
            }
        }
        check("merge: EXIF orientations 1–8 come out as displayed", orientationOK, detail)

        // 4. Page ranges.
        func ranges(_ t: String, _ n: Int = 10) -> [PageRanges.Part]? { try? PageRanges.parse(t, pageCount: n) }
        let expected = [PageRanges.Part(first: 1, last: 3), PageRanges.Part(first: 5, last: 5), PageRanges.Part(first: 8, last: 10)]
        check("ranges: \"1-3, 5, 8-10\"", ranges("1-3, 5, 8-10") == expected)
        check("ranges: spaces anywhere", ranges("  1 - 3 ,5,  8-10 ") == expected)
        check("ranges: full-width digits, dashes and commas", ranges("１－３、５、８〜１０") == expected && ranges("1ー3，5，8～10") == expected)
        check("ranges: labels", expected.map(\.label) == ["1-3", "5", "8-10"])
        func failure(_ t: String, _ n: Int = 10) -> PageRanges.ParseError? {
            do { _ = try PageRanges.parse(t, pageCount: n); return nil } catch { return error as? PageRanges.ParseError }
        }
        check("ranges: empty input is refused", failure("") == .empty && failure(" , ") == .empty)
        check("ranges: garbage is refused", failure("a-b") == .invalid("a-b") && failure("1--2") != nil && failure("1-2-3") != nil && failure("-3") != nil && failure("3-") != nil && failure("1.5") != nil)
        check("ranges: backwards range is refused", failure("5-3") == .reversed("5-3"))
        check("ranges: out of range is refused", failure("0") != nil && failure("11") == .outOfRange("11", pageCount: 10) && failure("1-11") != nil && failure("2, 99999999999999999999") != nil)
        check("ranges: errors read as sentences", failure("11")?.errorDescription?.contains("10") == true)
        check("ranges: page count text", (try? PageRanges.parseCount("５")) == 5 && (try? PageRanges.parseCount(" 12 ")) == 12 && (try? PageRanges.parseCount("0")) == nil && (try? PageRanges.parseCount("x")) == nil && (try? PageRanges.parseCount("")) == nil)
        let chunked = (try? PageRanges.chunks(pageCount: 7, every: 3)) ?? []
        check("chunks: 7 pages by 3 → 1-3, 4-6, 7", chunked.map(\.label) == ["1-3", "4-6", "7"] && chunked.map(\.count) == [3, 3, 1])
        check("chunks: N larger than the document → one chunk; N = 0 refused", ((try? PageRanges.chunks(pageCount: 4, every: 9)) ?? []).map(\.label) == ["1-4"] && (try? PageRanges.chunks(pageCount: 4, every: 0)) == nil)

        // 5. Splitting a 7-page PDF.
        let seven = d.appendingPathComponent("doc.pdf")
        makePDF(seven, pages: (1...7).map { CGSize(width: 100 + $0 * 10, height: 200) })
        var o = EngineOptions(); o.splitEvery = 3
        switch await run(Act.pdfSplitEvery, [seven], options: o) {
        case .success(let r):
            let folder = r.outputs[0]
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            check("split every 3: folder next to the original", folder.deletingLastPathComponent().standardizedFileURL.path == seven.deletingLastPathComponent().standardizedFileURL.path && folder.lastPathComponent.hasPrefix("doc ("), folder.lastPathComponent)
            check("split every 3: files doc p1-3 / p4-6 / p7", names == ["doc p1-3.pdf", "doc p4-6.pdf", "doc p7.pdf"], "\(names)")
            check("split every 3: page counts 3, 3, 1", names.map { PDFDocument(url: folder.appendingPathComponent($0))?.pageCount ?? -1 } == [3, 3, 1])
            check("split every 3: right pages in each file", pageSizes(folder.appendingPathComponent("doc p4-6.pdf")).map { Int($0.width) } == [140, 150, 160])
        case .failure(let e): check("split every 3", false, errText(e))
        }
        o = EngineOptions(); o.splitRanges = "１-２, 5, 7"
        switch await run(Act.pdfSplitRanges, [seven], options: o) {
        case .success(let r):
            let folder = r.outputs[0]
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            check("split by ranges: files doc p1-2 / p5 / p7", names == ["doc p1-2.pdf", "doc p5.pdf", "doc p7.pdf"], "\(names)")
            check("split by ranges: page counts 2, 1, 1", names.map { PDFDocument(url: folder.appendingPathComponent($0))?.pageCount ?? -1 } == [2, 1, 1])
            check("split by ranges: a second run gets its own folder", folder.lastPathComponent != "doc (分割)" && folder.lastPathComponent.hasPrefix("doc ("), folder.lastPathComponent)
        case .failure(let e): check("split by ranges", false, errText(e))
        }
        o = EngineOptions(); o.splitRanges = "1-9"
        switch await run(Act.pdfSplitRanges, [seven], options: o) {
        case .success: check("split by ranges: out-of-range input fails", false)
        case .failure(let e):
            check("split by ranges: out-of-range input fails with a message, no folder left", !errText(e).isEmpty && !((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).contains { $0.hasPrefix("doc (") && $0.hasSuffix(" 3") })
        }

        // 6. Selection order bookkeeping.
        var sel = SelectionOrder()
        let (pa, pb, pc, pd) = ("/x/A.pdf", "/x/B.pdf", "/x/C.pdf", "/x/D.pdf")
        sel.update(with: [pc])                       // click C
        sel.update(with: [pa, pc])                   // Cmd-click A (Finder lists A first)
        sel.update(with: [pa, pb, pc])               // Cmd-click B
        check("selection order: appended in click order, not listing order", sel.paths == [pc, pa, pb], "\(sel.paths)")
        sel.update(with: [pa, pb])                   // Cmd-click C again to deselect
        check("selection order: deselected items are dropped", sel.paths == [pa, pb])
        sel.update(with: [pa, pb, pd])
        check("selection order: a new item goes to the end", sel.paths == [pa, pb, pd])
        let urls = [pb, pd, pa].map { URL(fileURLWithPath: $0) }
        check("selection order: requested files come back in click order", sel.order(urls).map(\.path) == [pa, pb, pd])
        check("selection order: unknown selection keeps the received order", sel.order([pa, pc].map { URL(fileURLWithPath: $0) }).map(\.path) == [pa, pc] && sel.order([pd, pb].map { URL(fileURLWithPath: $0) }).map(\.path) == [pd, pb])
        sel.update(with: [pb])
        check("selection order: a single item resets the list", sel.paths == [pb])
        sel.update(with: [])
        check("selection order: an empty selection clears it", sel.paths.isEmpty)
        check("selection order: nothing known keeps the received order", sel.order([pd, pa].map { URL(fileURLWithPath: $0) }).map(\.path) == [pd, pa])

        // 7. Menus.
        let mixed = ActionCatalog.menu(for: ["a.pdf", "b.png"].map { URL(fileURLWithPath: "/tmp/" + $0) })
        check("menu: PDF + image offers 結合 (pdf.merge)", mixed.first?.action == Act.pdfMerge && mixed.first?.title == L("PDF に結合") && mixed.first?.shortTitle == L("結合"))
        check("menu: two images offer the same merge action", ActionCatalog.menu(for: ["a.png", "b.jpg"].map { URL(fileURLWithPath: "/tmp/" + $0) }).contains { $0.action == Act.pdfMerge })
        check("menu: PDF + Word does not offer it", !ActionCatalog.menu(for: ["a.pdf", "b.docx"].map { URL(fileURLWithPath: "/tmp/" + $0) }).contains { $0.action == Act.pdfMerge })
        let pdfNodes = ActionCatalog.menu(for: [URL(fileURLWithPath: "/tmp/a.pdf")])
        let split = pdfNodes.flatMap(\.children).first { $0.id == "g.split" }
        check("menu: 分割 is a group of 3 (1ページずつ, 範囲, N ページごと)", split?.children.map(\.action) == [Act.pdfSplit, Act.editSplitRanges, Act.editSplitEvery])
        let ring = ActionCatalog.ringMenu(for: [URL(fileURLWithPath: "/tmp/a.pdf")])
        check("ring: every split entry is reachable one level down, ≤6 children per item", ring.allSatisfy { $0.children.count <= 6 && $0.children.allSatisfy { $0.children.isEmpty } } && ring.flatMap(\.children).compactMap(\.action).contains(Act.editSplitEvery))
    }
}
