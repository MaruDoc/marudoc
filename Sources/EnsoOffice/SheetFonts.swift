import Foundation
import CoreText
import CoreGraphics
import AppKit
import EnsoDoc

/// Fonts for printing sheets: Windows / Office font names mapped to Mac fonts, Excel's column-width unit and row
/// heights, and a fast glyph path for plain cell text (most cells), so a 50,000-row CSV draws in seconds.
public enum SheetFonts {

    private static func key(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }

    /// Mac stand-ins for Windows fonts, with a size factor. Calibri at 11 pt has about the cap height and digit width
    /// of Helvetica Neue at 10 pt, so it is drawn at 90 % size: Excel's line breaks and column fits then hold. (A
    /// condensing font matrix would do the same but makes CoreGraphics write PDFs 3 times larger, 12 times slower.)
    static func macFamily(_ name: String?) -> (family: String, condense: CGFloat, cjk: Bool) {
        let k = key(name ?? "calibri")
        if k.contains("游ゴシック") || k.hasPrefix("yugothic") || k == "yugo" { return ("YuGothic", 1, true) }
        if k.contains("游明朝") || k.hasPrefix("yumincho") { return ("YuMincho", 1, true) }
        if k.contains("明朝") || k.contains("mincho") { return ("Hiragino Mincho ProN", 1, true) }
        if k.contains("ゴシック") || k.contains("gothic") || k.contains("ｺﾞｼｯｸ") || k.contains("メイリオ") || k.hasPrefix("meiryo")
            || k.hasPrefix("hiragino") || k.contains("ヒラギノ") || k.contains("notosanscjk") || k.contains("notosansjp") { return ("Hiragino Sans", 1, true) }
        switch k {
        case "calibri", "calibrilight", "carlito", "aptosnarrow": return ("Helvetica Neue", 0.9, false)
        case "aptos", "aptosdisplay", "segoeui", "tahoma", "arialnova", "verdana", "trebuchetms", "linuxbiolinumg", "dejavusans",
             "liberationsans", "notosans", "roboto", "opensans": return ("Helvetica Neue", 1, false)
        case "cambria", "cambriamath", "constantia", "linuxlibertineg", "liberationserif", "dejavuserif": return ("Times New Roman", 1, false)
        case "century", "centuryschoolbook", "bookantiqua", "garamond": return ("Times New Roman", 1, false)
        case "consolas", "lucidaconsole", "liberationmono", "dejavusansmono": return ("Menlo", 1, false)
        default: break
        }
        if let name, installed(name) { return (name, 1, false) }
        return ("Helvetica Neue", 1, false)
    }

    static func installed(_ name: String) -> Bool {
        if NSFont(name: name, size: 11) != nil { return true }
        return NSFontManager.shared.availableMembers(ofFontFamily: name)?.isEmpty == false
    }

    /// Excel's maximum digit width of a font in pixels at 96 dpi, the unit of column widths. Known Office fonts use
    /// the value Windows Excel measures; others are measured on the Mac font drawn in their place.
    public static func maxDigitWidth(_ f: SheetFont) -> Double {
        let k = key(f.name ?? "calibri")
        let at11: Double?
        if k.hasPrefix("calibri") || k == "carlito" || k.hasPrefix("aptosnarrow") { at11 = 7 }
        else if k.hasPrefix("aptos") || k.hasPrefix("arial") || k.hasPrefix("segoe") { at11 = 8 }
        else if k.contains("游ゴシック") || k.hasPrefix("yugothic") || k.contains("ｍｓｐ") || k.contains("ｍｓ") || k.hasPrefix("ms")
                    || k.contains("游明朝") || k.hasPrefix("yumincho") { at11 = 8 }
        else if k.contains("メイリオ") || k.hasPrefix("meiryo") { at11 = 9 }
        else { at11 = nil }
        if let at11 { return max(1, (at11 * f.size / 11).rounded()) }
        let font = primaryFont(f)
        var best: CGFloat = 0
        for d in "0123456789".utf16 {
            var c = d, g: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(font, &c, &g, 1) {
                var adv = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &adv, 1)
                best = max(best, adv.width)
            }
        }
        return max(1, (Double(best) * 96 / 72).rounded())
    }

    /// The height Excel gives a row holding one line of this font, in points (whole pixels at 96 dpi).
    public static func lineHeight(_ f: SheetFont) -> Double {
        let k = key(f.name ?? "calibri")
        let ratio: Double
        if k.hasPrefix("calibri") || k.hasPrefix("aptos") || k == "carlito" { ratio = 15.0 / 11 }
        else if k.contains("游") || k.hasPrefix("yu") || k.contains("メイリオ") || k.hasPrefix("meiryo") { ratio = 18.75 / 11 }
        else if k.contains("ｍｓ") || k.hasPrefix("ms") { ratio = 13.5 / 11 }
        else if k.hasPrefix("arial") || k.hasPrefix("helvetica") { ratio = 12.75 / 10 }
        else {
            let font = primaryFont(f)
            ratio = max(1.25, Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) / f.size)
        }
        return ((f.size * ratio) / 0.75).rounded(.up) * 0.75
    }

    // MARK: Font objects

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fontCache: [String: CTFont] = [:]

    private static func named(_ ps: String, _ size: CGFloat) -> CTFont? {
        let f = CTFontCreateWithName(ps as CFString, size, nil)
        return (CTFontCopyPostScriptName(f) as String) == ps ? f : nil
    }

    /// The Mac font a sheet font is drawn with (no fallback attached).
    static func primaryFont(_ f: SheetFont, size: CGFloat? = nil) -> CTFont {
        let s = CGFloat(size ?? f.size)
        let cacheKey = "\(f.name ?? "")|\(s)|\(f.bold)|\(f.italic)"
        lock.lock()
        if let hit = fontCache[cacheKey] { lock.unlock(); return hit }
        lock.unlock()
        let (family, condense, cjk) = macFamily(f.name)
        var font: CTFont?
        if cjk {
            let names: [String: (String, String)] = [
                "YuGothic": ("YuGo-Medium", "YuGo-Bold"), "YuMincho": ("YuMin-Medium", "YuMin-Demibold"),
                "Hiragino Sans": ("HiraginoSans-W3", "HiraginoSans-W6"), "Hiragino Mincho ProN": ("HiraMinProN-W3", "HiraMinProN-W6"),
            ]
            if let pair = names[family] { font = named(f.bold ? pair.1 : pair.0, s) ?? named(f.bold ? "HiraginoSans-W6" : "HiraginoSans-W3", s) }
        }
        if font == nil {
            var traits: NSFontTraitMask = []
            if f.bold { traits.insert(.boldFontMask) }
            if f.italic { traits.insert(.italicFontMask) }
            font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: s)
                ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: s)
                ?? NSFontManager.shared.font(withFamily: "Helvetica Neue", traits: traits, weight: 5, size: s)
        }
        var result: CTFont = font ?? CTFontCreateWithName("Helvetica" as CFString, s, nil)
        let traits = CTFontGetSymbolicTraits(result)
        if f.bold && !traits.contains(.traitBold) && cjk == false, let b = CTFontCreateCopyWithSymbolicTraits(result, s, nil, .traitBold, .traitBold) { result = b }
        if condense != 1 { result = CTFontCreateCopyWithAttributes(result, s * condense, nil, nil) }
        if f.italic && !traits.contains(.traitItalic) {
            // No italic face (Japanese fonts): slanted, as Excel does.
            var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            result = CTFontCreateWithFontDescriptor(CTFontCopyFontDescriptor(result), CTFontGetSize(result), &matrix)
        }
        lock.lock(); fontCache[cacheKey] = result; lock.unlock()
        return result
    }

    /// Japanese text in a Latin font is drawn in Hiragino Sans, as macOS does.
    static func cjkFallback(bold: Bool, size: CGFloat) -> CTFont {
        let key = "#cjk|\(size)|\(bold)"
        lock.lock()
        if let hit = fontCache[key] { lock.unlock(); return hit }
        lock.unlock()
        let f = named(bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size) ?? CTFontCreateUIFontForLanguage(.system, size, "ja" as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        lock.lock(); fontCache[key] = f; lock.unlock()
        return f
    }

    /// Hiragino and Yu fonts share one glyph between "—" and U+0336, "–" and U+2012, "−" and "－", "〜" and "～";
    /// a PDF made with them gives back the wrong character on copy and search. These few characters are drawn
    /// from fonts whose glyphs map back one to one: PingFang (part of macOS, Japanese-style "—" and "〜") and
    /// Arial Unicode MS ("–" and "−").
    static func needsDashFont(_ u: UInt16) -> Bool { u == 0x2013 || u == 0x2014 || u == 0x2212 || u == 0x301C }

    /// Index into SheetFace.fonts of the font drawing a dash character: 2 Arial Unicode MS, 3 PingFang.
    static func dashFontIndex(_ u: UInt16) -> Int { u == 0x2014 || u == 0x301C ? 3 : 2 }

    static func dashFonts(size: CGFloat, bold: Bool) -> (CTFont, CTFont) {
        let key = "#dash|\(size)|\(bold)"
        lock.lock()
        if let a = fontCache[key + "a"], let b = fontCache[key + "b"] { lock.unlock(); return (a, b) }
        lock.unlock()
        let a = named("ArialUnicodeMS", size) ?? named("HelveticaNeue", size) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let b = named(bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size) ?? a
        lock.lock(); fontCache[key + "a"] = a; fontCache[key + "b"] = b; lock.unlock()
        return (a, b)
    }

    static func isSharedGlyphFont(_ font: CTFont) -> Bool {
        let ps = CTFontCopyPostScriptName(font) as String
        return ps.hasPrefix("Hira") || ps.hasPrefix("YuGo") || ps.hasPrefix("YuMin")
    }

    /// An attributed string for CoreText with ligatures off (so "office" copies as "office", not "oﬃce"), each
    /// character in the same font the fast path gives it (Japanese in Hiragino at the cell's size, the dash
    /// characters in a font that maps them back correctly), anything else left to CoreText's own fallback.
    static func attributed(_ runs: [(String, SheetFont, CGColor)], sizeScale: CGFloat = 1) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        for (text, f, color) in runs where !text.isEmpty {
            var spec = f
            spec.size = f.size * Double(sizeScale) * (f.baseline == .normal ? 1 : 0.7)
            let face = SheetFace.face(spec)
            let size = CGFloat(spec.size)
            let cascade = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: [CTFontCopyFontDescriptor(face.fonts[1])]] as CFDictionary)
            let primary = CTFontCreateCopyWithAttributes(face.fonts[0], CTFontGetSize(face.fonts[0]), nil, cascade)
            var attrs: [NSAttributedString.Key: Any] = [
                fontKey: primary,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
            ]
            if f.baseline != .normal {
                attrs[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = f.baseline == .superscript ? size * 0.5 : -size * 0.2
            }
            let start = out.length
            out.append(NSAttributedString(string: text, attributes: attrs))
            let ns = text as NSString
            var i = 0
            while i < ns.length {
                let k = face.fontIndex(ns.character(at: i))
                var j = i + 1
                while j < ns.length, face.fontIndex(ns.character(at: j)) == k { j += 1 }
                if let k, k > 0 { out.addAttribute(fontKey, value: face.fonts[k], range: NSRange(location: start + i, length: j - i)) }
                i = j
            }
        }
        return out
    }

    /// Width of one line of text (no wrapping).
    public static func measure(_ text: String, _ f: SheetFont) -> Double {
        let face = SheetFace.face(f)
        if let w = face.simpleWidth(text) { return w }
        let line = CTLineCreateWithAttributedString(attributed([(text, f, CGColor(gray: 0, alpha: 1))]))
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// A sheet font ready for the fast path: glyphs and advances of every UTF-16 unit it has met, from the primary
/// font, the Japanese fallback or the dash font. Text with anything else (emoji, combining marks, scripts that need
/// shaping, characters neither font has) goes through CoreText lines instead.
final class SheetFace: @unchecked Sendable {
    let fonts: [CTFont]          // 0 primary, 1 Japanese fallback, 2 and 3 dash fonts
    let ascent: CGFloat, descent: CGFloat
    let spec: SheetFont
    private var glyph = [CGGlyph](repeating: 0, count: 65536)
    private var which = [UInt8](repeating: 255, count: 65536)   // 255 = not looked up yet, 254 = not drawable here
    private var advance = [CGFloat](repeating: 0, count: 65536)
    private let lock = NSLock()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var faces: [String: SheetFace] = [:]

    static func face(_ f: SheetFont, size: Double? = nil) -> SheetFace {
        let s = size ?? f.size
        let key = "\(f.name ?? "")|\(s)|\(f.bold)|\(f.italic)"
        lock.lock(); defer { lock.unlock() }
        if let hit = faces[key] { return hit }
        var spec = f
        spec.size = s
        let face = SheetFace(spec)
        faces[key] = face
        return face
    }

    private init(_ f: SheetFont) {
        spec = f
        let size = CGFloat(f.size)
        let primary = SheetFonts.primaryFont(f, size: f.size)
        // Japanese text keeps the cell's full size even when the Latin stand-in is drawn smaller (Calibri).
        let dash = SheetFonts.dashFonts(size: size, bold: f.bold)
        fonts = [primary, SheetFonts.cjkFallback(bold: f.bold, size: size), dash.0, dash.1]
        ascent = CTFontGetAscent(primary)
        descent = CTFontGetDescent(primary)
    }

    /// Characters the fast path may draw glyph by glyph (no shaping, no combining).
    @inline(__always) static func isSimple(_ u: UInt16) -> Bool {
        switch u {
        case 0x0020...0x02FF, 0x0370...0x058F, 0x1E00...0x1FFF, 0x2010...0x2027, 0x2030...0x205E, 0x2070...0x2BFF,
             0x2E80...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF01...0xFFEF:
            return true
        default:
            return false
        }
    }

    @inline(__always) private func lookup(_ u: UInt16) -> UInt8 {
        let i = Int(u)
        let w = which[i]
        if w != 255 { return w }
        var result: UInt8 = 254
        guard SheetFace.isSimple(u) else { which[i] = 254; return 254 }
        var c = u, g: CGGlyph = 0
        let primaryShares = SheetFonts.isSharedGlyphFont(fonts[0])
        if SheetFonts.needsDashFont(u) {
            let k = SheetFonts.dashFontIndex(u)
            if !primaryShares, CTFontGetGlyphsForCharacters(fonts[0], &c, &g, 1) { result = 0 }
            else if CTFontGetGlyphsForCharacters(fonts[k], &c, &g, 1) { result = UInt8(k) }
            else if CTFontGetGlyphsForCharacters(fonts[5 - k], &c, &g, 1) { result = UInt8(5 - k) }
        } else if CTFontGetGlyphsForCharacters(fonts[0], &c, &g, 1) {
            result = 0
        } else if CTFontGetGlyphsForCharacters(fonts[1], &c, &g, 1) {
            result = 1
        }
        if result < 254 {
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(fonts[Int(result)], .horizontal, &g, &adv, 1)
            glyph[i] = g
            advance[i] = adv.width
        }
        which[i] = result
        return result
    }

    /// Which of `fonts` draws this UTF-16 unit; nil when none of them does (CoreText falls back on its own).
    func fontIndex(_ u: UInt16) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let k = lookup(u)
        return k < 254 ? Int(k) : nil
    }

    /// Width of single-line text, or nil when it needs CoreText.
    func simpleWidth(_ s: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        var w: CGFloat = 0
        for u in s.utf16 {
            let k = lookup(u)
            if k >= 254 { return nil }
            w += advance[Int(u)]
        }
        return Double(w)
    }

    /// Appends the glyphs of `s` starting at `x` on baseline `y` to the batch (one list per font), or returns false
    /// when the text needs CoreText. Positions are in the batch's coordinate space.
    func append(_ s: String, x: CGFloat, y: CGFloat, scale: CGFloat = 1, to batch: inout GlyphBatch, color: CGColor) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var units: [UInt16] = []
        units.reserveCapacity(s.utf16.count)
        for u in s.utf16 {
            if lookup(u) >= 254 { return false }
            units.append(u)
        }
        var cx = x
        for u in units {
            let i = Int(u)
            // Spaces are drawn too (invisible), so copied text keeps them.
            batch.add(font: fonts[Int(which[i])], color: color, glyph: glyph[i], at: CGPoint(x: cx, y: y))
            cx += advance[i] * scale
        }
        // A space after the value keeps neighbouring cells apart in copied text.
        if lookup(0x20) < 254 { batch.add(font: fonts[Int(which[0x20])], color: color, glyph: glyph[0x20], at: CGPoint(x: cx, y: y)) }
        return true
    }
}

/// Glyphs collected for a row of cells, drawn in the order they were added (so copied text keeps each cell's
/// characters together); consecutive glyphs in the same font and colour share one drawing call.
struct GlyphBatch {
    private var fonts: [CTFont] = []
    private var colors: [CGColor] = []
    private var ends: [Int] = []
    private var glyphs: [CGGlyph] = []
    private var positions: [CGPoint] = []

    mutating func add(font: CTFont, color: CGColor, glyph: CGGlyph, at p: CGPoint) {
        if let f = fonts.last, f == font, let c = colors.last, c == color {
            ends[ends.count - 1] += 1
        } else {
            fonts.append(font); colors.append(color); ends.append(glyphs.count + 1)
        }
        glyphs.append(glyph)
        positions.append(p)
    }

    var isEmpty: Bool { glyphs.isEmpty }

    mutating func flush(_ ctx: CGContext) {
        var start = 0
        glyphs.withUnsafeBufferPointer { g in
            positions.withUnsafeBufferPointer { p in
                for (i, end) in ends.enumerated() where end > start {
                    ctx.setFillColor(colors[i])
                    CTFontDrawGlyphs(fonts[i], g.baseAddress! + start, p.baseAddress! + start, end - start, ctx)
                    start = end
                }
            }
        }
        fonts.removeAll(keepingCapacity: true); colors.removeAll(keepingCapacity: true); ends.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true); positions.removeAll(keepingCapacity: true)
    }
}
