import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision
import EnsoShared
import EnsoDoc

public enum ImageOps {

    // MARK: Loading / writing

    struct Loaded {
        var image: CGImage
        var properties: [CFString: Any]
        var type: UTType
    }

    /// Full-resolution image with EXIF orientation applied.
    static func loadOriented(_ url: URL) -> Loaded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), ImageCodec.isWithinLimits(src),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let type = (CGImageSourceGetType(src) as String?).flatMap { UTType($0) } ?? .png
        return Loaded(image: img, properties: props, type: type)
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
        guard let l = loadOriented(file) else { throw DocIOError.unreadable(file.lastPathComponent) }
        let target = utType(for: format)
        let out = OutputNamer.file(for: file, ext: ext(for: target), tag: l.type == target ? L("変換") : nil)
        try write(l.image, to: out, format: format, quality: 0.92, metadata: l.properties)
        return out
    }

    // MARK: Orientation (in place, lossless where ImageIO allows)

    public enum Orientation { case right, left, flipH, flipV }

    static func reorient(_ file: URL, _ op: Orientation) throws -> SafeWrite.Backup {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), ImageCodec.isWithinLimits(src),
              let typeID = CGImageSourceGetType(src) else { throw DocIOError.unreadable(file.lastPathComponent) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let current = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let next = combine(current, op)
        return try SafeWrite.replace(file) { tmp in
            guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, typeID, 1, nil) else { throw DocIOError.writeFailed(file.lastPathComponent) }
            // Lossless: only the orientation tag changes (JPEG / HEIC / TIFF / PNG).
            var err: Unmanaged<CFError>?
            let ok = CGImageDestinationCopyImageSource(dest, src, [kCGImageDestinationOrientation: next] as CFDictionary, &err)
            if !ok {
                // Fallback: re-encode upright pixels.
                guard let l = loadOriented(file), let rotated = transform(l.image, op) else { throw DocIOError.writeFailed(file.lastPathComponent) }
                try write(rotated, to: tmp, format: ext(for: l.type), quality: 0.95, metadata: l.properties)
            }
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

    static func transform(_ img: CGImage, _ op: Orientation) -> CGImage? {
        let w = img.width, h = img.height
        let swap = op == .right || op == .left
        let W = swap ? h : w, H = swap ? w : h
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        switch op {
        case .right: ctx.translateBy(x: 0, y: CGFloat(H)); ctx.rotate(by: -.pi / 2)
        case .left: ctx.translateBy(x: CGFloat(W), y: 0); ctx.rotate(by: .pi / 2)
        case .flipH: ctx.translateBy(x: CGFloat(W), y: 0); ctx.scaleBy(x: -1, y: 1)
        case .flipV: ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Resize / compress

    enum ResizeSpec { case scale(Double), longEdge(Int) }

    static func resize(_ file: URL, _ spec: ResizeSpec) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), ImageCodec.isWithinLimits(src),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { throw DocIOError.unreadable(file.lastPathComponent) }
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
        guard let l = loadOriented(file) else { throw DocIOError.unreadable(file.lastPathComponent) }
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
        guard let l = loadOriented(file) else { throw DocIOError.unreadable(file.lastPathComponent) }
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

    static func stripMetadata(_ file: URL) throws -> SafeWrite.Backup {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), ImageCodec.isWithinLimits(src), let typeID = CGImageSourceGetType(src) else {
            throw DocIOError.unreadable(file.lastPathComponent)
        }
        // Everything goes except the orientation tag, otherwise portrait photos would turn sideways.
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let meta = CGImageMetadataCreateMutable()
        if orientation != 1 {
            _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        }
        return try SafeWrite.replace(file) { tmp in
            guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, typeID, 1, nil) else { throw DocIOError.writeFailed(file.lastPathComponent) }
            let opts: [CFString: Any] = [
                kCGImageDestinationMetadata: meta,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
            ]
            var err: Unmanaged<CFError>?
            if !CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) {
                // Re-encode with only the basics.
                guard let l = loadOriented(file) else { throw DocIOError.writeFailed(file.lastPathComponent) }
                try write(l.image, to: tmp, format: ext(for: l.type), quality: 0.95, metadata: nil)
            }
        }
    }
}

/// On-device text recognition (Vision).
public enum TextRecognizer {
    public static func recognize(url: URL, languages: [String]) throws -> String {
        guard let l = ImageOps.loadOriented(url) else { throw DocIOError.unreadable(url.lastPathComponent) }
        return try recognize(cgImage: l.image, languages: languages)
    }

    public static func recognize(cgImage: CGImage, languages: [String]) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
