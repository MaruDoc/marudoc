import AppKit

/// Maps the font names Word documents use (often Windows-only) to fonts installed on a Mac, for on-screen editing.
/// The document keeps its original font names; this only decides what is drawn.
enum DocxDisplayFonts {

    private static let table: [String: String] = {
        var t: [String: String] = [:]
        func map(_ mac: String, _ names: String...) { for n in names { t[key(n)] = mac } }
        map("YuMincho", "游明朝", "Yu Mincho", "游明朝 Demibold", "游明朝 Light", "Yu Mincho Demibold", "Yu Mincho Light", "YuMincho")
        map("YuGothic", "游ゴシック", "Yu Gothic", "游ゴシック Medium", "游ゴシック Light", "Yu Gothic Medium", "Yu Gothic Light", "Yu Gothic UI", "YuGothic")
        map("Hiragino Mincho ProN", "ＭＳ 明朝", "MS Mincho", "ＭＳ Ｐ明朝", "MS PMincho", "HG明朝E", "HGP明朝E", "BIZ UD明朝", "BIZ UDP明朝", "IPA明朝", "IPAex明朝", "小塚明朝 Pr6N", "ヒラギノ明朝 ProN")
        map("Hiragino Sans", "ＭＳ ゴシック", "MS Gothic", "ＭＳ Ｐゴシック", "MS PGothic", "MS UI Gothic", "メイリオ", "Meiryo", "Meiryo UI",
            "BIZ UDゴシック", "BIZ UDPゴシック", "HGゴシックE", "HGPゴシックE", "HG丸ｺﾞｼｯｸM-PRO", "IPAゴシック", "IPAexゴシック", "Noto Sans JP", "Noto Sans CJK JP", "源ノ角ゴシック", "ヒラギノ角ゴ ProN", "ヒラギノ角ゴシック")
        map("Helvetica Neue", "Calibri", "Calibri Light", "Segoe UI", "Aptos", "Aptos Display", "Arial Nova", "Tahoma")
        map("Georgia", "Cambria", "Cambria Math", "Constantia")
        map("Times New Roman", "Century", "Century Schoolbook", "Book Antiqua", "Garamond")
        map("Menlo", "Consolas", "Courier New", "Lucida Console")
        return t
    }()

    private static func key(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }

    private static var cache: [String: NSFont] = [:]
    private static let lock = NSLock()

    /// A Mac font for `name` (nil = document default) at `size`.
    static func font(_ name: String?, size: CGFloat, bold: Bool, italic: Bool, eastAsian: Bool) -> NSFont {
        let cacheKey = "\(name ?? "-")|\(size)|\(bold)|\(italic)|\(eastAsian)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[cacheKey] { return f }
        var base: NSFont?
        if let name, !name.isEmpty {
            base = family(name, size: size)
            if base == nil, let mapped = table[key(name)] { base = family(mapped, size: size) }
            if base == nil {
                // Classify unknown names.
                let k = key(name)
                if k.contains("明朝") || k.contains("mincho") || k.contains("serif") { base = family("Hiragino Mincho ProN", size: size) }
                else if k.contains("ゴシック") || k.contains("gothic") || k.contains("sans") || k.contains("ｺﾞｼｯｸ") { base = family("Hiragino Sans", size: size) }
            }
        }
        if base == nil { base = family(eastAsian ? "YuMincho" : "Times New Roman", size: size) }
        var f = base ?? NSFont.systemFont(ofSize: size)
        if bold { f = emboldened(f) }
        if italic {
            let i = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
            if i.fontDescriptor.symbolicTraits.contains(.italic) { f = i }
            else { f = NSFont(descriptor: f.fontDescriptor.withMatrix(AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)), size: size) ?? f }
        }
        cache[cacheKey] = f
        return f
    }

    private static func family(_ name: String, size: CGFloat) -> NSFont? {
        if let f = NSFont(name: name, size: size) { return f }
        guard NSFontManager.shared.availableMembers(ofFontFamily: name)?.isEmpty == false else { return nil }
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: name]), size: size)
    }

    private static func emboldened(_ f: NSFont) -> NSFont {
        let b = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        if b.fontDescriptor.symbolicTraits.contains(.bold) || b.fontName != f.fontName { return b }
        if f.fontName.hasPrefix("HiraginoSans"), let w6 = NSFont(name: "HiraginoSans-W6", size: f.pointSize) { return w6 }
        if f.fontName.hasPrefix("HiraMinProN"), let w6 = NSFont(name: "HiraMinProN-W6", size: f.pointSize) { return w6 }
        if f.fontName.hasPrefix("YuMin"), let d = NSFont(name: "YuMin-Demibold", size: f.pointSize) { return d }
        if f.fontName.hasPrefix("YuGo"), let d = NSFont(name: "YuGo-Bold", size: f.pointSize) { return d }
        return f
    }

    /// The height Word gives one single-spaced line of `font`. Word measures the Windows font it asked for, which
    /// is often not the Mac font drawn in its place, so known Windows families use their own ratio.
    static func wordLineHeight(requested: String?, font: NSFont, eastAsian: Bool) -> CGFloat {
        let size = font.pointSize
        let k = key(requested ?? "")
        if k.contains("游") || k.hasPrefix("yu") { return size * 1.7 }
        if k.hasPrefix("ｍｓ") || k.hasPrefix("ms") { return size * 1.0 }
        if k.contains("メイリオ") || k.hasPrefix("meiryo") { return size * 1.5 }
        if k.hasPrefix("calibri") { return size * 1.22 }
        if k.hasPrefix("century") || k.hasPrefix("timesnewroman") || k.hasPrefix("arial") { return size * 1.15 }
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Characters Word lays out with the East Asian font.
    static func isEastAsian(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x11FF, 0x2E80...0x2FFF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x31FF, 0x3200...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFFEF, 0x20000...0x2FFFF:
            return true
        default:
            return false
        }
    }

    /// With w:hint="eastAsia", Word also uses the East Asian font for shared punctuation and symbols.
    static func isAmbiguous(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2010...0x206F, 0x2190...0x21FF, 0x2200...0x22FF, 0x2460...0x24FF, 0x2500...0x27BF, 0x00A7, 0x00B0, 0x00B1, 0x00B4, 0x00B6, 0x00D7, 0x00F7:
            return true
        default:
            return false
        }
    }
}
