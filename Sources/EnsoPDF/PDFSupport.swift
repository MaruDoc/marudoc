import Foundation
import CoreGraphics
import PDFKit
import EnsoDoc

// Shared internal types and small helpers for the PDF analysis pipeline.
// All geometry below is in "display space": points, origin at the top-left of the
// visible (crop) box after applying the page rotation, y growing downwards.

struct PageGeometry {
    /// Page space -> rotated crop box space (origin bottom-left).
    let transform: CGAffineTransform
    let size: CGSize

    init(page: PDFPage) {
        let t = page.transform(for: .cropBox)
        let b = page.bounds(for: .cropBox).applying(t)
        transform = t
        size = CGSize(width: max(1, abs(b.width)), height: max(1, abs(b.height)))
    }

    func toDisplay(_ r: CGRect) -> CGRect {
        let b = r.standardized.applying(transform)
        return CGRect(x: b.minX, y: size.height - b.maxY, width: b.width, height: b.height)
    }

    func toDisplay(_ p: CGPoint) -> CGPoint {
        let q = p.applying(transform)
        return CGPoint(x: q.x, y: size.height - q.y)
    }

    var bounds: CGRect { CGRect(origin: .zero, size: size) }
}

struct GlyphStyle: Hashable {
    var fontName: String?
    var size: Double
    var bold: Bool
    var italic: Bool
    var monospaced: Bool
    var color: DocColor?
}

/// Interns glyph styles so glyphs only carry an index.
final class StyleTable {
    private(set) var styles: [GlyphStyle] = []
    private var lookup: [GlyphStyle: Int] = [:]

    func intern(_ s: GlyphStyle) -> Int {
        if let i = lookup[s] { return i }
        styles.append(s)
        lookup[s] = styles.count - 1
        return styles.count - 1
    }

    subscript(i: Int) -> GlyphStyle { styles[i] }

    func boldVariant(of i: Int) -> Int {
        var s = styles[i]
        if s.bold { return i }
        s.bold = true
        return intern(s)
    }
}

struct Glyph {
    var text: String
    var rect: CGRect
    var style: Int
    var link: String?
    /// Whitespace preceded this glyph in PDFKit's text (real or synthesised).
    var spaceBefore: Bool
    /// Position in the page's glyph array (set by the analyzer; -1 when unknown).
    var id: Int = -1
}

struct Segment {
    var glyphs: [Glyph]
    var rect: CGRect

    init(_ g: Glyph) { glyphs = [g]; rect = g.rect }
    init(glyphs: [Glyph]) {
        self.glyphs = glyphs
        rect = glyphs.dropFirst().reduce(glyphs.first?.rect ?? .zero) { $0.union($1.rect) }
    }

    mutating func append(_ g: Glyph) { glyphs.append(g); rect = rect.union(g.rect) }

    var text: String { glyphs.map(\.text).joined() }
}

struct TextLine {
    var segments: [Segment]
    var rect: CGRect
    var page: Int
    /// Dominant font size (rounded to 0.5pt).
    var size: Double = 0
    var boldRatio: Double = 0
    var monoRatio: Double = 0
    var charCount: Int = 0
    var fontName: String?
    /// Column bounds of the region this line was laid out in (set by the layout step).
    var colLeft: CGFloat = 0
    var colRight: CGFloat = 0
    /// Right edge shared with neighbouring lines (narrower boxes inside the column); <= colRight.
    var localRight: CGFloat = .greatestFiniteMagnitude
    /// True for lines recognised by OCR (no font information).
    var fromOCR = false

    init(segments: [Segment], page: Int, styles: StyleTable) {
        self.segments = segments
        self.page = page
        rect = segments.dropFirst().reduce(segments.first?.rect ?? .zero) { $0.union($1.rect) }
        computeStats(styles)
    }

    mutating func computeStats(_ styles: StyleTable) {
        var sizeWeights: [Double: Int] = [:]
        var fontWeights: [String: Int] = [:]
        var bold = 0, mono = 0, n = 0
        for s in segments {
            for g in s.glyphs {
                let st = styles[g.style]
                n += 1
                sizeWeights[(st.size * 2).rounded() / 2, default: 0] += 1
                if st.bold { bold += 1 }
                if st.monospaced { mono += 1 }
                if let f = st.fontName { fontWeights[f, default: 0] += 1 }
            }
        }
        charCount = n
        size = sizeWeights.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key ?? 10
        boldRatio = n > 0 ? Double(bold) / Double(n) : 0
        monoRatio = n > 0 ? Double(mono) / Double(n) : 0
        fontName = fontWeights.max { $0.value < $1.value }?.key
        rect = segments.dropFirst().reduce(segments.first?.rect ?? .zero) { $0.union($1.rect) }
    }

    var glyphs: [Glyph] { segments.flatMap(\.glyphs) }
    var text: String { segments.map(\.text).joined(separator: " ") }
    var left: CGFloat { rect.minX }
    var right: CGFloat { rect.maxX }
    var midY: CGFloat { rect.midY }
}

// MARK: - Character classes

enum CharClass {
    static func isCJK(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x31FF,
             0x3200...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x2FFFF:
            return true
        default:
            return false
        }
    }

    static func isCJK(_ s: String) -> Bool {
        guard let u = s.unicodeScalars.first else { return false }
        return isCJK(u.value)
    }

    static func isKana(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) || $0.value == 0x30FC || $0.value == 0xFF70 }
    }

    static func isLatinLower(_ s: String) -> Bool {
        guard let u = s.unicodeScalars.first else { return false }
        return (0x61...0x7A).contains(u.value) || (0xDF...0xFF).contains(u.value)
    }

    static func isLatinLetter(_ s: String) -> Bool {
        guard let u = s.unicodeScalars.first else { return false }
        return (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) || (0xC0...0x24F).contains(u.value)
    }

    static func isWhitespaceUnit(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0xA0 || c == 0x3000 || c == 0x0C ||
            (0x2000...0x200B).contains(c) || c == 0x202F || c == 0x205F
    }

    static let sentenceEnders: Set<String> = ["。", ".", "．", "!", "！", "?", "？", ":", "：", "」", "』", ")", "）"]
}

// MARK: - Text joining

enum TextJoin {
    /// Separator to put between the end of one line and the start of the next inside a paragraph.
    /// Returns (separator, dropLastChar) where dropLastChar removes a hyphen.
    static func lineJoin(prevLast: String, prevBeforeLast: String?, nextFirst: String) -> (String, Bool) {
        if prevLast == "-" || prevLast == "\u{00AD}", let b = prevBeforeLast, CharClass.isLatinLower(b), CharClass.isLatinLower(nextFirst) {
            return ("", true)
        }
        if CharClass.isCJK(prevLast) || CharClass.isCJK(nextFirst) { return ("", false) }
        if prevLast == "-" || prevLast == "/" { return ("", false) }
        return (" ", false)
    }
}

// MARK: - List markers

struct ListMarker {
    var ordered: Bool
    var number: Int?
    /// Length of the marker in characters (including trailing spaces) at the start of the text.
    var length: Int
}

enum ListMarkers {
    static let bulletChars: Set<Character> = ["•", "・", "●", "○", "◦", "■", "□", "▪", "▫", "‣", "◆", "◇", "▶", "►", "▸", "➢", "➤", "✓", "✔", "★", "☆", "※", "＊", "⚫", "⦿", "◎", "❖", "♦"]
    static let dashBullets: Set<Character> = ["-", "–", "—", "*", "−", "‐"]

    private static let numbered: [(NSRegularExpression, Kind)] = [(String, Kind)]([
        (#"^([0-9０-９]{1,3})[\.．](?![0-9０-９])\s*"#, .arabic),
        (#"^([0-9０-９]{1,3})[\)）]\s*"#, .arabic),
        (#"^[\(（]([0-9０-９]{1,3})[\)）]\s*"#, .arabic),
        (#"^([①-⑳㉑-㉟])\s*"#, .circled),
        (#"^([⑴-⒇])\s*"#, .parenDigit),
        (#"^([⒈-⒛])\s*"#, .digitStop),
        (#"^([一二三四五六七八九十]{1,3})[、\.．]\s*"#, .kanji),
        (#"^[\(（]([一二三四五六七八九十]{1,3})[\)）]\s*"#, .kanji),
        (#"^([アイウエオカキクケコサシスセソタチツテトナニヌネノ])[\.．\)）]\s*"#, .katakana),
        (#"^[\(（]([アイウエオカキクケコサシスセソタチツテトナニヌネノ])[\)）]\s*"#, .katakana),
        (#"^((?:i|ii|iii|iv|v|vi|vii|viii|ix|x))[\.\)]\s+"#, .roman),
        (#"^[\(（]((?:i|ii|iii|iv|v|vi|vii|viii|ix|x))[\)）]\s*"#, .roman),
        (#"^([a-z])[\)]\s*"#, .latin),
        (#"^([a-zA-Z])\.\s+"#, .latin),
        (#"^[\(（]([a-z])[\)）]\s*"#, .latin),
    ]).compactMap { p, k in (try? NSRegularExpression(pattern: p)).map { ($0, k) } }

    enum Kind { case arabic, circled, parenDigit, digitStop, kanji, katakana, roman, latin }

    static func detect(_ text: String) -> ListMarker? {
        guard let first = text.first else { return nil }
        if bulletChars.contains(first) {
            let rest = text.dropFirst()
            let spaces = rest.prefix { $0 == " " || $0 == "\u{3000}" || $0 == "\t" }.count
            guard rest.count > spaces else { return nil }
            return ListMarker(ordered: false, number: nil, length: 1 + spaces)
        }
        if dashBullets.contains(first) {
            let rest = text.dropFirst()
            let spaces = rest.prefix { $0 == " " || $0 == "\u{3000}" || $0 == "\t" }.count
            guard spaces > 0, rest.count > spaces else { return nil }
            return ListMarker(ordered: false, number: nil, length: 1 + spaces)
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: min(ns.length, 16))
        for (re, kind) in numbered {
            guard let m = re.firstMatch(in: text, range: full), m.range.location == 0 else { continue }
            guard ns.length > m.range.length else { return nil }
            let token = m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ""
            return ListMarker(ordered: true, number: number(token, kind), length: (ns.substring(with: m.range) as String).count)
        }
        return nil
    }

    /// True when the whole string is only a marker (used to glue a detached bullet to its text).
    static func isBareMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.count == 1, let c = t.first, bulletChars.contains(c) || dashBullets.contains(c) { return true }
        return detect(t + " x").map { $0.length >= t.count } ?? false
    }

    private static func number(_ token: String, _ kind: Kind) -> Int? {
        let t = token.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? token
        switch kind {
        case .arabic: return Int(t)
        case .circled:
            guard let v = token.unicodeScalars.first?.value else { return nil }
            if (0x2460...0x2473).contains(v) { return Int(v - 0x2460 + 1) }
            if (0x3251...0x325F).contains(v) { return Int(v - 0x3251 + 21) }
            return nil
        case .parenDigit:
            guard let v = token.unicodeScalars.first?.value else { return nil }
            return Int(v) - 0x2474 + 1
        case .digitStop:
            guard let v = token.unicodeScalars.first?.value else { return nil }
            return Int(v) - 0x2488 + 1
        case .kanji: return kanjiNumber(token)
        case .katakana:
            let order = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノ")
            return token.first.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 }
        case .roman:
            let order = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]
            return order.firstIndex(of: token.lowercased()).map { $0 + 1 }
        case .latin:
            guard let v = token.lowercased().unicodeScalars.first?.value else { return nil }
            return Int(v) - 0x61 + 1
        }
    }

    static func kanjiNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, current = 0
        for c in s {
            if c == "十" { total += max(current, 1) * 10; current = 0 } else if let d = digits[c] { current = d } else { return nil }
        }
        return total + current
    }
}

// MARK: - Small numeric helpers

enum Stats {
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let idx = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[idx]
    }
}

extension CGRect {
    func verticalOverlap(_ o: CGRect) -> CGFloat { min(maxY, o.maxY) - max(minY, o.minY) }
    func horizontalOverlap(_ o: CGRect) -> CGFloat { min(maxX, o.maxX) - max(minX, o.minX) }
    var area: CGFloat { isNull ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

enum NumericText {
    /// True for cell-like numeric strings: "1,234", "12.5%", "¥300", "-3", "(12)".
    static func isNumeric(_ s: String) -> Bool {
        if case .number = CellValue.guess(s) { return true }
        return false
    }
}

/// Cheap content hash for dedupe (FNV-1a over the bytes, sampled for large data).
enum ContentHash {
    static func hash(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        let n = data.count
        let stride = n > 2_000_000 ? max(1, n / 1_000_000) : 1
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var i = 0
            while i < n {
                h ^= UInt64(buf[i])
                h = h &* 0x100000001b3
                i += stride
            }
        }
        h ^= UInt64(n)
        return h
    }
}
