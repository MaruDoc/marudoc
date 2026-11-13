import AppKit

/// Hiragino and Yu fonts draw some characters with a glyph they share with another code point, and Core Graphics
/// writes the PDF's text layer from the glyph: copied or searched text then shows the other character ("—" comes back
/// as U+0336, "–" as U+2012, "−" as "-" or "－", "〜" as "～", ㉑ as "21"). These characters are drawn from a font of
/// similar style whose glyphs map back one to one. The lists were found by drawing every candidate with TextKit into a
/// PDF and reading it back with PDFKit (the same method as SlideFonts and SheetFonts for slides and sheets).
enum TextLayerFonts {

    /// Hiragino Sans / Mincho / Maru Gothic.
    static let hiragino: Set<UInt32> = {
        var s: Set<UInt32> = [0x02DC, 0x2012, 0x2013, 0x2014, 0x2212, 0x223C, 0x301C, 0x22C4, 0x21F5, 0x25FB, 0x25FC,
                              0x26AA, 0x26AB, 0x26BE, 0x26CB, 0x277F, 0x3244]
        for v in 0x24EB...0x24F4 { s.insert(UInt32(v)) }
        for v in 0x3251...0x325F { s.insert(UInt32(v)) }
        for v in 0x32B1...0x32BF { s.insert(UInt32(v)) }
        return s
    }()
    /// Yu Mincho: also swaps the full-width tilde and minus with the wave dash and minus sign.
    static let yuMincho: Set<UInt32> = [0x2013, 0x2014, 0x223C, 0xFF0D, 0xFF5E]
    /// Yu Gothic and the other Japanese system families (Toppan Bunkyu, Klee, Tsukushi).
    static let yuGothic: Set<UInt32> = hiragino.union([0x26BD, 0x27BF, 0x2491, 0x2492])

    static let all: Set<UInt32> = hiragino.union(yuMincho).union(yuGothic)
    private static let allSet: CharacterSet = {
        var cs = CharacterSet()
        for v in all { if let u = UnicodeScalar(v) { cs.insert(u) } }
        return cs
    }()

    /// `s` with the affected characters set in a text-layer-safe font; `s` itself when it has none.
    static func fixed(_ s: NSAttributedString) -> NSAttributedString {
        let ns = s.string as NSString
        guard ns.rangeOfCharacter(from: allSet).location != NSNotFound else { return s }
        let m = NSMutableAttributedString(attributedString: s)
        fix(m)
        return m
    }

    static func fix(_ m: NSMutableAttributedString) {
        let ns = m.string as NSString
        var pos = 0
        while pos < ns.length {
            let r = ns.rangeOfCharacter(from: allSet, options: [], range: NSRange(location: pos, length: ns.length - pos))
            if r.location == NSNotFound { break }
            pos = NSMaxRange(r)
            guard r.length == 1 else { continue }
            let c = UInt32(ns.character(at: r.location))
            let font = (m.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? NSFont(name: "Helvetica", size: 12)
            guard let font, let safe = safeFont(for: c, drawnWith: font) else { continue }
            m.addAttribute(.font, value: safe, range: r)
        }
    }

    private enum Family { case hiragino, yuMincho, yuGothic, other }

    private static func family(_ postScript: String) -> Family {
        if postScript.hasPrefix("Hiragino") || postScript.hasPrefix("HiraMin") || postScript.hasPrefix("HiraMaru")
            || postScript.hasPrefix("HiraKaku") { return .hiragino }
        if postScript.hasPrefix("YuMin") { return .yuMincho }
        if postScript.hasPrefix("YuGo") || postScript.hasPrefix("Toppan") || postScript.hasPrefix("Klee") || postScript.hasPrefix("Tsuku") { return .yuGothic }
        return .other
    }

    private static func affected(_ f: Family, _ c: UInt32) -> Bool {
        switch f {
        case .hiragino: return hiragino.contains(c)
        case .yuMincho: return yuMincho.contains(c)
        case .yuGothic: return yuGothic.contains(c)
        case .other: return false
        }
    }

    static func hasGlyph(_ font: NSFont, _ c: UInt32) -> Bool {
        guard let u = UnicodeScalar(c) else { return false }
        var units = Array(String(u).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyphs, units.count)
    }

    /// The font to draw `c` with instead of `font`, or nil when `font` already gives the right text.
    static func safeFont(for c: UInt32, drawnWith font: NSFont) -> NSFont? {
        let cascade = (font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])?.first
            .flatMap { NSFont(descriptor: $0, size: font.pointSize) }
        // The font that really draws the character: the font itself when it has it, else the first fallback (the
        // document's East Asian font, or the system's Japanese fallback, which is Hiragino).
        let drawing: Family
        if hasGlyph(font, c) { drawing = family(font.fontName) }
        else if let cascade, hasGlyph(cascade, c) { drawing = family(cascade.fontName) }
        else { drawing = .hiragino }
        guard affected(drawing, c) else { return nil }
        let names = font.fontName + " " + (cascade?.fontName ?? "")
        let mincho = names.contains("Min") || names.contains("Times") || names.contains("Georgia")
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold) || names.contains("W6") || names.contains("Bold")
            || names.contains("Demibold")
        // Fonts whose ascent and descent match Hiragino's, so a line does not grow where they stand in: STHeiti (dash
        // widths as Hiragino's: "—" and "〜" full width, "–" half) and BIZ UD (whose "—" is only half width). PingFang
        // and Arial Unicode MS are taller and come last.
        let heiti = bold ? "STHeitiSC-Medium" : "STHeitiSC-Light"
        let biz = mincho ? "BIZUDMincho-Regular" : (bold ? "BIZUDGothic-Bold" : "BIZUDGothic-Regular")
        let pingFang = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        let candidates: [String]
        switch c {
        case 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0x301C, 0xFF0D:
            candidates = [heiti, pingFang, "ArialUnicodeMS"]
        case 0xFF5E:
            // STHeiti gives the full-width tilde back as the wave dash.
            candidates = [biz, pingFang, "ArialUnicodeMS"]
        default:
            // Symbols (⇵ ◻ ◼ ⚪ ⚫) only Apple Symbols has besides the Japanese fonts.
            candidates = [biz, heiti, "ArialUnicodeMS", "AppleSymbols", pingFang, mincho ? "TimesNewRomanPSMT" : "HelveticaNeue"]
        }
        let key = "\(mincho)|\(bold)|\(font.pointSize)|\(c)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit.font }
        lock.unlock()
        var found: NSFont?
        for name in candidates {
            if let f = NSFont(name: name, size: font.pointSize), family(f.fontName) == .other, hasGlyph(f, c) { found = f; break }
        }
        lock.lock(); cache[key] = Box(font: found); lock.unlock()
        return found
    }

    private struct Box { let font: NSFont? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Box] = [:]
}
