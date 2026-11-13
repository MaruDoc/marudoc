import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// Plays the drawing records of an EMF picture (bitmaps, lines, polygons, rectangles, ellipses, paths, fills and
/// text) into a Core Graphics context whose y axis points down. macOS cannot decode EMF itself; Office pictures that
/// are EMF (org charts, OLE previews, pasted Excel ranges) would otherwise be lost. EMF+ records and WMF are not
/// played: `draw` returns false so the caller can report the picture.
enum EMFPlayer {

    /// Draws `data` stretched over `rect` (the picture's frame, with `crop` fractions cut from its edges).
    /// Returns false when the data is not an EMF it can play.
    static func draw(_ data: Data, in rect: CGRect, crop: (l: Double, t: Double, r: Double, b: Double), ctx: CGContext) -> Bool {
        var bytes = [UInt8](data)
        // .emz: gzip-compressed EMF.
        if bytes.count > 2, bytes[0] == 0x1F, bytes[1] == 0x8B, let raw = try? Gzip.inflate(data) { bytes = [UInt8](raw) }
        guard bytes.count >= 88, u32(bytes, 0) == 1, u32(bytes, 40) == 0x464D4520 else { return false }
        var p = Player(b: bytes, ctx: ctx)
        guard p.prepare(target: rect, crop: crop) else { return false }
        ctx.saveGState()
        ctx.clip(to: rect)
        p.play()
        ctx.restoreGState()
        return p.drewSomething
    }

    @inline(__always) static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    @inline(__always) static func i32(_ b: [UInt8], _ o: Int) -> Int32 { Int32(bitPattern: u32(b, o)) }
    @inline(__always) static func i16(_ b: [UInt8], _ o: Int) -> Int16 {
        guard o >= 0, o + 2 <= b.count else { return 0 }
        return Int16(bitPattern: UInt16(b[o]) | UInt16(b[o + 1]) << 8)
    }
    @inline(__always) static func f32(_ b: [UInt8], _ o: Int) -> Double { Double(Float(bitPattern: u32(b, o))) }

    private enum Obj {
        case pen(width: Double, color: DColor?, style: UInt32)
        case brush(DColor?)
        case font(height: Double, weight: Int, italic: Bool, face: String, escapement: Double)
    }

    private struct DC {
        var pen: Obj = .pen(width: 0, color: .black, style: 0)
        var brush: Obj = .brush(.white)
        var font: Obj = .font(height: 12, weight: 400, italic: false, face: "Arial", escapement: 0)
        var textColor = DColor.black
        var textAlign: UInt32 = 0
        var mapMode: UInt32 = 1
        var winOrg = CGPoint.zero, winExt = CGSize(width: 1, height: 1)
        var vpOrg = CGPoint.zero, vpExt = CGSize(width: 1, height: 1)
        var world = CGAffineTransform.identity
        var polyFill: CGPathFillRule = .evenOdd
        var current = CGPoint.zero
        var clip: CGRect?
    }

    private struct Player {
        let b: [UInt8]
        let ctx: CGContext
        var dc = DC()
        var stack: [DC] = []
        var objects: [UInt32: Obj] = [:]
        var device = CGAffineTransform.identity     // device units -> page
        var path: CGMutablePath?
        var drewSomething = false
        let fonts = SlideFonts()
        var dpmm = CGSize(width: 1, height: 1)      // device pixels per millimetre

        init(b: [UInt8], ctx: CGContext) { self.b = b; self.ctx = ctx }

        mutating func prepare(target: CGRect, crop: (l: Double, t: Double, r: Double, b: Double)) -> Bool {
            let bounds = CGRect(x: Double(i32(b, 8)), y: Double(i32(b, 12)), width: Double(i32(b, 16) - i32(b, 8) + 1), height: Double(i32(b, 20) - i32(b, 12) + 1))
            let frame = (Double(i32(b, 24)), Double(i32(b, 28)), Double(i32(b, 32)), Double(i32(b, 36)))   // 0.01 mm
            let devPx = (Double(i32(b, 72)), Double(i32(b, 76))), devMM = (Double(i32(b, 80)), Double(i32(b, 84)))
            var src = bounds
            if devPx.0 > 0, devPx.1 > 0, devMM.0 > 0, devMM.1 > 0, frame.2 > frame.0, frame.3 > frame.1 {
                dpmm = CGSize(width: devPx.0 / devMM.0, height: devPx.1 / devMM.1)
                src = CGRect(x: frame.0 / 100 * Double(dpmm.width), y: frame.1 / 100 * Double(dpmm.height),
                             width: (frame.2 - frame.0) / 100 * Double(dpmm.width), height: (frame.3 - frame.1) / 100 * Double(dpmm.height))
            }
            guard src.width > 0, src.height > 0, src.width.isFinite, src.height.isFinite else { return false }
            let cw = 1 - crop.l - crop.r, ch = 1 - crop.t - crop.b
            guard cw > 0.0001, ch > 0.0001 else { return false }
            let full = CGRect(x: target.minX - target.width * crop.l / cw, y: target.minY - target.height * crop.t / ch,
                              width: target.width / cw, height: target.height / ch)
            device = CGAffineTransform(translationX: -src.minX, y: -src.minY)
                .concatenating(CGAffineTransform(scaleX: full.width / src.width, y: full.height / src.height))
                .concatenating(CGAffineTransform(translationX: full.minX, y: full.minY))
            return true
        }

        /// Logical (world) coordinates -> page.
        var transform: CGAffineTransform {
            var page: CGAffineTransform
            switch dc.mapMode {
            case 1: // MM_TEXT
                page = CGAffineTransform(translationX: -dc.winOrg.x, y: -dc.winOrg.y).concatenating(CGAffineTransform(translationX: dc.vpOrg.x, y: dc.vpOrg.y))
            case 7, 8: // MM_ISOTROPIC, MM_ANISOTROPIC
                var sx = dc.winExt.width != 0 ? dc.vpExt.width / dc.winExt.width : 1
                var sy = dc.winExt.height != 0 ? dc.vpExt.height / dc.winExt.height : 1
                if dc.mapMode == 7 { let s = min(abs(sx), abs(sy)); sx = sx < 0 ? -s : s; sy = sy < 0 ? -s : s }
                page = CGAffineTransform(translationX: -dc.winOrg.x, y: -dc.winOrg.y).concatenating(CGAffineTransform(scaleX: sx, y: sy))
                    .concatenating(CGAffineTransform(translationX: dc.vpOrg.x, y: dc.vpOrg.y))
            default: // metric modes: logical units in mm fractions, y up
                let unit: Double = [2: 0.1, 3: 0.01, 4: 0.254, 5: 0.0254, 6: 25.4 / 1440][dc.mapMode] ?? 1
                page = CGAffineTransform(translationX: -dc.winOrg.x, y: -dc.winOrg.y)
                    .concatenating(CGAffineTransform(scaleX: unit * dpmm.width, y: -unit * dpmm.height))
                    .concatenating(CGAffineTransform(translationX: dc.vpOrg.x, y: dc.vpOrg.y))
            }
            return dc.world.concatenating(page).concatenating(device)
        }

        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }

        /// Scale of one logical unit on the page (for pen widths and font sizes).
        var unitScale: Double {
            let t = transform
            return (hypot(t.a, t.b) + hypot(t.c, t.d)) / 2
        }

        mutating func play() {
            var off = 0
            var guardCount = 0
            while off + 8 <= b.count, guardCount < 5_000_000 {
                guardCount += 1
                let type = u32(b, off), size = Int(u32(b, off + 4))
                guard size >= 8, off + size <= b.count else { break }
                record(type, off, size)
                if type == 14 { break }
                off += size
            }
        }

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        mutating func record(_ t: UInt32, _ o: Int, _ size: Int) {
            switch t {
            case 9: dc.winExt = CGSize(width: Double(i32(b, o + 8)), height: Double(i32(b, o + 12)))
            case 10: dc.winOrg = CGPoint(x: Double(i32(b, o + 8)), y: Double(i32(b, o + 12)))
            case 11: dc.vpExt = CGSize(width: Double(i32(b, o + 8)), height: Double(i32(b, o + 12)))
            case 12: dc.vpOrg = CGPoint(x: Double(i32(b, o + 8)), y: Double(i32(b, o + 12)))
            case 17: dc.mapMode = u32(b, o + 8)
            case 19: dc.polyFill = u32(b, o + 8) == 2 ? .winding : .evenOdd
            case 22: dc.textAlign = u32(b, o + 8)
            case 24: dc.textColor = color(o + 8) ?? .black
            case 27: dc.current = CGPoint(x: Double(i32(b, o + 8)), y: Double(i32(b, o + 12)))
            case 33: stack.append(dc); ctx.saveGState()
            case 34:
                // RestoreDC with a relative count (usually -1).
                let n = Int(i32(b, o + 8))
                let k = n < 0 ? -n : max(stack.count - n + 1, 0)
                for _ in 0..<k where !stack.isEmpty { dc = stack.removeLast(); ctx.restoreGState() }
            case 35: dc.world = xform(o + 8)
            case 36:
                let m = xform(o + 8)
                switch u32(b, o + 32) {
                case 1: dc.world = .identity
                case 2: dc.world = m.concatenating(dc.world)
                case 3: dc.world = dc.world.concatenating(m)
                case 4: dc.world = m
                default: break
                }
            case 37: // SelectObject
                let h = u32(b, o + 8)
                if h & 0x8000_0000 != 0 { stock(h & 0x7FFF_FFFF) } else if let obj = objects[h] {
                    switch obj { case .pen: dc.pen = obj; case .brush: dc.brush = obj; case .font: dc.font = obj }
                }
            case 38: // CreatePen
                let style = u32(b, o + 12)
                objects[u32(b, o + 8)] = .pen(width: Double(i32(b, o + 16)), color: style & 0xF == 5 ? nil : color(o + 24), style: style)
            case 95: // ExtCreatePen
                let style = u32(b, o + 24)
                objects[u32(b, o + 8)] = .pen(width: Double(u32(b, o + 28)), color: style & 0xF == 5 ? nil : color(o + 36), style: style)
            case 39: // CreateBrushIndirect
                objects[u32(b, o + 8)] = .brush(u32(b, o + 12) == 1 ? nil : color(o + 16))
            case 40: objects[u32(b, o + 8)] = nil
            case 82: // ExtCreateFontIndirectW
                let lf = o + 12
                var face = ""
                for i in 0..<32 {
                    let c = UInt16(bitPattern: i16(b, lf + 28 + i * 2))
                    if c == 0 { break }
                    if let u = UnicodeScalar(c) { face.unicodeScalars.append(u) }
                }
                objects[u32(b, o + 8)] = .font(height: abs(Double(i32(b, lf))), weight: Int(i32(b, lf + 16)), italic: b[safe: lf + 20] ?? 0 != 0,
                                               face: face.isEmpty ? "Arial" : face, escapement: Double(i32(b, lf + 8)) / 10)
            case 30: // IntersectClipRect
                let r = rect(o + 8)
                ctx.clip(to: r)
            case 2, 3, 4, 5, 6, 85, 86, 87, 88, 89:
                poly(t, o)
            case 7, 8, 90, 91:
                polyPoly(t, o)
            case 42, 43, 44: // Ellipse, Rectangle, RoundRect
                let r = rect(o + 8)
                let p = CGMutablePath()
                if t == 42 { p.addEllipse(in: r) } else if t == 43 { p.addRect(r) } else {
                    let s = unitScale
                    p.addRoundedRect(in: r, cornerWidth: min(Double(i32(b, o + 24)) * s / 2, r.width / 2), cornerHeight: min(Double(i32(b, o + 28)) * s / 2, r.height / 2))
                }
                fillAndStroke(p, close: true)
            case 54: // LineTo
                let to = CGPoint(x: Double(i32(b, o + 8)), y: Double(i32(b, o + 12)))
                if let path { path.addLine(to: pt(to.x, to.y)) } else {
                    let p = CGMutablePath(); p.move(to: pt(dc.current.x, dc.current.y)); p.addLine(to: pt(to.x, to.y)); strokeOnly(p)
                }
                dc.current = to
            case 59: path = CGMutablePath()
            case 60: break
            case 61: path?.closeSubpath()
            case 62: if let p = path { fillOnly(p) }; path = nil
            case 63: if let p = path { fillAndStroke(p, close: false) }; path = nil
            case 64: if let p = path { strokeOnly(p) }; path = nil
            case 67: if let p = path, !p.isEmpty { ctx.addPath(p); ctx.clip() }; path = nil
            case 68: path = nil
            case 76, 77, 80, 81: bitmap(t, o)
            case 84: text(o)
            default: break
            }
        }

        mutating func stock(_ i: UInt32) {
            switch i {
            case 0: dc.brush = .brush(.white)
            case 1: dc.brush = .brush(DColor(hex: "C0C0C0"))
            case 2: dc.brush = .brush(DColor(hex: "808080"))
            case 3: dc.brush = .brush(DColor(hex: "404040"))
            case 4: dc.brush = .brush(.black)
            case 5: dc.brush = .brush(nil)
            case 6: dc.pen = .pen(width: 0, color: .white, style: 0)
            case 7: dc.pen = .pen(width: 0, color: .black, style: 0)
            case 8: dc.pen = .pen(width: 0, color: nil, style: 5)
            default: break
            }
        }

        func color(_ o: Int) -> DColor? {
            guard o + 3 <= b.count else { return nil }
            return DColor(r: Double(b[o]) / 255, g: Double(b[o + 1]) / 255, b: Double(b[o + 2]) / 255)
        }

        func rect(_ o: Int) -> CGRect {
            let a = pt(Double(i32(b, o)), Double(i32(b, o + 4))), c = pt(Double(i32(b, o + 8)), Double(i32(b, o + 12)))
            return CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(c.x - a.x), height: abs(c.y - a.y))
        }

        func xform(_ o: Int) -> CGAffineTransform {
            CGAffineTransform(a: f32(b, o), b: f32(b, o + 4), c: f32(b, o + 8), d: f32(b, o + 12), tx: f32(b, o + 16), ty: f32(b, o + 20))
        }

        mutating func poly(_ t: UInt32, _ o: Int) {
            let short = t >= 85
            let n = min(Int(u32(b, o + 24)), 1_000_000)
            var pts: [CGPoint] = []
            pts.reserveCapacity(n)
            for i in 0..<n {
                let q = o + 28 + i * (short ? 4 : 8)
                guard q + (short ? 4 : 8) <= b.count else { break }
                pts.append(short ? CGPoint(x: Double(i16(b, q)), y: Double(i16(b, q + 2))) : CGPoint(x: Double(i32(b, q)), y: Double(i32(b, q + 4))))
            }
            guard !pts.isEmpty else { return }
            let base = t == 5 || t == 6 || t == 88 || t == 89   // ...To variants continue from the current point
            let bezier = t == 2 || t == 5 || t == 85 || t == 88
            let target = path ?? CGMutablePath()
            var mapped = pts.map { pt($0.x, $0.y) }
            if base {
                if target.isEmpty { target.move(to: pt(dc.current.x, dc.current.y)) }
            } else {
                target.move(to: mapped.removeFirst())
            }
            if bezier {
                var i = 0
                while i + 2 < mapped.count { target.addCurve(to: mapped[i + 2], control1: mapped[i], control2: mapped[i + 1]); i += 3 }
            } else {
                for q in mapped { target.addLine(to: q) }
            }
            dc.current = pts.last!
            if path != nil { return }
            if t == 3 || t == 86 { fillAndStroke(target, close: true) } else { strokeOnly(target) }
        }

        mutating func polyPoly(_ t: UInt32, _ o: Int) {
            let short = t >= 90
            let nPolys = min(Int(u32(b, o + 24)), 100_000)
            var counts: [Int] = []
            for i in 0..<nPolys { counts.append(min(Int(u32(b, o + 32 + i * 4)), 1_000_000)) }
            var q = o + 32 + nPolys * 4
            let p = path ?? CGMutablePath()
            for c in counts {
                var first = true
                for _ in 0..<c {
                    guard q + (short ? 4 : 8) <= b.count else { break }
                    let v = short ? pt(Double(i16(b, q)), Double(i16(b, q + 2))) : pt(Double(i32(b, q)), Double(i32(b, q + 4)))
                    if first { p.move(to: v); first = false } else { p.addLine(to: v) }
                    q += short ? 4 : 8
                }
                if t == 8 || t == 91 { p.closeSubpath() }
            }
            if path != nil { return }
            if t == 8 || t == 91 { fillAndStroke(p, close: true) } else { strokeOnly(p) }
        }

        mutating func fillOnly(_ p: CGPath) {
            guard case .brush(let c) = dc.brush, let c else { return }
            ctx.addPath(p); ctx.setFillColor(c.cgColor); ctx.fillPath(using: dc.polyFill); drewSomething = true
        }

        mutating func strokeOnly(_ p: CGPath) {
            guard case .pen(let w, let c, let style) = dc.pen, let c, style & 0xF != 5 else { return }
            ctx.addPath(p)
            ctx.setStrokeColor(c.cgColor)
            ctx.setLineWidth(max(w * unitScale, 0.3))
            switch style & 0xF {
            case 1: ctx.setLineDash(phase: 0, lengths: [6, 3])
            case 2: ctx.setLineDash(phase: 0, lengths: [1.5, 1.5])
            case 3: ctx.setLineDash(phase: 0, lengths: [6, 2, 1.5, 2])
            default: ctx.setLineDash(phase: 0, lengths: [])
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            drewSomething = true
        }

        mutating func fillAndStroke(_ p: CGPath, close: Bool) {
            fillOnly(p)
            strokeOnly(p)
        }

        /// BITBLT, STRETCHBLT, SETDIBITSTODEVICE and STRETCHDIBITS: device-independent bitmaps.
        mutating func bitmap(_ t: UInt32, _ o: Int) {
            var dest: CGRect, offBmi: Int, offBits: Int, cbBits: Int, rop: UInt32 = 0xCC0020
            switch t {
            case 81: // StretchDIBits
                dest = CGRect(x: Double(i32(b, o + 24)), y: Double(i32(b, o + 28)), width: Double(i32(b, o + 72)), height: Double(i32(b, o + 76)))
                offBmi = Int(u32(b, o + 48)); offBits = Int(u32(b, o + 56)); cbBits = Int(u32(b, o + 60)); rop = u32(b, o + 68)
            case 80: // SetDIBitsToDevice
                dest = CGRect(x: Double(i32(b, o + 24)), y: Double(i32(b, o + 28)), width: Double(i32(b, o + 40)), height: Double(i32(b, o + 44)))
                offBmi = Int(u32(b, o + 48)); offBits = Int(u32(b, o + 56)); cbBits = Int(u32(b, o + 60))
            case 76, 77: // BitBlt, StretchBlt
                dest = CGRect(x: Double(i32(b, o + 24)), y: Double(i32(b, o + 28)), width: Double(i32(b, o + 32)), height: Double(i32(b, o + 36)))
                rop = u32(b, o + 40)
                offBmi = Int(u32(b, o + 84)); offBits = Int(u32(b, o + 92)); cbBits = Int(u32(b, o + 96))
                if offBmi == 0 || cbBits == 0 {
                    // A pattern fill without a source bitmap (PATCOPY / WHITENESS / BLACKNESS).
                    let r = CGRect(origin: pt(dest.minX, dest.minY), size: .zero).union(CGRect(origin: pt(dest.maxX, dest.maxY), size: .zero))
                    var fill: DColor?
                    if rop == 0x00FF0062 { fill = .white } else if rop == 0x00000042 { fill = .black } else if case .brush(let c) = dc.brush { fill = c }
                    if let fill { ctx.setFillColor(fill.cgColor); ctx.fill(r); drewSomething = true }
                    return
                }
            default: return
            }
            guard let img = EMFPlayer.dib(b, bmi: o + offBmi, bits: o + offBits, cbBits: cbBits) else { return }
            let a = pt(dest.minX, dest.minY), c = pt(dest.maxX, dest.maxY)
            let r = CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(c.x - a.x), height: abs(c.y - a.y))
            guard r.width > 0, r.height > 0 else { return }
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
            if c.x < a.x { ctx.translateBy(x: r.width, y: 0); ctx.scaleBy(x: -1, y: 1) }
            if c.y < a.y { ctx.translateBy(x: 0, y: r.height); ctx.scaleBy(x: 1, y: -1) }
            ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
            ctx.restoreGState()
            drewSomething = true
        }

        /// EXTTEXTOUTW: text at a reference point, with the per-character advances the recording application used.
        mutating func text(_ o: Int) {
            let e = o + 36
            let ref = CGPoint(x: Double(i32(b, e)), y: Double(i32(b, e + 4)))
            let n = min(Int(u32(b, e + 8)), 100_000), offStr = Int(u32(b, e + 12)), offDx = Int(u32(b, e + 36))
            var s = ""
            for i in 0..<n {
                let c = UInt16(bitPattern: i16(b, o + offStr + i * 2))
                if let u = UnicodeScalar(c) { s.unicodeScalars.append(u) }
            }
            guard !s.isEmpty, case .font(let height, let weight, let italic, let face, let esc) = dc.font else { return }
            let scale = unitScale
            let size = max(height * scale, 0.5)
            let ea = s.unicodeScalars.contains { DocxDisplayFonts.isEastAsian($0) }
            let f = fonts.face(face, size: size, bold: weight >= 600, italic: italic, eastAsian: ea)
            var dx: [Double] = []
            if offDx > 0 { for i in 0..<n { dx.append(Double(i32(b, o + offDx + i * 4)) * scale) } }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): f.font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): dc.textColor.cgColor]) as CFAttributedString)
            let width = dx.isEmpty ? CTLineGetTypographicBounds(line, nil, nil, nil) : dx.reduce(0, +)
            var origin = pt(ref.x, ref.y)
            let align = dc.textAlign
            if align & 6 == 6 { origin.x -= width / 2 } else if align & 2 != 0 { origin.x -= width }
            let ascent = CTFontGetAscent(f.font), descent = CTFontGetDescent(f.font)
            if align & 24 == 24 { /* baseline */ } else if align & 8 != 0 { origin.y -= descent } else { origin.y += ascent }
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            if esc != 0 { ctx.rotate(by: -esc * .pi / 180) }
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            if dx.isEmpty {
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
            } else {
                // Place each character where the recording put it, so table-like layouts keep their columns.
                var x = 0.0
                for (i, ch) in s.enumerated() {
                    let l = CTLineCreateWithAttributedString(NSAttributedString(string: String(ch), attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): f.font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): dc.textColor.cgColor]) as CFAttributedString)
                    ctx.textPosition = CGPoint(x: x, y: 0)
                    CTLineDraw(l, ctx)
                    x += i < dx.count ? dx[i] : CTLineGetTypographicBounds(l, nil, nil, nil)
                }
            }
            ctx.restoreGState()
            drewSomething = true
        }
    }

    /// A DIB (BITMAPINFO + bits) as a CGImage: 1/4/8-bit palettes, 16/24/32-bit, and embedded JPEG / PNG.
    static func dib(_ b: [UInt8], bmi: Int, bits: Int, cbBits: Int) -> CGImage? {
        guard bmi >= 0, bmi + 40 <= b.count, bits >= 0, cbBits > 0, bits + cbBits <= b.count else { return nil }
        let hdr = Int(u32(b, bmi))
        let w = Int(i32(b, bmi + 4)), h0 = Int(i32(b, bmi + 8))
        let bpp = Int(UInt16(bitPattern: i16(b, bmi + 14))), comp = u32(b, bmi + 16)
        let h = abs(h0), topDown = h0 < 0
        guard w > 0, h > 0, SafeIntDIB.reasonable(w, h) else { return nil }
        if comp == 4 || comp == 5 {
            // BI_JPEG / BI_PNG: the bits are a whole image file.
            let data = Data(b[bits..<(bits + cbBits)])
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard comp == 0 || comp == 3, [1, 4, 8, 16, 24, 32].contains(bpp) else { return nil }
        var palette: [(UInt8, UInt8, UInt8)] = []
        if bpp <= 8 {
            var n = Int(u32(b, bmi + 32))
            if n == 0 { n = 1 << bpp }
            let po = bmi + hdr
            for i in 0..<min(n, 256) {
                let q = po + i * 4
                guard q + 3 <= b.count else { break }
                palette.append((b[q + 2], b[q + 1], b[q]))
            }
        }
        let stride = ((w * bpp + 31) / 32) * 4
        guard bits + stride * h <= b.count else { return nil }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        var masks: (UInt32, UInt32, UInt32) = bpp == 16 ? (0x7C00, 0x03E0, 0x001F) : (0xFF0000, 0x00FF00, 0x0000FF)
        if comp == 3 { masks = (u32(b, bmi + hdr), u32(b, bmi + hdr + 4), u32(b, bmi + hdr + 8)); if hdr >= 52 { masks = (u32(b, bmi + 40), u32(b, bmi + 44), u32(b, bmi + 48)) } }
        func channel(_ v: UInt32, _ m: UInt32) -> UInt8 {
            guard m != 0 else { return 0 }
            let shift = m.trailingZeroBitCount, width = (m >> UInt32(shift)).nonzeroBitCount
            let x = (v & m) >> UInt32(shift)
            return width >= 8 ? UInt8(truncatingIfNeeded: x >> UInt32(width - 8)) : UInt8(min(255, Int(x) * 255 / max((1 << width) - 1, 1)))
        }
        for y in 0..<h {
            let row = bits + (topDown ? y : h - 1 - y) * stride
            for x in 0..<w {
                let d = (y * w + x) * 4
                switch bpp {
                case 1, 4, 8:
                    let bitOff = x * bpp
                    let byte = b[row + bitOff / 8]
                    let idx = Int((byte >> UInt8(8 - bpp - bitOff % 8)) & UInt8((1 << bpp) - 1))
                    let c = idx < palette.count ? palette[idx] : (0, 0, 0)
                    rgba[d] = c.0; rgba[d + 1] = c.1; rgba[d + 2] = c.2
                case 16:
                    let v = UInt32(b[row + x * 2]) | UInt32(b[row + x * 2 + 1]) << 8
                    rgba[d] = channel(v, masks.0); rgba[d + 1] = channel(v, masks.1); rgba[d + 2] = channel(v, masks.2)
                case 24:
                    let q = row + x * 3
                    rgba[d] = b[q + 2]; rgba[d + 1] = b[q + 1]; rgba[d + 2] = b[q]
                default:
                    let q = row + x * 4
                    if comp == 3 {
                        let v = u32(b, q)
                        rgba[d] = channel(v, masks.0); rgba[d + 1] = channel(v, masks.1); rgba[d + 2] = channel(v, masks.2)
                    } else { rgba[d] = b[q + 2]; rgba[d + 1] = b[q + 1]; rgba[d + 2] = b[q] }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private enum SafeIntDIB {
    static func reasonable(_ w: Int, _ h: Int) -> Bool { w <= 30_000 && h <= 30_000 && w * h <= 50_000_000 }
}

private extension Array where Element == UInt8 {
    subscript(safe i: Int) -> UInt8? { i >= 0 && i < count ? self[i] : nil }
}

/// Inflates gzip data (.emz / .wmz pictures).
enum Gzip {
    static func inflate(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw OfficeError.invalidDocument("not gzip") }
        var o = 10
        let flags = b[3]
        if flags & 4 != 0 { guard o + 2 <= b.count else { throw OfficeError.invalidDocument("gzip") }; o += 2 + Int(b[o]) | Int(b[o + 1]) << 8 }
        if flags & 8 != 0 { while o < b.count && b[o] != 0 { o += 1 }; o += 1 }
        if flags & 16 != 0 { while o < b.count && b[o] != 0 { o += 1 }; o += 1 }
        if flags & 2 != 0 { o += 2 }
        guard o < b.count - 8 else { throw OfficeError.invalidDocument("gzip") }
        return try Deflate.decompress(Data(b[o..<(b.count - 8)]), limit: 200_000_000, what: "picture")
    }
}
