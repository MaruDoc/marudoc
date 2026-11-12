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

    /// How a slide shows a picture, beyond its frame size.
    struct Adjust {
        /// Fractions cut from each edge (DrawingML a:srcRect). Negative values add empty space instead.
        var crop: (l: Double, t: Double, r: Double, b: Double) = (0, 0, 0, 0)
        /// Degrees clockwise, applied after the flips (as DrawingML does).
        var rotation: Double = 0
        var flipH = false, flipV = false
        /// 0...1 (a:alphaModFix).
        var opacity: Double = 1
        /// Draw a picture whose strokes are all white or near-white in black instead (white ink on a white page).
        var darkenNearWhite = false

        var isIdentity: Bool {
            crop == (0, 0, 0, 0) && rotationQuarterTurns == 0 && abs(normalizedRotation) < 0.01 && !flipH && !flipV
                && opacity >= 1 && !darkenNearWhite
        }
        var normalizedRotation: Double { let r = rotation.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }
        var rotationQuarterTurns: Int { abs(normalizedRotation.truncatingRemainder(dividingBy: 90)) < 0.01 ? Int((normalizedRotation / 90).rounded()) % 4 : 0 }
    }

    /// Like `docImage(from:widthPt:heightPt:alt:)`, with the picture cropped, flipped, rotated and faded the way the
    /// slide shows it. `widthPt` x `heightPt` is the unrotated frame; the result's display size is the rotated frame's
    /// bounding box. When the adjustment cannot be applied the picture is returned unadjusted.
    static func docImage(from data: Data, widthPt: Double?, heightPt: Double?, alt: String?, adjust: Adjust) -> DocImage? {
        guard !adjust.isIdentity, let adjusted = apply(adjust, to: data, widthPt: widthPt, heightPt: heightPt) else {
            return docImage(from: data, widthPt: widthPt, heightPt: heightPt, alt: alt)
        }
        let altText = alt?.trimmingCharacters(in: .whitespacesAndNewlines)
        var img = adjusted
        img.altText = (altText?.isEmpty ?? true) ? nil : altText
        return img
    }

    /// Longest side of an adjusted picture, in pixels. Keeps re-rendered photos at a sane size.
    static let maxAdjustedSide = 6000.0

    private static func apply(_ a: Adjust, to data: Data, widthPt: Double?, heightPt: Double?) -> DocImage? {
        // The visible part of the picture, as fractions of it (may reach outside it for negative crops).
        let x0 = a.crop.l, x1 = 1 - a.crop.r, y0 = a.crop.t, y1 = 1 - a.crop.b
        guard x1 - x0 > 0.001, y1 - y0 > 0.001, [x0, x1, y0, y1].allSatisfy({ $0.isFinite && abs($0) < 100 }) else { return nil }

        // Decode with the EXIF orientation applied: crop rectangles refer to the picture as it is seen. A huge picture
        // is decoded only as large as the visible part needs (the result is capped at maxAdjustedSide anyway).
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), ImageCodec.isWithinLimits(src),
              let (pw, ph) = pixelSize(data) else { return nil }
        let needed = maxAdjustedSide * 1.5 / min(max(x1 - x0, y1 - y0), 1)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: min(max(pw, ph), Int(min(needed, 1e9))), kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), image.width > 0, image.height > 0 else { return nil }
        let iw = Double(image.width), ih = Double(image.height)
        let regionW = (x1 - x0) * iw, regionH = (y1 - y0) * ih

        // Unrotated frame in points; without one, the visible region at 96 dpi.
        var fw = widthPt ?? 0, fh = heightPt ?? 0
        if !(fw > 0 && fh > 0 && fw.isFinite && fh.isFinite) { fw = regionW * 0.75; fh = regionH * 0.75 }
        // Pixels per point: the visible region keeps its full resolution, stretched to the frame's shape as on the slide.
        var ppp = max(regionW / fw, regionH / fh)
        let longest = max(fw, fh) * ppp
        if longest > maxAdjustedSide { ppp *= maxAdjustedSide / longest }
        let tw = fw * ppp, th = fh * ppp

        let quarter = a.rotationQuarterTurns
        let angle = a.normalizedRotation * .pi / 180
        let rightAngle = abs(a.normalizedRotation - Double(quarter) * 90) < 0.01
        let cosA = rightAngle ? [1.0, 0, -1, 0][quarter] : cos(angle), sinA = rightAngle ? [0.0, 1, 0, -1][quarter] : sin(angle)
        let bw = abs(tw * cosA) + abs(th * sinA), bh = abs(tw * sinA) + abs(th * cosA)
        let cw = max(1, Int(bw.rounded())), ch = max(1, Int(bh.rounded()))
        guard SafeInt.isReasonablePixelSize(cw, ch, limit: 100_000_000),
              let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // DrawingML flips the picture inside its frame, then turns the frame clockwise about its centre.
        // Core Graphics has y up, so clockwise is a negative angle.
        ctx.translateBy(x: Double(cw) / 2, y: Double(ch) / 2)
        ctx.rotate(by: -angle)
        ctx.scaleBy(x: a.flipH ? -1 : 1, y: a.flipV ? -1 : 1)
        let frameRect = CGRect(x: -tw / 2, y: -th / 2, width: tw, height: th)
        ctx.clip(to: frameRect)
        ctx.setAlpha(a.opacity)
        let fullW = tw / (x1 - x0), fullH = th / (y1 - y0)
        ctx.draw(image, in: CGRect(x: -tw / 2 - x0 * fullW, y: th / 2 - (1 - y0) * fullH, width: fullW, height: fullH))

        var darkened = false
        if a.darkenNearWhite {
            darkened = darkenIfNearWhite(ctx)
            // Visible ink and nothing else to change: let the caller pass the original bytes through.
            var rest = a; rest.darkenNearWhite = false
            if !darkened && rest.isIdentity { return nil }
        }
        guard let out = ctx.makeImage() else { return nil }

        // Keep JPEG for opaque photos; anything with transparency (rotation corners, fading, empty crop space) is PNG.
        let opaque: Bool = {
            switch image.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: break; default: return false }
            return a.opacity >= 1 && rightAngle && x0 >= 0 && y0 >= 0 && x1 <= 1 && y1 <= 1 && !darkened
        }()
        let format: DocImageFormat = opaque && sniff(data) == .jpeg ? .jpeg : .png
        guard let bytes = ImageCodec.encode(out, as: format, quality: 0.92) else { return nil }
        let k = 1 / ppp   // points per pixel
        return DocImage(data: bytes, format: format, pixelWidth: cw, pixelHeight: ch,
                        displayWidth: bw * k, displayHeight: bh * k)
    }

    /// When every visible pixel is white or nearly so, paints the strokes black (keeping their shape and alpha).
    /// Returns whether it did.
    private static func darkenIfNearWhite(_ ctx: CGContext) -> Bool {
        guard let base = ctx.data else { return false }
        let w = ctx.width, h = ctx.height, row = ctx.bytesPerRow
        let px = base.bindMemory(to: UInt8.self, capacity: row * h)
        var visible = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * row + x * 4
                let alpha = Int(px[i + 3])
                guard alpha > 25 else { continue }
                // Premultiplied: a white pixel has each colour component equal to alpha.
                if Int(min(px[i], px[i + 1], px[i + 2])) * 100 < alpha * 85 { return false }
                visible += 1
            }
        }
        guard visible > 0 else { return false }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * row + x * 4
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 0
            }
        }
        return true
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
