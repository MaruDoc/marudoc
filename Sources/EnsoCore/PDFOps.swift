import AppKit
import PDFKit
import Quartz
import ImageIO
import EnsoShared
import EnsoDoc

enum Rasterizer {

    /// Page size as displayed (cropBox, rotation applied), in points.
    static func displaySize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// Renders a page on white at the given resolution, honouring rotation and the crop box.
    static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let size = displaySize(page)
        let scale = dpi / 72
        let w = SafeInt.round(size.width * scale, 0, 1_000_000), h = SafeInt.round(size.height * scale, 0, 1_000_000)
        guard w > 0, h > 0, SafeInt.isReasonablePixelSize(w, h, limit: 200_000_000),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        page.transform(ctx, for: .cropBox)
        page.draw(with: .cropBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// One image for a single-page PDF, a folder of images otherwise.
    static func export(_ file: URL, format: String, dpi: Double, progress: @escaping Engine.Progress, cancelled: @escaping Engine.Cancelled) throws -> URL {
        guard let doc = PDFDocument(url: file) else { throw DocIOError.unreadable(file.lastPathComponent) }
        if doc.isLocked { throw DocIOError.encrypted }
        let ext = format == "jpeg" ? "jpg" : format
        let base = file.deletingPathExtension().lastPathComponent
        if doc.pageCount == 1, let page = doc.page(at: 0) {
            guard let img = render(page, dpi: dpi) else { throw EngineError.failed(L("ページを画像にできませんでした")) }
            let out = OutputNamer.file(for: file, ext: ext)
            try ImageOps.write(img, to: out, format: format, quality: 0.92, dpi: dpi)
            return out
        }
        let folder = OutputNamer.folder(for: file, tag: L("画像"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for i in 0..<doc.pageCount {
                if cancelled() { throw EngineError.cancelled }
                guard let page = doc.page(at: i), let img = render(page, dpi: dpi) else {
                    throw EngineError.failed(String(format: L("%d ページ目を画像にできませんでした"), i + 1))
                }
                let name = OutputNamer.numbered(base, index: i + 1, count: doc.pageCount, ext: ext)
                try ImageOps.write(img, to: folder.appendingPathComponent(name), format: format, quality: 0.92, dpi: dpi)
                progress(Double(i + 1) / Double(doc.pageCount))
            }
        } catch {
            // Don't leave a half-filled folder behind.
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            throw error
        }
        return folder
    }
}

/// Public entry points the app's editors share with the engine.
public enum PDFPageFactory {
    /// A page for an image, sized like the engine does (not one point per pixel).
    public static func page(forImage url: URL) -> PDFPage? { PDFOps.imagePage(url) }
}

enum PDFOps {

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw DocIOError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw DocIOError.encrypted }
        return doc
    }

    static func save(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard doc.write(to: url, withOptions: options) else { throw DocIOError.writeFailed(url.lastPathComponent) }
    }

    // MARK: Merge / split

    /// Joins PDFs and images into one PDF, in exactly the order given. The caller decides the order (the app passes
    /// the order the user selected the files in); nothing here sorts. PDF pages keep their crop boxes and rotation;
    /// each image becomes one A4 page (see `a4ImagePage`).
    static func merge(_ files: [URL], progress: Engine.Progress = { _ in }, cancelled: Engine.Cancelled = { false }) throws -> URL {
        guard let first = files.first else { throw EngineError.nothingToDo }
        let out = OutputNamer.file(for: first, ext: "pdf", tag: L("結合"), baseName: mergedBaseName(files))
        let result = PDFDocument()
        // Pages made from images belong to small documents of their own; keep them alive until the result is written.
        var keepAlive: [PDFDocument] = []
        for (i, f) in files.enumerated() {
            if cancelled() { throw EngineError.cancelled }
            switch FileKind.of(f) {
            case .pdf:
                let doc = try open(f)
                for p in 0..<doc.pageCount {
                    if let page = doc.page(at: p) { result.insert(page, at: result.pageCount) }
                }
                keepAlive.append(doc)
            case .image:
                guard let (doc, page) = a4ImagePage(f) else { throw DocIOError.unreadable(f.lastPathComponent) }
                keepAlive.append(doc)
                result.insert(page, at: result.pageCount)
            default: continue
            }
            progress(Double(i + 1) / Double(files.count) * 0.9)
        }
        guard result.pageCount > 0 else { throw EngineError.nothingToDo }
        try save(result, to: out)
        withExtendedLifetime(keepAlive) {}
        return out
    }

    /// "<a> ほか N 件" for three or more files, "<a> と <b>" for two, the plain name for one.
    static func mergedBaseName(_ files: [URL]) -> String? {
        func base(_ u: URL) -> String {
            let b = u.deletingPathExtension().lastPathComponent
            // Two long names must not push the result past the file system's 255-byte limit.
            return b.count > 48 ? String(b.prefix(48)) : b
        }
        switch files.count {
        case 0, 1: return nil
        case 2: return String(format: L("%@ と %@"), base(files[0]), base(files[1]))
        default: return String(format: L("%@ ほか %d 件"), base(files[0]), files.count - 1)
        }
    }

    /// A4 (595 x 842 pt) page, portrait or landscape to match the picture as displayed. The picture is drawn at its
    /// full pixel size, scaled to fit and centred. EXIF orientation is applied through the drawing transform, so the
    /// stored pixels go into the PDF untouched (a JPEG can stay a JPEG).
    static func a4ImagePage(_ url: URL) -> (PDFDocument, PDFPage)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), ImageCodec.isWithinLimits(src),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let m = ImageOps.orientationMatrices[orientation] ?? [1, 0, 0, 1]
        let w = CGFloat(img.width), h = CGFloat(img.height)
        guard w > 0, h > 0 else { return nil }
        // Size as displayed: the quarter-turn orientations (5-8) swap width and height.
        let swapped = m[0] == 0
        let dw = swapped ? h : w, dh = swapped ? w : h
        let a4 = CGSize(width: 595, height: 842)
        let page = dw > dh ? CGSize(width: a4.height, height: a4.width) : a4
        let s = min(page.width / dw, page.height / dh)
        let x0 = (page.width - dw * s) / 2, y0 = (page.height - dh * s) / 2

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(box)
        ctx.interpolationQuality = .high
        // Stored pixel (cx, cy) in the image rectangle (y up) -> displayed point -> page point.
        let a = CGFloat(m[0]), b = CGFloat(m[1]), c = CGFloat(m[2]), d = CGFloat(m[3])
        let tx = (a < 0 ? w : 0) + (b < 0 ? h : 0), ty = (c < 0 ? w : 0) + (d < 0 ? h : 0)
        ctx.concatenate(CGAffineTransform(a: s * a, b: -s * c, c: -s * b, d: s * d,
                                          tx: x0 + s * (b * h + tx), ty: y0 + s * (dh - d * h - ty)))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data), let pdfPage = doc.page(at: 0) else { return nil }
        return (doc, pdfPage)
    }

    static func imagesToPDF(_ files: [URL], output: URL) throws -> URL {
        let result = PDFDocument()
        for f in files { if let p = imagePage(f) { result.insert(p, at: result.pageCount) } }
        guard result.pageCount > 0 else { throw DocIOError.unreadable(files.first?.lastPathComponent ?? "") }
        try save(result, to: output)
        return output
    }

    /// A page the size of the photo at 144 dpi (so phone photos come out around A4-ish, not metres wide).
    static func imagePage(_ url: URL) -> PDFPage? {
        guard let img = ImageOps.loadOriented(url)?.image else { return nil }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        // Long edge between half and full A4 height, at 144 dpi when that falls inside the range.
        let longPoints = min(842, max(420, max(w, h) * 0.5))
        let k = longPoints / max(w, h)
        let size = CGSize(width: max(1, w * k), height: max(1, h * k))
        let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        return PDFPage(image: ns, options: [.mediaBox: CGRect(origin: .zero, size: size), .compressionQuality: 0.9])
    }

    static func split(_ file: URL) throws -> URL {
        let doc = try open(file)
        let folder = OutputNamer.folder(for: file, tag: L("分割"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = file.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            try save(single, to: folder.appendingPathComponent(OutputNamer.numbered(base, index: i + 1, count: doc.pageCount, ext: "pdf")))
        }
        return folder
    }

    /// One output file per range typed by the user ("1-3, 5, 8-10"), or per chunk of N pages. Files are named
    /// "<name> p1.pdf" / "<name> p1-3.pdf" inside "<name> (分割)".
    static func split(_ file: URL, ranges text: String? = nil, every: Int? = nil,
                      progress: Engine.Progress = { _ in }, cancelled: Engine.Cancelled = { false }) throws -> URL {
        let doc = try open(file)
        let parts: [PageRanges.Part]
        if let text { parts = try PageRanges.parse(text, pageCount: doc.pageCount) }
        else if let every { parts = try PageRanges.chunks(pageCount: doc.pageCount, every: every) }
        else { throw PageRanges.ParseError.empty }
        let folder = OutputNamer.folder(for: file, tag: L("分割"))
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = file.deletingPathExtension().lastPathComponent
        do {
            for (i, part) in parts.enumerated() {
                if cancelled() { throw EngineError.cancelled }
                let piece = PDFDocument()
                for p in (part.first - 1)..<part.last {
                    guard let page = doc.page(at: p)?.copy() as? PDFPage else { continue }
                    piece.insert(page, at: piece.pageCount)
                }
                guard piece.pageCount > 0 else { continue }
                // The same range typed twice must not overwrite the first file.
                let out = OutputNamer.unique(folder.appendingPathComponent("\(base) p\(part.label)").appendingPathExtension("pdf"))
                try save(piece, to: out)
                progress(Double(i + 1) / Double(parts.count))
            }
        } catch {
            // Don't leave a half-filled folder behind.
            try? fm.trashItem(at: folder, resultingItemURL: nil)
            throw error
        }
        return folder
    }

    // MARK: Rotate (in place)

    static func rotate(_ file: URL, by degrees: Int) throws -> SafeWrite.Backup {
        let doc = try open(file)
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            p.rotation = ((p.rotation + degrees) % 360 + 360) % 360
        }
        return try SafeWrite.replace(file) { tmp in try save(doc, to: tmp) }
    }

    // MARK: Compress

    enum CompressionLevel { case light, standard, strong }

    static func compress(_ file: URL, level: CompressionLevel) throws -> URL {
        let doc = try open(file)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        // PDFKit's JPEG / screen options don't touch images already inside a PDF, so a Quartz filter
        // (the same mechanism as Preview's "Reduce File Size") does the work, tuned per level.
        let (quality, dpi, maxSize): (Double, Int, Int) = {
            switch level {
            case .light: return (0.82, 220, 4000)
            case .standard: return (0.7, 150, 2400)
            case .strong: return (0.5, 100, 1600)
            }
        }()
        let filterProps: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "MaruDoc Compress",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true, "ImageSizeMax": maxSize, "ImageSizeMin": 0],
            ]]],
        ]
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let filter = QuartzFilter(properties: filterProps) {
            options[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = filter
        } else {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        try save(doc, to: tmp, options: options)
        let before = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard after > 0, Double(after) < Double(before) * 0.97 else {
            try? FileManager.default.removeItem(at: tmp)
            throw EngineError.noGain
        }
        let out = OutputNamer.file(for: file, ext: "pdf", tag: L("圧縮"))
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    // MARK: OCR

    static func ocr(_ file: URL, languages: [String], progress: @escaping Engine.Progress) throws -> URL {
        let doc = try open(file)
        let data = try Formats.searchablePDF(doc, languages: languages, progress: progress)
        let out = OutputNamer.file(for: file, ext: "pdf", tag: L("文字認識"))
        try data.write(to: out, options: .atomic)
        return out
    }

    // MARK: Passwords

    static func encrypt(_ file: URL, password: String, owner: String?) throws -> URL {
        let doc = try open(file)
        let out = OutputNamer.file(for: file, ext: "pdf", tag: L("保護"))
        try save(doc, to: out, options: [.userPasswordOption: password, .ownerPasswordOption: owner ?? password])
        return out
    }

    static func decrypt(_ file: URL, password: String) throws -> URL {
        guard let doc = PDFDocument(url: file) else { throw DocIOError.unreadable(file.lastPathComponent) }
        if doc.isLocked, !doc.unlock(withPassword: password) { throw EngineError.failed(L("パスワードが違います")) }
        // Re-insert pages into a fresh document so no encryption carries over.
        let plain = PDFDocument()
        for i in 0..<doc.pageCount { if let p = doc.page(at: i) { plain.insert(p, at: plain.pageCount) } }
        let out = OutputNamer.file(for: file, ext: "pdf", tag: L("解除"))
        try save(plain, to: out)
        return out
    }

    // MARK: Stamps (page numbers, watermark)

    enum Stamp { case pageNumbers, watermark(String) }

    /// Redraws each page (vector) with the stamp on top, then re-attaches the original annotations.
    static func stamp(_ file: URL, kind: Stamp) throws -> URL {
        let doc = try open(file)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextCreator: "MaruDoc"] as CFDictionary) else {
            throw DocIOError.writeFailed(file.lastPathComponent)
        }
        let total = doc.pageCount
        for i in 0..<total {
            guard let page = doc.page(at: i) else { continue }
            let size = Rasterizer.displaySize(page)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            page.transform(ctx, for: .cropBox)
            page.draw(with: .cropBox, to: ctx)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            switch kind {
            case .pageNumbers:
                let label = "\(i + 1) / \(total)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(8, size.width / 60)), .foregroundColor: NSColor(white: 0.3, alpha: 1)]
                let s = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: (size.width - s.width) / 2, y: max(14, size.height * 0.025)), withAttributes: attrs)
            case .watermark(let text):
                let fontSize = min(size.width, size.height) / CGFloat(max(4, text.count)) * 1.4
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: min(fontSize, 96), weight: .bold),
                                                             .foregroundColor: NSColor(white: 0.5, alpha: 0.22)]
                let s = (text as NSString).size(withAttributes: attrs)
                ctx.saveGState()
                ctx.translateBy(x: size.width / 2, y: size.height / 2)
                ctx.rotate(by: atan2(size.height, size.width))
                (text as NSString).draw(at: CGPoint(x: -s.width / 2, y: -s.height / 2), withAttributes: attrs)
                ctx.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPage()
        }
        ctx.closePDF()

        guard let stamped = PDFDocument(data: data as Data) else { throw DocIOError.writeFailed(file.lastPathComponent) }
        // Links and comments survive.
        for i in 0..<min(total, stamped.pageCount) {
            guard let src = doc.page(at: i), let dst = stamped.page(at: i), src.rotation == 0 else { continue }
            for a in src.annotations { if let c = a.copy() as? PDFAnnotation { dst.addAnnotation(c) } }
        }
        let tag: String = { if case .pageNumbers = kind { return L("ページ番号") }; return L("透かし") }()
        let out = OutputNamer.file(for: file, ext: "pdf", tag: tag)
        try save(stamped, to: out)
        return out
    }

    static func flatten(_ file: URL) throws -> URL {
        let doc = try open(file)
        let out = OutputNamer.file(for: file, ext: "pdf", tag: L("統合"))
        try save(doc, to: out, options: [.burnInAnnotationsOption: true])
        return out
    }
}

enum ImageExtraction {
    static func extract(from file: URL) throws -> URL {
        var images: [(String, Data)] = []
        switch FileKind.of(file) {
        case .pdf:
            let doc = try PDFOps.open(file)
            for (i, img) in Formats.pdfImages(doc).enumerated() {
                images.append((String(format: "image-%03d.%@", i + 1, img.format == .jpeg ? "jpg" : "png"), img.data))
            }
        case .presentation:
            images = try Formats.pptxImages(file)
        case .word:
            images = try Formats.docxImages(file)
        default:
            throw EngineError.unsupported(file.pathExtension)
        }
        guard !images.isEmpty else { throw EngineError.failed(L("画像が見つかりませんでした")) }
        let folder = OutputNamer.folder(for: file, tag: L("画像"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in images {
            let safe = (name as NSString).lastPathComponent
            try data.write(to: OutputNamer.unique(folder.appendingPathComponent(safe)), options: .withoutOverwriting)
        }
        return folder
    }
}

enum TextExtraction {
    static func text(of files: [URL], languages: [String]) async throws -> String {
        var parts: [String] = []
        for f in files {
            switch FileKind.of(f) {
            case .image:
                parts.append(try TextRecognizer.recognize(url: f, languages: languages))
            case .pdf:
                let doc = try PDFOps.open(f)
                var s = doc.string ?? ""
                if s.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 {
                    // Scanned: recognise.
                    var pages: [String] = []
                    for i in 0..<doc.pageCount {
                        guard let p = doc.page(at: i), let img = Rasterizer.render(p, dpi: 200) else { continue }
                        pages.append(try TextRecognizer.recognize(cgImage: img, languages: languages))
                    }
                    s = pages.joined(separator: "\n\n")
                }
                parts.append(s)
            default:
                parts.append(try await DocumentReader.model(of: f).plainText)
            }
        }
        let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError.failed(L("文字が見つかりませんでした")) }
        return text
    }
}
