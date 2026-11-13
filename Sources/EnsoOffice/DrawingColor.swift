import Foundation
import CoreGraphics

/// An sRGB colour with alpha, 0...1 per component.
struct DColor: Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let black = DColor(r: 0, g: 0, b: 0)
    static let white = DColor(r: 1, g: 1, b: 1)

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func with(alpha: Double) -> DColor { var c = self; c.a = alpha; return c }

    /// Linear mix towards `other` (t = 0 keeps self).
    func mixed(with other: DColor, _ t: Double) -> DColor {
        DColor(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }

    // MARK: Colour spaces used by the DrawingML modifiers

    static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func toSRGB(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx - mn > 1e-9 else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    init(h: Double, s: Double, l: Double, a: Double = 1) {
        func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        if s <= 0 { self.init(r: l, g: l, b: l, a: a); return }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        self.init(r: hue(p, q, h + 1.0 / 3), g: hue(p, q, h), b: hue(p, q, h - 1.0 / 3), a: a)
    }

    func clamped() -> DColor {
        func c(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        return DColor(r: c(r), g: c(g), b: c(b), a: c(a))
    }
}

/// The parts of a theme (a:theme) the slide renderer uses.
final class DrawingTheme {
    var colors: [String: DColor] = [:]
    var majorLatin = "", majorEA = "", majorCS = ""
    var minorLatin = "", minorEA = "", minorCS = ""
    /// Per-script fonts (a:font script="Jpan" ...) of the major and minor font.
    var majorScripts: [String: String] = [:], minorScripts: [String: String] = [:]
    var fillStyles: [XNode] = [], lineStyles: [XNode] = [], effectStyles: [XNode] = [], bgFillStyles: [XNode] = []

    /// The Office 2013 default theme, used when a deck has none.
    static let fallback: DrawingTheme = {
        let t = DrawingTheme()
        let hex = ["dk1": "000000", "lt1": "FFFFFF", "dk2": "44546A", "lt2": "E7E6E6", "accent1": "4472C4", "accent2": "ED7D31",
                   "accent3": "A5A5A5", "accent4": "FFC000", "accent5": "5B9BD5", "accent6": "70AD47", "hlink": "0563C1", "folHlink": "954F72"]
        for (k, v) in hex { t.colors[k] = DColor(hex: v) }
        t.majorLatin = "Calibri Light"; t.minorLatin = "Calibri"
        return t
    }()

    init() {}

    init(_ root: XNode) {
        guard let el = root.child("a:themeElements") else { return }
        if let cs = el.child("a:clrScheme") {
            for c in cs.children {
                let name = String(c.localName)
                // Theme colours are plain sRGB or system colours; no scheme references are possible here.
                if let col = ColorResolver.baseColor(c.children.first, scheme: { _ in nil }) { colors[name] = col }
            }
        }
        if let fs = el.child("a:fontScheme") {
            func read(_ f: XNode?) -> (String, String, String, [String: String]) {
                var scripts: [String: String] = [:]
                for s in f?.children("a:font") ?? [] { if let k = s["script"], let v = s["typeface"] { scripts[k] = v } }
                return (f?.child("a:latin")?["typeface"] ?? "", f?.child("a:ea")?["typeface"] ?? "", f?.child("a:cs")?["typeface"] ?? "", scripts)
            }
            (majorLatin, majorEA, majorCS, majorScripts) = read(fs.child("a:majorFont"))
            (minorLatin, minorEA, minorCS, minorScripts) = read(fs.child("a:minorFont"))
        }
        if let fmt = el.child("a:fmtScheme") {
            fillStyles = fmt.child("a:fillStyleLst")?.children ?? []
            lineStyles = fmt.child("a:lnStyleLst")?.children ?? []
            effectStyles = fmt.child("a:effectStyleLst")?.children ?? []
            bgFillStyles = fmt.child("a:bgFillStyleLst")?.children ?? []
        }
    }
}

/// Resolves DrawingML colour elements (srgbClr, schemeClr, sysClr, prstClr, scrgbClr, hslClr) and their modifiers.
struct ColorResolver {
    let theme: DrawingTheme
    /// p:clrMap of the master, with any p:clrMapOvr applied: bg1 -> lt1, tx1 -> dk1, ...
    let map: [String: String]
    /// The colour a style reference (lnRef, fillRef, fontRef, bgRef) passes to "phClr".
    var phClr: DColor?

    static let defaultMap = ["bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2"]

    func scheme(_ name: String) -> DColor? {
        if name == "phClr" { return phClr }
        let key = map[name] ?? ColorResolver.defaultMap[name] ?? name
        return theme.colors[key] ?? DrawingTheme.fallback.colors[key]
    }

    func with(phClr c: DColor?) -> ColorResolver { var r = self; r.phClr = c; return r }

    /// The colour of a colour element, modifiers applied.
    func color(_ el: XNode?) -> DColor? {
        guard let el, let base = ColorResolver.baseColor(el, scheme: scheme) else { return nil }
        return ColorResolver.apply(el.children, to: base)
    }

    /// The first colour element directly inside `parent` (a:solidFill, a:gs, a:fontRef, ...).
    func color(in parent: XNode?) -> DColor? {
        guard let parent else { return nil }
        for c in parent.children where ColorResolver.colorTags.contains(c.tag) { return color(c) }
        return nil
    }

    static let colorTags: Set<String> = ["a:srgbClr", "a:schemeClr", "a:sysClr", "a:prstClr", "a:scrgbClr", "a:hslClr"]

    static func baseColor(_ el: XNode?, scheme: (String) -> DColor?) -> DColor? {
        guard let el else { return nil }
        switch el.tag {
        case "a:srgbClr": return DColor(hex: el["val"] ?? "")
        case "a:schemeClr": return el["val"].flatMap(scheme)
        case "a:sysClr":
            if let last = el["lastClr"], let c = DColor(hex: last) { return c }
            return ["windowText": DColor.black, "window": DColor.white, "btnFace": DColor(hex: "F0F0F0")!,
                    "btnText": DColor.black, "highlight": DColor(hex: "0078D7")!, "grayText": DColor(hex: "6D6D6D")!][el["val"] ?? ""] ?? .black
        case "a:prstClr": return presetColors[el["val"] ?? ""] ?? .black
        case "a:scrgbClr":
            func f(_ k: String) -> Double { DColor.toSRGB(min(max((OOXMLValue.double(el[k]) ?? 0) / 100_000, 0), 1)) }
            return DColor(r: f("r"), g: f("g"), b: f("b"))
        case "a:hslClr":
            let h = (OOXMLValue.double(el["hue"]) ?? 0) / 60_000 / 360
            return DColor(h: h, s: (OOXMLValue.double(el["sat"]) ?? 0) / 100_000, l: (OOXMLValue.double(el["lum"]) ?? 0) / 100_000)
        default: return nil
        }
    }

    /// Applies colour transforms in document order. Tint and shade work on linear RGB (as Office does: Medium Style 2's
    /// accent1 tint 40% gives CFD5EA); luminance, saturation and hue work on HSL.
    static func apply(_ mods: [XNode], to base: DColor) -> DColor {
        var c = base
        for m in mods {
            let v = (OOXMLValue.double(m["val"]) ?? 0) / 100_000
            switch m.tag {
            case "a:tint":
                func t(_ x: Double) -> Double { DColor.toSRGB(1 - (1 - DColor.toLinear(x)) * v) }
                c = DColor(r: t(c.r), g: t(c.g), b: t(c.b), a: c.a)
            case "a:shade":
                func s(_ x: Double) -> Double { DColor.toSRGB(DColor.toLinear(x) * v) }
                c = DColor(r: s(c.r), g: s(c.g), b: s(c.b), a: c.a)
            case "a:lumMod": var h = c.hsl; h.l *= v; c = DColor(h: h.h, s: h.s, l: min(max(h.l, 0), 1), a: c.a)
            case "a:lumOff": var h = c.hsl; h.l += v; c = DColor(h: h.h, s: h.s, l: min(max(h.l, 0), 1), a: c.a)
            case "a:lum": var h = c.hsl; h.l = v; c = DColor(h: h.h, s: h.s, l: min(max(h.l, 0), 1), a: c.a)
            case "a:satMod": var h = c.hsl; h.s *= v; c = DColor(h: h.h, s: min(max(h.s, 0), 1), l: h.l, a: c.a)
            case "a:satOff": var h = c.hsl; h.s += v; c = DColor(h: h.h, s: min(max(h.s, 0), 1), l: h.l, a: c.a)
            case "a:sat": var h = c.hsl; h.s = v; c = DColor(h: h.h, s: min(max(h.s, 0), 1), l: h.l, a: c.a)
            case "a:hueMod": var h = c.hsl; h.h = (h.h * v).truncatingRemainder(dividingBy: 1); c = DColor(h: h.h, s: h.s, l: h.l, a: c.a)
            case "a:hueOff":
                var h = c.hsl
                h.h = (h.h + (OOXMLValue.double(m["val"]) ?? 0) / 60_000 / 360).truncatingRemainder(dividingBy: 1)
                if h.h < 0 { h.h += 1 }
                c = DColor(h: h.h, s: h.s, l: h.l, a: c.a)
            case "a:alpha": c.a = v
            case "a:alphaMod": c.a *= v
            case "a:alphaOff": c.a += v
            case "a:gray": let y = 0.3 * c.r + 0.59 * c.g + 0.11 * c.b; c = DColor(r: y, g: y, b: y, a: c.a)
            case "a:inv": c = DColor(r: 1 - c.r, g: 1 - c.g, b: 1 - c.b, a: c.a)
            case "a:comp": var h = c.hsl; h.h = (h.h + 0.5).truncatingRemainder(dividingBy: 1); c = DColor(h: h.h, s: h.s, l: h.l, a: c.a)
            case "a:red": c.r = v
            case "a:green": c.g = v
            case "a:blue": c.b = v
            case "a:redMod": c.r *= v
            case "a:greenMod": c.g *= v
            case "a:blueMod": c.b *= v
            case "a:redOff": c.r += v
            case "a:greenOff": c.g += v
            case "a:blueOff": c.b += v
            default: break
            }
            c = c.clamped()
        }
        return c
    }

    static let presetColors: [String: DColor] = {
        let table: [String: String] = [
            "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "008000", "blue": "0000FF", "yellow": "FFFF00",
            "gray": "808080", "grey": "808080", "silver": "C0C0C0", "maroon": "800000", "navy": "000080", "olive": "808000",
            "purple": "800080", "teal": "008080", "lime": "00FF00", "aqua": "00FFFF", "cyan": "00FFFF", "fuchsia": "FF00FF",
            "magenta": "FF00FF", "orange": "FFA500", "darkGray": "A9A9A9", "dkGray": "A9A9A9", "lightGray": "D3D3D3",
            "ltGray": "D3D3D3", "darkRed": "8B0000", "dkRed": "8B0000", "darkBlue": "00008B", "dkBlue": "00008B",
            "darkGreen": "006400", "dkGreen": "006400", "lightBlue": "ADD8E6", "ltBlue": "ADD8E6", "lightGreen": "90EE90",
            "ltGreen": "90EE90", "pink": "FFC0CB", "brown": "A52A2A", "gold": "FFD700", "beige": "F5F5DC", "violet": "EE82EE",
            "indigo": "4B0082", "coral": "FF7F50", "crimson": "DC143C", "tan": "D2B48C", "skyBlue": "87CEEB", "steelBlue": "4682B4",
            "royalBlue": "4169E1", "orangeRed": "FF4500", "darkOrange": "FF8C00", "dkOrange": "FF8C00", "lightYellow": "FFFFE0",
            "ltYellow": "FFFFE0", "darkSlateGray": "2F4F4F", "dkSlateGray": "2F4F4F", "dimGray": "696969", "whiteSmoke": "F5F5F5",
        ]
        return table.compactMapValues { DColor(hex: $0) }
    }()
}
