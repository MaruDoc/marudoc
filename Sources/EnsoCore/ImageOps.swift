import Foundation
import CoreGraphics
import CoreImage
import Compression
import ImageIO
import UniformTypeIdentifiers
import Vision
import EnsoShared
import EnsoDoc
import EnsoPDF

public enum ImageOps {

    // MARK: Loading / writing

    struct Loaded {
        var image: CGImage
        var properties: [CFString: Any]
        var type: UTType
    }

    /// Full-resolution image with EXIF orientation applied. Nil for unreadable files and for files that stop
    /// before the end of their picture data (ImageIO would fill the missing part with grey or black).
    static func loadOriented(_ url: URL) -> Loaded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), ImageCodec.isWithinLimits(src),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              !ImageFile.isTruncated(url) else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        // Turning a HEIC / AVIF picture this way adds an alpha channel it does not have; PNG and TIFF outputs would
        // carry it (a third more data, and a TIFF twice the size). Keep the source's opaque layout.
        if hasAlpha(img), let stored = CGImageSourceCreateImageAtIndex(src, 0, nil), !hasAlpha(stored), let opaque = opaqueCopy(img) { img = opaque }
        let type = (CGImageSourceGetType(src) as String?).flatMap { UTType($0) } ?? .png
        return Loaded(image: img, properties: props, type: type)
    }

    /// The same pixels without an alpha channel (for images whose alpha is 1 everywhere).
    static func opaqueCopy(_ img: CGImage) -> CGImage? {
        guard let space = img.colorSpace, img.bitsPerComponent == 8 || img.bitsPerComponent == 16,
              !img.bitmapInfo.contains(.floatComponents) else { return nil }
        let info = space.model == .monochrome ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: img.bitsPerComponent, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    /// `loadOriented`, with the reason when it fails.
    static func load(_ url: URL) throws -> Loaded {
        if let l = loadOriented(url) { return l }
        throw ImageFile.isTruncated(url) ? ImageFile.truncatedError(url.lastPathComponent) : DocIOError.unreadable(url.lastPathComponent)
    }

    static func utType(for format: String) -> UTType {
        switch format.lowercased() {
        case "jpeg", "jpg": return .jpeg
        case "heic", "heif": return .heic
        case "tiff", "tif": return .tiff
        case "gif": return .gif
        case "bmp": return .bmp
        default: return .png
        }
    }

    static func ext(for type: UTType) -> String {
        if type.conforms(to: .jpeg) { return "jpg" }
        if type.conforms(to: .heic) { return "heic" }
        if type.conforms(to: .tiff) { return "tiff" }
        if type.conforms(to: .gif) { return "gif" }
        if type.conforms(to: .bmp) { return "bmp" }
        return "png"
    }

    /// Writes an image. Metadata from the source is carried over except orientation (pixels are already upright).
    static func write(_ image: CGImage, to url: URL, format: String, quality: Double = 0.92, dpi: Double? = nil,
                      metadata: [CFString: Any]? = nil, stripLocation: Bool = false) throws {
        let type = utType(for: format)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw DocIOError.writeFailed(url.lastPathComponent)
        }
        var props: [CFString: Any] = metadata ?? [:]
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = 1; props[kCGImagePropertyTIFFDictionary] = tiff }
        props[kCGImagePropertyPixelWidth] = nil
        props[kCGImagePropertyPixelHeight] = nil
        if stripLocation { props[kCGImagePropertyGPSDictionary] = nil }
        if let dpi { props[kCGImagePropertyDPIWidth] = dpi; props[kCGImagePropertyDPIHeight] = dpi }
        if type == .jpeg || type == .heic { props[kCGImageDestinationLossyCompressionQuality] = quality }
        if type == .tiff {
            // LZW (lossless): an uncompressed 24 MP TIFF is over 70 MB.
            // A HEIC source reports its HEVC tile size here; carried over, ImageIO writes an uncompressed tiled TIFF.
            var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5
            tiff[kCGImagePropertyTIFFTileWidth] = nil
            tiff[kCGImagePropertyTIFFTileLength] = nil
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        // JPEG has no alpha: flatten onto white so transparent areas don't turn black.
        var img = image
        if type == .jpeg, hasAlpha(image), let flat = flattened(image) { img = flat }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DocIOError.writeFailed(url.lastPathComponent) }
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: return false; default: return true }
    }

    /// True when the image has an alpha channel and actually uses it (checked on a 256 px sample).
    static func usesTransparency(_ img: CGImage) -> Bool {
        guard hasAlpha(img) else { return false }
        let k = min(1, 256 / Double(max(img.width, img.height)))
        let w = max(1, Int(Double(img.width) * k)), h = max(1, Int(Double(img.height) * k))
        var px = [UInt8](repeating: 255, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 3, to: px.count, by: 4) where px[i] < 250 { return true }
        return false
    }

    static func flattened(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    // MARK: Convert

    static func convert(_ file: URL, to format: String) throws -> URL {
        let l = try load(file)
        let target = utType(for: format)
        let out = OutputNamer.file(for: file, ext: ext(for: target), tag: l.type == target ? L("変換") : nil)
        try write(l.image, to: out, format: format, quality: 0.92, metadata: l.properties)
        return out
    }

    // MARK: Orientation (in place, lossless)

    public enum Orientation { case right, left, flipH, flipV }

    /// Rotates or flips the file itself. The result has the same format, keeps every frame, page and auxiliary
    /// image (HDR gain map, Portrait matte) and nothing is re-compressed. Formats where that cannot be done are
    /// refused, and the original stays byte-identical: the new bytes are built in memory, written next to the file,
    /// re-read and checked before they replace it.
    static func reorient(_ file: URL, _ op: Orientation) throws -> SafeWrite.Backup {
        let input = try InPlace.Input(file)
        let target = combine(input.orientation, op)
        let output = try InPlace.building(input, rotate: true) { () throws -> [UInt8] in
            switch input.format {
            case .png where PNGFile.canTurnPixels(input.bytes):
                // Decoders that ignore the EXIF orientation (many web and Linux tools) would show a tag-only turn
                // unrotated, so the pixels themselves are turned; PNG is lossless, so nothing is lost.
                return try PNGFile.turned(input.bytes, target)
            case .jpeg:
                // Only the orientation tag changes. ImageIO leaves the XMP copy of the orientation as it was.
                return JPEGFile.withXMPOrientation(try InPlace.orientationCopy(input, target), target)
            case .png:
                // APNG and interlaced PNG: only the orientation tag changes, every frame stays.
                return try InPlace.orientationCopy(input, target)
            case .tiff:
                return try TIFFFile.reoriented(input.bytes, op)
            case .gif:
                return try GIFFile.transformed(input.bytes, op)
            case .heif:
                return try BMFFFile.reoriented(input.bytes, current: input.orientation, target: target)
            case .bmp, .tga, .ico:
                // Uncompressed or lossless formats without an orientation tag: the pixels are moved exactly.
                return try InPlace.reencoded(input, op)
            case .other:
                throw InPlace.refusal(input, rotate: true)
            }
        }
        return try SafeWrite.replace(file) { tmp in
            try Data(output).write(to: tmp)
            try InPlace.verify(input, written: tmp, op: op)
        }
    }

    /// EXIF orientation algebra. Each orientation is the 2×2 matrix that maps stored pixels to the displayed image
    /// (x right, y down). Applying a user operation U to what is displayed gives U × M; we look up that matrix.
    static let orientationMatrices: [UInt32: [Int]] = [
        1: [1, 0, 0, 1], 2: [-1, 0, 0, 1], 3: [-1, 0, 0, -1], 4: [1, 0, 0, -1],
        5: [0, 1, 1, 0], 6: [0, -1, 1, 0], 7: [0, -1, -1, 0], 8: [0, 1, -1, 0],
    ]

    static func combine(_ o: UInt32, _ op: Orientation) -> UInt32 {
        let m = orientationMatrices[o] ?? [1, 0, 0, 1]
        let u: [Int]
        switch op {
        case .right: u = [0, -1, 1, 0]
        case .left: u = [0, 1, -1, 0]
        case .flipH: u = [-1, 0, 0, 1]
        case .flipV: u = [1, 0, 0, -1]
        }
        let r = [u[0] * m[0] + u[1] * m[2], u[0] * m[1] + u[1] * m[3],
                 u[2] * m[0] + u[3] * m[2], u[2] * m[1] + u[3] * m[3]]
        return orientationMatrices.first { $0.value == r }?.key ?? 1
    }

    // MARK: Resize / compress

    enum ResizeSpec { case scale(Double), longEdge(Int) }

    static func resize(_ file: URL, _ spec: ResizeSpec) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), ImageCodec.isWithinLimits(src),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { throw DocIOError.unreadable(file.lastPathComponent) }
        if ImageFile.isTruncated(file) { throw ImageFile.truncatedError(file.lastPathComponent) }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let long = max(w, h)
        let target: Int
        let tag: String
        switch spec {
        case .scale(let k): target = max(1, Int(Double(long) * k)); tag = "\(Int(k * 100))%"
        case .longEdge(let e): target = min(e, long); tag = "\(e)px"
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: target]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw DocIOError.unreadable(file.lastPathComponent) }
        let type = (CGImageSourceGetType(src) as String?).flatMap { UTType($0) } ?? .png
        let fmt = ext(for: type)
        let out = OutputNamer.file(for: file, ext: fmt, tag: tag)
        try write(img, to: out, format: fmt, quality: 0.9, metadata: props)
        return out
    }

    static func compress(_ file: URL, quality: Double, strong: Bool) throws -> URL {
        let l = try load(file)
        var img = l.image
        if strong, max(img.width, img.height) > 2560 {
            let k = 2560 / Double(max(img.width, img.height))
            img = scaled(img, k) ?? img
        }
        // Keep transparency as PNG (or HEIC), everything else as JPEG / HEIC.
        let keepHEIC = l.type.conforms(to: .heic)
        let fmt: String = usesTransparency(img) && !keepHEIC ? "png" : (keepHEIC ? "heic" : "jpeg")
        if fmt == "png", !strong { throw EngineError.noGain }
        if fmt == "png", let half = scaled(img, 0.5) { img = half }
        let out = OutputNamer.file(for: file, ext: fmt == "jpeg" ? "jpg" : fmt, tag: L("圧縮"))
        try write(img, to: out, format: fmt, quality: quality, metadata: l.properties)
        let before = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if after >= before {
            try? FileManager.default.removeItem(at: out)
            throw EngineError.noGain
        }
        return out
    }

    static func scaled(_ img: CGImage, _ k: Double) -> CGImage? {
        let W = max(1, Int(Double(img.width) * k)), H = max(1, Int(Double(img.height) * k))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        return ctx.makeImage()
    }

    // MARK: Background removal (macOS 14+ Vision)

    static func removeBackground(_ file: URL) throws -> URL {
        let l = try load(file)
        let cut = try subjectCutout(l.image)
        let out = OutputNamer.file(for: file, ext: "png", tag: L("背景なし"))
        try write(cut, to: out, format: "png")
        return out
    }

    public static func subjectCutout(_ image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
            throw EngineError.failed(L("被写体が見つかりませんでした"))
        }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw EngineError.failed(L("背景を削除できませんでした")) }
        return cg
    }

    // MARK: Metadata (in place)

    /// Removes location, camera, date, author and editing metadata, embedded thumbnails and text notes from the file
    /// itself. Kept: what is needed to show the picture as before (orientation, colour profile, resolution) and every
    /// frame, page and auxiliary image. The compressed picture data is copied unchanged. The written file is re-read
    /// and checked; if anything personal is still there, or the picture changed, the original is left untouched.
    static func stripMetadata(_ file: URL) throws -> SafeWrite.Backup {
        let input = try InPlace.Input(file)
        let output = try InPlace.building(input, rotate: false) { () throws -> [UInt8] in
            switch input.format {
            case .jpeg: return try JPEGFile.stripped(input.bytes, orientation: input.orientation)
            case .png: return try PNGFile.stripped(input.bytes, orientation: input.orientation)
            case .tiff: return try TIFFFile.stripped(input.bytes)
            case .gif: return try GIFFile.stripped(input.bytes)
            case .heif: return try BMFFFile.stripped(input.bytes)
            case .bmp, .tga, .ico: return try InPlace.reencoded(input, nil)
            case .other: throw InPlace.refusal(input, rotate: false)
            }
        }
        return try SafeWrite.replace(file) { tmp in
            try Data(output).write(to: tmp)
            try InPlace.verify(input, written: tmp, op: nil)
        }
    }
}

// MARK: - In-place rewrites: shared input, verification and refusals

/// Rotate, flip and metadata removal change the user's file. They work on the file's bytes so that nothing is
/// re-compressed, and every result is re-read before it replaces the original.
enum InPlace {
    enum Format { case jpeg, png, tiff, gif, heif, bmp, tga, ico, other }

    struct Input {
        let url: URL
        let bytes: [UInt8]
        let source: CGImageSource
        let type: String
        let format: Format
        let count: Int
        let orientation: UInt32
        let auxTypes: Set<String>

        init(_ url: URL) throws {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url), let src = CGImageSourceCreateWithData(data as CFData, nil),
                  ImageCodec.isWithinLimits(src), let type = CGImageSourceGetType(src) as String?,
                  CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else { throw DocIOError.unreadable(name) }
            self.url = url
            bytes = [UInt8](data)
            source = src
            self.type = type
            format = InPlace.format(type)
            count = CGImageSourceGetCount(src)
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            auxTypes = InPlace.auxTypes(src)
            // A cut-off file shows grey or black where data is missing; rewriting it would make that permanent.
            if ImageFile.isTruncated(bytes, type: type) { throw ImageFile.truncatedError(name) }
        }
    }

    static func format(_ type: String) -> Format {
        switch type {
        case UTType.jpeg.identifier: return .jpeg
        case UTType.png.identifier: return .png
        case UTType.tiff.identifier: return .tiff
        case UTType.gif.identifier: return .gif
        case UTType.heic.identifier, UTType.heif.identifier, "public.avif": return .heif
        case UTType.bmp.identifier: return .bmp
        case "com.truevision.tga-image": return .tga
        case UTType.ico.identifier: return .ico
        default: return .other
        }
    }

    static let auxiliaryKinds: [CFString] = {
        var kinds = baseAuxiliaryKinds
        if #available(macOS 15.0, *) { kinds.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        return kinds
    }()
    static let baseAuxiliaryKinds: [CFString] = [
        kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeDepth,
        kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
    ]

    static func auxTypes(_ src: CGImageSource) -> Set<String> {
        Set(auxiliaryKinds.filter { CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, $0) != nil }.map { $0 as String })
    }

    /// Short format name for messages ("WEBP", "JP2", "DNG").
    static func formatName(_ input: Input) -> String {
        let ext = UTType(input.type)?.preferredFilenameExtension ?? input.url.pathExtension
        return ext.uppercased()
    }

    static func refusal(_ input: Input, rotate: Bool) -> EngineError {
        let name = formatName(input)
        return .failed(String(format: rotate ? L("%@ の画像はそのまま回転・反転できません。元のファイルは変更していません")
                                             : L("%@ の画像からは位置情報などを削除できません。元のファイルは変更していません"), name))
    }

    /// Runs a format rewriter. A file whose structure it does not handle (e.g. a GIF with a text overlay, a TIFF
    /// with Photoshop layers, a HEIF image sequence) is refused with a clear message instead of a technical one.
    static func building(_ input: Input, rotate: Bool, _ make: () throws -> [UInt8]) throws -> [UInt8] {
        do {
            return try make()
        } catch is ImageFile.Malformed {
            throw EngineError.failed(rotate ? L("この画像は作りが特殊なため、そのまま回転・反転できません。元のファイルは変更していません")
                                            : L("この画像は作りが特殊なため、位置情報などを削除できません。元のファイルは変更していません"))
        }
    }

    static func notVerified(rotate: Bool, _ why: String) -> EngineError {
        .failed((rotate ? L("回転・反転した結果を確認できなかったため、元のファイルは変更していません")
                        : L("位置情報などを削除しきれなかったため、元のファイルは変更していません")) + " (\(why))")
    }

    /// ImageIO's own lossless path: only the orientation tag is rewritten (JPEG, PNG and APNG).
    static func orientationCopy(_ input: Input, _ target: UInt32) throws -> [UInt8] {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, input.type as CFString, input.count, nil) else {
            throw refusal(input, rotate: true)
        }
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, input.source, [kCGImageDestinationOrientation: target] as CFDictionary, &err) else {
            _ = err?.takeRetainedValue()
            throw refusal(input, rotate: true)
        }
        return [UInt8](data as Data)
    }

    /// BMP, TGA and ICO: every frame is decoded, its pixels moved exactly (no resampling, same pixel format) and
    /// written back in the same format without metadata. The check in `verify` compares the pixels.
    static func reencoded(_ input: Input, _ op: ImageOps.Orientation?) throws -> [UInt8] {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, input.type as CFString, input.count, nil) else {
            throw refusal(input, rotate: op != nil)
        }
        for i in 0..<input.count {
            guard let img = CGImageSourceCreateImageAtIndex(input.source, i, nil) else { throw DocIOError.unreadable(input.url.lastPathComponent) }
            let out = op == nil ? img : movedPixels(img, op!)
            guard let out else { throw refusal(input, rotate: op != nil) }
            CGImageDestinationAddImage(dest, out, nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw refusal(input, rotate: op != nil) }
        return [UInt8](data as Data)
    }

    /// The image turned or mirrored by copying whole pixels, so values stay exactly the same.
    static func movedPixels(_ img: CGImage, _ op: ImageOps.Orientation) -> CGImage? {
        guard img.bitsPerPixel % 8 == 0, let space = img.colorSpace, let cf = img.dataProvider?.data,
              let src = CFDataGetBytePtr(cf) else { return nil }
        let bpp = img.bitsPerPixel / 8, w = img.width, h = img.height, bpr = img.bytesPerRow
        guard CFDataGetLength(cf) >= (h - 1) * bpr + w * bpp else { return nil }
        let swap = op == .right || op == .left
        let W = swap ? h : w, H = swap ? w : h
        var out = [UInt8](repeating: 0, count: W * H * bpp)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<H {
                for x in 0..<W {
                    let sx: Int, sy: Int
                    switch op {
                    case .right: sx = y; sy = h - 1 - x
                    case .left: sx = w - 1 - y; sy = x
                    case .flipH: sx = w - 1 - x; sy = y
                    case .flipV: sx = x; sy = h - 1 - y
                    }
                    let s = sy * bpr + sx * bpp, d = (y * W + x) * bpp
                    for k in 0..<bpp { dst[d + k] = src[s + k] }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: img.bitsPerComponent, bitsPerPixel: img.bitsPerPixel, bytesPerRow: W * bpp,
                       space: space, bitmapInfo: img.bitmapInfo, provider: provider, decode: img.decode,
                       shouldInterpolate: false, intent: img.renderingIntent)
    }

    // MARK: Verification

    /// Re-reads the written file. It must be the same format with the same number of frames / pages and the same
    /// auxiliary images, every frame must show the original picture (turned by `op`), and after metadata removal
    /// nothing from the removal list may be left. Throws, so SafeWrite discards the file and keeps the original.
    static func verify(_ input: Input, written: URL, op: ImageOps.Orientation?) throws {
        let rotate = op != nil
        guard let out = CGImageSourceCreateWithURL(written as CFURL, nil), let type = CGImageSourceGetType(out) as String? else {
            throw notVerified(rotate: rotate, "unreadable")
        }
        guard type == input.type else { throw notVerified(rotate: rotate, "type \(type)") }
        guard CGImageSourceGetCount(out) == input.count else { throw notVerified(rotate: rotate, "frames \(CGImageSourceGetCount(out))/\(input.count)") }
        guard auxTypes(out) == input.auxTypes else { throw notVerified(rotate: rotate, "auxiliary images") }
        for i in 0..<input.count {
            guard let a = render(input.source, i), let b = render(out, i) else { throw notVerified(rotate: rotate, "frame \(i + 1)") }
            let expected = op.flatMap { movedPixels(a, $0) } ?? a
            // Metadata removal copies the coded picture, so its render must match; a turn is compared after
            // resampling to the render size, which may differ by a little.
            guard let diff = meanDifference(expected, b), diff <= (rotate ? 3 : 1) else { throw notVerified(rotate: rotate, "picture \(i + 1)") }
            if !rotate {
                let left = remainingMetadata(out, i)
                if !left.isEmpty { throw notVerified(rotate: false, left.prefix(4).joined(separator: ", ")) }
            }
        }
    }

    /// A small upright sRGB render of one frame (orientation applied).
    static func render(_ src: CGImageSource, _ i: Int) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceShouldCacheImmediately: true]
        guard let t = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary),
              let ctx = CGContext(data: nil, width: t.width, height: t.height, bitsPerComponent: 8, bytesPerRow: t.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(t, in: CGRect(x: 0, y: 0, width: t.width, height: t.height))
        return ctx.makeImage()
    }

    /// Mean absolute difference per channel (0–255) of two renders of the same size, or nil if the sizes differ.
    static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height, a.bitsPerPixel == 32, b.bitsPerPixel == 32,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data,
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return nil }
        var total = 0
        for y in 0..<a.height {
            let ra = y * a.bytesPerRow, rb = y * b.bytesPerRow
            for x in 0..<(a.width * 4) { total += abs(Int(pa[ra + x]) - Int(pb[rb + x])) }
        }
        return Double(total) / Double(max(1, a.width * a.height * 4))
    }

    /// Keys that may stay after metadata removal: they only describe how to show the picture.
    static let allowedExif: Set<String> = [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifColorSpace].map { $0 as String }.reduce(into: []) { $0.insert($1) }
    static let personalTIFF: [CFString] = [kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFDocumentName,
                                           kCGImagePropertyTIFFHostComputer, kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
                                           kCGImagePropertyTIFFSoftware]
    static let personalPNG: [CFString] = [kCGImagePropertyPNGAuthor, kCGImagePropertyPNGComment, kCGImagePropertyPNGCopyright, kCGImagePropertyPNGCreationTime,
                                          kCGImagePropertyPNGDescription, kCGImagePropertyPNGDisclaimer, kCGImagePropertyPNGModificationTime,
                                          kCGImagePropertyPNGSoftware, kCGImagePropertyPNGSource, kCGImagePropertyPNGTitle, kCGImagePropertyPNGWarning]
    /// Metadata tags (ImageIO's XMP view, which also lists EXIF, TIFF, GPS and IPTC values) that may stay.
    static let allowedTags: Set<String> = ["tiff:Orientation", "tiff:XResolution", "tiff:YResolution", "tiff:ResolutionUnit",
                                           "exif:PixelXDimension", "exif:PixelYDimension", "exif:ColorSpace",
                                           // Structure and colour of the picture data (TIFF, and tiles of HEIF / AVIF).
                                           "tiff:ImageWidth", "tiff:ImageLength", "tiff:BitsPerSample", "tiff:SamplesPerPixel", "tiff:Compression",
                                           "tiff:PhotometricInterpretation", "tiff:PlanarConfiguration", "tiff:TileWidth", "tiff:TileLength",
                                           "tiff:WhitePoint", "tiff:PrimaryChromaticities", "tiff:TransferFunction", "tiff:YCbCrCoefficients",
                                           "tiff:YCbCrSubSampling", "tiff:YCbCrPositioning", "tiff:ReferenceBlackWhite"]

    /// What is still in frame `i` from the removal list: GPS, EXIF beyond the display basics, IPTC, XMP, maker
    /// notes, text chunks with personal fields, embedded thumbnails.
    static func remainingMetadata(_ src: CGImageSource, _ i: Int) -> [String] {
        var left: [String] = []
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
        if props[kCGImagePropertyGPSDictionary] != nil { left.append("GPS") }
        if props[kCGImagePropertyIPTCDictionary] != nil { left.append("IPTC") }
        if props[kCGImagePropertyExifAuxDictionary] != nil { left.append("ExifAux") }
        for k in props.keys where (k as String).hasPrefix("{Maker") { left.append(k as String) }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            left += exif.keys.map { $0 as String }.filter { !allowedExif.contains($0) }.map { "Exif " + $0 }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            left += personalTIFF.filter { tiff[$0] != nil }.map { "TIFF " + ($0 as String) }
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            left += personalPNG.filter { png[$0] != nil }.map { "PNG " + ($0 as String) }
        }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, i, nil), let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
            for tag in tags {
                let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? "?"
                let name = CGImageMetadataTagCopyName(tag) as String? ?? "?"
                if !allowedTags.contains("\(prefix):\(name)") { left.append("\(prefix):\(name)") }
            }
        }
        if let file = CGImageSourceCopyProperties(src, nil) as? [CFString: Any],
           let contents = file[kCGImagePropertyFileContentsDictionary] as? [CFString: Any],
           let images = contents[kCGImagePropertyImages] as? [[CFString: Any]], i < images.count,
           let thumbs = images[i][kCGImagePropertyThumbnailImages] as? [Any], !thumbs.isEmpty {
            left.append("thumbnail")
        }
        // JPEG and TIFF thumbnails are not listed there: ask for the embedded one only and see if it is smaller.
        if let type = CGImageSourceGetType(src) as String?, type == UTType.jpeg.identifier || type == UTType.tiff.identifier,
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
           let t = CGImageSourceCreateThumbnailAtIndex(src, i, [kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                                                                kCGImageSourceThumbnailMaxPixelSize: max(w, h)] as CFDictionary),
           max(t.width, t.height) < max(w, h) {
            left.append("thumbnail")
        }
        return left
    }
}

/// On-device text recognition (Vision).
public enum TextRecognizer {
    public static func recognize(url: URL, languages: [String]) throws -> String {
        return try recognize(cgImage: ImageOps.load(url).image, languages: languages)
    }

    /// English lines in a Japanese-first recognition are read again English-first (see `PDFOCR.readLines`).
    public static func recognize(cgImage: CGImage, languages: [String]) throws -> String {
        let lines = try PDFOCR.readLines(cgImage, languages: languages) { request in
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
        }
        return lines.map(\.text).joined(separator: "\n")
    }
}

// MARK: - Byte-level helpers shared by the format rewriters

enum ImageFile {
    struct Malformed: Error {}

    static func be16(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) << 8 | Int(d[o + 1]) }
    static func be32(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
    static func be64(_ d: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(d[o + $1]) } }
    static func le16(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
    static func put16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func put32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func put64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> (56 - 8 * UInt64($0)) & 0xFF) } }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// A big-endian TIFF block holding only an orientation tag: the EXIF kept in JPEG (APP1) and PNG (eXIf)
    /// after metadata removal, so portrait photos stay upright.
    static func orientationTIFF(_ o: UInt32) -> [UInt8] {
        [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, UInt8(o & 0xFF), 0, 0, 0, 0, 0, 0]
    }

    /// Sets the XMP copy of the orientation (`tiff:Orientation`, element or attribute form) inside `range` to
    /// `value`. The value is one digit, so the packet keeps its length and nothing else moves.
    static func patchXMPOrientation(_ d: inout [UInt8], _ range: Range<Int>, _ value: UInt32) {
        guard (1...8).contains(value), range.lowerBound >= 0, range.upperBound <= d.count else { return }
        for key in ["tiff:Orientation>", "tiff:Orientation=\"", "tiff:Orientation='"] {
            let k = Array(key.utf8)
            var i = range.lowerBound
            while i + k.count < range.upperBound {
                if d[i] == k[0], Array(d[i..<(i + k.count)]) == k {
                    let at = i + k.count
                    if (0x31...0x38).contains(d[at]), at + 1 < range.upperBound, !(0x30...0x39).contains(d[at + 1]) { d[at] = 0x30 + UInt8(value) }
                    i = at
                } else { i += 1 }
            }
        }
    }

    static func truncatedError(_ name: String) -> EngineError {
        .failed(String(format: L("「%@」は途中で切れているか壊れているため、読み込めませんでした"), name))
    }

    /// True when the file stops before the end of its picture data. ImageIO decodes such files without an error and
    /// fills the missing part with grey (JPEG) or black (PNG).
    static func isTruncated(_ d: [UInt8], type: String) -> Bool {
        switch type {
        case UTType.jpeg.identifier: return JPEGFile.endOfImage(d) == nil
        case UTType.png.identifier: return !PNGFile.isComplete(d)
        case UTType.gif.identifier: return (try? GIFFile.parse(d)) == nil
        case UTType.tiff.identifier: return TIFFFile.isTruncated(d)
        default: return false
        }
    }

    static func isTruncated(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src) as String? else { return false }
        return isTruncated([UInt8](data), type: type)
    }
}

// MARK: JPEG

enum JPEGFile {
    /// Walks the marker segments and entropy-coded data. Calls `segment` for every marker segment with its marker
    /// byte and the byte range of the whole segment (FF xx + length + payload), and `scan` for entropy-coded data.
    /// Returns the index just past EOI, or nil when the file ends before EOI (truncated or not a JPEG).
    @discardableResult
    static func walk(_ d: [UInt8], segment: (UInt8, Range<Int>) -> Void = { _, _ in }, scan: (Range<Int>) -> Void = { _ in }) -> Int? {
        guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else { return nil }
        var i = 2
        var inScan = false
        while i < d.count {
            if inScan {
                let start = i
                while i < d.count {
                    if d[i] == 0xFF, i + 1 < d.count {
                        let m = d[i + 1]
                        if m == 0x00 || (0xD0...0xD7).contains(m) { i += 2; continue }
                        if m == 0xFF { i += 1; continue }
                        break
                    }
                    i += 1
                }
                if i >= d.count { return nil }
                scan(start..<i)
                inScan = false
                continue
            }
            guard d[i] == 0xFF else { return nil }
            while i + 1 < d.count, d[i + 1] == 0xFF { i += 1 }
            guard i + 1 < d.count else { return nil }
            let m = d[i + 1]
            if m == 0xD9 { return i + 2 }
            if m == 0x01 || (0xD0...0xD7).contains(m) { segment(m, i..<(i + 2)); i += 2; continue }
            guard i + 3 < d.count else { return nil }
            let len = ImageFile.be16(d, i + 2)
            guard len >= 2, i + 2 + len <= d.count else { return nil }
            segment(m, i..<(i + 2 + len))
            if m == 0xDA { inScan = true }
            i += 2 + len
        }
        return nil
    }

    static func endOfImage(_ d: [UInt8]) -> Int? { walk(d) }

    static func withXMPOrientation(_ d: [UInt8], _ value: UInt32) -> [UInt8] {
        var out = d
        let ns = Array("http://ns.adobe.com/xap/1.0/".utf8)
        walk(d, segment: { m, r in
            if m == 0xE1, r.count > 4 + ns.count, Array(d[(r.lowerBound + 4)..<(r.lowerBound + 4 + ns.count)]) == ns {
                ImageFile.patchXMPOrientation(&out, r, value)
            }
        })
        return out
    }

    /// Keeps what decodes and colours the picture (frame, tables, scans, ICC profile, Adobe colour transform, JFIF
    /// density) and drops every other APPn and COM segment: EXIF (with its thumbnail), XMP, IPTC / Photoshop,
    /// maker data. The only EXIF written back is the orientation tag. Data after the picture goes too, except the
    /// images a Multi-Picture (MPF) index lists that belong to the picture (an HDR gain map, a depth map): those are
    /// cleaned the same way and the index is rebuilt for them. MPF preview images (large thumbnails) go.
    static func stripped(_ d: [UInt8], orientation: UInt32) throws -> [UInt8] {
        guard let primaryEnd = walk(d) else { throw ImageFile.Malformed() }
        var secondaries: [(attr: UInt32, bytes: [UInt8])] = []
        if let mp = multiPicture(d) {
            for e in mp.entries.dropFirst() {
                // Type code 0x01xxxx: large thumbnail (preview) — an embedded thumbnail by another name.
                if e.attr & 0x00FF_0000 == 0x0001_0000 { continue }
                let start = mp.header + e.offset
                guard e.offset > 0, start >= primaryEnd, start + e.size <= d.count else { throw ImageFile.Malformed() }
                let image = Array(d[start..<(start + e.size)])
                guard let end = walk(image) else { throw ImageFile.Malformed() }
                secondaries.append((e.attr, try cleaned(image[0..<end], orientation: nil, mpfImages: 0).bytes))
            }
        }
        let primaryAttr = multiPicture(d)?.entries.first?.attr ?? 0x2003_0000
        var (out, mpfAt) = try cleaned(d[0..<primaryEnd], orientation: orientation, mpfImages: secondaries.isEmpty ? 0 : secondaries.count + 1)
        if let mpfAt {
            // Fill the MP entries: attribute, size, offset from the MP header, no dependent images.
            let header = mpfAt + 8
            var entries = ImageFile.put32(Int(primaryAttr)) + ImageFile.put32(out.count) + ImageFile.put32(0) + [0, 0, 0, 0]
            var at = out.count
            for s in secondaries {
                entries += ImageFile.put32(Int(s.attr)) + ImageFile.put32(s.bytes.count) + ImageFile.put32(at - header) + [0, 0, 0, 0]
                at += s.bytes.count
            }
            out.replaceSubrange((header + 50)..<(header + 50 + entries.count), with: entries)
            for s in secondaries { out += s.bytes }
        }
        return out
    }

    /// The segment filter of `stripped` for one JPEG image (SOI to EOI). With `mpfImages` > 0 an empty MPF index
    /// for that many images is written where the original one was; its position is returned.
    static func cleaned(_ d: ArraySlice<UInt8>, orientation: UInt32?, mpfImages: Int) throws -> (bytes: [UInt8], mpfAt: Int?) {
        let d = Array(d)
        var out: [UInt8] = [0xFF, 0xD8]
        var mpfAt: Int?
        var exifPending = orientation != nil
        func flushExif() {
            guard exifPending, let orientation else { return }
            exifPending = false
            guard orientation != 1 else { return }
            let payload = Array("Exif".utf8) + [0, 0] + ImageFile.orientationTIFF(orientation)
            out += [0xFF, 0xE1] + ImageFile.put16(payload.count + 2) + payload
        }
        func starts(_ r: Range<Int>, _ s: String) -> Bool {
            let p = Array(s.utf8)
            return r.count >= 4 + p.count && Array(d[(r.lowerBound + 4)..<(r.lowerBound + 4 + p.count)]) == p
        }
        let end = walk(d, segment: { m, r in
            switch m {
            case 0xE0:
                // JFIF keeps its density but loses its thumbnail; JFXX (thumbnail) and other APP0 go. Without a
                // thumbnail the segment stays whole: Apple appends "AMPF" there to mark an HDR (gain map) JPEG.
                if starts(r, "JFIF\0"), r.count >= 18 {
                    if d[r.lowerBound + 16] == 0 || d[r.lowerBound + 17] == 0 {
                        out += d[r]
                    } else {
                        var seg = Array(d[r.lowerBound..<(r.lowerBound + 18)])
                        seg[2] = 0; seg[3] = 16; seg[16] = 0; seg[17] = 0
                        out += seg
                    }
                }
            case 0xE2:
                flushExif()
                // Colour profile and the ISO 21496-1 gain map description stay.
                if starts(r, "ICC_PROFILE\0") || starts(r, "urn:iso:std:iso:ts:21496:-1\0") { out += d[r] }
                if starts(r, "MPF\0"), mpfImages > 0, mpfAt == nil {
                    mpfAt = out.count
                    let tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8, 0, 3,
                                         0xB0, 0x00, 0, 7, 0, 0, 0, 4, 0x30, 0x31, 0x30, 0x30,
                                         0xB0, 0x01, 0, 4, 0, 0, 0, 1, 0, 0, 0, UInt8(mpfImages)]
                        + [0xB0, 0x02, 0, 7] + ImageFile.put32(16 * mpfImages) + ImageFile.put32(50) + [0, 0, 0, 0]
                        + [UInt8](repeating: 0, count: 16 * mpfImages)
                    let payload = Array("MPF".utf8) + [0] + tiff
                    out += [0xFF, 0xE2] + ImageFile.put16(payload.count + 2) + payload
                }
            case 0xEE:
                flushExif()
                if starts(r, "Adobe") { out += d[r] }
            case 0xE1, 0xE3...0xED, 0xEF, 0xFE:
                break
            default:
                flushExif()
                out += d[r]
            }
        }, scan: { r in out += d[r] })
        guard end != nil, mpfImages == 0 || mpfAt != nil, mpfImages < 256 else { throw ImageFile.Malformed() }
        out += [0xFF, 0xD9]
        return (out, mpfAt)
    }

    /// The Multi-Picture index in the first image: MP header position (its byte-order mark) and the entries.
    static func multiPicture(_ d: [UInt8]) -> (header: Int, entries: [(attr: UInt32, size: Int, offset: Int)])? {
        var found: Range<Int>?
        let tag = Array("MPF".utf8) + [0]
        walk(d, segment: { m, r in
            if found == nil, m == 0xE2, r.count > 16, Array(d[(r.lowerBound + 4)..<(r.lowerBound + 8)]) == tag { found = r }
        })
        guard let r = found else { return nil }
        let header = r.lowerBound + 8
        let tiff = Array(d[header..<r.upperBound])
        guard let t = TIFFFile.reader(tiff) else { return nil }
        let ifd = t.u32(4)
        guard ifd + 2 <= tiff.count else { return nil }
        for k in 0..<t.u16(ifd) where ifd + 2 + 12 * k + 12 <= tiff.count {
            let at = ifd + 2 + 12 * k
            guard t.u16(at) == 0xB002 else { continue }
            let count = t.u32(at + 4), off = t.u32(at + 8)
            guard count % 16 == 0, count > 0, off + count <= tiff.count else { return nil }
            let entries = (0..<(count / 16)).map { i -> (UInt32, Int, Int) in
                let e = off + 16 * i
                return (UInt32(truncatingIfNeeded: t.u32(e)), t.u32(e + 4), t.u32(e + 8))
            }
            return (header, entries)
        }
        return nil
    }
}

// MARK: PNG

enum PNGFile {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Chunks as (type, range of the whole chunk including length and CRC). Nil if the structure is broken.
    static func chunks(_ d: [UInt8]) -> [(type: String, range: Range<Int>)]? {
        guard d.count >= 8, Array(d[0..<8]) == signature else { return nil }
        var out: [(String, Range<Int>)] = []
        var i = 8
        while i + 12 <= d.count {
            let len = ImageFile.be32(d, i)
            guard len >= 0, len <= d.count, i + 12 + len <= d.count else { return nil }
            let type = String(decoding: d[(i + 4)..<(i + 8)], as: UTF8.self)
            out.append((type, i..<(i + 12 + len)))
            i += 12 + len
            if type == "IEND" { return out }
        }
        return out
    }

    static func isComplete(_ d: [UInt8]) -> Bool { chunks(d)?.last?.type == "IEND" }

    /// Chunks needed to show the picture as before, animation (APNG) included. Text (tEXt, zTXt, iTXt), eXIf,
    /// tIME and unknown ancillary chunks are dropped.
    static let kept: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "cICP", "mDCV", "mDCv",
                                    "cLLI", "cLLi", "sBIT", "bKGD", "pHYs", "acTL", "fcTL", "fdAT"]

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        return ImageFile.put32(data.count) + body + ImageFile.put32(Int(ImageFile.crc32(body[...])))
    }

    struct Header { let width: Int, height: Int, bitDepth: Int, colorType: Int, interlace: Int
        var channels: Int { [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colorType] ?? 0 }
        var bitsPerPixel: Int { channels * bitDepth }
        var rowBytes: Int { (width * bitsPerPixel + 7) / 8 }
    }

    static func header(_ d: [UInt8], _ list: [(type: String, range: Range<Int>)]) -> Header? {
        guard let h = list.first, h.type == "IHDR", h.range.count == 25 else { return nil }
        let o = h.range.lowerBound + 8
        return Header(width: ImageFile.be32(d, o), height: ImageFile.be32(d, o + 4), bitDepth: Int(d[o + 8]), colorType: Int(d[o + 9]), interlace: Int(d[o + 12]))
    }

    /// Single-frame, non-interlaced PNGs of a sane size; others keep the tag-only turn.
    static func canTurnPixels(_ d: [UInt8]) -> Bool {
        guard let list = chunks(d), list.last?.type == "IEND", !list.contains(where: { $0.type == "acTL" }), let h = header(d, list),
              h.interlace == 0, h.channels > 0, [1, 2, 4, 8, 16].contains(h.bitDepth), h.width > 0, h.height > 0 else { return false }
        return (h.rowBytes + 1) * h.height <= 512 << 20
    }

    static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
    }

    static func adler32(_ d: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < d.count {
            let end = min(d.count, i + 5552)
            while i < end { a += UInt32(d[i]); b += a; i += 1 }
            a %= 65521; b %= 65521
        }
        return b << 16 | a
    }

    /// Bakes orientation `t` (the turn to show, as an EXIF orientation) into the pixels and sets the stored
    /// orientation to 1. The image data is decoded, moved pixel by pixel and compressed again losslessly; every
    /// other chunk (colour profile, text, EXIF) stays, with the EXIF / XMP orientation set to 1 and the pixel
    /// density swapped on a quarter turn.
    static func turned(_ d: [UInt8], _ t: UInt32) throws -> [UInt8] {
        guard let list = chunks(d), let h = header(d, list) else { throw ImageFile.Malformed() }
        let w = h.width, ht = h.height, rb = h.rowBytes, bpp = max(1, h.bitsPerPixel / 8)
        // Inflate the zlib stream (2-byte header, raw deflate, Adler-32).
        let z = list.filter { $0.type == "IDAT" }.flatMap { d[($0.range.lowerBound + 8)..<($0.range.upperBound - 4)] }
        guard z.count > 6, z[0] & 0x0F == 8 else { throw ImageFile.Malformed() }
        let expected = (rb + 1) * ht
        var filtered = [UInt8](repeating: 0, count: expected + 1)
        let got = z.withUnsafeBufferPointer { zp in
            filtered.withUnsafeMutableBufferPointer { fp in
                compression_decode_buffer(fp.baseAddress!, fp.count, zp.baseAddress! + 2, zp.count - 2, nil, COMPRESSION_ZLIB)
            }
        }
        guard got == expected, !(0..<ht).contains(where: { filtered[$0 * (rb + 1)] > 4 }) else { throw ImageFile.Malformed() }
        // Unfilter into plain rows.
        var raw = [UInt8](repeating: 0, count: rb * ht)
        raw.withUnsafeMutableBufferPointer { r in
            filtered.withUnsafeBufferPointer { f in
                for y in 0..<ht {
                    let ft = f[y * (rb + 1)], src = y * (rb + 1) + 1, row = y * rb, prev = row - rb
                    for i in 0..<rb {
                        let x = Int(f[src + i])
                        let a = i >= bpp ? Int(r[row + i - bpp]) : 0
                        let b = y > 0 ? Int(r[prev + i]) : 0
                        let c = i >= bpp && y > 0 ? Int(r[prev + i - bpp]) : 0
                        let v: Int
                        switch ft {
                        case 0: v = x
                        case 1: v = x + a
                        case 2: v = x + b
                        case 3: v = x + (a + b) / 2
                        default: v = x + paeth(a, b, c)
                        }
                        r[row + i] = UInt8(truncatingIfNeeded: v)
                    }
                }
            }
        }
        // Move the pixels.
        let swap = t >= 5
        let W = swap ? ht : w, H = swap ? w : ht
        let orb = (W * h.bitsPerPixel + 7) / 8
        var moved = [UInt8](repeating: 0, count: orb * H)
        func source(_ x: Int, _ y: Int) -> (Int, Int) {
            switch t {
            case 2: return (w - 1 - x, y)
            case 3: return (w - 1 - x, ht - 1 - y)
            case 4: return (x, ht - 1 - y)
            case 5: return (y, x)
            case 6: return (y, ht - 1 - x)
            case 7: return (w - 1 - y, ht - 1 - x)
            case 8: return (w - 1 - y, x)
            default: return (x, y)
            }
        }
        raw.withUnsafeBufferPointer { r in
            moved.withUnsafeMutableBufferPointer { m in
                if h.bitDepth >= 8 {
                    let px = h.bitsPerPixel / 8
                    for y in 0..<H {
                        for x in 0..<W {
                            let (sx, sy) = source(x, y)
                            let s = sy * rb + sx * px, o = y * orb + x * px
                            for k in 0..<px { m[o + k] = r[s + k] }
                        }
                    }
                } else {
                    let bd = h.bitDepth, mask = (1 << bd) - 1
                    for y in 0..<H {
                        for x in 0..<W {
                            let (sx, sy) = source(x, y)
                            let sb = sx * bd, v = (Int(r[sy * rb + sb / 8]) >> (8 - bd - sb % 8)) & mask
                            let ob = x * bd
                            m[y * orb + ob / 8] |= UInt8(v << (8 - bd - ob % 8))
                        }
                    }
                }
            }
        }
        // Filter each row with the type that gives the smallest sum (filter 0 for palettes and < 8-bit, as the
        // PNG specification recommends), then deflate.
        var out = [UInt8](); out.reserveCapacity((orb + 1) * H)
        let adaptive = h.colorType != 3 && h.bitDepth >= 8
        var cand = [[UInt8]](repeating: [UInt8](repeating: 0, count: orb), count: 5)
        for y in 0..<H {
            let row = y * orb, prev = row - orb
            if !adaptive { out.append(0); out += moved[row..<(row + orb)]; continue }
            var best = 0, bestSum = Int.max
            for ft in 0..<5 {
                var sum = 0
                for i in 0..<orb {
                    let x = Int(moved[row + i])
                    let a = i >= bpp ? Int(moved[row + i - bpp]) : 0
                    let b = y > 0 ? Int(moved[prev + i]) : 0
                    let c = i >= bpp && y > 0 ? Int(moved[prev + i - bpp]) : 0
                    let p: Int
                    switch ft {
                    case 0: p = 0
                    case 1: p = a
                    case 2: p = b
                    case 3: p = (a + b) / 2
                    default: p = paeth(a, b, c)
                    }
                    let v = UInt8(truncatingIfNeeded: x - p)
                    cand[ft][i] = v
                    sum += Int(v) < 128 ? Int(v) : 256 - Int(v)
                }
                if sum < bestSum { bestSum = sum; best = ft }
            }
            out.append(UInt8(best)); out += cand[best]
        }
        var deflated = [UInt8](repeating: 0, count: out.count + out.count / 8 + 1024)
        let n = out.withUnsafeBufferPointer { o in
            deflated.withUnsafeMutableBufferPointer { dp in compression_encode_buffer(dp.baseAddress!, dp.count, o.baseAddress!, o.count, nil, COMPRESSION_ZLIB) }
        }
        guard n > 0 else { throw ImageFile.Malformed() }
        let a = adler32(out)
        let idat = chunk("IDAT", [0x78, 0x9C] + deflated[0..<n] + ImageFile.put32(Int(a)))
        // Rebuild the file around the new image data.
        var file = signature
        var wroteIDAT = false
        for c in list {
            let body = Array(d[(c.range.lowerBound + 8)..<(c.range.upperBound - 4)])
            switch c.type {
            case "IHDR":
                var b = body
                b.replaceSubrange(0..<4, with: ImageFile.put32(W)); b.replaceSubrange(4..<8, with: ImageFile.put32(H))
                file += chunk("IHDR", b)
            case "IDAT":
                if !wroteIDAT { file += idat; wroteIDAT = true }
            case "iDOT":
                break   // Apple's index into the old IDAT layout
            case "pHYs" where swap && body.count == 9:
                file += chunk("pHYs", Array(body[4..<8]) + Array(body[0..<4]) + [body[8]])
            case "eXIf":
                file += chunk("eXIf", exifWithOrientation1(body, swapSize: swap))
            case "iTXt", "tEXt", "zTXt":
                var b = body
                ImageFile.patchXMPOrientation(&b, 0..<b.count, 1)
                file += b == body ? Array(d[c.range]) : chunk(c.type, b)
            default:
                file += d[c.range]
            }
        }
        return file
    }

    /// The EXIF block with its orientation tag (IFD0) set to 1 and, after a quarter turn, the pixel width and
    /// height (EXIF IFD) swapped.
    static func exifWithOrientation1(_ b: [UInt8], swapSize: Bool) -> [UInt8] {
        var b = b
        guard let r = TIFFFile.reader(b), r.u32(4) + 2 <= b.count else { return b }
        func entries(_ ifd: Int) -> [Int] {
            guard ifd + 2 <= b.count else { return [] }
            return (0..<r.u16(ifd)).map { ifd + 2 + 12 * $0 }.filter { $0 + 12 <= b.count }
        }
        for at in entries(r.u32(4)) {
            if r.u16(at) == 274, r.u16(at + 2) == 3 { b.replaceSubrange((at + 8)..<(at + 10), with: r.put16(1)) }
            if r.u16(at) == 0x8769, swapSize {
                let dims = entries(r.u32(at + 8)).filter { [0xA002, 0xA003].contains(r.u16($0)) }
                if dims.count == 2, r.u16(dims[0] + 2) == r.u16(dims[1] + 2) {
                    let a = Array(b[(dims[0] + 8)..<(dims[0] + 12)]), c = Array(b[(dims[1] + 8)..<(dims[1] + 12)])
                    b.replaceSubrange((dims[0] + 8)..<(dims[0] + 12), with: c); b.replaceSubrange((dims[1] + 8)..<(dims[1] + 12), with: a)
                }
            }
        }
        return b
    }

    static func stripped(_ d: [UInt8], orientation: UInt32) throws -> [UInt8] {
        guard let list = chunks(d), list.last?.type == "IEND" else { throw ImageFile.Malformed() }
        var out = signature
        var exifPending = true
        for c in list {
            if c.type == "IDAT" || c.type == "acTL", exifPending {
                exifPending = false
                if orientation != 1 { out += chunk("eXIf", ImageFile.orientationTIFF(orientation)) }
            }
            if kept.contains(c.type) {
                out += d[c.range]
            } else if let first = c.type.unicodeScalars.first, first.properties.isUppercase {
                // An unknown critical chunk cannot be dropped without breaking the file.
                throw ImageFile.Malformed()
            }
        }
        return out
    }
}

// MARK: TIFF

enum TIFFFile {
    struct Reader {
        let d: [UInt8]
        let le: Bool
        func u16(_ o: Int) -> Int { le ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1]) }
        func u32(_ o: Int) -> Int { le ? Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24
                                       : Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        func put16(_ v: Int) -> [UInt8] { le ? [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] : [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func put32(_ v: Int) -> [UInt8] { le ? (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } : (0..<4).map { UInt8(v >> (24 - 8 * $0) & 0xFF) } }
    }

    struct Entry {
        let tag: Int, type: Int, count: Int
        /// Where the 12-byte entry is.
        let at: Int
        /// The value bytes (inline or external).
        let value: Range<Int>
    }

    static let typeSizes: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]

    /// Classic TIFF only (BigTIFF and anything odd are refused by the callers).
    static func reader(_ d: [UInt8]) -> Reader? {
        guard d.count >= 8 else { return nil }
        let r: Reader
        if d[0] == 0x49, d[1] == 0x49 { r = Reader(d: d, le: true) } else if d[0] == 0x4D, d[1] == 0x4D { r = Reader(d: d, le: false) } else { return nil }
        return r.u16(2) == 42 ? r : nil
    }

    /// The main IFD chain: (offset of the IFD, offset of the pointer that refers to it).
    static func chain(_ r: Reader) -> [(ifd: Int, pointer: Int)]? {
        var out: [(Int, Int)] = []
        var pointer = 4
        var seen = Set<Int>()
        while true {
            let ifd = r.u32(pointer)
            if ifd == 0 { break }
            guard ifd + 2 <= r.d.count, !seen.contains(ifd), out.count < 100_000 else { return nil }
            seen.insert(ifd)
            let n = r.u16(ifd)
            guard ifd + 2 + 12 * n + 4 <= r.d.count else { return nil }
            out.append((ifd, pointer))
            pointer = ifd + 2 + 12 * n
        }
        return out.isEmpty ? nil : out
    }

    static func entries(_ r: Reader, _ ifd: Int) -> [Entry]? {
        let n = r.u16(ifd)
        var out: [Entry] = []
        for k in 0..<n {
            let at = ifd + 2 + 12 * k
            let tag = r.u16(at), type = r.u16(at + 2), count = r.u32(at + 4)
            guard let size = typeSizes[type], count >= 0, count <= r.d.count else { return nil }
            let bytes = size * count
            let start = bytes <= 4 ? at + 8 : r.u32(at + 8)
            guard start >= 0, start + bytes <= r.d.count else { return nil }
            out.append(Entry(tag: tag, type: type, count: count, at: at, value: start..<(start + bytes)))
        }
        return out
    }

    static func numbers(_ r: Reader, _ e: Entry) -> [Int] {
        switch e.type {
        case 3: return (0..<e.count).map { r.u16(e.value.lowerBound + 2 * $0) }
        case 4, 13: return (0..<e.count).map { r.u32(e.value.lowerBound + 4 * $0) }
        case 1, 7: return (0..<e.count).map { Int(r.d[e.value.lowerBound + $0]) }
        default: return []
        }
    }

    /// Picture data blocks of one IFD (strips or tiles) as (offset, length).
    static func blocks(_ r: Reader, _ es: [Entry]) -> (offsetsTag: Int, countsTag: Int, blocks: [(Int, Int)])? {
        for (o, c) in [(273, 279), (324, 325)] {
            guard let oe = es.first(where: { $0.tag == o }) else { continue }
            guard let ce = es.first(where: { $0.tag == c }) else { return nil }
            let offs = numbers(r, oe), counts = numbers(r, ce)
            guard offs.count == counts.count, !offs.isEmpty else { return nil }
            return (o, c, Array(zip(offs, counts)))
        }
        return nil
    }

    static func isTruncated(_ d: [UInt8]) -> Bool {
        guard let r = reader(d), let ifds = chain(r) else { return false }
        for (ifd, _) in ifds {
            guard let es = entries(r, ifd), let b = blocks(r, es) else { continue }
            if b.blocks.contains(where: { $0.0 + $0.1 > d.count }) { return true }
        }
        return false
    }

    /// Sets the orientation tag of every page (the tag changes in place; a page without one gets a copy of its
    /// directory with the tag added, at the end of the file). Picture data is not touched.
    static func reoriented(_ d: [UInt8], _ op: ImageOps.Orientation) throws -> [UInt8] {
        guard let r = reader(d), let ifds = chain(r) else { throw ImageFile.Malformed() }
        var out = d
        var pointer = 4
        for (ifd, _) in ifds {
            guard let es = entries(r, ifd) else { throw ImageFile.Malformed() }
            let n = es.count
            let next = r.u32(ifd + 2 + 12 * n)
            let current = es.first(where: { $0.tag == 274 }).map { UInt32(r.u16($0.at + 8)) } ?? 1
            if let xmp = es.first(where: { $0.tag == 700 }) { ImageFile.patchXMPOrientation(&out, xmp.value, ImageOps.combine(current, op)) }
            if let e = es.first(where: { $0.tag == 274 }) {
                guard e.type == 3, e.count == 1 else { throw ImageFile.Malformed() }
                let target = ImageOps.combine(UInt32(r.u16(e.at + 8)), op)
                out.replaceSubrange((e.at + 8)..<(e.at + 10), with: r.put16(Int(target)))
                pointer = ifd + 2 + 12 * n
            } else {
                let target = ImageOps.combine(1, op)
                if out.count % 2 == 1 { out.append(0) }
                let at = out.count
                guard at + 2 + 12 * (n + 1) + 4 < Int(UInt32.max) else { throw ImageFile.Malformed() }
                var dir = r.put16(n + 1)
                var inserted = false
                for e in es {
                    if !inserted, e.tag > 274 { dir += r.put16(274) + r.put16(3) + r.put32(1) + r.put16(Int(target)) + [0, 0]; inserted = true }
                    dir += d[e.at..<(e.at + 12)]
                }
                if !inserted { dir += r.put16(274) + r.put16(3) + r.put32(1) + r.put16(Int(target)) + [0, 0] }
                dir += r.put32(next)
                out += dir
                out.replaceSubrange(pointer..<(pointer + 4), with: r.put32(at))
                pointer = at + 2 + 12 * (n + 1)
            }
        }
        return out
    }

    /// Tags that describe how to decode and show the picture. Everything else goes: EXIF and GPS directories,
    /// XMP, IPTC, Photoshop resources, artist, dates, software, camera, descriptions, GeoTIFF, sub-images
    /// (thumbnails and previews).
    static let kept: Set<Int> = [254, 255, 256, 257, 258, 259, 262, 263, 264, 265, 266, 273, 274, 277, 278, 279, 280, 281, 282, 283, 284,
                                 290, 291, 292, 293, 296, 297, 301, 317, 318, 319, 320, 321, 322, 323, 324, 325, 332, 334, 336, 338, 339,
                                 340, 341, 342, 347, 529, 530, 531, 532, 34675]

    /// Rewrites the file with only the kept tags. Strips and tiles are copied as they are (no re-compression).
    static func stripped(_ d: [UInt8]) throws -> [UInt8] {
        guard let r = reader(d), let ifds = chain(r) else { throw ImageFile.Malformed() }
        var out = Array(d[0..<4]) + r.put32(0)
        var pointer = 4
        func align() { if out.count % 2 == 1 { out.append(0) } }
        for (ifd, _) in ifds {
            guard let es = entries(r, ifd), let b = blocks(r, es) else { throw ImageFile.Malformed() }
            let compression = es.first { $0.tag == 259 }.map { numbers(r, $0).first ?? 1 } ?? 1
            // Old-style JPEG points into the file from tags we would drop; Photoshop layer data is not metadata.
            guard compression != 6, !es.contains(where: { $0.tag == 37724 }) else { throw ImageFile.Malformed() }
            guard !b.blocks.contains(where: { $0.0 < 0 || $0.0 + $0.1 > d.count }) else { throw ImageFile.Malformed() }
            var newOffsets: [Int] = []
            for (o, c) in b.blocks {
                align()
                newOffsets.append(out.count)
                out += d[o..<(o + c)]
            }
            var dir: [[UInt8]] = []
            for e in es where kept.contains(e.tag) {
                var type = e.type, count = e.count
                var value: [UInt8]
                if e.tag == b.offsetsTag {
                    type = 4; count = newOffsets.count
                    value = newOffsets.flatMap { r.put32($0) }
                } else {
                    value = Array(d[e.value])
                }
                if value.count <= 4 {
                    value += [UInt8](repeating: 0, count: 4 - value.count)
                } else {
                    align()
                    let at = out.count
                    out += value
                    value = r.put32(at)
                }
                dir.append(r.put16(e.tag) + r.put16(type) + r.put32(count) + value)
            }
            align()
            let at = out.count
            out += r.put16(dir.count) + dir.flatMap { $0 } + r.put32(0)
            out.replaceSubrange(pointer..<(pointer + 4), with: r.put32(at))
            pointer = at + 2 + 12 * dir.count
            guard out.count < Int(UInt32.max) else { throw ImageFile.Malformed() }
        }
        return out
    }
}

// MARK: GIF

enum GIFFile {
    struct Frame {
        var left: Int, top: Int, width: Int, height: Int
        var packed: UInt8
        var colorTable: [UInt8]
        var minCodeSize: Int
        var lzw: [UInt8]
    }
    enum Block {
        case ext(label: UInt8, range: Range<Int>, app: String?)
        case image(Frame)
    }
    struct Parsed {
        var header: [UInt8]   // signature + logical screen descriptor + global colour table
        var width: Int, height: Int
        var blocks: [Block]
    }

    /// Reads sub-blocks from `i`; returns their concatenated data and the index after the terminator.
    static func subBlocks(_ d: [UInt8], _ start: Int) throws -> ([UInt8], Int) {
        var i = start
        var data: [UInt8] = []
        while true {
            guard i < d.count else { throw ImageFile.Malformed() }
            let n = Int(d[i]); i += 1
            if n == 0 { return (data, i) }
            guard i + n <= d.count else { throw ImageFile.Malformed() }
            data += d[i..<(i + n)]; i += n
        }
    }

    /// Throws when the file is cut off inside a block (a missing trailer alone is tolerated, as decoders do).
    static func parse(_ d: [UInt8]) throws -> Parsed {
        guard d.count >= 13, d[0] == 0x47, d[1] == 0x49, d[2] == 0x46 else { throw ImageFile.Malformed() }
        let w = ImageFile.le16(d, 6), h = ImageFile.le16(d, 8)
        var i = 13
        if d[10] & 0x80 != 0 { i += 3 * (1 << (Int(d[10] & 7) + 1)) }
        guard i <= d.count else { throw ImageFile.Malformed() }
        var p = Parsed(header: Array(d[0..<i]), width: w, height: h, blocks: [])
        while i < d.count {
            switch d[i] {
            case 0x3B:
                return p
            case 0x21:
                guard i + 1 < d.count else { throw ImageFile.Malformed() }
                let label = d[i + 1]
                var app: String?
                if label == 0xFF, i + 2 < d.count, d[i + 2] == 11, i + 14 <= d.count { app = String(decoding: d[(i + 3)..<(i + 14)], as: UTF8.self) }
                let (_, end) = try subBlocks(d, i + 2)
                p.blocks.append(.ext(label: label, range: i..<end, app: app))
                i = end
            case 0x2C:
                guard i + 10 <= d.count else { throw ImageFile.Malformed() }
                let packed = d[i + 9]
                var j = i + 10
                var table: [UInt8] = []
                if packed & 0x80 != 0 {
                    let n = 3 * (1 << (Int(packed & 7) + 1))
                    guard j + n <= d.count else { throw ImageFile.Malformed() }
                    table = Array(d[j..<(j + n)]); j += n
                }
                guard j < d.count else { throw ImageFile.Malformed() }
                let minCode = Int(d[j])
                let (lzw, end) = try subBlocks(d, j + 1)
                p.blocks.append(.image(Frame(left: ImageFile.le16(d, i + 1), top: ImageFile.le16(d, i + 3), width: ImageFile.le16(d, i + 5),
                                             height: ImageFile.le16(d, i + 7), packed: packed, colorTable: table, minCodeSize: minCode, lzw: lzw)))
                i = end
            default:
                throw ImageFile.Malformed()
            }
        }
        // No trailer: complete only if at least one picture was read.
        if p.blocks.contains(where: { if case .image = $0 { return true } else { return false } }) { return p }
        throw ImageFile.Malformed()
    }

    static func packed(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < data.count {
            let n = min(255, data.count - i)
            out.append(UInt8(n)); out += data[i..<(i + n)]; i += n
        }
        return out + [0]
    }

    static func descriptor(_ f: Frame) -> [UInt8] {
        [0x2C, UInt8(f.left & 0xFF), UInt8(f.left >> 8), UInt8(f.top & 0xFF), UInt8(f.top >> 8),
         UInt8(f.width & 0xFF), UInt8(f.width >> 8), UInt8(f.height & 0xFF), UInt8(f.height >> 8), f.packed] + f.colorTable
            + [UInt8(f.minCodeSize)] + packed(f.lzw)
    }

    /// Application extensions that affect playback or colour: loop count and ICC profile. XMP and others go.
    static let keptApps: Set<String> = ["NETSCAPE2.0", "ANIMEXTS1.0", "ICCRGBG1012"]

    /// Drops comments and application extensions other than the loop count and ICC profile. Frames are copied as
    /// they are.
    static func stripped(_ d: [UInt8]) throws -> [UInt8] {
        let p = try parse(d)
        var out = p.header
        for b in p.blocks {
            switch b {
            case .ext(let label, let range, let app):
                // 0xF9 graphic control (delays, transparency) and 0x01 plain text (visible) stay.
                if label == 0xF9 || label == 0x01 || (label == 0xFF && app.map(keptApps.contains) == true) { out += d[range] }
            case .image(let f):
                out += descriptor(f)
            }
        }
        return out + [0x3B]
    }

    /// Turns or mirrors every frame exactly: each frame's LZW data is decoded to palette indices, moved, and
    /// encoded again with the same palette, delays, disposal and transparency.
    static func transformed(_ d: [UInt8], _ op: ImageOps.Orientation) throws -> [UInt8] {
        let p = try parse(d)
        let W = p.width, H = p.height
        let swap = op == .right || op == .left
        var out = p.header
        if swap {
            out[6] = UInt8(H & 0xFF); out[7] = UInt8(H >> 8); out[8] = UInt8(W & 0xFF); out[9] = UInt8(W >> 8)
        }
        for b in p.blocks {
            switch b {
            case .ext(let label, let range, _):
                // Plain text is drawn at a grid position that cannot be turned.
                guard label != 0x01 else { throw ImageFile.Malformed() }
                out += d[range]
            case .image(var f):
                guard f.width > 0, f.height > 0, f.left + f.width <= W, f.top + f.height <= H,
                      var idx = lzwDecode(f.lzw, minCodeSize: f.minCodeSize, count: f.width * f.height) else { throw ImageFile.Malformed() }
                if f.packed & 0x40 != 0 { idx = deinterlaced(idx, width: f.width, height: f.height) }
                idx = moved(idx, width: f.width, height: f.height, op)
                switch op {
                case .right: (f.left, f.top) = (H - f.top - f.height, f.left)
                case .left: (f.left, f.top) = (f.top, W - f.left - f.width)
                case .flipH: f.left = W - f.left - f.width
                case .flipV: f.top = H - f.top - f.height
                }
                if swap { (f.width, f.height) = (f.height, f.width) }
                f.packed &= ~0x40
                f.lzw = lzwEncode(idx, minCodeSize: f.minCodeSize)
                out += descriptor(f)
            }
        }
        return out + [0x3B]
    }

    static func moved(_ idx: [UInt8], width w: Int, height h: Int, _ op: ImageOps.Orientation) -> [UInt8] {
        let swap = op == .right || op == .left
        let W = swap ? h : w, H = swap ? w : h
        var out = [UInt8](repeating: 0, count: idx.count)
        for y in 0..<H {
            for x in 0..<W {
                let sx: Int, sy: Int
                switch op {
                case .right: sx = y; sy = h - 1 - x
                case .left: sx = w - 1 - y; sy = x
                case .flipH: sx = w - 1 - x; sy = y
                case .flipV: sx = x; sy = h - 1 - y
                }
                out[y * W + x] = idx[sy * w + sx]
            }
        }
        return out
    }

    static func deinterlaced(_ idx: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: idx.count)
        var row = 0
        for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] {
            var y = start
            while y < h {
                out.replaceSubrange((y * w)..<((y + 1) * w), with: idx[(row * w)..<((row + 1) * w)])
                row += 1; y += step
            }
        }
        return out
    }

    static func lzwDecode(_ data: [UInt8], minCodeSize: Int, count: Int) -> [UInt8]? {
        guard (2...8).contains(minCodeSize) else { return nil }
        let clear = 1 << minCodeSize, eoi = clear + 1
        var prefix = [Int](repeating: 0, count: 4096), suffix = [UInt8](repeating: 0, count: 4096)
        var first = [UInt8](repeating: 0, count: 4096), length = [Int](repeating: 0, count: 4096)
        for k in 0..<clear { suffix[k] = UInt8(k); first[k] = UInt8(k); length[k] = 1 }
        var codeSize = minCodeSize + 1, next = eoi + 1, prev = -1
        var out = [UInt8](); out.reserveCapacity(count)
        var buf = 0, bits = 0, pos = 0
        var stack = [UInt8](repeating: 0, count: 4097)
        while out.count < count {
            while bits < codeSize {
                guard pos < data.count else { return nil }
                buf |= Int(data[pos]) << bits; pos += 1; bits += 8
            }
            let code = buf & ((1 << codeSize) - 1)
            buf >>= codeSize; bits -= codeSize
            if code == clear { codeSize = minCodeSize + 1; next = eoi + 1; prev = -1; continue }
            if code == eoi { break }
            if prev == -1 {
                guard code < clear else { return nil }
                out.append(UInt8(code)); prev = code; continue
            }
            let c: Int
            if code < next { c = code } else if code == next { c = prev } else { return nil }
            // Write the string for c backwards, then the extra first byte for the KwKwK case.
            var n = length[c], k = c
            guard n > 0 else { return nil }
            for j in stride(from: n - 1, through: 0, by: -1) { stack[j] = suffix[k]; k = prefix[k] }
            if code == next { stack[n] = first[prev]; n += 1 }
            out += stack[0..<n]
            if next < 4096 {
                prefix[next] = prev; suffix[next] = first[code == next ? prev : code]; first[next] = first[prev]; length[next] = length[prev] + 1
                next += 1
                if next == 1 << codeSize, codeSize < 12 { codeSize += 1 }
            }
            prev = code
        }
        return out.count >= count ? Array(out.prefix(count)) : nil
    }

    static func lzwEncode(_ idx: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clear = 1 << minCodeSize, eoi = clear + 1
        var codeSize = minCodeSize + 1, next = eoi + 1
        var table = [Int: Int]()
        var out: [UInt8] = []; out.reserveCapacity(idx.count / 2)
        var buf = 0, bits = 0
        func emit(_ code: Int) {
            buf |= code << bits; bits += codeSize
            while bits >= 8 { out.append(UInt8(buf & 0xFF)); buf >>= 8; bits -= 8 }
        }
        emit(clear)
        var current = -1
        for b in idx {
            if current < 0 { current = Int(b); continue }
            let key = current << 8 | Int(b)
            if let c = table[key] { current = c; continue }
            emit(current)
            if next < 4096 {
                table[key] = next; next += 1
                if next > 1 << codeSize, codeSize < 12 { codeSize += 1 }
            } else {
                emit(clear)
                table.removeAll(keepingCapacity: true)
                codeSize = minCodeSize + 1; next = eoi + 1
            }
            current = Int(b)
        }
        if current >= 0 { emit(current) }
        emit(eoi)
        if bits > 0 { out.append(UInt8(buf & 0xFF)) }
        return out
    }
}

// MARK: HEIF / HEIC / AVIF (ISO base media file format)

/// A small editor for still-image HEIF files: it can drop items (metadata, thumbnails) and change the rotation /
/// mirror properties, and writes the file again with every kept item's coded data copied byte for byte.
enum BMFFFile {
    struct Box { let type: String; let range: Range<Int>; let header: Int
        var payload: Range<Int> { (range.lowerBound + header)..<range.upperBound }
    }
    struct Location { var id: Int; var method: Int; var dataRef: Int; var base: UInt64; var extents: [(offset: UInt64, length: UInt64)] }
    struct Association { var essential: Bool; var index: Int }

    struct File {
        var d: [UInt8]
        var top: [Box]
        var meta: Box
        var metaHeader: [UInt8]            // version and flags
        var metaChildren: [Box]
        var primary: Int
        var items: [(id: Int, type: String, infe: [UInt8])]
        var iinfVersion: UInt8
        var locations: [Location]
        var ilocVersion: UInt8
        var refs: [(type: String, from: Int, to: [Int])]
        var irefVersion: UInt8
        var properties: [[UInt8]]          // ipco children; ipma indices are 1-based
        var assoc: [(id: Int, list: [Association])]
        var ipmaVersion: UInt8
        var ipmaFlags: Int
        var idat: [UInt8]
        var groups: [Int]                  // entity ids used by entity groups (grpl)
    }

    static func boxes(_ d: [UInt8], _ r: Range<Int>) -> [Box]? {
        var out: [Box] = []
        var i = r.lowerBound
        while i < r.upperBound {
            guard i + 8 <= r.upperBound else { return nil }
            var size = ImageFile.be32(d, i)
            var header = 8
            if size == 1 {
                guard i + 16 <= r.upperBound else { return nil }
                let big = ImageFile.be64(d, i + 8)
                guard big <= UInt64(r.upperBound - i) else { return nil }
                size = Int(big); header = 16
            } else if size == 0 { size = r.upperBound - i }
            guard size >= header, i + size <= r.upperBound else { return nil }
            out.append(Box(type: String(decoding: d[(i + 4)..<(i + 8)], as: UTF8.self), range: i..<(i + size), header: header))
            i += size
        }
        return out
    }

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        ImageFile.put32(payload.count + 8) + Array(type.utf8) + payload
    }

    /// Reads a big-endian unsigned number of `size` bytes (0, 2, 4 or 8).
    static func uint(_ d: [UInt8], _ o: inout Int, _ size: Int, _ end: Int) throws -> UInt64 {
        guard o + size <= end else { throw ImageFile.Malformed() }
        var v: UInt64 = 0
        for k in 0..<size { v = v << 8 | UInt64(d[o + k]) }
        o += size
        return v
    }

    static func parse(_ d: [UInt8]) throws -> File {
        guard let top = boxes(d, 0..<d.count), top.first?.type == "ftyp",
              let meta = top.first(where: { $0.type == "meta" }), top.filter({ $0.type == "meta" }).count == 1,
              !top.contains(where: { $0.type == "moov" }) else { throw ImageFile.Malformed() }
        let mp = meta.payload
        guard mp.count >= 4, let children = boxes(d, (mp.lowerBound + 4)..<mp.upperBound) else { throw ImageFile.Malformed() }
        var f = File(d: d, top: top, meta: meta, metaHeader: Array(d[mp.lowerBound..<(mp.lowerBound + 4)]), metaChildren: children,
                     primary: -1, items: [], iinfVersion: 0, locations: [], ilocVersion: 0, refs: [], irefVersion: 0, properties: [],
                     assoc: [], ipmaVersion: 0, ipmaFlags: 0, idat: [], groups: [])
        var sawIloc = false, sawIinf = false, sawIprp = false
        for c in children {
            let p = c.payload
            switch c.type {
            case "hdlr":
                guard p.count >= 12, String(decoding: d[(p.lowerBound + 8)..<(p.lowerBound + 12)], as: UTF8.self) == "pict" else { throw ImageFile.Malformed() }
            case "pitm":
                var o = p.lowerBound + 4
                f.primary = Int(try uint(d, &o, d[p.lowerBound] == 0 ? 2 : 4, p.upperBound))
            case "iinf":
                sawIinf = true
                f.iinfVersion = d[p.lowerBound]
                var o = p.lowerBound + 4
                _ = try uint(d, &o, f.iinfVersion == 0 ? 2 : 4, p.upperBound)
                guard let entries = boxes(d, o..<p.upperBound) else { throw ImageFile.Malformed() }
                for e in entries where e.type == "infe" {
                    let ep = e.payload
                    guard ep.count >= 4 else { throw ImageFile.Malformed() }
                    let v = d[ep.lowerBound]
                    guard v >= 2 else { throw ImageFile.Malformed() }
                    var q = ep.lowerBound + 4
                    let id = Int(try uint(d, &q, v == 2 ? 2 : 4, ep.upperBound))
                    q += 2
                    guard q + 4 <= ep.upperBound else { throw ImageFile.Malformed() }
                    f.items.append((id, String(decoding: d[q..<(q + 4)], as: UTF8.self), Array(d[e.range])))
                }
            case "iloc":
                sawIloc = true
                let v = d[p.lowerBound]
                f.ilocVersion = v
                guard v <= 2, p.count >= 6 else { throw ImageFile.Malformed() }
                let offSize = Int(d[p.lowerBound + 4] >> 4), lenSize = Int(d[p.lowerBound + 4] & 15)
                let baseSize = Int(d[p.lowerBound + 5] >> 4), idxSize = v >= 1 ? Int(d[p.lowerBound + 5] & 15) : 0
                var o = p.lowerBound + 6
                let n = Int(try uint(d, &o, v < 2 ? 2 : 4, p.upperBound))
                for _ in 0..<n {
                    let id = Int(try uint(d, &o, v < 2 ? 2 : 4, p.upperBound))
                    var method = 0
                    if v >= 1 { method = Int(try uint(d, &o, 2, p.upperBound) & 15) }
                    let dataRef = Int(try uint(d, &o, 2, p.upperBound))
                    let base = try uint(d, &o, baseSize, p.upperBound)
                    let ec = Int(try uint(d, &o, 2, p.upperBound))
                    var ext: [(UInt64, UInt64)] = []
                    for _ in 0..<ec {
                        _ = try uint(d, &o, idxSize, p.upperBound)
                        let eo = try uint(d, &o, offSize, p.upperBound), el = try uint(d, &o, lenSize, p.upperBound)
                        ext.append((eo, el))
                    }
                    f.locations.append(Location(id: id, method: method, dataRef: dataRef, base: base, extents: ext))
                }
            case "iref":
                f.irefVersion = d[p.lowerBound]
                let w = f.irefVersion == 0 ? 2 : 4
                guard let rs = boxes(d, (p.lowerBound + 4)..<p.upperBound) else { throw ImageFile.Malformed() }
                for r in rs {
                    var o = r.payload.lowerBound
                    let from = Int(try uint(d, &o, w, r.range.upperBound))
                    let n = Int(try uint(d, &o, 2, r.range.upperBound))
                    var to: [Int] = []
                    for _ in 0..<n { to.append(Int(try uint(d, &o, w, r.range.upperBound))) }
                    f.refs.append((r.type, from, to))
                }
            case "iprp":
                sawIprp = true
                guard let parts = boxes(d, p), parts.count == 2, parts[0].type == "ipco", parts[1].type == "ipma",
                      let props = boxes(d, parts[0].payload) else { throw ImageFile.Malformed() }
                f.properties = props.map { Array(d[$0.range]) }
                let ip = parts[1].payload
                f.ipmaVersion = d[ip.lowerBound]
                f.ipmaFlags = Int(d[ip.lowerBound + 3])
                var o = ip.lowerBound + 4
                let n = Int(try uint(d, &o, 4, ip.upperBound))
                for _ in 0..<n {
                    let id = Int(try uint(d, &o, f.ipmaVersion < 1 ? 2 : 4, ip.upperBound))
                    let c = Int(try uint(d, &o, 1, ip.upperBound))
                    var list: [Association] = []
                    for _ in 0..<c {
                        if f.ipmaFlags & 1 != 0 {
                            let x = Int(try uint(d, &o, 2, ip.upperBound)); list.append(Association(essential: x & 0x8000 != 0, index: x & 0x7FFF))
                        } else {
                            let x = Int(try uint(d, &o, 1, ip.upperBound)); list.append(Association(essential: x & 0x80 != 0, index: x & 0x7F))
                        }
                    }
                    f.assoc.append((id, list))
                }
            case "idat":
                f.idat = Array(d[p])
            case "grpl":
                guard let gs = boxes(d, p) else { throw ImageFile.Malformed() }
                for g in gs {
                    var o = g.payload.lowerBound + 8
                    let n = Int(try uint(d, &o, 4, g.range.upperBound))
                    for _ in 0..<n { f.groups.append(Int(try uint(d, &o, 4, g.range.upperBound))) }
                }
            default: break
            }
        }
        guard sawIloc, sawIinf, sawIprp, f.items.contains(where: { $0.id == f.primary }) else { throw ImageFile.Malformed() }
        // Only data inside this file (no external references, no item-offset construction).
        guard !f.locations.contains(where: { $0.dataRef != 0 || $0.method > 1 || $0.extents.contains { $0.length == 0 } }) else { throw ImageFile.Malformed() }
        return f
    }

    /// Writes the file again: ftyp and other kept top-level boxes, the new meta, then one mdat with every kept
    /// item's data in its original order. Item locations are recomputed; coded data is copied unchanged.
    static func serialize(_ f: File, keepTop: (Box) -> Bool) throws -> [UInt8] {
        let d = f.d
        let kept = Set(f.items.map(\.id))
        let locs = f.locations.filter { kept.contains($0.id) }
        // Unique byte ranges of file data (method 0) and idat data (method 1), merged where they overlap.
        func ranges(_ method: Int) -> [Range<Int>] {
            var rs: [Range<Int>] = []
            for l in locs where l.method == method {
                for e in l.extents { let s = Int(l.base + e.offset); rs.append(s..<(s + Int(e.length))) }
            }
            rs.sort { $0.lowerBound < $1.lowerBound }
            var merged: [Range<Int>] = []
            for r in rs {
                if let last = merged.last, r.lowerBound <= last.upperBound { merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound) } else { merged.append(r) }
            }
            return merged
        }
        let fileRanges = ranges(0), idatRanges = ranges(1)
        guard !fileRanges.contains(where: { $0.lowerBound < 0 || $0.upperBound > d.count }),
              !idatRanges.contains(where: { $0.lowerBound < 0 || $0.upperBound > f.idat.count }) else { throw ImageFile.Malformed() }
        var newIdat: [UInt8] = []
        var idatStarts: [Int] = []
        for r in idatRanges { idatStarts.append(newIdat.count); newIdat += f.idat[r] }
        let mdatPayload = fileRanges.reduce(0) { $0 + $1.count }
        func mapped(_ x: Int, _ rs: [Range<Int>], _ starts: [Int]) -> Int {
            let k = rs.firstIndex { $0.contains(x) } ?? 0
            return starts[k] + (x - rs[k].lowerBound)
        }
        let wide = d.count + 1_000_000 > Int(UInt32.max)
        let offSize = wide ? 8 : 4
        let lenSize = locs.contains { $0.extents.contains { $0.length > UInt64(UInt32.max) } } ? 8 : 4
        let idW = f.ilocVersion < 2 ? 2 : 4
        func put(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(v >> (8 * UInt64(n - 1 - $0)) & 0xFF) } }

        func iloc(mdatStart: Int) -> [UInt8] {
            var p: [UInt8] = [f.ilocVersion, 0, 0, 0, UInt8(offSize << 4 | lenSize), 0]
            p += put(UInt64(locs.count), f.ilocVersion < 2 ? 2 : 4)
            var fileStarts: [Int] = []
            var acc = mdatStart
            for r in fileRanges { fileStarts.append(acc); acc += r.count }
            for l in locs {
                p += put(UInt64(l.id), idW)
                if f.ilocVersion >= 1 { p += put(UInt64(l.method), 2) }
                p += put(0, 2)
                p += put(UInt64(l.extents.count), 2)
                for e in l.extents {
                    let abs = Int(l.base + e.offset)
                    let off = l.method == 0 ? mapped(abs, fileRanges, fileStarts) : mapped(abs, idatRanges, idatStarts)
                    p += put(UInt64(off), offSize) + put(e.length, lenSize)
                }
            }
            return box("iloc", p)
        }
        let iinf: [UInt8] = box("iinf", [f.iinfVersion, 0, 0, 0] + put(UInt64(f.items.count), f.iinfVersion == 0 ? 2 : 4) + f.items.flatMap(\.infe))
        let rw = f.irefVersion == 0 ? 2 : 4
        let refs = f.refs.filter { kept.contains($0.from) && !$0.to.isEmpty }
        let iref: [UInt8] = refs.isEmpty ? [] : box("iref", [f.irefVersion, 0, 0, 0] + refs.flatMap { r in
            box(r.type, put(UInt64(r.from), rw) + put(UInt64(r.to.count), 2) + r.to.flatMap { put(UInt64($0), rw) })
        })
        let assoc = f.assoc.filter { kept.contains($0.id) }
        let wideIndex = f.ipmaFlags & 1 != 0 || assoc.contains { $0.list.contains { $0.index > 127 } }
        var ipma: [UInt8] = [f.ipmaVersion, 0, 0, UInt8(wideIndex ? (f.ipmaFlags | 1) : f.ipmaFlags)] + put(UInt64(assoc.count), 4)
        for a in assoc {
            ipma += put(UInt64(a.id), f.ipmaVersion < 1 ? 2 : 4) + [UInt8(a.list.count)]
            for x in a.list {
                ipma += wideIndex ? put(UInt64(x.index | (x.essential ? 0x8000 : 0)), 2) : [UInt8(x.index | (x.essential ? 0x80 : 0))]
            }
        }
        let iprp = box("iprp", box("ipco", f.properties.flatMap { $0 }) + box("ipma", ipma))

        func metaBox(mdatStart: Int) -> [UInt8] {
            var p = f.metaHeader
            for c in f.metaChildren {
                switch c.type {
                case "iinf": p += iinf
                case "iloc": p += iloc(mdatStart: mdatStart)
                case "iref": p += iref
                case "iprp": p += iprp
                case "idat": p += box("idat", newIdat)
                default: p += d[c.range]
                }
            }
            return box("meta", p)
        }
        var head: [UInt8] = []
        for b in f.top where b.type != "mdat" && b.type != "meta" && b.type != "free" && b.type != "skip" && keepTop(b) { head += d[b.range] }
        let mdatHeader = mdatPayload + 8 > Int(UInt32.max) ? 16 : 8
        let metaSize = metaBox(mdatStart: 0).count
        let mdatStart = head.count + metaSize + mdatHeader
        var out = head + metaBox(mdatStart: mdatStart)
        out += mdatHeader == 8 ? ImageFile.put32(mdatPayload + 8) + Array("mdat".utf8)
                               : ImageFile.put32(1) + Array("mdat".utf8) + ImageFile.put64(UInt64(mdatPayload + 16))
        for r in fileRanges { out += d[r] }
        return out
    }

    /// Item ids whose data is only metadata about another item (EXIF, XMP and other `cdsc` items), and
    /// thumbnails with the tiles only they use.
    static func removable(_ f: File) -> Set<Int> {
        var out = Set<Int>()
        for it in f.items where ["Exif", "mime", "uri ", "jumb"].contains(it.type) { out.insert(it.id) }
        for r in f.refs where r.type == "cdsc" { out.insert(r.from) }
        var thumbs = Set(f.refs.filter { $0.type == "thmb" }.map(\.from))
        // Tiles of a thumbnail grid go with it unless something else uses them.
        while true {
            let used = Set(f.refs.filter { $0.type == "dimg" && !thumbs.contains($0.from) && !out.contains($0.from) }.flatMap(\.to))
            let tiles = Set(f.refs.filter { $0.type == "dimg" && thumbs.contains($0.from) }.flatMap(\.to)).subtracting(used).subtracting(thumbs)
            if tiles.isEmpty { break }
            thumbs.formUnion(tiles)
        }
        return out.union(thumbs)
    }

    static func dropping(_ f: File, _ gone: Set<Int>) throws -> File {
        guard !gone.contains(f.primary), gone.isDisjoint(with: f.groups) else { throw ImageFile.Malformed() }
        var g = f
        g.items.removeAll { gone.contains($0.id) }
        g.locations.removeAll { gone.contains($0.id) }
        g.assoc.removeAll { gone.contains($0.id) }
        g.refs = f.refs.filter { !gone.contains($0.from) }.map { ($0.type, $0.from, $0.to.filter { !gone.contains($0) }) }
        return g
    }

    /// Removes EXIF, XMP and other metadata items and thumbnails; everything else (the picture, its tiles, the HDR
    /// gain map, mattes, colour and rotation properties) is copied unchanged. Top-level boxes other than the file
    /// type, metadata and media data (e.g. XMP in a `uuid` box) go too.
    static func stripped(_ d: [UInt8]) throws -> [UInt8] {
        let f = try parse(d)
        return try serialize(try dropping(f, removable(f)), keepTop: { $0.type == "ftyp" })
    }

    // Orientation as HEIF properties: `irot` turns anticlockwise by angle × 90°, then `imir` mirrors.
    static func mul(_ a: [Int], _ b: [Int]) -> [Int] {
        [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3], a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3]]
    }
    /// As ImageIO (and so Finder, Preview and Photos) reads `imir`, axis 0 mirrors top-bottom and 1 left-right;
    /// `InPlace.verify` checks the displayed result, so a reader disagreeing here would refuse, not damage.
    static func transform(for orientation: UInt32) -> (angle: UInt8, mirror: UInt8?)? {
        guard let want = ImageOps.orientationMatrices[orientation] else { return nil }
        let ccw = [0, 1, -1, 0]
        for mirror in [nil, UInt8(0), UInt8(1)] as [UInt8?] {
            var r = [1, 0, 0, 1]
            for angle in 0..<4 {
                let m: [Int] = mirror.map { mul($0 == 0 ? [1, 0, 0, -1] : [-1, 0, 0, 1], r) } ?? r
                if m == want { return (UInt8(angle), mirror) }
                r = mul(ccw, r)
            }
        }
        return nil
    }

    /// Sets the picture's rotation / mirror. The primary image, its thumbnails, its auxiliary images (gain map,
    /// mattes) and the other inputs of a derived HDR (`tmap`) image turn together. The derived image itself keeps
    /// its own transform: its inputs are turned, so only its declared size swaps on a quarter turn (ImageIO drops
    /// the HDR rendition when that size does not match). When the needed property boxes are already there and
    /// shared only by those items (an iPhone portrait photo), only their values change in place; otherwise new
    /// boxes are added and the file is written again. The EXIF orientation, if any, is updated to match.
    static func reoriented(_ d: [UInt8], current: UInt32, target: UInt32) throws -> [UInt8] {
        var f = try parse(d)
        guard let (angle, mirror) = transform(for: target), f.assoc.contains(where: { $0.id == f.primary }) else { throw ImageFile.Malformed() }
        func kind(_ index: Int) -> String? {
            guard index >= 1, index <= f.properties.count, f.properties[index - 1].count >= 8 else { return nil }
            return String(decoding: f.properties[index - 1][4..<8], as: UTF8.self)
        }
        func list(_ id: Int) -> [Association] { f.assoc.first { $0.id == id }?.list ?? [] }
        func transformOf(_ id: Int) -> [Int] { list(id).filter { kind($0.index) == "irot" || kind($0.index) == "imir" }.map(\.index) }
        let rot = list(f.primary).first { kind($0.index) == "irot" }?.index
        let mir = list(f.primary).first { kind($0.index) == "imir" }?.index
        let primaryTransform = transformOf(f.primary)

        let derived = Set(f.refs.filter { $0.type == "dimg" && $0.to.contains(f.primary) }.map(\.from))
            .filter { id in f.items.first { $0.id == id }?.type != "grid" }
        var targets: Set<Int> = [f.primary]
        for r in f.refs where (r.type == "thmb" || r.type == "auxl") && r.to.contains(f.primary) { targets.insert(r.from) }
        for r in f.refs where r.type == "dimg" && derived.contains(r.from) {
            for id in r.to where transformOf(id) == primaryTransform { targets.insert(id) }
        }
        if !primaryTransform.isEmpty {
            for a in f.assoc where a.list.contains(where: { primaryTransform.contains($0.index) }) { targets.insert(a.id) }
        }
        targets.subtract(derived)
        let quarterTurn = (current >= 5) != (target >= 5)

        let sharedOnlyByTargets = f.assoc.allSatisfy { a in targets.contains(a.id) || !a.list.contains { primaryTransform.contains($0.index) } }
        let uniform = targets.allSatisfy { transformOf($0) == primaryTransform }
        f.d = updatedExifOrientation(f, target)
        if uniform, sharedOnlyByTargets, !(quarterTurn && !derived.isEmpty), rot != nil || angle == 0, (mir != nil) == (mirror != nil) {
            // Same layout: patch the property values where they are in the file.
            var out = f.d
            guard let ipco = locateIpco(f) else { throw ImageFile.Malformed() }
            var at = ipco
            for (k, p) in f.properties.enumerated() {
                if k + 1 == rot { out[at + 8] = angle }
                if k + 1 == mir, let mirror { out[at + 8] = mirror }
                at += p.count
            }
            return out
        }
        var added: [Association] = []
        if angle != 0 { f.properties.append(box("irot", [angle])); added.append(Association(essential: true, index: f.properties.count)) }
        if let mirror { f.properties.append(box("imir", [mirror])); added.append(Association(essential: true, index: f.properties.count)) }
        for k in f.assoc.indices where targets.contains(f.assoc[k].id) {
            f.assoc[k].list = f.assoc[k].list.filter { kind($0.index) != "irot" && kind($0.index) != "imir" } + added
        }
        if quarterTurn {
            // A derived image's size is the size of its (now turned) inputs.
            for k in f.assoc.indices where derived.contains(f.assoc[k].id) {
                guard let j = f.assoc[k].list.firstIndex(where: { kind($0.index) == "ispe" }) else { continue }
                let old = f.properties[f.assoc[k].list[j].index - 1]
                guard old.count >= 20 else { throw ImageFile.Malformed() }
                f.properties.append(box("ispe", Array(old[8..<12]) + Array(old[16..<20]) + Array(old[12..<16])))
                f.assoc[k].list[j].index = f.properties.count
            }
        }
        guard f.properties.count < 0x7FFF, f.assoc.allSatisfy({ $0.list.count < 256 }) else { throw ImageFile.Malformed() }
        return try serialize(f, keepTop: { _ in true })
    }

    /// File offset of the first property box inside ipco.
    static func locateIpco(_ f: File) -> Int? {
        guard let iprp = f.metaChildren.first(where: { $0.type == "iprp" }), let parts = boxes(f.d, iprp.payload),
              let ipco = parts.first(where: { $0.type == "ipco" }) else { return nil }
        return ipco.payload.lowerBound
    }

    /// Copy of the file bytes with the EXIF orientation tag (if an EXIF item has one) set to `target`.
    static func updatedExifOrientation(_ f: File, _ target: UInt32) -> [UInt8] {
        var d = f.d
        for it in f.items where it.type == "Exif" {
            guard let l = f.locations.first(where: { $0.id == it.id }), l.extents.count == 1 else { continue }
            let e = l.extents[0]
            let start = Int(l.base + e.offset), len = Int(e.length)
            // The item starts with the offset of the TIFF header from the end of that 4-byte field.
            func patch(_ buf: inout [UInt8], _ s: Int) {
                guard s >= 0, len >= 12, s + len <= buf.count else { return }
                let tiff = s + 4 + ImageFile.be32(buf, s)
                let slice = Array(buf[tiff..<min(s + len, buf.count)])
                guard let r = TIFFFile.reader(slice) else { return }
                let ifd = r.u32(4)
                guard ifd + 2 <= slice.count else { return }
                let n = r.u16(ifd)
                for k in 0..<n where ifd + 2 + 12 * k + 12 <= slice.count {
                    let at = ifd + 2 + 12 * k
                    if r.u16(at) == 274, r.u16(at + 2) == 3 {
                        let v = r.put16(Int(target))
                        buf[tiff + at + 8] = v[0]; buf[tiff + at + 9] = v[1]
                    }
                }
            }
            if l.method == 0 { patch(&d, start) }
        }
        return d
    }
}
