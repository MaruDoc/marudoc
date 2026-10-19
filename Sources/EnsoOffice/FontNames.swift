import Foundation
import CoreText

/// Turns font names found in PDFs (PostScript names, often with a subset prefix) into
/// family names that Word, Pages and LibreOffice resolve, preferring the names Windows uses.
public enum FontNameMapper {
    public struct Family: Hashable, Sendable {
        public let name: String
        /// CJK font: also usable for the eastAsia slot.
        public let isEastAsian: Bool
    }

    /// Returns nil for names that should fall back to the document default (empty, system UI fonts).
    /// Japanese families that exist on only one platform are swapped for Yu Gothic / Yu Mincho, which ship with
    /// both macOS and Windows; otherwise a document converted from a Windows PDF shows in a fallback serif on a Mac.
    public static func portable(_ fam: Family) -> Family {
        guard fam.isEastAsian else { return fam }
        let n = fam.name.lowercased().replacingOccurrences(of: " ", with: "")
        if n.hasPrefix("yu") || n.contains("游") { return fam }
        let mincho = ["mincho", "明朝", "serif", "song", "ming"].contains { n.contains($0) }
        let gothic = ["gothic", "ゴシック", "meiryo", "メイリオ", "sans", "kakugo", "角ゴ", "osaka", "udgothic", "maru"].contains { n.contains($0) }
        if mincho { return Family(name: "Yu Mincho", isEastAsian: true) }
        if gothic { return Family(name: "Yu Gothic", isEastAsian: true) }
        return fam
    }

    public static func family(for rawName: String) -> Family? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Subset prefix "ABCDEF+".
        if name.count > 7, name.dropFirst(6).first == "+", name.prefix(6).allSatisfy({ $0.isASCII && $0.isUppercase }) {
            name = String(name.dropFirst(7))
        }
        name = name.precomposedStringWithCompatibilityMapping // full-width ASCII -> ASCII
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }

        // Exact table hit, then progressively shorter prefixes ("MS-PGothic-Bold" -> "MS-PGothic" -> "MS").
        var candidate = name
        while true {
            if let hit = table[compact(candidate)] { return hit }
            guard let cut = candidate.lastIndex(where: { $0 == "-" || $0 == "," }) else { break }
            candidate = String(candidate[..<cut])
        }

        if let fromSystem = systemFamily(postScriptName: name) { return fromSystem }

        // Heuristic: drop style suffix and MT/PS markers, then split CamelCase.
        var base = name
        if let cut = base.firstIndex(where: { $0 == "-" || $0 == "," }) { base = String(base[..<cut]) }
        for suffix in ["PSMT", "MT", "PS"] where base.hasSuffix(suffix) && base.count > suffix.count + 2 {
            base.removeLast(suffix.count)
            break
        }
        if let hit = table[compact(base)] { return hit }
        let family = base.contains(" ") ? base : splitCamelCase(base)
        return Family(name: family, isEastAsian: looksEastAsian(family))
    }

    private static func compact(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" }
    }

    private static func splitCamelCase(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) { out.append(" ") }
            }
            out.append(c)
        }
        return out
    }

    private static func looksEastAsian(_ s: String) -> Bool {
        if s.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { return true }
        let l = s.lowercased()
        return ["mincho", "kaku", "maru", "hira", "meiryo", "cjk", " jp", "kyokasho", "song", "hei", "ming", "batang",
                "gulim", "dotum", "osaka", "kozuka", "ryumin", "shin go", "a-otf", "morisawa", "yu go", "yu min"]
            .contains { l.contains($0) }
    }

    /// Looks the PostScript name up among installed fonts (CoreText never falls back silently here:
    /// the match must have the same PostScript name).
    private static func systemFamily(postScriptName: String) -> Family? {
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: postScriptName] as CFDictionary)
        guard let match = CTFontDescriptorCreateMatchingFontDescriptor(desc, nil),
              let ps = CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute) as? String,
              ps.caseInsensitiveCompare(postScriptName) == .orderedSame,
              let family = CTFontDescriptorCopyAttribute(match, kCTFontFamilyNameAttribute) as? String else { return nil }
        if let hit = table[compact(family)] { return hit }
        let font = CTFontCreateWithFontDescriptor(match, 12, nil)
        var glyphs = [CGGlyph](repeating: 0, count: 2)
        let chars: [UniChar] = [0x3042, 0x6F22] // あ 漢
        let cjk = CTFontGetGlyphsForCharacters(font, chars, &glyphs, 2)
        return Family(name: family, isEastAsian: cjk || looksEastAsian(family))
    }

    private static let table: [String: Family] = {
        var t: [String: Family] = [:]
        func ea(_ family: String, _ keys: String...) { for k in keys { t[compact(k)] = Family(name: family, isEastAsian: true) } }
        func la(_ family: String, _ keys: String...) { for k in keys { t[compact(k)] = Family(name: family, isEastAsian: false) } }

        ea("Hiragino Sans", "HiraginoSans", "ヒラギノ角ゴシック")
        ea("Hiragino Kaku Gothic ProN", "HiraKakuProN", "HiraginoKakuGothicProN", "ヒラギノ角ゴ ProN")
        ea("Hiragino Kaku Gothic Pro", "HiraKakuPro", "HiraginoKakuGothicPro", "ヒラギノ角ゴ Pro")
        ea("Hiragino Kaku Gothic StdN", "HiraKakuStdN")
        ea("Hiragino Kaku Gothic Std", "HiraKakuStd")
        ea("Hiragino Mincho ProN", "HiraMinProN", "HiraginoMinchoProN", "ヒラギノ明朝 ProN")
        ea("Hiragino Mincho Pro", "HiraMinPro", "HiraginoMinchoPro", "ヒラギノ明朝 Pro")
        ea("Hiragino Maru Gothic ProN", "HiraMaruProN", "HiraginoMaruGothicProN", "ヒラギノ丸ゴ ProN")
        ea("Hiragino Maru Gothic Pro", "HiraMaruPro")
        ea("Hiragino Sans GB", "HiraginoSansGB")
        ea("Hiragino Sans CNS", "HiraginoSansCNS")
        ea("Hiragino Mincho StdN", "HiraMinStdN")
        ea("MS Mincho", "MS-Mincho", "MSMincho", "MS明朝", "ＭＳ 明朝")
        ea("MS PMincho", "MS-PMincho", "MSPMincho", "MSP明朝", "ＭＳ Ｐ明朝")
        ea("MS Gothic", "MS-Gothic", "MSGothic", "MSゴシック", "ＭＳ ゴシック")
        ea("MS PGothic", "MS-PGothic", "MSPGothic", "MSPゴシック", "ＭＳ Ｐゴシック")
        ea("MS UI Gothic", "MS-UIGothic", "MSUIGothic")
        ea("Yu Gothic", "YuGothic", "YuGo", "YuGothic-Medium", "游ゴシック", "游ゴシック体", "YuGothM", "YuGothR", "YuGothB", "YuGothL")
        ea("Yu Gothic UI", "YuGothicUI")
        ea("Yu Mincho", "YuMincho", "YuMin", "游明朝", "游明朝体")
        ea("Meiryo", "Meiryo", "メイリオ")
        ea("Meiryo UI", "MeiryoUI")
        ea("BIZ UDGothic", "BIZ-UDGothic", "BIZUDGothic")
        ea("BIZ UDPGothic", "BIZ-UDPGothic", "BIZUDPGothic")
        ea("BIZ UDMincho", "BIZ-UDMincho", "BIZUDMincho")
        ea("BIZ UDPMincho", "BIZ-UDPMincho", "BIZUDPMincho")
        ea("UD Digi Kyokasho N-R", "UDDigiKyokashoN-R", "UDDigiKyokashoNR")
        ea("Kozuka Mincho Pr6N", "KozMinPr6N")
        ea("Kozuka Mincho Pro", "KozMinPro")
        ea("Kozuka Gothic Pr6N", "KozGoPr6N")
        ea("Kozuka Gothic Pro", "KozGoPro")
        ea("Noto Sans CJK JP", "NotoSansCJKjp", "NotoSansCJKJP")
        ea("Noto Serif CJK JP", "NotoSerifCJKjp", "NotoSerifCJKJP")
        ea("Noto Sans JP", "NotoSansJP")
        ea("Noto Serif JP", "NotoSerifJP")
        ea("Source Han Sans", "SourceHanSans")
        ea("Source Han Sans JP", "SourceHanSansJP", "SourceHanSansJp")
        ea("Source Han Serif", "SourceHanSerif")
        ea("IPAMincho", "IPAMincho"); ea("IPAGothic", "IPAGothic")
        ea("IPAexMincho", "IPAexMincho"); ea("IPAexGothic", "IPAexGothic")
        ea("IPAPMincho", "IPAPMincho"); ea("IPAPGothic", "IPAPGothic")
        ea("Osaka", "Osaka")
        ea("PingFang SC", "PingFangSC"); ea("PingFang TC", "PingFangTC")
        ea("SimSun", "SimSun", "宋体"); ea("SimHei", "SimHei", "黑体")
        ea("Microsoft YaHei", "MicrosoftYaHei"); ea("Microsoft JhengHei", "MicrosoftJhengHei")
        ea("MingLiU", "MingLiU"); ea("PMingLiU", "PMingLiU")
        ea("Malgun Gothic", "MalgunGothic"); ea("Batang", "Batang"); ea("Gulim", "Gulim"); ea("Dotum", "Dotum")
        ea("Apple SD Gothic Neo", "AppleSDGothicNeo")

        la("Arial", "Arial", "ArialMT")
        la("Arial Narrow", "ArialNarrow")
        la("Arial Black", "ArialBlack", "Arial-Black")
        la("Times New Roman", "TimesNewRoman", "TimesNewRomanPSMT", "TimesNewRomanPS", "Times", "Times-Roman")
        la("Courier New", "CourierNew", "CourierNewPSMT", "CourierNewPS", "Courier")
        la("Helvetica", "Helvetica")
        la("Helvetica Neue", "HelveticaNeue")
        la("Calibri", "Calibri"); la("Calibri Light", "CalibriLight"); la("Cambria", "Cambria")
        la("Candara", "Candara"); la("Consolas", "Consolas"); la("Constantia", "Constantia"); la("Corbel", "Corbel")
        la("Georgia", "Georgia"); la("Verdana", "Verdana"); la("Tahoma", "Tahoma"); la("Trebuchet MS", "TrebuchetMS")
        la("Segoe UI", "SegoeUI"); la("Century Gothic", "CenturyGothic"); la("Century", "Century")
        la("Book Antiqua", "BookAntiqua"); la("Palatino Linotype", "PalatinoLinotype"); la("Palatino", "Palatino")
        la("Garamond", "Garamond"); la("Gill Sans", "GillSans"); la("Futura", "Futura"); la("Optima", "Optima")
        la("Avenir", "Avenir"); la("Avenir Next", "AvenirNext"); la("Menlo", "Menlo"); la("Monaco", "Monaco")
        la("Lucida Grande", "LucidaGrande"); la("Symbol", "Symbol"); la("Wingdings", "Wingdings")
        la("Minion Pro", "MinionPro"); la("Myriad Pro", "MyriadPro")
        la("Roboto", "Roboto"); la("Open Sans", "OpenSans"); la("Noto Sans", "NotoSans"); la("Noto Serif", "NotoSerif")
        la("Source Sans Pro", "SourceSansPro"); la("Source Serif Pro", "SourceSerifPro"); la("Source Code Pro", "SourceCodePro")
        la("Liberation Sans", "LiberationSans"); la("Liberation Serif", "LiberationSerif"); la("Liberation Mono", "LiberationMono")
        la("DejaVu Sans", "DejaVuSans"); la("DejaVu Serif", "DejaVuSerif"); la("DejaVu Sans Mono", "DejaVuSansMono")
        return t
    }()
}
