import Foundation
import CoreGraphics
import ImageIO
import EnsoDoc

/// The subset of PDF colour spaces we can turn into pixels.
indirect enum PDFColorSpace {
    case gray, rgb, cmyk
    case icc(components: Int, space: CGColorSpace?)
    case indexed(base: PDFColorSpace, hival: Int, lookup: [UInt8])
    case lab
    /// Separation / single-channel DeviceN: tint 1 = full ink (dark).
    case tint
    case deviceN(Int)

    var components: Int {
        switch self {
        case .gray, .tint, .indexed: return 1
        case .rgb, .lab: return 3
        case .cmyk: return 4
        case .icc(let n, _): return n
        case .deviceN(let n): return n
        }
    }

    static func isDeviceName(_ n: String) -> Bool {
        ["DeviceGray", "G", "DeviceRGB", "RGB", "DeviceCMYK", "CMYK", "CalRGB", "CalGray", "Indexed", "I", "Pattern"].contains(n)
    }

    static func resolve(_ obj: CGPDFObjectRef?, depth: Int = 0) -> PDFColorSpace? {
        guard let obj, depth < 6 else { return nil }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(obj, .name, &name), let name {
            switch String(cString: name) {
            case "DeviceGray", "G", "CalGray": return .gray
            case "DeviceRGB", "RGB", "CalRGB": return .rgb
            case "DeviceCMYK", "CMYK": return .cmyk
            default: return nil
            }
        }
        var arr: CGPDFArrayRef?
        guard CGPDFObjectGetValue(obj, .array, &arr), let arr, CGPDFArrayGetCount(arr) >= 1 else { return nil }
        var famPtr: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(arr, 0, &famPtr), let famPtr else { return nil }
        let family = String(cString: famPtr)
        switch family {
        case "ICCBased":
            var s: CGPDFStreamRef?
            guard CGPDFArrayGetStream(arr, 1, &s), let s, let d = CGPDFStreamGetDictionary(s) else { return nil }
            var n: CGPDFInteger = 0
            _ = CGPDFDictionaryGetInteger(d, "N", &n)
            guard [1, 3, 4].contains(n) else { return nil }
            var fmt = CGPDFDataFormat.raw
            var space: CGColorSpace?
            if let data = CGPDFStreamCopyData(s, &fmt), fmt == .raw {
                space = CGColorSpace(iccData: data)
                if let sp = space, sp.numberOfComponents != Int(n) { space = nil }
            }
            return .icc(components: Int(n), space: space)
        case "Indexed", "I":
            guard CGPDFArrayGetCount(arr) >= 4 else { return nil }
            var baseObj: CGPDFObjectRef?
            guard CGPDFArrayGetObject(arr, 1, &baseObj), let base = resolve(baseObj, depth: depth + 1) else { return nil }
            var hival: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(arr, 2, &hival), hival >= 0, hival < 256 else { return nil }
            var lookup: [UInt8] = []
            var str: CGPDFStringRef?
            var lstream: CGPDFStreamRef?
            if CGPDFArrayGetString(arr, 3, &str), let str, let p = CGPDFStringGetBytePtr(str) {
                lookup = Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(str)))
            } else if CGPDFArrayGetStream(arr, 3, &lstream), let lstream {
                var fmt = CGPDFDataFormat.raw
                if let d = CGPDFStreamCopyData(lstream, &fmt) { lookup = [UInt8](d as Data) }
            }
            guard !lookup.isEmpty else { return nil }
            return .indexed(base: base, hival: Int(hival), lookup: lookup)
        case "CalRGB": return .rgb
        case "CalGray": return .gray
        case "Lab": return .lab
        case "Separation": return .tint
        case "DeviceN":
            var names: CGPDFArrayRef?
            guard CGPDFArrayGetArray(arr, 1, &names), let names else { return nil }
            let n = CGPDFArrayGetCount(names)
            return n == 1 ? .tint : .deviceN(n)
        default:
            return nil
        }
    }
}

/// Decodes PDF image XObjects into encoded PNG/JPEG data.
enum PDFImageDecoder {
    struct Decoded {
        var data: Data
        var format: DocImageFormat
        var width: Int
        var height: Int
    }

    private static let maxPixels = 60_000_000

    static func decode(_ p: ImagePlacement) -> Decoded? {
        guard let dict = CGPDFStreamGetDictionary(p.stream) else { return nil }
        if p.isMask { return nil }
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &w), CGPDFDictionaryGetInteger(dict, "Height", &h),
              w > 0, h > 0, SafeInt.isReasonablePixelSize(Int(w), Int(h), limit: maxPixels) else { return nil }
        let width = Int(w), height = Int(h)

        var fmt = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(p.stream, &fmt) else { return nil }
        let data = cfData as Data
        let alpha = softMask(dict: dict)

        switch fmt {
        case .jpegEncoded, .JPEG2000:
            guard let src = CGImageSourceCreateWithData(data as CFData, nil), ImageCodec.isWithinLimits(src),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let model = img.colorSpace?.model
            let passthrough = fmt == .jpegEncoded && alpha == nil && (model == .rgb || model == .monochrome) && !hasInvertingDecode(dict)
            if passthrough {
                return Decoded(data: data, format: .jpeg, width: img.width, height: img.height)
            }
            var final = toSRGB(img)
            if hasInvertingDecode(dict), model == .cmyk, let f = final { final = invert(f) }
            if let a = alpha, let f = final { final = applyAlpha(f, mask: a) }
            guard let out = final else { return nil }
            return encode(out, photo: true, hasAlpha: alpha != nil)
        case .raw:
            var bpc: CGPDFInteger = 8
            _ = CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc)
            guard [1, 2, 4, 8, 16].contains(bpc) else { return nil }
            var csObj: CGPDFObjectRef? = p.colorSpace
            if csObj == nil { _ = CGPDFDictionaryGetObject(dict, "ColorSpace", &csObj) }
            let space = PDFColorSpace.resolve(csObj) ?? (Int(bpc) == 1 ? .gray : nil)
            guard let space else { return nil }
            let decodeArr = numberArray(dict, "Decode")
            guard let img = rawImage(data: data, width: width, height: height, bpc: Int(bpc), space: space, decode: decodeArr) else { return nil }
            var final = img
            if let a = alpha, let f = applyAlpha(img, mask: a) { final = f }
            let indexedOrBinary: Bool = {
                if case .indexed = space { return true }
                return bpc <= 2
            }()
            return encode(final, photo: !indexedOrBinary && looksPhotographic(final), hasAlpha: alpha != nil)
        @unknown default:
            return nil
        }
    }

    // MARK: Raw samples

    static func rawImage(data: Data, width: Int, height: Int, bpc: Int, space: PDFColorSpace, decode: [Double]?) -> CGImage? {
        guard SafeInt.isReasonablePixelSize(width, height, limit: maxPixels) else { return nil }
        if let img = nativeImage(data: data, width: width, height: height, bpc: bpc, space: space, decode: decode) { return img }
        return manualImage(data: data, width: width, height: height, bpc: bpc, space: space, decode: decode)
    }

    private static func cgSpace(_ s: PDFColorSpace) -> CGColorSpace? {
        switch s {
        case .gray: return CGColorSpaceCreateDeviceGray()
        case .rgb: return CGColorSpaceCreateDeviceRGB()
        case .cmyk: return CGColorSpaceCreateDeviceCMYK()
        case .icc(let n, let cs):
            if let cs { return cs }
            return n == 1 ? CGColorSpaceCreateDeviceGray() : n == 3 ? CGColorSpaceCreateDeviceRGB() : n == 4 ? CGColorSpaceCreateDeviceCMYK() : nil
        case .indexed(let base, let hival, let lookup):
            guard let b = cgSpace(base), lookup.count >= (hival + 1) * b.numberOfComponents else { return nil }
            return lookup.withUnsafeBufferPointer { buf in buf.baseAddress.flatMap { CGColorSpace(indexedBaseSpace: b, last: hival, colorTable: $0) } }
        default: return nil
        }
    }

    /// Lets CoreGraphics interpret the samples (bit depths, Decode arrays, indexed and ICC spaces).
    private static func nativeImage(data: Data, width: Int, height: Int, bpc: Int, space: PDFColorSpace, decode: [Double]?) -> CGImage? {
        guard let cs = cgSpace(space) else { return nil }
        let n = space.components
        if n > 1 && bpc != 8 && bpc != 16 { return nil }
        guard SafeInt.isReasonablePixelSize(width, height, limit: maxPixels) else { return nil }
        let rowBytes = (width * n * bpc + 7) / 8
        guard rowBytes > 0, data.count >= rowBytes else { return nil }
        var bytes = data
        let need = rowBytes * height
        // A short stream is padded so the visible part survives, but never by an unbounded amount.
        guard need - bytes.count <= 256 << 20 else { return nil }
        if bytes.count < need {
            // Truncated stream: pad with white so the visible part survives.
            var fill: UInt8 = 0xFF
            if case .cmyk = space { fill = 0 }
            bytes.append(Data(repeating: fill, count: need - bytes.count))
        } else if bytes.count > need {
            bytes = bytes.prefix(need)
        }
        var dec: [CGFloat]?
        if let d = decode, d.count >= 2 * n { dec = d.prefix(2 * n).map { CGFloat($0) } }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let info: CGBitmapInfo = bpc == 16 ? [CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), .byteOrder16Big] : CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        let img: CGImage? = dec.withOptionalBuffer { ptr in
            CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc * n, bytesPerRow: rowBytes,
                    space: cs, bitmapInfo: info, provider: provider, decode: ptr, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let img else { return nil }
        // Gray and RGB encode directly; everything else is flattened to sRGB.
        if cs.model == .monochrome && bpc == 8 && dec == nil { return img }
        if cs.model == .rgb && bpc == 8 && dec == nil && cs.name != nil { return img }
        return toSRGB(img)
    }

    private static func manualImage(data: Data, width: Int, height: Int, bpc: Int, space: PDFColorSpace, decode: [Double]?) -> CGImage? {
        let ncomp = space.components
        let rowBytes = (width * ncomp * bpc + 7) / 8
        guard rowBytes > 0 else { return nil }
        let rows = min(height, data.count / rowBytes)
        guard rows > 0 else { return nil }
        let maxVal = Double((1 << min(bpc, 16)) - 1)

        // Per-component decode ranges.
        var dmin = [Double](repeating: 0, count: ncomp)
        var dmax = [Double](repeating: 1, count: ncomp)
        switch space {
        case .indexed: dmax[0] = maxVal          // default Decode maps samples straight to indices
        case .lab: dmin = [0, -100, -100]; dmax = [100, 100, 100]
        default: break
        }
        if let d = decode, d.count >= 2 * ncomp {
            for c in 0..<ncomp { dmin[c] = d[2 * c]; dmax[c] = d[2 * c + 1] }
        }

        // Output: 8-bit samples in an "output space".
        enum Out { case gray, rgb, cmyk(CGColorSpace?), icc(CGColorSpace) }
        let outSpace: Out
        let outComps: Int
        switch space {
        case .gray, .tint: outSpace = .gray; outComps = 1
        case .rgb, .lab: outSpace = .rgb; outComps = 3
        case .cmyk: outSpace = .cmyk(nil); outComps = 4
        case .icc(let n, let cs):
            if let cs { outSpace = .icc(cs); outComps = n } else {
                outComps = n
                outSpace = n == 1 ? .gray : n == 3 ? .rgb : .cmyk(nil)
            }
        case .deviceN(let n):
            outComps = n >= 4 ? 4 : n == 3 ? 3 : 1
            outSpace = n >= 4 ? .cmyk(nil) : n == 3 ? .rgb : .gray
        case .indexed(let base, _, _):
            switch base {
            case .gray, .tint: outSpace = .gray; outComps = 1
            case .cmyk: outSpace = .cmyk(nil); outComps = 4
            case .icc(let n, let cs):
                outComps = n
                if let cs { outSpace = .icc(cs) } else { outSpace = n == 1 ? .gray : n == 3 ? .rgb : .cmyk(nil) }
            default: outSpace = .rgb; outComps = 3
            }
        }

        var out = [UInt8](repeating: 255, count: width * height * outComps)
        if case .cmyk = outSpace { for i in out.indices { out[i] = 0 } }
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var samples = [Double](repeating: 0, count: ncomp)
            for y in 0..<rows {
                let rowBase = y * rowBytes
                var bitPos = 0
                for x in 0..<width {
                    for c in 0..<ncomp {
                        let raw: Int
                        switch bpc {
                        case 8: raw = Int(src[rowBase + x * ncomp + c])
                        case 16:
                            let o = rowBase + (x * ncomp + c) * 2
                            raw = Int(src[o]) << 8 | Int(src[o + 1])
                        default:
                            let byte = Int(src[rowBase + bitPos >> 3])
                            let shift = 8 - bpc - (bitPos & 7)
                            raw = (byte >> shift) & ((1 << bpc) - 1)
                            bitPos += bpc
                        }
                        samples[c] = dmin[c] + Double(raw) * (dmax[c] - dmin[c]) / maxVal
                    }
                    let o = (y * width + x) * outComps
                    switch space {
                    case .indexed(let base, let hival, let lookup):
                        let idx = max(0, min(hival, SafeInt.round(samples[0], 0, 255)))
                        let bc = outComps
                        for k in 0..<bc {
                            let li = idx * bc + k
                            out[o + k] = li < lookup.count ? lookup[li] : 0
                        }
                        if case .tint = base { out[o] = 255 - out[o] }
                    case .lab:
                        let (r, g, b) = labToRGB(samples[0], samples[1], samples[2])
                        out[o] = r; out[o + 1] = g; out[o + 2] = b
                    case .tint:
                        out[o] = UInt8(max(0, min(255, (1 - samples[0]) * 255)))
                    case .deviceN(let n):
                        if n >= 4 { for k in 0..<4 { out[o + k] = clamp8(samples[k]) } } else if n == 3 { for k in 0..<3 { out[o + k] = clamp8(samples[k]) } } else {
                            out[o] = UInt8(max(0, min(255, (1 - samples[0]) * 255)))
                        }
                    default:
                        for k in 0..<outComps { out[o + k] = clamp8(samples[k]) }
                    }
                }
            }
        }

        let cgSpace: CGColorSpace
        switch outSpace {
        case .gray: cgSpace = CGColorSpaceCreateDeviceGray()
        case .rgb: cgSpace = CGColorSpaceCreateDeviceRGB()
        case .cmyk(let s): cgSpace = s ?? CGColorSpaceCreateDeviceCMYK()
        case .icc(let s): cgSpace = s
        }
        guard cgSpace.numberOfComponents == outComps,
              let provider = CGDataProvider(data: Data(out) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * outComps,
                                bytesPerRow: width * outComps, space: cgSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        if case .gray = outSpace { return img }
        if case .rgb = outSpace { return img }
        return toSRGB(img)
    }

    private static func clamp8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }

    private static func labToRGB(_ L: Double, _ a: Double, _ b: Double) -> (UInt8, UInt8, UInt8) {
        var y = (L + 16) / 116, x = a / 500 + y, z = y - b / 200
        func f(_ t: Double) -> Double { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16.0 / 116) / 7.787 }
        x = f(x) * 0.96422; y = f(y); z = f(z) * 0.82521
        var r = x * 3.1338561 + y * -1.6168667 + z * -0.4906146
        var g = x * -0.9787684 + y * 1.9161415 + z * 0.0334540
        var bl = x * 0.0719453 + y * -0.2289914 + z * 1.4052427
        func gamma(_ c: Double) -> Double { c > 0.0031308 ? 1.055 * pow(c, 1 / 2.4) - 0.055 : 12.92 * c }
        r = gamma(r); g = gamma(g); bl = gamma(bl)
        return (clamp8(r), clamp8(g), clamp8(bl))
    }

    // MARK: Masks

    /// Gray image whose white = opaque, from /SMask or a stencil /Mask.
    private static func softMask(dict: CGPDFDictionaryRef) -> CGImage? {
        var smRef: CGPDFStreamRef?
        var stencil = false
        if !CGPDFDictionaryGetStream(dict, "SMask", &smRef) || smRef == nil {
            smRef = nil
            guard CGPDFDictionaryGetStream(dict, "Mask", &smRef) else { return nil }
            stencil = true
        }
        guard let sm = smRef, let md = CGPDFStreamGetDictionary(sm) else { return nil }
        var mw: CGPDFInteger = 0, mh: CGPDFInteger = 0, bpc: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(md, "Width", &mw), CGPDFDictionaryGetInteger(md, "Height", &mh),
              mw > 0, mh > 0, SafeInt.isReasonablePixelSize(Int(mw), Int(mh), limit: maxPixels) else { return nil }
        if !CGPDFDictionaryGetInteger(md, "BitsPerComponent", &bpc) { bpc = stencil ? 1 : 8 }
        guard [1, 2, 4, 8, 16].contains(bpc) else { return nil }
        var fmt = CGPDFDataFormat.raw
        guard let cf = CGPDFStreamCopyData(sm, &fmt) else { return nil }
        if fmt != .raw {
            return CGImageSourceCreateWithData(cf, nil).flatMap { ImageCodec.isWithinLimits($0) ? CGImageSourceCreateImageAtIndex($0, 0, nil) : nil }
        }
        var dec = numberArray(md, "Decode")
        if stencil {
            // Stencil semantics: sample 0 paints, 1 masks out (inverted again by a [1 0] Decode).
            if let d = dec, d.count >= 2, d[0] > d[1] { dec = [0, 1] } else { dec = [1, 0] }
        }
        return rawImage(data: cf as Data, width: Int(mw), height: Int(mh), bpc: Int(bpc), space: .gray, decode: dec)
    }

    private static func applyAlpha(_ img: CGImage, mask: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var m = mask
        if m.colorSpace?.model != .monochrome || m.bitsPerComponent != 8, let g = toGray(m) { m = g }
        ctx.clip(to: rect, mask: m)
        ctx.draw(img, in: rect)
        return ctx.makeImage()
    }

    private static func toGray(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    // MARK: Helpers

    static func toSRGB(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func invert(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setBlendMode(.difference)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func hasInvertingDecode(_ dict: CGPDFDictionaryRef) -> Bool {
        guard let d = numberArray(dict, "Decode"), d.count >= 2 else { return false }
        return d[0] > d[1]
    }

    static func numberArray(_ dict: CGPDFDictionaryRef, _ key: String) -> [Double]? {
        var arr: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, key, &arr), let arr else { return nil }
        var out: [Double] = []
        for i in 0..<CGPDFArrayGetCount(arr) {
            var v: CGPDFReal = 0
            guard CGPDFArrayGetNumber(arr, i, &v), v.isFinite else { return nil }
            out.append(Double(v))
        }
        return out
    }

    /// Samples the image to decide between JPEG (photos) and PNG (flat graphics).
    static func looksPhotographic(_ img: CGImage) -> Bool {
        guard img.width * img.height > 40_000 else { return false }
        let sw = 64, sh = 64
        var px = [UInt8](repeating: 0, count: sw * sh * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            return true
        }
        guard ok else { return false }
        var colors = Set<UInt32>()
        for i in 0..<(sw * sh) {
            let o = i * 4
            colors.insert(UInt32(px[o]) << 16 | UInt32(px[o + 1]) << 8 | UInt32(px[o + 2]))
        }
        return colors.count > 700
    }

    static func encode(_ img: CGImage, photo: Bool, hasAlpha: Bool) -> Decoded? {
        var img = img
        // ImageIO cannot write CMYK/indexed PNGs; flatten anything unusual first.
        if let m = img.colorSpace?.model, m != .rgb && m != .monochrome, let f = toSRGB(img) { img = f }
        let format: DocImageFormat = (photo && !hasAlpha) ? .jpeg : .png
        guard let data = ImageCodec.encode(img, as: format, quality: 0.9) else { return nil }
        return Decoded(data: data, format: format, width: img.width, height: img.height)
    }
}

private extension Optional where Wrapped == [CGFloat] {
    func withOptionalBuffer<R>(_ body: (UnsafePointer<CGFloat>?) -> R) -> R {
        switch self {
        case .none: return body(nil)
        case .some(let a): return a.withUnsafeBufferPointer { body($0.baseAddress) }
        }
    }
}
