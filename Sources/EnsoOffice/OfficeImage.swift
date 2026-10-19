import Foundation
import CoreGraphics
import ImageIO
import EnsoDoc

/// Normalises images found inside Office packages to what DocImage carries (PNG / JPEG).
enum OfficeImage {
    static func sniff(_ data: Data) -> DocImageFormat? {
        let b = [UInt8](data.prefix(8))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return .png }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        return nil
    }

    /// False for images whose header declares an absurd size; unreadable data is left to the caller.
    static func withinLimits(_ data: Data) -> Bool {
        CGImageSourceCreateWithData(data as CFData, nil).map { ImageCodec.isWithinLimits($0, strict: false) } ?? true
    }

    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              SafeInt.isReasonablePixelSize(w, h) else { return nil }
        return (w, h)
    }

    /// PNG/JPEG pass through untouched; anything else ImageIO can decode (GIF, TIFF, BMP, HEIC, WebP...) becomes PNG.
    /// Returns nil for formats macOS cannot render (EMF/WMF/SVG) or broken data.
    static func docImage(from data: Data, widthPt: Double?, heightPt: Double?, alt: String?) -> DocImage? {
        var bytes = data
        var format: DocImageFormat
        var size: (Int, Int)
        if let f = sniff(data), let s = pixelSize(data) {
            format = f; size = s
        } else {
            guard let cg = ImageCodec.decode(data), cg.width > 0, cg.height > 0,
                  let png = ImageCodec.encode(cg, as: .png) else { return nil }
            bytes = png; format = .png; size = (cg.width, cg.height)
        }
        var w = widthPt ?? 0, h = heightPt ?? 0
        if !(w > 0 && h > 0 && w.isFinite && h.isFinite) {
            // Unknown placement size: assume 96 dpi like Office does.
            w = Double(size.0) * 0.75; h = Double(size.1) * 0.75
        }
        let altText = alt?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DocImage(data: bytes, format: format, pixelWidth: size.0, pixelHeight: size.1,
                        displayWidth: w, displayHeight: h, altText: (altText?.isEmpty ?? true) ? nil : altText)
    }

    /// Checks the bytes really are PNG/JPEG (re-encoding anything else ImageIO understands) and gets the pixel size.
    static func prepare(_ img: DocImage) -> (data: Data, format: DocImageFormat, width: Int, height: Int)? {
        if let f = sniff(img.data), let (w, h) = pixelSize(img.data) { return (img.data, f, w, h) }
        guard let cg = ImageCodec.decode(img.data), let png = ImageCodec.encode(cg, as: .png) else { return nil }
        return (png, .png, cg.width, cg.height)
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "jpe", "gif", "tif", "tiff", "bmp", "emf", "wmf",
                                               "svg", "heic", "webp", "wdp", "jxr", "ico", "pict", "pct", "emz", "wmz"]
}
