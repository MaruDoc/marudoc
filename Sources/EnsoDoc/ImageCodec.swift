import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ImageCodec {
    public static func encode(_ image: CGImage, as format: DocImageFormat, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// False when the declared size is beyond `SafeInt.maxImagePixels` (checked from the header, before any decoding).
    /// By default a raster source whose size cannot be read is refused (fail closed). Vector sources (PDF, SVG) have no pixel size and pass.
    /// With `strict: false`, any unreadable source is left to the caller.
    public static func isWithinLimits(_ src: CGImageSource, strict: Bool = true) -> Bool {
        func unreadable() -> Bool {
            guard strict else { return true }
            guard let id = CGImageSourceGetType(src) as String?, let t = UTType(id) else { return false }
            return t.conforms(to: .pdf) || t.conforms(to: .svg)
        }
        guard CGImageSourceGetCount(src) > 0, let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return unreadable() }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0, h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if w <= 0 || h <= 0 { return unreadable() }
        return SafeInt.isReasonablePixelSize(w, h)
    }

    /// Header check on encoded image bytes: true only when the declared size is readable and within the limit.
    public static func isWithinLimits(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return isWithinLimits(src, strict: true)
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), isWithinLimits(src) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Picks JPEG for photos (no alpha) and PNG otherwise.
    public static func docImage(from image: CGImage, displayWidth: Double? = nil, displayHeight: Double? = nil, preferJPEG: Bool? = nil) -> DocImage? {
        let hasAlpha: Bool = {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        let format: DocImageFormat = (preferJPEG ?? !hasAlpha) ? .jpeg : .png
        guard let data = encode(image, as: format, quality: 0.88) else { return nil }
        return DocImage(data: data, format: format, pixelWidth: image.width, pixelHeight: image.height,
                        displayWidth: displayWidth, displayHeight: displayHeight)
    }
}
