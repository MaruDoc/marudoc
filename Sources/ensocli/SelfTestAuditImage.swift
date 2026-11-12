import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import EnsoShared
import EnsoCore

/// Audit 2026-11-12, image area: metadata removal that really removes (IMG-01, IMG-09), in-place rotate / flip /
/// metadata removal that keeps every frame, page and auxiliary image or refuses (IMG-02, 03, 04, 05, 08), OCR of
/// English text (IMG-06), truncated files (IMG-14), and menus that only offer what works (IMG-17, IMG-18).
extension SelfTest {

    func testAuditImage() async {
        let d = fresh("audit-image")
        await auditStripMetadata(d)
        await auditInPlaceFormats(d)
        await auditHDRPhoto(d)
        await auditOCRLanguages(d)
        await auditTruncated(d)
        auditImageMenus()
        await auditPNGPixelsAndConversions(d)
    }

    // MARK: Helpers

    func imageProps(_ u: URL, _ i: Int = 0) -> [CFString: Any] {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(s, i, nil) as? [CFString: Any] ?? [:]
    }

    func frameCount(_ u: URL) -> Int { CGImageSourceCreateWithURL(u as CFURL, nil).map(CGImageSourceGetCount) ?? 0 }

    func imageType(_ u: URL) -> String { CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? } ?? "?" }

    /// ImageIO's XMP view of frame `i` (it also lists EXIF, TIFF, GPS and IPTC values) as "prefix:name".
    func metadataTags(_ u: URL, _ i: Int = 0) -> [String] {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let m = CGImageSourceCopyMetadataAtIndex(s, i, nil),
              let tags = CGImageMetadataCopyTags(m) as? [CGImageMetadataTag] else { return [] }
        return tags.map { "\(CGImageMetadataTagCopyPrefix($0) as String? ?? "?"):\(CGImageMetadataTagCopyName($0) as String? ?? "?")" }
    }

    /// Tags that only describe how to show the picture (orientation, resolution, colour space, pixel layout).
    func onlyDisplayTags(_ tags: [String]) -> Bool {
        tags.allSatisfy { $0.hasPrefix("tiff:") && !["tiff:Artist", "tiff:Make", "tiff:Model", "tiff:Software", "tiff:DateTime", "tiff:HostComputer",
                                                     "tiff:ImageDescription", "tiff:Copyright", "tiff:DocumentName"].contains($0)
            || ["exif:PixelXDimension", "exif:PixelYDimension", "exif:ColorSpace"].contains($0) }
    }

    /// HEIF lists its thumbnails in the file contents; for JPEG / TIFF ask for the embedded one and compare sizes.
    func hasEmbeddedThumbnail(_ u: URL) -> Bool {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil) else { return false }
        if let p = CGImageSourceCopyProperties(s, nil) as? [CFString: Any], let c = p[kCGImagePropertyFileContentsDictionary] as? [CFString: Any],
           let images = c[kCGImagePropertyImages] as? [[CFString: Any]], images.contains(where: { ($0[kCGImagePropertyThumbnailImages] as? [Any])?.isEmpty == false }) {
            return true
        }
        let props = imageProps(u)
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard let t = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                                                                kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1)] as CFDictionary) else { return false }
        return max(t.width, t.height) < max(w, h)
    }

    func hiddenFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".") && $0 != ".DS_Store" }
    }

    func fileBytes(_ u: URL) -> [UInt8] { [UInt8]((try? Data(contentsOf: u)) ?? Data()) }

    func occurrences(_ hay: [UInt8], _ needle: [UInt8]) -> Int {
        guard needle.count <= hay.count else { return 0 }
        var n = 0
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { n += 1 }
        return n
    }

    func encoded(_ img: CGImage, _ type: UTType, _ props: [CFString: Any] = [:]) -> [UInt8] {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? [UInt8](data as Data) : []
    }

    static let auditCRC: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    func pngChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        var c: UInt32 = 0xFFFF_FFFF
        for b in body { c = SelfTest.auditCRC[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        c ^= 0xFFFF_FFFF
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        return be(UInt32(data.count)) + body + be(c)
    }

    /// The EXIF block (TIFF structure) ImageIO writes for these properties, taken from a JPEG's APP1.
    func exifBlock(_ props: [CFString: Any]) -> [UInt8] {
        let jpg = encoded(pattern(width: 16, height: 16, alpha: false), .jpeg, props)
        let tag = Array("Exif".utf8) + [0, 0]
        for i in 0..<(jpg.count - 10) where jpg[i] == 0xFF && jpg[i + 1] == 0xE1 && Array(jpg[(i + 4)..<(i + 10)]) == tag {
            let len = Int(jpg[i + 2]) << 8 | Int(jpg[i + 3])
            return Array(jpg[(i + 10)..<(i + 2 + len)])
        }
        return []
    }

    static let privateGPS: [CFString: Any] = [kCGImagePropertyGPSLatitude: 35.6586, kCGImagePropertyGPSLatitudeRef: "N",
                                              kCGImagePropertyGPSLongitude: 139.7454, kCGImagePropertyGPSLongitudeRef: "E"]

    // MARK: IMG-01, IMG-09

    func auditStripMetadata(_ d: URL) async {
        // PNG with GPS in eXIf, an Artist text chunk and XMP in iTXt (what exiftool writes).
        let png = d.appendingPathComponent("gps.png")
        var bytes = encoded(pattern(width: 400, height: 300, alpha: false), .png)
        let exif = exifBlock([kCGImagePropertyGPSDictionary: SelfTest.privateGPS, kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Taro Yamada"]])
        let xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">private png xmp</rdf:li></rdf:Alt></dc:description></rdf:Description></rdf:RDF></x:xmpmeta>"
        let extra = pngChunk("eXIf", exif) + pngChunk("tEXt", Array("Artist".utf8) + [0] + Array("Taro Yamada".utf8))
            + pngChunk("iTXt", Array("XML:com.adobe.xmp".utf8) + [0, 0, 0, 0, 0] + Array(xmp.utf8))
        bytes.insert(contentsOf: extra, at: 33)   // after the signature and IHDR
        try? Data(bytes).write(to: png)
        let before = topLeftIsRed(png)
        check("audit fixture: PNG carries GPS, text and XMP", imageProps(png)[kCGImagePropertyGPSDictionary] != nil && !exif.isEmpty)
        switch await run(Act.imgStripMetadata, [png]) {
        case .success:
            let after = fileBytes(png)
            let left = metadataTags(png)
            check("audit IMG-01: PNG metadata removal leaves no GPS, text or XMP",
                  imageProps(png)[kCGImagePropertyGPSDictionary] == nil && onlyDisplayTags(left)
                  && occurrences(after, Array("Taro".utf8)) == 0 && occurrences(after, Array("private png".utf8)) == 0
                  && occurrences(after, Array("eXIf".utf8)) == 0 && topLeftIsRed(png) == before, left.joined(separator: " "))
        case .failure(let e): check("audit IMG-01: PNG metadata removal", false, errText(e))
        }

        // JPEG stored sideways with GPS, camera, author, IPTC and an EXIF thumbnail.
        let jpg = d.appendingPathComponent("thumb.jpg")
        try? Data(encoded(pattern(width: 640, height: 480, alpha: false), .jpeg, [
            kCGImagePropertyOrientation: 6, kCGImageDestinationEmbedThumbnail: true, kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyGPSDictionary: SelfTest.privateGPS,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Taro Yamada", kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:12 10:00:00", kCGImagePropertyExifUserComment: "secret note"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["secret"], kCGImagePropertyIPTCByline: ["Taro Yamada"]],
        ])).write(to: jpg)
        let jpgBefore = topLeftIsRed(jpg)
        let soi: [UInt8] = [0xFF, 0xD8, 0xFF]
        check("audit fixture: JPEG has an EXIF thumbnail and IPTC", occurrences(fileBytes(jpg), soi) >= 2 && hasEmbeddedThumbnail(jpg)
              && imageProps(jpg)[kCGImagePropertyIPTCDictionary] != nil)
        switch await run(Act.imgStripMetadata, [jpg]) {
        case .success:
            let p = imageProps(jpg), left = metadataTags(jpg)
            check("audit IMG-09: JPEG metadata removal drops the EXIF thumbnail, IPTC and camera data, keeps orientation",
                  occurrences(fileBytes(jpg), soi) == 1 && !hasEmbeddedThumbnail(jpg) && p[kCGImagePropertyIPTCDictionary] == nil
                  && p[kCGImagePropertyGPSDictionary] == nil && onlyDisplayTags(left) && (p[kCGImagePropertyOrientation] as? Int) == 6
                  && topLeftIsRed(jpg) == jpgBefore, left.joined(separator: " "))
        case .failure(let e): check("audit IMG-09: JPEG metadata removal", false, errText(e))
        }

        // TIFF with IPTC keywords, GPS and an artist.
        let tif = d.appendingPathComponent("meta.tiff")
        try? Data(encoded(pattern(width: 300, height: 200, alpha: false), .tiff, [
            kCGImagePropertyGPSDictionary: SelfTest.privateGPS,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Taro Yamada"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["secret"]],
        ])).write(to: tif)
        switch await run(Act.imgStripMetadata, [tif]) {
        case .success:
            let p = imageProps(tif), left = metadataTags(tif)
            check("audit IMG-09: TIFF metadata removal drops IPTC, GPS and artist",
                  p[kCGImagePropertyIPTCDictionary] == nil && p[kCGImagePropertyGPSDictionary] == nil && onlyDisplayTags(left)
                  && occurrences(fileBytes(tif), Array("Taro".utf8)) == 0, left.joined(separator: " "))
        case .failure(let e): check("audit IMG-09: TIFF metadata removal", false, errText(e))
        }

        // HEIC with XMP (dates, creator), GPS, camera EXIF and a thumbnail.
        let heic = d.appendingPathComponent("meta.heic")
        if let dest = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil) {
            let meta = CGImageMetadataCreateMutable()
            _ = CGImageMetadataSetValueWithPath(meta, nil, "xmp:CreatorTool" as CFString, "27.0.1" as CFString)
            _ = CGImageMetadataSetValueWithPath(meta, nil, "xmp:CreateDate" as CFString, "2026-11-07T05:58:15" as CFString)
            _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, 35.6586 as CFNumber)
            _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, "iPhone" as CFString)
            _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 6 as CFNumber)
            CGImageDestinationAddImageAndMetadata(dest, pattern(width: 640, height: 480, alpha: false), meta,
                                                  [kCGImageDestinationEmbedThumbnail: true, kCGImageDestinationLossyCompressionQuality: 0.9,
                                                   kCGImagePropertyOrientation: 6] as CFDictionary)
            _ = CGImageDestinationFinalize(dest)
        }
        let heicBefore = topLeftIsRed(heic)
        check("audit fixture: HEIC carries XMP, GPS and a thumbnail, stored sideways", metadataTags(heic).contains("xmp:CreatorTool")
              && metadataTags(heic).contains { $0.hasPrefix("exif:GPS") } && hasEmbeddedThumbnail(heic) && (imageProps(heic)[kCGImagePropertyOrientation] as? Int) == 6)
        switch await run(Act.imgStripMetadata, [heic]) {
        case .success:
            let left = metadataTags(heic)
            check("audit IMG-09: HEIC metadata removal drops XMP, GPS, EXIF and the thumbnail, keeps orientation",
                  onlyDisplayTags(left) && !hasEmbeddedThumbnail(heic) && imageProps(heic)[kCGImagePropertyGPSDictionary] == nil
                  && (imageProps(heic)[kCGImagePropertyOrientation] as? Int) == 6 && topLeftIsRed(heic) == heicBefore
                  && occurrences(fileBytes(heic), Array("27.0.1".utf8)) == 0, left.joined(separator: " "))
        case .failure(let e): check("audit IMG-09: HEIC metadata removal", false, errText(e))
        }
        check("audit IMG-08: no hidden temporary files after metadata removal", hiddenFiles(d).isEmpty, hiddenFiles(d).joined(separator: " "))
    }

    // MARK: IMG-02, 03, 05, 08

    /// Colour name at a fraction of the displayed frame.
    func colourAt(_ img: CGImage, _ fx: Double, _ fy: Double) -> String {
        let p = pixel(img, x: Int(Double(img.width) * fx), yFromTop: Int(Double(img.height) * fy))
        return p.r > 150 && p.g < 100 ? "R" : p.g > 150 && p.r < 100 && p.b < 100 ? "G" : p.b > 150 && p.r < 100 ? "B" : p.a < 50 ? "T" : "W"
    }

    func frameImage(_ u: URL, _ i: Int) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 400]
        return CGImageSourceCreateThumbnailAtIndex(s, i, o as CFDictionary)
    }

    /// Red top-left, green top-right, blue bottom-left, white bottom-right; `shift` rotates the colours so frames differ.
    func quadrants(_ w: Int, _ h: Int, shift: Int = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colours = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                       CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)]
        let rects = [CGRect(x: 0, y: h / 2, width: w / 2, height: h - h / 2), CGRect(x: w / 2, y: h / 2, width: w - w / 2, height: h - h / 2),
                     CGRect(x: 0, y: 0, width: w / 2, height: h / 2), CGRect(x: w / 2, y: 0, width: w - w / 2, height: h / 2)]
        for k in 0..<4 { ctx.setFillColor(colours[(k + shift) % 4]); ctx.fill(rects[k]) }
        return ctx.makeImage()!
    }

    /// TL TR BL BR colours of a displayed frame.
    func quadCode(_ img: CGImage) -> String { colourAt(img, 0.25, 0.25) + colourAt(img, 0.75, 0.25) + colourAt(img, 0.25, 0.75) + colourAt(img, 0.75, 0.75) }

    func rotatedRight(_ q: String) -> String { let a = Array(q); return String([a[2], a[0], a[3], a[1]]) }

    func auditInPlaceFormats(_ d: URL) async {
        // Animated GIF: three different frames, delays and a loop count.
        let gif = d.appendingPathComponent("anim.gif")
        if let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 3, nil) {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for k in 0..<3 {
                CGImageDestinationAddImage(dest, quadrants(120, 80, shift: k), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.25]] as CFDictionary)
            }
            _ = CGImageDestinationFinalize(dest)
        }
        let gifBefore = (0..<frameCount(gif)).compactMap { frameImage(gif, $0).map(quadCode) }
        switch await run(Act.imgRotateRight, [gif]) {
        case .success:
            let after = (0..<frameCount(gif)).compactMap { frameImage(gif, $0).map(quadCode) }
            let delay = (imageProps(gif, 2)[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
            check("audit IMG-02: rotating an animated GIF keeps and turns every frame",
                  gifBefore.count == 3 && after == gifBefore.map(rotatedRight) && imageType(gif) == UTType.gif.identifier && abs(delay - 0.25) < 0.02,
                  "\(gifBefore) → \(after) delay \(delay)")
        case .failure(let e): check("audit IMG-02: rotating an animated GIF", false, errText(e))
        }
        switch await run(Act.imgStripMetadata, [gif]) {
        case .success: check("audit IMG-02: metadata removal keeps every GIF frame", frameCount(gif) == 3)
        case .failure(let e): check("audit IMG-02: metadata removal on a GIF", false, errText(e))
        }

        // Multi-page TIFF: every page turns.
        let tif = d.appendingPathComponent("pages.tiff")
        if let dest = CGImageDestinationCreateWithURL(tif as CFURL, UTType.tiff.identifier as CFString, 3, nil) {
            for k in 0..<3 { CGImageDestinationAddImage(dest, quadrants(120, 80, shift: k), nil) }
            _ = CGImageDestinationFinalize(dest)
        }
        let pagesBefore = (0..<frameCount(tif)).compactMap { frameImage(tif, $0).map(quadCode) }
        switch await run(Act.imgRotateRight, [tif]) {
        case .success:
            let after = (0..<frameCount(tif)).compactMap { frameImage(tif, $0).map(quadCode) }
            check("audit IMG-05: rotating a multi-page TIFF turns every page", pagesBefore.count == 3 && after == pagesBefore.map(rotatedRight),
                  "\(pagesBefore) → \(after)")
        case .failure(let e): check("audit IMG-05: rotating a multi-page TIFF", false, errText(e))
        }

        // Formats without an orientation tag stay in their format (ICO with two sizes, TGA) or are refused (JPEG 2000).
        let ico = d.appendingPathComponent("icon.ico")
        if let dest = CGImageDestinationCreateWithURL(ico as CFURL, UTType.ico.identifier as CFString, 2, nil) {
            CGImageDestinationAddImage(dest, quadrants(64, 64), nil); CGImageDestinationAddImage(dest, quadrants(32, 32), nil)
            _ = CGImageDestinationFinalize(dest)
        }
        let icoBefore = frameImage(ico, 0).map(quadCode)
        switch await run(Act.imgRotateRight, [ico]) {
        case .success:
            check("audit IMG-03: rotating an ICO keeps ICO data and both sizes",
                  imageType(ico) == UTType.ico.identifier && frameCount(ico) == 2 && frameImage(ico, 0).map(quadCode) == icoBefore.map(rotatedRight),
                  imageType(ico))
        case .failure(let e): check("audit IMG-03: rotating an ICO", false, errText(e))
        }
        let tga = d.appendingPathComponent("pic.tga")
        try? Data(encoded(quadrants(120, 80), UTType(filenameExtension: "tga") ?? .image)).write(to: tga)
        let tgaBefore = frameImage(tga, 0).map(quadCode)
        switch await run(Act.imgFlipH, [tga]) {
        case .success:
            check("audit IMG-03: flipping a TGA keeps TGA data", imageType(tga) == "com.truevision.tga-image"
                  && frameImage(tga, 0).map(quadCode) == tgaBefore.map { q in let a = Array(q); return String([a[1], a[0], a[3], a[2]]) }, imageType(tga))
        case .failure(let e): check("audit IMG-03: flipping a TGA", false, errText(e))
        }
        let avif = d.appendingPathComponent("photo.avif")
        try? Data(encoded(quadrants(240, 160), UTType(filenameExtension: "avif") ?? .image, [kCGImageDestinationLossyCompressionQuality: 0.8])).write(to: avif)
        if imageType(avif) == "public.avif" {
            let avifBefore = frameImage(avif, 0).map(quadCode)
            switch await run(Act.imgRotateRight, [avif]) {
            case .success:
                check("audit IMG-03: rotating an AVIF keeps AVIF data", imageType(avif) == "public.avif"
                      && frameImage(avif, 0).map(quadCode) == avifBefore.map(rotatedRight), imageType(avif))
            case .failure(let e): check("audit IMG-03: rotating an AVIF", false, errText(e))
            }
        } else {
            skip("audit IMG-03: AVIF", "this system cannot write AVIF")
        }
        let jp2 = d.appendingPathComponent("scan.jp2")
        try? Data(encoded(quadrants(120, 80), UTType(filenameExtension: "jp2") ?? .image)).write(to: jp2)
        let jp2Bytes = fileBytes(jp2)
        switch await run(Act.imgRotateRight, [jp2]) {
        case .success: check("audit IMG-03/IMG-17: JPEG 2000 rotation is refused, file untouched", false, "reported success; type now \(imageType(jp2))")
        case .failure(let e):
            check("audit IMG-03/IMG-17: JPEG 2000 rotation is refused, file untouched", fileBytes(jp2) == jp2Bytes && !jp2Bytes.isEmpty && errText(e).contains("JP2"), errText(e))
        }
        check("audit IMG-08: no hidden temporary files after in-place actions", hiddenFiles(d).isEmpty, hiddenFiles(d).joined(separator: " "))
    }

    // MARK: IMG-04

    /// An HDR photo with an ISO gain map, stored sideways, like an iPhone HEIC.
    func auditHDRPhoto(_ d: URL) async {
        guard #available(macOS 15.0, *) else { skip("audit IMG-04: HDR HEIC", "needs macOS 15"); return }
        let dir = d.appendingPathComponent("hdr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let w = 300, h = 200
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return }
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.1, 0.1, 0.8, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(colorSpace: space, components: [3.0, 0.3, 0.3, 1])!); ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        guard let img = ctx.makeImage() else { return }
        func gainMap(_ u: URL) -> Bool {
            CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceCopyAuxiliaryDataInfoAtIndex($0, 0, kCGImageAuxiliaryDataTypeISOGainMap) } != nil
        }
        for (ext, type) in [("heic", UTType.heic), ("jpg", UTType.jpeg)] {
            for op in [Act.imgRotateRight, Act.imgFlipH, Act.imgStripMetadata] {
                let f = dir.appendingPathComponent("hdr-\(op).\(ext)")
                try? Data(encoded(img, type, [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap, kCGImagePropertyOrientation: 6,
                                              kCGImagePropertyGPSDictionary: SelfTest.privateGPS])).write(to: f)
                guard gainMap(f) else { skip("audit IMG-04: \(ext) \(op)", "ImageIO wrote no gain map"); continue }
                let sizeBefore = size(f)
                let before = frameImage(f, 0).map(quadCode)
                switch await run(op, [f]) {
                case .success:
                    let after = frameImage(f, 0).map(quadCode)
                    let expected: String? = op == Act.imgRotateRight ? before.map(rotatedRight)
                        : op == Act.imgFlipH ? before.map { q in let a = Array(q); return String([a[1], a[0], a[3], a[2]]) } : before
                    check("audit IMG-04: \(op) on an HDR \(ext.uppercased()) keeps the gain map, format and size",
                          gainMap(f) && imageType(f) == type.identifier && size(f) < sizeBefore * 3 / 2 && after == expected,
                          "gain map \(gainMap(f)), \(sizeBefore) → \(size(f)) bytes, \(before ?? "?") → \(after ?? "?")")
                case .failure(let e): check("audit IMG-04: \(op) on an HDR \(ext.uppercased())", false, errText(e))
                }
            }
        }
        check("audit IMG-08: no hidden temporary files after HDR in-place actions", hiddenFiles(dir).isEmpty, hiddenFiles(dir).joined(separator: " "))
    }

    // MARK: IMG-06

    func lineImage(_ text: String, font: String) -> CGImage {
        let w = 1400, h = 420
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(in: CGRect(x: 40, y: 20, width: w - 80, height: h - 40),
                                withAttributes: [.font: NSFont(name: font, size: 44) ?? NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    func auditOCRLanguages(_ d: URL) async {
        let en = d.appendingPathComponent("english.png")
        try? writeImage(lineImage("Invoice 2026-0418\nTotal: $1,284.00 due December 25, 2026\nReference: AB-7731-QX\nBill to: Northline Studio", font: "Helvetica"),
                        to: en, type: .png, extra: [:])
        switch await run(Act.imgOCR, [en]) {
        case .success(let r):
            let text = (try? String(contentsOf: r.outputs[0], encoding: .utf8)) ?? ""
            check("audit IMG-06: English OCR has plain punctuation and letters", text.contains("Total: $1,284.00") && text.contains("AB-7731-QX")
                  && text.contains("Bill to:") && !text.contains("：") && !text.contains("×"), text)
        case .failure(let e): check("audit IMG-06: English OCR", false, errText(e))
        }
        let mixed = d.appendingPathComponent("mixed.png")
        try? writeImage(lineImage("請求書 合計金額 12,345円\nInvoice Total: $99.50 due Friday\nお支払い期限：2026年12月25日", font: "HiraginoSans-W3"),
                        to: mixed, type: .png, extra: [:])
        switch await run(Act.imgOCR, [mixed]) {
        case .success(let r):
            let text = (try? String(contentsOf: r.outputs[0], encoding: .utf8)) ?? ""
            check("audit IMG-06: mixed Japanese / English OCR keeps the Japanese lines and reads the English line",
                  text.contains("請求書") && text.contains("12,345") && text.contains("2026年12月25日") && text.contains("Total: $99.50"), text)
        case .failure(let e): check("audit IMG-06: mixed OCR", false, errText(e))
        }
        // A scanned English page through PDF OCR (same languages).
        let pdf = d.appendingPathComponent("scan-en.pdf")
        let page = lineImage("Total: $1,284.00 due December 25, 2026\nReference: AB-7731-QX\nBill to: Northline Studio", font: "Helvetica")
        var box = CGRect(x: 0, y: 0, width: 700, height: 210)
        if let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) { ctx.beginPDFPage(nil); ctx.draw(page, in: box); ctx.endPDFPage(); ctx.closePDF() }
        switch await run(Act.pdfOCR, [pdf]) {
        case .success(let r):
            let text = pdfText(r.outputs[0])
            check("audit IMG-06: PDF OCR of an English scan has plain punctuation", text.contains("Total:") && text.contains("AB-7731-QX") && !text.contains("："), text)
        case .failure(let e): check("audit IMG-06: PDF OCR of an English scan", false, errText(e))
        }
    }

    // MARK: IMG-14

    func auditTruncated(_ d: URL) async {
        for (name, type) in [("cut.jpg", UTType.jpeg), ("cut.png", UTType.png)] {
            let full = encoded(noise(width: 600, height: 400), type, [kCGImageDestinationLossyCompressionQuality: 0.9])
            let f = d.appendingPathComponent(name)
            try? Data(full.prefix(full.count * 6 / 10)).write(to: f)
            switch await run(type == .png ? Act.toJPEG : Act.toPNG, [f]) {
            case .success(let r): check("audit IMG-14: truncated \(name) is refused when converting", false, "wrote \(r.outputs.map(\.lastPathComponent))")
            case .failure(let e): check("audit IMG-14: truncated \(name) is refused when converting", errText(e).contains(name), errText(e))
            }
            switch await run(Act.imgResize50, [f]) {
            case .success: check("audit IMG-14: truncated \(name) is refused when resizing", false)
            case .failure(let e): check("audit IMG-14: truncated \(name) is refused when resizing", errText(e).contains(name), errText(e))
            }
        }
    }

    // MARK: IMG-10, IMG-16

    /// Colours of the stored pixels, ignoring any orientation tag (what decoders that ignore EXIF show).
    func storedQuadCode(_ u: URL) -> String? {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
        return quadCode(img)
    }

    func auditPNGPixelsAndConversions(_ d: URL) async {
        let png = d.appendingPathComponent("turn.png")
        try? writeImage(quadrants(120, 80), to: png, type: .png, extra: [kCGImagePropertyOrientation: 6])
        let shown = frameImage(png, 0).map(quadCode)
        switch await run(Act.imgRotateRight, [png]) {
        case .success:
            let o = imageProps(png)[kCGImagePropertyOrientation] as? Int ?? 1
            check("audit IMG-10: rotating a PNG turns the pixels (no orientation tag left)",
                  o == 1 && storedQuadCode(png) == shown.map(rotatedRight) && frameImage(png, 0).map(quadCode) == shown.map(rotatedRight),
                  "orientation \(o), stored \(storedQuadCode(png) ?? "?"), shown before \(shown ?? "?")")
        case .failure(let e): check("audit IMG-10: rotating a PNG", false, errText(e))
        }
        // An opaque photo stored sideways (as from an iPhone) converted to PNG and TIFF.
        let heic = d.appendingPathComponent("opaque.heic")
        try? writeImage(quadrants(600, 400), to: heic, type: .heic, extra: [kCGImagePropertyOrientation: 6])
        for (action, ext) in [(Act.toPNG, "png"), (Act.toTIFF, "tiff")] {
            switch await run(action, [heic]) {
            case .success(let r):
                let p = imageProps(r.outputs[0])
                let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let compressed = ext == "png" || (tiff?[kCGImagePropertyTIFFCompression] as? Int ?? 1) != 1
                check("audit IMG-16: HEIC → \(ext.uppercased()) has no unused alpha channel\(ext == "tiff" ? " and is compressed" : "")",
                      (p[kCGImagePropertyHasAlpha] as? Bool ?? false) == false && compressed && frameImage(r.outputs[0], 0).map(quadCode) == frameImage(heic, 0).map(quadCode),
                      "\(p[kCGImagePropertyHasAlpha] ?? "-") \(tiff?[kCGImagePropertyTIFFCompression] ?? "-")")
            case .failure(let e): check("audit IMG-16: HEIC → \(ext)", false, errText(e))
            }
        }
    }

    // MARK: IMG-17, IMG-18

    func auditImageMenus() {
        func actions(_ names: [String]) -> Set<String> {
            var out = Set<String>()
            func walk(_ nodes: [MenuNode]) { for n in nodes { if let a = n.action { out.insert(a) }; walk(n.children) } }
            walk(ActionCatalog.menu(for: names.map { URL(fileURLWithPath: "/tmp/" + $0) }))
            return out
        }
        let inPlace: Set<String> = [Act.imgRotateRight, Act.imgRotateLeft, Act.imgFlipH, Act.imgFlipV, Act.imgStripMetadata]
        check("audit IMG-18: SVG gets no image menu", actions(["logo.svg"]).isEmpty, actions(["logo.svg"]).sorted().joined(separator: " "))
        check("audit IMG-17: WebP and DNG offer no rotate, flip or metadata removal",
              actions(["a.webp"]).isDisjoint(with: inPlace) && actions(["a.dng"]).isDisjoint(with: inPlace) && actions(["a.jp2"]).isDisjoint(with: inPlace)
              && actions(["a.webp", "b.png"]).isDisjoint(with: inPlace) && actions(["a.webp"]).contains(Act.toPNG))
        check("audit IMG-17: JPEG, PNG, HEIC, GIF and TIFF still offer them",
              ["a.jpg", "a.png", "a.heic", "a.gif", "a.tiff"].allSatisfy { inPlace.isSubset(of: actions([$0])) }
              && actions(["a.png", "b.jpg"]).contains(Act.imgStripMetadata))
    }
}
