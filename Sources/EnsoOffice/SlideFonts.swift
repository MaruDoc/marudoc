import Foundation
import CoreText
import CoreGraphics

/// Picks the Mac font drawn for a font name in a slide. Windows-only Japanese families become the Hiragino or Yu
/// fonts closest in style; installed fonts are used as they are.
final class SlideFonts {
    struct Face {
        let font: CTFont
        /// No bold face exists: the renderer thickens the outline instead.
        let fakeBold: Bool
    }

    private var cache: [String: Face] = [:]
    private var familyCache: [String: String?] = [:]

    /// Known Windows names -> (regular, bold) PostScript names on this Mac.
    private static let table: [String: (String, String?)] = {
        var t: [String: (String, String?)] = [:]
        func map(_ reg: String, _ bold: String?, _ names: String...) { for n in names { t[key(n)] = (reg, bold) } }
        map("HiraMinProN-W3", "HiraMinProN-W6", "MS Mincho", "MS PMincho", "ＭＳ 明朝", "ＭＳ Ｐ明朝", "MS明朝", "MSP明朝", "HG明朝E", "HGP明朝E",
            "HG明朝B", "HGP明朝B", "HGS明朝E", "IPA明朝", "IPAex明朝", "IPAMincho", "IPAexMincho", "小塚明朝 Pr6N", "ヒラギノ明朝 ProN",
            "Hiragino Mincho ProN", "Kozuka Mincho Pr6N", "Noto Serif JP", "Noto Serif CJK JP", "源ノ明朝")
        map("HiraginoSans-W3", "HiraginoSans-W6", "MS Gothic", "MS PGothic", "ＭＳ ゴシック", "ＭＳ Ｐゴシック", "MSゴシック", "MSPゴシック",
            "MS UI Gothic", "メイリオ", "Meiryo", "Meiryo UI", "HGゴシックE", "HGPゴシックE", "HGSゴシックE", "HGゴシックM", "HGPゴシックM",
            "HG創英角ｺﾞｼｯｸUB", "HGP創英角ｺﾞｼｯｸUB", "HGS創英角ｺﾞｼｯｸUB", "IPAゴシック", "IPAexゴシック", "IPAGothic", "IPAexGothic",
            "Noto Sans JP", "Noto Sans CJK JP", "源ノ角ゴシック", "Source Han Sans", "ヒラギノ角ゴ ProN", "ヒラギノ角ゴシック", "Hiragino Sans",
            "Hiragino Kaku Gothic ProN", "小塚ゴシック Pr6N", "Kozuka Gothic Pr6N", "UD デジタル 教科書体 N-R", "UD Digi Kyokasho N-R")
        map("HiraMaruProN-W4", nil, "HG丸ｺﾞｼｯｸM-PRO", "HG丸ゴシックM-PRO", "ヒラギノ丸ゴ ProN")
        map("YuGo-Medium", "YuGo-Bold", "游ゴシック", "Yu Gothic", "游ゴシック Medium", "游ゴシック Light", "游ゴシック体", "Yu Gothic Medium",
            "Yu Gothic Light", "Yu Gothic UI", "Yu Gothic UI Semibold", "YuGothic", "游ゴシック Regular")
        map("YuMin-Medium", "YuMin-Demibold", "游明朝", "Yu Mincho", "游明朝 Demibold", "游明朝 Light", "游明朝体", "Yu Mincho Demibold",
            "Yu Mincho Light", "YuMincho")
        map("BIZUDGothic-Regular", "BIZUDGothic-Bold", "BIZ UDゴシック", "BIZ UDGothic")
        map("BIZUDMincho-Regular", nil, "BIZ UD明朝", "BIZ UDMincho", "BIZ UD明朝 Medium")
        // The Mac has only the fixed-width BIZ UD faces, which have no proportional forms; the proportional ("P")
        // families take Hiragino, whose proportional alternates come close to their widths.
        map("HiraginoSans-W3", "HiraginoSans-W6", "BIZ UDPゴシック", "BIZ UDPGothic")
        map("HiraMinProN-W3", "HiraMinProN-W6", "BIZ UDP明朝", "BIZ UDPMincho", "BIZ UDP明朝 Medium")
        map("AppleSDGothicNeo-Regular", "AppleSDGothicNeo-Bold", "굴림", "Gulim", "새굴림", "New Gulim", "돋움", "Dotum", "맑은 고딕",
            "Malgun Gothic", "HY헤드라인M", "HY견고딕", "나눔고딕", "NanumGothic")
        map("AppleMyungjo", nil, "바탕", "Batang", "함초롬바탕", "HCR Batang", "궁서", "Gungsuh", "HY신명조")
        map("PingFangSC-Regular", "PingFangSC-Semibold", "等线", "等线 Light", "DengXian", "微软雅黑", "Microsoft YaHei", "黑体", "SimHei")
        map("STSongti-SC-Regular", "STSongti-SC-Bold", "宋体", "SimSun", "新宋体", "NSimSun")
        map("PingFangTC-Regular", "PingFangTC-Semibold", "新細明體", "PMingLiU", "細明體", "MingLiU", "微軟正黑體", "Microsoft JhengHei")
        map("HelveticaNeue", "HelveticaNeue-Bold", "Calibri", "Calibri Light", "Segoe UI", "Segoe UI Light", "Segoe UI Semibold", "Aptos",
            "Aptos Display", "Arial Nova", "Corbel", "Candara", "Gill Sans MT", "Franklin Gothic Book", "Franklin Gothic Medium", "Century Gothic")
        map("Georgia", "Georgia-Bold", "Cambria", "Cambria Math", "Constantia")
        map("TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT", "Century", "Century Schoolbook", "Book Antiqua", "Garamond", "Palatino Linotype")
        map("Menlo-Regular", "Menlo-Bold", "Consolas", "Lucida Console")
        return t
    }()

    static func key(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" }
    }

    /// A font for `name` (already theme-resolved). `eastAsian`: the text is CJK, so a sans/serif guess uses Hiragino.
    func face(_ name: String, size: Double, bold: Bool, italic: Bool, eastAsian: Bool) -> Face {
        let size = min(max(size, 0.5), 4000)
        let ck = "\(name)|\(size)|\(bold)|\(italic)|\(eastAsian)"
        if let f = cache[ck] { return f }
        var font: CTFont?
        var fakeBold = false
        let k = SlideFonts.key(name)

        if let fam = installedFamily(name) {
            let base = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: fam] as CFDictionary), size, nil)
            font = base
            if bold {
                if let b = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) { font = b } else { fakeBold = true }
            }
        } else if let (reg, boldName) = SlideFonts.table[k] ?? SlideFonts.guess(k, eastAsian: eastAsian) {
            if bold, let boldName {
                font = CTFontCreateWithName(boldName as CFString, size, nil)
            } else {
                font = CTFontCreateWithName(reg as CFString, size, nil)
                fakeBold = bold
            }
        }
        var f = font ?? CTFontCreateWithName("HiraginoSans-W3" as CFString, size, nil)
        if italic {
            if let i = CTFontCreateCopyWithSymbolicTraits(f, size, nil, .traitItalic, .traitItalic) { f = i } else {
                // No italic face (CJK fonts): slant the upright one, as Office does.
                var m = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                f = CTFontCreateCopyWithAttributes(f, size, &m, nil)
            }
        }
        if SlideFonts.isProportional(name) {
            // Windows "P" fonts (MS PGothic, BIZ UDPGothic, Meiryo...) set kana and punctuation proportionally; the Mac
            // substitutes do the same with their proportional alternates, so lines break where PowerPoint breaks them.
            let features = [[kCTFontOpenTypeFeatureTag: "palt", kCTFontOpenTypeFeatureValue: 1]] as CFArray
            let d = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: features] as CFDictionary)
            f = CTFontCreateCopyWithAttributes(f, size, nil, d)
        }
        let face = Face(font: f, fakeBold: fakeBold)
        cache[ck] = face
        return face
    }

    /// True when the font a deck names is on this Mac, so text is drawn in the font it was laid out with. Yu Gothic,
    /// Yu Mincho, Hiragino and BIZ UD (non-P) under their Japanese or Windows names count: macOS has the same
    /// families. A substitute (MS PGothic → Hiragino, Calibri → Helvetica Neue) does not.
    func isInstalled(_ name: String) -> Bool {
        if let c = installedCache[name] { return c }
        let k = SlideFonts.key(name)
        let ok = installedFamily(name) != nil || SlideFonts.sameOnMac.contains { k.hasPrefix($0) }
        installedCache[name] = ok
        return ok
    }

    private var installedCache: [String: Bool] = [:]

    private static let sameOnMac: [String] = ["游ゴシック", "yugothic", "游明朝", "yumincho", "ヒラギノ", "hiragino", "bizudゴシック", "bizudgothic",
                                             "bizud明朝", "bizudmincho", "osaka"]

    /// The installed family a name refers to, if any (exact family name, or a PostScript / full name).
    private func installedFamily(_ name: String) -> String? {
        if let c = familyCache[name] { return c }
        var result: String?
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !trimmed.hasPrefix("+") {
            for attr in [kCTFontFamilyNameAttribute, kCTFontNameAttribute] {
                let d = CTFontDescriptorCreateWithAttributes([attr: trimmed] as CFDictionary)
                if let m = CTFontDescriptorCreateMatchingFontDescriptor(d, nil),
                   let fam = CTFontDescriptorCopyAttribute(m, kCTFontFamilyNameAttribute) as? String {
                    let ps = CTFontDescriptorCopyAttribute(m, kCTFontNameAttribute) as? String ?? ""
                    let disp = CTFontDescriptorCopyAttribute(m, kCTFontDisplayNameAttribute) as? String ?? ""
                    let want = SlideFonts.key(trimmed)
                    if [fam, ps, disp].contains(where: { SlideFonts.key($0) == want }) { result = fam; break }
                }
            }
        }
        familyCache[name] = result
        return result
    }

    /// Unknown names: Mincho / serif styles become Hiragino Mincho, everything else a sans face.
    private static func guess(_ k: String, eastAsian: Bool) -> (String, String?)? {
        if ["明朝", "mincho", "serif", "song", "宋", "batang", "myungjo", "times", "roman"].contains(where: { k.contains($0) }) {
            return eastAsian || k.contains("明朝") || k.contains("mincho") ? ("HiraMinProN-W3", "HiraMinProN-W6") : ("TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT")
        }
        if ["ゴシック", "ｺﾞｼｯｸ", "gothic", "sans", "hei", "黑", "gulim", "dotum", "丸"].contains(where: { k.contains($0) }) || eastAsian {
            return ("HiraginoSans-W3", "HiraginoSans-W6")
        }
        return ("HelveticaNeue", "HelveticaNeue-Bold")
    }

    /// Japanese fonts whose kana and punctuation are proportional on Windows.
    static func isProportional(_ name: String) -> Bool {
        let k = key(name)
        return k.hasPrefix("msp") || k.hasPrefix("hgp") || k.hasPrefix("bizudp") || k.hasPrefix("meiryo") || k.hasPrefix("メイリオ")
            || k.hasPrefix("msuigothic") || k.hasPrefix("yugothicui")
    }

    // MARK: Text layer

    /// Code points that Hiragino and Yu Gothic draw with a glyph shared by another code point. Core Graphics writes
    /// the PDF's ToUnicode map from the glyph, so copied text would show the other character (en dash -> figure
    /// dash, em dash -> U+0336, wave dash -> fullwidth tilde, circled 21-50 -> plain digits). Found by drawing every
    /// candidate and reading it back with PDFKit.
    static let sharedGlyphScalars: Set<UInt32> = {
        var s: Set<UInt32> = [0x2013, 0x2014, 0x2212, 0x301C, 0x22C4, 0x21F5, 0x25FB, 0x25FC, 0x26AA, 0x26AB, 0x26BD, 0x26BE,
                              0x26CB, 0x277F, 0x27BF, 0x2491, 0x2492, 0x3244]
        for v in 0x24EB...0x24F4 { s.insert(UInt32(v)) }
        for v in 0x3251...0x325F { s.insert(UInt32(v)) }
        for v in 0x32B1...0x32BF { s.insert(UInt32(v)) }
        return s
    }()

    static func sharesGlyphs(_ font: CTFont) -> Bool {
        let ps = CTFontCopyPostScriptName(font) as String
        return ps.hasPrefix("Hiragino") || ps.hasPrefix("HiraMin") || ps.hasPrefix("HiraMaru") || ps.hasPrefix("HiraKaku") || ps.hasPrefix("YuGo")
    }

    /// A face of similar style whose glyphs map back to the right characters: BIZ UD Gothic for Gothic text, Yu
    /// Mincho for Mincho text and for symbols BIZ UD lacks.
    func textLayerSafeFace(for base: Face, scalar: Unicode.Scalar, size: Double, bold: Bool) -> Face {
        let ps = CTFontCopyPostScriptName(base.font) as String
        var name = bold ? "BIZUDGothic-Bold" : "BIZUDGothic-Regular"
        if ps.hasPrefix("HiraMin") || !SlideFonts.has(name, scalar) { name = bold ? "YuMin-Demibold" : "YuMin-Medium" }
        let key = "safe|\(name)|\(size)"
        if let f = cache[key] { return f }
        let f = Face(font: CTFontCreateWithName(name as CFString, min(max(size, 0.5), 4000), nil), fakeBold: false)
        cache[key] = f
        return f
    }

    private static func has(_ ps: String, _ s: Unicode.Scalar) -> Bool {
        let f = CTFontCreateWithName(ps as CFString, 12, nil)
        var u = Array(String(s).utf16)
        var g = [CGGlyph](repeating: 0, count: u.count)
        return CTFontGetGlyphsForCharacters(f, &u, &g, u.count)
    }

    // MARK: Symbol fonts

    static func isSymbolFont(_ name: String) -> Bool {
        let k = key(name)
        return k.hasPrefix("wingdings") || k == "symbol" || k == "webdings" || k.hasPrefix("monotypesorts") || k == "zapfdingbats"
    }

    /// Bullets in Wingdings / Symbol are stored as the font's own codes. They are drawn as the Unicode character they
    /// show, so the text layer reads correctly.
    static func unicodeBullet(_ ch: String, font: String) -> String {
        guard let s = ch.unicodeScalars.first else { return "•" }
        var v = s.value
        if v >= 0xF000 && v <= 0xF0FF { v -= 0xF000 }
        let k = key(font)
        if k == "symbol" {
            let m: [UInt32: String] = [0xB7: "•", 0xA8: "♦", 0xA7: "♣", 0xA9: "♥", 0xAA: "♠", 0xAE: "→", 0xDE: "⇒", 0x2D: "−", 0xD7: "⋅", 0x6F: "ο"]
            return m[v] ?? (v < 0x80 ? String(UnicodeScalar(UInt8(v))) : "•")
        }
        if k.hasPrefix("wingdings") && k != "wingdings" {
            // Wingdings 2 / 3: arrows and squares.
            let m: [UInt32: String] = [0x97: "■", 0x98: "□", 0xA2: "◆", 0xA3: "◇", 0x50: "✔", 0x4F: "✘", 0x7D: "➤", 0xF0: "▶", 0x75: "▶", 0x5D: "▸", 0x71: "▸"]
            return m[v] ?? "▪"
        }
        let m: [UInt32: String] = [
            0x6C: "●", 0x6D: "❍", 0x6E: "■", 0x6F: "□", 0x70: "◻", 0x71: "❑", 0x72: "❒", 0x73: "⬧", 0x74: "⧫", 0x75: "◆",
            0x76: "❖", 0x77: "⬥", 0xA7: "▪", 0xA8: "◻", 0x9F: "•", 0xA1: "○", 0xA2: "⭕", 0xD8: "➢", 0xD7: "⮚", 0xFC: "✔",
            0xFB: "✘", 0xFE: "☑", 0xFD: "☒", 0xE0: "➔", 0xE8: "➔", 0xF0: "⇨", 0xEF: "⇦", 0xF1: "⇧", 0xF2: "⇩", 0xDF: "⇐",
            0xE2: "⇑", 0x46: "☞", 0x4A: "☺", 0x4C: "☹", 0x8C: "①", 0x8D: "②", 0x8E: "③", 0x81: "①", 0x82: "②", 0x83: "③",
            0x84: "④", 0x85: "⑤", 0x86: "⑥", 0x87: "⑦", 0x88: "⑧", 0x89: "⑨", 0x8A: "⑩", 0x3E: "✇", 0x2A: "✉", 0xAB: "★",
            0xB2: "✧", 0xB5: "⌖", 0x52: "✿", 0xA4: "◉", 0xA5: "◎",
        ]
        return m[v] ?? "•"
    }
}
