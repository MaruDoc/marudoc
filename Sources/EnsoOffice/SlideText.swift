import Foundation
import CoreText
import CoreGraphics

/// What a text body inherits from outside its own XML.
struct TextInheritance {
    /// List styles after the body's own a:lstStyle, most specific first: layout placeholder, master placeholder,
    /// master text style (title / body / other), presentation default.
    var lists: [XNode] = []
    /// p:style/a:fontRef of the shape (font and colour for text in drawn shapes).
    var fontRef: XNode?
    /// Table style text (bold, italic, colour, font) for cells.
    var tableText: XNode?
    var colors: ColorResolver
    var rels: [String: OPCRelationship] = [:]
    var slideNumber = 1
    var theme: DrawingTheme
    /// Language that decides the East Asian script font when a run names none ("ja-JP").
    var defaultLang = "ja-JP"
}

/// A run of text with everything needed to draw it.
struct StyledRun {
    var text: String
    var size: Double
    var bold = false, italic = false
    var underline: String?
    var strike: String?
    var color: DColor? = .black          // nil: not filled (outline only)
    var highlight: DColor?
    var latin = "", ea = "", cs = "", sym = ""
    var eaLang = true
    var baseline: Double = 0             // fraction of the size; positive raises
    var spacing: Double = 0              // extra space between characters, pt
    var outline: (width: Double, color: DColor)?
    var link: String?
    var isBreak = false
    var allCaps = false
    /// Outer shadow: offset (y down), blur radius and colour.
    var shadow: (dx: Double, dy: Double, blur: Double, color: DColor)?
}

enum BulletKind {
    case none
    case char(String, font: String?)
    case number(type: String, start: Int)
}

struct StyledParagraph {
    var runs: [StyledRun]
    var level = 0
    var align = "l"
    var marL = 0.0, indent = 0.0
    var lineSpacingPct: Double? = 1
    var lineSpacingPts: Double?
    var spaceBefore = (pct: 0.0, pts: 0.0), spaceAfter = (pct: 0.0, pts: 0.0)
    var bullet: BulletKind = .none
    var bulletColor: DColor?
    var bulletSizePct: Double?, bulletSizePts: Double?
    var bulletFontFollowsText = true
    var tabs: [(pos: Double, align: String)] = []
    var defTab = 72.0
    /// Size of the paragraph mark, which sets the height of an empty paragraph.
    var endSize: Double = 18
    var number = 0
}

/// Builds styled paragraphs from a DrawingML text body (p:txBody, a:txBody, dsp:txBody) and its inheritance.
struct TextStyler {
    let inh: TextInheritance
    let ownList: XNode?
    /// normAutofit font scale and line spacing reduction.
    var fontScale = 1.0
    var spacingReduction = 0.0

    init(body: XNode, inheritance: TextInheritance) {
        inh = inheritance
        ownList = body.child("a:lstStyle")
    }

    // MARK: Layers

    private func levelNodes(_ level: Int) -> (own: [XNode], rest: [XNode]) {
        let tag = "a:lvl\(level + 1)pPr"
        func nodes(_ list: XNode?) -> [XNode] {
            guard let list else { return [] }
            return [list.child(tag), list.child("a:defPPr")].compactMap { $0 }
        }
        return (nodes(ownList), inh.lists.flatMap(nodes))
    }

    func paragraphs(_ body: XNode) -> [StyledParagraph] {
        var out: [StyledParagraph] = []
        var counters: [Int: (type: String, n: Int)] = [:]
        for p in body.children("a:p") {
            var para = paragraph(p)
            // Auto-numbering continues across paragraphs of the same level and scheme; a shallower paragraph
            // restarts deeper levels.
            counters = counters.filter { $0.key <= para.level }
            if case .number(let type, let start) = para.bullet, !para.runs.allSatisfy({ $0.text.isEmpty }) {
                if let c = counters[para.level], c.type == type { counters[para.level] = (type, c.n + 1) } else { counters[para.level] = (type, start) }
                para.number = counters[para.level]!.n
            } else if !para.runs.allSatisfy({ $0.text.isEmpty }) {
                counters[para.level] = nil
            }
            out.append(para)
        }
        return out
    }

    func paragraph(_ p: XNode) -> StyledParagraph {
        let pPr = p.child("a:pPr")
        let level = min(max(OOXMLValue.int(pPr?["lvl"]) ?? 0, 0), 8)
        let (own, rest) = levelNodes(level)
        let layers = [pPr].compactMap { $0 } + own + rest
        func attr(_ n: String) -> String? { for l in layers { if let v = l[n] { return v } }; return nil }
        func child(_ t: String) -> XNode? { for l in layers { if let c = l.child(t) { return c } }; return nil }
        func firstOf(_ tags: [String]) -> XNode? { for l in layers { for c in l.children where tags.contains(c.tag) { return c } }; return nil }

        var para = StyledParagraph(runs: [])
        para.level = level
        para.align = attr("algn") ?? "l"
        para.marL = emu(attr("marL")) ?? 0
        para.indent = emu(attr("indent")) ?? 0
        para.defTab = emu(attr("defTabSz")).flatMap { $0 > 0 ? $0 : nil } ?? 72
        if let ln = child("a:lnSpc") {
            if let pct = ln.child("a:spcPct") {
                para.lineSpacingPct = max((OOXMLValue.double(pct["val"]) ?? 100_000) / 100_000 - spacingReduction, 0.1)
            } else if let pts = ln.child("a:spcPts") {
                para.lineSpacingPts = (OOXMLValue.double(pts["val"]) ?? 0) / 100; para.lineSpacingPct = nil
            }
        } else { para.lineSpacingPct = max(1 - spacingReduction, 0.1) }
        func spacing(_ tag: String) -> (Double, Double) {
            guard let s = child(tag) else { return (0, 0) }
            if let pct = s.child("a:spcPct") { return ((OOXMLValue.double(pct["val"]) ?? 0) / 100_000, 0) }
            if let pts = s.child("a:spcPts") { return (0, (OOXMLValue.double(pts["val"]) ?? 0) / 100 * fontScale) }
            return (0, 0)
        }
        para.spaceBefore = spacing("a:spcBef")
        para.spaceAfter = spacing("a:spcAft")
        if let tl = firstOf(["a:tabLst"]) {
            para.tabs = tl.children("a:tab").compactMap { t in emu(t["pos"]).map { ($0, t["algn"] ?? "l") } }.sorted { $0.pos < $1.pos }
        }

        // Bullet: kind, font, colour and size are inherited separately.
        if let b = firstOf(["a:buNone", "a:buChar", "a:buAutoNum", "a:buBlip"]) {
            switch b.tag {
            case "a:buChar": para.bullet = .char(b["char"] ?? "•", font: nil)
            case "a:buAutoNum": para.bullet = .number(type: b["type"] ?? "arabicPeriod", start: OOXMLValue.clamp(OOXMLValue.int(b["startAt"]) ?? 1, 1, 32767))
            case "a:buBlip": para.bullet = .char("•", font: nil)
            default: para.bullet = .none
            }
        }
        if case .char(let c, _) = para.bullet, let f = firstOf(["a:buFont", "a:buFontTx"]), f.tag == "a:buFont", let face = f["typeface"] {
            para.bullet = .char(c, font: face)
            para.bulletFontFollowsText = false
        }
        if let c = firstOf(["a:buClr", "a:buClrTx"]), c.tag == "a:buClr" { para.bulletColor = inh.colors.color(in: c) }
        if let s = firstOf(["a:buSzPct", "a:buSzPts", "a:buSzTx"]) {
            if s.tag == "a:buSzPct" { para.bulletSizePct = (OOXMLValue.double(s["val"]) ?? 100_000) / 100_000 }
            if s.tag == "a:buSzPts" { para.bulletSizePts = (OOXMLValue.double(s["val"]) ?? 1200) / 100 * fontScale }
        }

        // Runs.
        let runLayers = own.map { $0.child("a:defRPr") } + [nil] + rest.map { $0.child("a:defRPr") }
        for c in p.children {
            switch c.tag {
            case "a:r", "a:fld":
                var text = c.child("a:t")?.text ?? ""
                if c.tag == "a:fld", (c["type"] ?? "").lowercased() == "slidenum" { text = String(inh.slideNumber) }
                var r = run(c.child("a:rPr"), layers: runLayers)
                r.text = r.allCaps ? text.uppercased() : text
                para.runs.append(r)
            case "a:br":
                var r = run(c.child("a:rPr"), layers: runLayers)
                r.text = "\u{2028}"; r.isBreak = true
                para.runs.append(r)
            default: break
            }
        }
        para.endSize = run(p.child("a:endParaRPr"), layers: runLayers).size
        return para
    }

    /// `layers` holds the defRPr of each list level, with nil marking where the shape's font reference and the table
    /// style come in (after the body's own list style, before the inherited ones).
    func run(_ rPr: XNode?, layers: [XNode?]) -> StyledRun {
        let all: [XNode?] = [rPr] + layers
        func attr(_ n: String) -> String? { for l in all { if let v = l?[n] { return v } }; return nil }
        func font(_ tag: String) -> String? {
            for l in all {
                if l == nil {
                    if let tt = inh.tableText, let f = tt.child("a:font")?.child(tag)?["typeface"] { return f }
                    if let tt = inh.tableText?.child("a:fontRef"), tag != "a:sym" { return (tt["idx"] == "major" ? "+mj-" : "+mn-") + (tag == "a:ea" ? "ea" : tag == "a:cs" ? "cs" : "lt") }
                    if let fr = inh.fontRef, tag != "a:sym", let idx = fr["idx"], idx != "none" {
                        return (idx == "major" ? "+mj-" : "+mn-") + (tag == "a:ea" ? "ea" : tag == "a:cs" ? "cs" : "lt")
                    }
                    continue
                }
                if let f = l?.child(tag)?["typeface"] { return f }
            }
            return nil
        }
        var r = StyledRun(text: "", size: 18)
        r.size = (OOXMLValue.double(attr("sz")) ?? 1800) / 100 * fontScale
        var bold = attr("b").map { OOXMLValue.onOff($0) }
        var italic = attr("i").map { OOXMLValue.onOff($0) }
        if let tt = inh.tableText {
            // Table style text: below the run's own settings, above the inherited list styles.
            if rPr?["b"] == nil, let b = tt["b"] { bold = b == "on" }
            if rPr?["i"] == nil, let i = tt["i"] { italic = i == "on" }
        }
        r.bold = bold ?? false
        r.italic = italic ?? false
        if let u = attr("u"), u != "none" { r.underline = u }
        if let s = attr("strike"), s != "noStrike" { r.strike = s }
        if let b = OOXMLValue.double(attr("baseline")), b != 0 { r.baseline = b / 100_000 }
        if let s = OOXMLValue.double(attr("spc")) { r.spacing = s / 100 * fontScale }
        let lang = attr("lang") ?? inh.defaultLang
        r.eaLang = TextStyler.isEALang(lang) || TextStyler.isEALang(attr("altLang") ?? "") || TextStyler.isEALang(inh.defaultLang)
        let script = TextStyler.script(for: TextStyler.isEALang(lang) ? lang : inh.defaultLang)
        r.latin = resolveFont(font("a:latin") ?? "+mn-lt", script: script)
        r.ea = resolveFont(font("a:ea") ?? "+mn-ea", script: script)
        r.cs = resolveFont(font("a:cs") ?? "+mn-cs", script: script)
        r.sym = font("a:sym").map { resolveFont($0, script: script) } ?? ""
        if r.latin.isEmpty { r.latin = inh.theme.minorLatin.isEmpty ? "Arial" : inh.theme.minorLatin }
        if r.ea.isEmpty { r.ea = (inh.theme.minorScripts[script]).flatMap { $0.isEmpty ? nil : $0 } ?? "Hiragino Sans" }

        // Colour: the first fill found walking the layers; the font reference and table style sit at the marker.
        var fill: DColor?? = nil
        for l in all {
            if l == nil {
                if let c = inh.tableText.flatMap({ inh.colors.color(in: $0) }) { fill = .some(c); break }
                if let fr = inh.fontRef, let c = inh.colors.color(in: fr) { fill = .some(c); break }
                continue
            }
            guard let l else { continue }
            if l.child("a:noFill") != nil { fill = .some(nil); break }
            if let s = l.child("a:solidFill") { fill = .some(inh.colors.color(in: s) ?? .black); break }
            if let g = l.child("a:gradFill") {
                fill = .some(inh.colors.color(in: g.child("a:gsLst")?.children("a:gs").first) ?? .black); break
            }
            if let pf = l.child("a:pattFill") { fill = .some(inh.colors.color(in: pf.child("a:fgClr")) ?? .black); break }
        }
        r.color = fill ?? .black
        for l in all {
            guard let l else { continue }
            if let h = l.child("a:highlight") { r.highlight = inh.colors.color(in: h); break }
        }
        for l in all {
            guard let l, let fx = l.child("a:effectLst") else { continue }
            if let sh = fx.child("a:outerShdw"), let c = inh.colors.color(in: sh) {
                let dist = (OOXMLValue.double(sh["dist"]) ?? 0) / 12700, dir = (OOXMLValue.double(sh["dir"]) ?? 0) / 60000 * .pi / 180
                r.shadow = (dist * cos(dir), dist * sin(dir), (OOXMLValue.double(sh["blurRad"]) ?? 0) / 12700, c)
            }
            break
        }
        for l in all {
            guard let l, let ln = l.child("a:ln") else { continue }
            if ln.child("a:noFill") == nil, let s = ln.child("a:solidFill"), let c = inh.colors.color(in: s) {
                r.outline = (max((OOXMLValue.double(ln["w"]) ?? 9525) / 12700, 0.25), c)
            }
            break
        }
        r.allCaps = attr("cap") == "all"
        if let link = rPr?.child("a:hlinkClick"), let id = link["r:id"], let rel = inh.rels[id], rel.external {
            r.link = rel.target
            // Hyperlinks show in the theme's link colour, underlined, unless the run keeps its own colour (Office 2019+).
            let keepsOwn = link.firstDescendant("http://schemas.microsoft.com/office/drawing/2018/hyperlinkcolor:hlinkClr") != nil
            if !keepsOwn { r.color = inh.colors.scheme("hlink") ?? r.color }
            if r.underline == nil { r.underline = "sng" }
        }
        return r
    }

    /// "+mn-lt" and friends from the theme; the East Asian slot falls back to the theme's script font.
    func resolveFont(_ name: String, script: String) -> String {
        guard name.hasPrefix("+") else { return name }
        let t = inh.theme
        switch name {
        case "+mj-lt": return t.majorLatin
        case "+mn-lt": return t.minorLatin
        case "+mj-ea": return t.majorEA.isEmpty ? (t.majorScripts[script] ?? "") : t.majorEA
        case "+mn-ea": return t.minorEA.isEmpty ? (t.minorScripts[script] ?? "") : t.minorEA
        case "+mj-cs": return t.majorCS
        case "+mn-cs": return t.minorCS
        default: return ""
        }
    }

    static func isEALang(_ lang: String) -> Bool {
        let l = lang.lowercased()
        return l.hasPrefix("ja") || l.hasPrefix("zh") || l.hasPrefix("ko")
    }

    static func script(for lang: String) -> String {
        let l = lang.lowercased()
        if l.hasPrefix("ko") { return "Hang" }
        if l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo") { return "Hant" }
        if l.hasPrefix("zh") { return "Hans" }
        return "Jpan"
    }

    private func emu(_ s: String?) -> Double? { OOXMLValue.double(s).map { $0 / 12700 } }
}
