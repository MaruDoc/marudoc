import Foundation
import CoreGraphics
import EnsoDoc

/// What the content stream says about a font: its real name, weight and glyph widths.
/// PDFKit often reports embedded subset fonts as "Helvetica", losing bold/italic.
final class PDFFontInfo {
    enum CodeLayout { case single, double, shiftJIS, euc }

    let name: String
    let bold: Bool
    let italic: Bool
    let layout: CodeLayout
    var twoByte: Bool { layout != .single }
    private let widths: [Int: CGFloat]
    private let defaultWidth: CGFloat
    /// Glyph space -> text space (0.001 except for Type3 fonts).
    let scale: CGFloat

    private init(name: String, bold: Bool, italic: Bool, layout: CodeLayout, widths: [Int: CGFloat], defaultWidth: CGFloat, scale: CGFloat) {
        self.name = name; self.bold = bold; self.italic = italic; self.layout = layout
        self.widths = widths; self.defaultWidth = defaultWidth; self.scale = scale
    }

    func width(_ code: Int) -> CGFloat { (widths[code] ?? defaultWidth) * scale }

    static func load(_ dict: CGPDFDictionaryRef) -> PDFFontInfo {
        var subtype = ""
        var p: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dict, "Subtype", &p), let p { subtype = String(cString: p) }
        var baseFont = ""
        if CGPDFDictionaryGetName(dict, "BaseFont", &p), let p { baseFont = String(cString: p) }
        let clean = TextExtractor.cleanFontName(baseFont)

        var widths: [Int: CGFloat] = [:]
        var defaultWidth: CGFloat = 500
        var scale: CGFloat = 0.001
        var layout = CodeLayout.single
        var descriptorDict: CGPDFDictionaryRef?

        if subtype == "Type0" {
            var enc = ""
            if CGPDFDictionaryGetName(dict, "Encoding", &p), let p { enc = String(cString: p) }
            if enc.isEmpty && (baseFont.contains("RKSJ") || baseFont.contains("EUC")) { enc = baseFont }
            // Shift-JIS and EUC CMaps mix one- and two-byte codes; Identity/UCS-2 use two bytes throughout.
            layout = enc.contains("RKSJ") ? .shiftJIS : enc.contains("EUC") ? .euc : .double
            var desc: CGPDFArrayRef?
            var cid: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dict, "DescendantFonts", &desc), let desc, CGPDFArrayGetDictionary(desc, 0, &cid), let cid {
                var dw: CGPDFInteger = 1000
                defaultWidth = CGPDFDictionaryGetInteger(cid, "DW", &dw) ? CGFloat(dw) : 1000
                var w: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(cid, "W", &w), let w { widths = parseCIDWidths(w) }
                var fd: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(cid, "FontDescriptor", &fd) { descriptorDict = fd }
            }
        } else {
            var first: CGPDFInteger = 0
            _ = CGPDFDictionaryGetInteger(dict, "FirstChar", &first)
            var w: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Widths", &w), let w {
                for i in 0..<min(CGPDFArrayGetCount(w), 65536) {
                    var v: CGPDFReal = 0
                    if CGPDFArrayGetNumber(w, i, &v), v.isFinite { widths[SafeInt.round(Double(first), 0, 1_000_000) + i] = CGFloat(v) }
                }
            }
            if subtype == "Type3", let m = PDFImageDecoder.numberArray(dict, "FontMatrix"), m.count == 6, m[0] != 0, m[0].isFinite {
                scale = CGFloat(abs(m[0]))
            }
            var fd: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "FontDescriptor", &fd) { descriptorDict = fd }
            if let fd = descriptorDict {
                var mw: CGPDFReal = 0
                if CGPDFDictionaryGetNumber(fd, "MissingWidth", &mw), mw > 0 { defaultWidth = CGFloat(mw) }
            }
            if widths.isEmpty { defaultWidth = 550 }
        }

        var bold = TextExtractor.nameLooksBold(clean)
        var italic = TextExtractor.nameLooksItalic(clean)
        if let fd = descriptorDict {
            var flags: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(fd, "Flags", &flags) {
                if flags & (1 << 18) != 0 { bold = true }
                if flags & (1 << 6) != 0 { italic = true }
            }
            var weight: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(fd, "FontWeight", &weight), weight >= 600 { bold = true }
            var angle: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(fd, "ItalicAngle", &angle), abs(angle) >= 4 { italic = true }
        }
        return PDFFontInfo(name: clean, bold: bold, italic: italic, layout: layout, widths: widths, defaultWidth: defaultWidth, scale: scale)
    }

    /// CID widths: [c [w1 w2 ...] cFirst cLast w ...]
    private static func parseCIDWidths(_ a: CGPDFArrayRef) -> [Int: CGFloat] {
        var out: [Int: CGFloat] = [:]
        let n = CGPDFArrayGetCount(a)
        var i = 0
        while i < n && out.count < 70000 {
            var c: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(a, i, &c), c >= 0, c <= 1_000_000 else { break }
            var sub: CGPDFArrayRef?
            if i + 1 < n, CGPDFArrayGetArray(a, i + 1, &sub), let sub {
                for k in 0..<CGPDFArrayGetCount(sub) {
                    var v: CGPDFReal = 0
                    if CGPDFArrayGetNumber(sub, k, &v), v.isFinite { out[Int(c) + k] = CGFloat(v) }
                }
                i += 2
            } else if i + 2 < n {
                var last: CGPDFInteger = 0
                var v: CGPDFReal = 0
                guard CGPDFArrayGetInteger(a, i + 1, &last), CGPDFArrayGetNumber(a, i + 2, &v), last >= c, last <= 1_000_000, last - c < 70000 else { break }
                for code in Int(c)...Int(last) { out[code] = CGFloat(v) }
                i += 3
            } else { break }
        }
        return out
    }
}

/// A text-showing operation located on the page.
struct TextRun {
    /// Baseline start and end in display space.
    var start: CGPoint
    var end: CGPoint
    /// Effective font size in points.
    var size: CGFloat
    var font: PDFFontInfo?
    /// 0 fill, 1 stroke, 2 fill+stroke (fake bold), 3 invisible, ...
    var renderMode: Int
    /// Number of non-space glyphs shown.
    var glyphCount: Int
    /// Double-byte (full-width) codes in Shift-JIS / EUC fonts.
    var wideCount: Int
    /// Text matrix is sheared (synthetic oblique).
    var slanted: Bool

    var minX: CGFloat { min(start.x, end.x) }
    var maxX: CGFloat { max(start.x, end.x) }
    var horizontal: Bool { abs(end.y - start.y) <= max(1, abs(end.x - start.x) * 0.05) }
}
