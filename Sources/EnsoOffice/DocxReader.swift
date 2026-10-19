import Foundation
import CoreGraphics
import EnsoDoc

/// WordprocessingML (.docx) -> DocModel. Headers, footers, footnotes and comments are not part of the body
/// and are skipped; DocxInspector reports their presence.
public enum DocxReader {
    public static func read(_ url: URL) throws -> DocModel {
        try read(data: try Data.readOffice(url))
    }

    public static func read(data: Data) throws -> DocModel {
        let zip = try ZipReader(data: data)
        return try DocxParser(zip: zip).parse()
    }

    /// Every image stored in the package (original bytes, including formats DocModel cannot carry).
    public static func mediaImages(_ url: URL) throws -> [(name: String, data: Data)] {
        try mediaImages(in: try ZipReader(url: url), folder: "word/")
    }

    static func mediaImages(in zip: ZipReader, folder: String) throws -> [(name: String, data: Data)] {
        var out: [(String, Data)] = []
        for e in zip.entries where !e.isDirectory && e.path.lowercased().hasPrefix(folder) {
            let ext = (e.path as NSString).pathExtension.lowercased()
            guard OfficeImage.imageExtensions.contains(ext) else { continue }
            out.append(((e.path as NSString).lastPathComponent, try zip.data(for: e)))
        }
        return out
    }
}

// MARK: - Properties

struct DocxRunProps {
    var bold: Bool?, italic: Bool?, underline: Bool?, strike: Bool?, hidden: Bool?
    var size: Double?
    var color: String?       // hex or "auto"
    var highlight: String?   // hex or "none"
    var font: String?, eastAsiaFont: String?
    var code: Bool?

    /// `self` wins over `base` where set.
    func over(_ base: DocxRunProps) -> DocxRunProps {
        DocxRunProps(bold: bold ?? base.bold, italic: italic ?? base.italic, underline: underline ?? base.underline,
                     strike: strike ?? base.strike, hidden: hidden ?? base.hidden, size: size ?? base.size,
                     color: color ?? base.color, highlight: highlight ?? base.highlight, font: font ?? base.font,
                     eastAsiaFont: eastAsiaFont ?? base.eastAsiaFont, code: code ?? base.code)
    }
}

private struct DocxStyle {
    var type = "paragraph"
    var name = ""
    var basedOn: String?
    var outlineLevel: Int?
    var numId: Int?
    var ilvl: Int?
    var run = DocxRunProps()
    var pageBreakBefore: Bool?
    var alignment: DocAlignment?
}

private struct NumLevel { var format: String; var start: Int }

private enum ParaKind { case heading(Int, title: Bool), code, quote, list(ordered: Bool, level: Int, numId: Int), plain }

// MARK: - Parser

private final class DocxParser {
    let zip: ZipReader
    var mainPart = "word/document.xml"
    var rels: [String: OPCRelationship] = [:]
    var styles: [String: DocxStyle] = [:]
    var defaultParagraphStyle: String?
    var defaults = DocxRunProps()
    var themeFonts: [String: String] = [:]
    var abstractNums: [Int: (levels: [Int: NumLevel], numStyleLink: String?)] = [:]
    var nums: [Int: (abstractId: Int, overrides: [Int: Int])] = [:]
    var counters: [Int: [Int?]] = [:]
    var bodySize: Double = 10
    var bodyRun = DocxRunProps()
    private var runCache: [String: DocxRunProps] = [:]

    var blocks: [DocBlock] = []
    var pageSize: CGSize?
    var titleFromStyle: String?
    /// Complex field state: one entry per open fldChar begin; `link` is set once the instruction is known.
    var fieldStack: [(instr: String, inResult: Bool, link: String?)] = []

    init(zip: ZipReader) { self.zip = zip }

    func parse() throws -> DocModel {
        mainPart = try OPC.mainPart(zip, fallback: "word/document.xml")
        let relList = try OPC.relationships(zip, for: mainPart)
        for r in relList { rels[r.id] = r }

        if let theme = relList.first(where: { $0.isType("theme") }), let d = try? zip.data(theme.target),
           let root = try? XNode.parse(d, part: theme.target) { parseTheme(root) }
        if let st = relList.first(where: { $0.isType("styles") }), zip.contains(st.target) {
            parseStyles(try XNode.parse(try zip.data(st.target), part: st.target))
        }
        if let nb = relList.first(where: { $0.isType("numbering") }), zip.contains(nb.target) {
            parseNumbering(try XNode.parse(try zip.data(nb.target), part: nb.target))
        }

        let doc = try XNode.parse(try zip.data(mainPart), part: mainPart)
        guard doc.tag == "w:document" else { throw OfficeError.invalidDocument("\(mainPart) is not a Word document") }
        guard let body = doc.child("w:body") else { return DocModel() }
        for child in blockChildren(body) { readBlock(child, into: &blocks) }

        return DocModel(title: OPC.coreTitle(zip) ?? titleFromStyle, blocks: blocks, pageSize: pageSize,
                        bodyFontSize: bodySize, bodyFontName: bodyRun.font)
    }

    // MARK: Styles, numbering, theme

    func parseTheme(_ root: XNode) {
        guard let scheme = root.firstDescendant("a:fontScheme") else { return }
        for (tag, prefix) in [("a:majorFont", "major"), ("a:minorFont", "minor")] {
            guard let f = scheme.child(tag) else { continue }
            if let latin = f.child("a:latin")?["typeface"], !latin.isEmpty { themeFonts[prefix + "HAnsi"] = latin; themeFonts[prefix + "Ascii"] = latin }
            var ea = f.child("a:ea")?["typeface"] ?? ""
            if ea.isEmpty { ea = f.children("a:font").first { $0["script"] == "Jpan" }?["typeface"] ?? "" }
            if !ea.isEmpty { themeFonts[prefix + "EastAsia"] = ea }
            if let cs = f.child("a:cs")?["typeface"], !cs.isEmpty { themeFonts[prefix + "Bidi"] = cs }
        }
    }

    func parseStyles(_ root: XNode) {
        if let rPr = root.child("w:docDefaults")?.child("w:rPrDefault")?.child("w:rPr") { defaults = runProps(rPr) }
        for s in root.children("w:style") {
            guard let id = s["w:styleId"] else { continue }
            var st = DocxStyle()
            st.type = s["w:type"] ?? "paragraph"
            st.name = s.child("w:name")?["w:val"] ?? id
            st.basedOn = s.child("w:basedOn")?["w:val"]
            if let pPr = s.child("w:pPr") {
                st.outlineLevel = OOXMLValue.int(pPr.child("w:outlineLvl")?["w:val"])
                if let numPr = pPr.child("w:numPr") {
                    st.numId = OOXMLValue.int(numPr.child("w:numId")?["w:val"])
                    st.ilvl = OOXMLValue.int(numPr.child("w:ilvl")?["w:val"])
                }
                if let pb = pPr.child("w:pageBreakBefore") { st.pageBreakBefore = OOXMLValue.onOff(pb["w:val"]) }
                st.alignment = alignment(pPr.child("w:jc")?["w:val"])
            }
            if let rPr = s.child("w:rPr") { st.run = runProps(rPr) }
            let lname = st.name.lowercased()
            if st.type == "character", ["verbatim", "code", "source text", "typewriter", "keyboard"].contains(where: { lname.contains($0) }) {
                st.run.code = true
            }
            styles[id] = st
            if st.type == "paragraph", OOXMLValue.onOff(s["w:default"] ?? "0") { defaultParagraphStyle = id }
        }
        let normal = defaultParagraphStyle.map { resolvedRun(style: $0) } ?? DocxRunProps()
        bodyRun = normal.over(defaults)
        bodySize = bodyRun.size ?? 10
    }

    func parseNumbering(_ root: XNode) {
        for a in root.children("w:abstractNum") {
            guard let id = OOXMLValue.int(a["w:abstractNumId"]) else { continue }
            var levels: [Int: NumLevel] = [:]
            for l in a.children("w:lvl") {
                guard let ilvl = OOXMLValue.int(l["w:ilvl"]) else { continue }
                levels[ilvl] = NumLevel(format: l.child("w:numFmt")?["w:val"] ?? "decimal",
                                        start: OOXMLValue.clamp(OOXMLValue.int(l.child("w:start")?["w:val"]) ?? 1, 0, 32767))
            }
            abstractNums[id] = (levels, a.child("w:numStyleLink")?["w:val"])
        }
        for n in root.children("w:num") {
            guard let id = OOXMLValue.int(n["w:numId"]), let abs = OOXMLValue.int(n.child("w:abstractNumId")?["w:val"]) else { continue }
            var overrides: [Int: Int] = [:]
            for o in n.children("w:lvlOverride") {
                guard let ilvl = OOXMLValue.int(o["w:ilvl"]) else { continue }
                if let start = OOXMLValue.int(o.child("w:startOverride")?["w:val"]) { overrides[ilvl] = OOXMLValue.clamp(start, 0, 32767) }
                else if let start = OOXMLValue.int(o.child("w:lvl")?.child("w:start")?["w:val"]) { overrides[ilvl] = OOXMLValue.clamp(start, 0, 32767) }
            }
            nums[id] = (abs, overrides)
        }
    }

    func numLevel(numId: Int, ilvl: Int) -> NumLevel? {
        guard let num = nums[numId] else { return nil }
        var absId = num.abstractId
        // numStyleLink -> numbering style -> its numId -> the abstractNum that really defines the levels.
        for _ in 0..<3 {
            guard let abs = abstractNums[absId] else { return nil }
            if let link = abs.numStyleLink, let st = styles[link], let linked = st.numId, let target = nums[linked], target.abstractId != absId {
                absId = target.abstractId
                continue
            }
            guard var lvl = abs.levels[ilvl] else { return nil }
            if let start = num.overrides[ilvl] { lvl.start = start }
            return lvl
        }
        return nil
    }

    /// Style chain from the given style up through basedOn (guarding against cycles).
    private func chain(_ id: String) -> [DocxStyle] {
        var out: [DocxStyle] = []
        var cur: String? = id
        var seen = Set<String>()
        while let c = cur, let st = styles[c], seen.insert(c).inserted, out.count < 32 {
            out.append(st)
            cur = st.basedOn
        }
        return out
    }

    func resolvedRun(style id: String) -> DocxRunProps {
        if let hit = runCache[id] { return hit }
        let r = chain(id).reversed().reduce(DocxRunProps()) { $1.run.over($0) }
        runCache[id] = r
        return r
    }

    func runProps(_ rPr: XNode) -> DocxRunProps {
        var p = DocxRunProps()
        for c in rPr.children {
            switch c.tag {
            case "w:b": p.bold = OOXMLValue.onOff(c["w:val"])
            case "w:i": p.italic = OOXMLValue.onOff(c["w:val"])
            case "w:strike", "w:dstrike": p.strike = OOXMLValue.onOff(c["w:val"])
            case "w:u": p.underline = (c["w:val"] ?? "single") != "none"
            case "w:vanish": p.hidden = OOXMLValue.onOff(c["w:val"])
            case "w:sz": if let v = OOXMLValue.double(c["w:val"]), v > 0 { p.size = v / 2 }
            case "w:color": if let v = c["w:val"] { p.color = v }
            case "w:highlight": if let v = c["w:val"] { p.highlight = DocxParser.highlightHex[v] ?? "none" }
            case "w:shd":
                if let fill = c["w:fill"], p.highlight == nil {
                    let f = fill.uppercased()
                    p.highlight = (f == "AUTO" || f == "FFFFFF" || c["w:val"] == "nil") ? "none" : f
                }
            case "w:rFonts":
                if let f = c["w:ascii"] ?? c["w:hAnsi"] { p.font = f }
                else if let t = c["w:asciiTheme"] ?? c["w:hAnsiTheme"], let f = themeFonts[t] { p.font = f }
                if let f = c["w:eastAsia"] { p.eastAsiaFont = f }
                else if let t = c["w:eastAsiaTheme"], let f = themeFonts[t] { p.eastAsiaFont = f }
            case "w:rStyle":
                if let id = c["w:val"] { p = p.over(resolvedRun(style: id)) }
            default: break
            }
        }
        return p
    }

    static let highlightHex: [String: String] = [
        "yellow": "FFFF00", "green": "00FF00", "cyan": "00FFFF", "magenta": "FF00FF", "blue": "0000FF", "red": "FF0000",
        "darkBlue": "000080", "darkCyan": "008080", "darkGreen": "008000", "darkMagenta": "800080", "darkRed": "800000",
        "darkYellow": "808000", "darkGray": "808080", "lightGray": "C0C0C0", "black": "000000", "white": "FFFFFF",
    ]

    func alignment(_ v: String?) -> DocAlignment? {
        switch v {
        case "center": return .center
        case "right", "end": return .right
        case "both", "distribute", "thaiDistribute", "lowKashida", "mediumKashida", "highKashida": return .justify
        case "left", "start": return .left
        default: return nil
        }
    }

    // MARK: Block level

    /// Children of a block container, looking through content controls, custom XML and tracked insertions.
    func blockChildren(_ n: XNode) -> [XNode] {
        var out: [XNode] = []
        for c in n.children {
            switch c.tag {
            case "w:sdt": if let content = c.child("w:sdtContent") { out += blockChildren(content) }
            case "w:customXml", "w:ins", "w:moveTo", "w:smartTag": out += blockChildren(c)
            case "mc:AlternateContent":
                if let choice = c.child("mc:Choice") { out += blockChildren(choice) }
            default: out.append(c)
            }
        }
        return out
    }

    func readBlock(_ n: XNode, into out: inout [DocBlock]) {
        switch n.tag {
        case "w:p": readParagraph(n, into: &out)
        case "w:tbl": if let t = readTable(n) { out.append(.table(t)) }
        case "w:sectPr": notePageSize(n)
        default: break
        }
    }

    func notePageSize(_ sectPr: XNode) {
        guard pageSize == nil, let pg = sectPr.child("w:pgSz"),
              let w = OOXMLValue.twips(pg["w:w"]), let h = OOXMLValue.twips(pg["w:h"]), w > 0, h > 0 else { return }
        pageSize = CGSize(width: w / 20, height: h / 20)
    }

    func classify(_ p: XNode) -> (ParaKind, styleId: String?) {
        let pPr = p.child("w:pPr")
        let styleId = pPr?.child("w:pStyle")?["w:val"] ?? defaultParagraphStyle
        let styleChain = styleId.map { chain($0) } ?? []

        // Heading by style name first (localised names included), then outline level.
        for st in styleChain {
            let name = st.name.lowercased().trimmingCharacters(in: .whitespaces)
            if name == "title" { return (.heading(1, title: true), styleId) }
            if let lvl = DocxParser.headingLevel(fromName: name) { return (.heading(lvl, title: false), styleId) }
        }
        let outline = OOXMLValue.int(pPr?.child("w:outlineLvl")?["w:val"]) ?? styleChain.lazy.compactMap(\.outlineLevel).first
        if let o = outline, (0...8).contains(o) { return (.heading(min(o + 1, 6), title: false), styleId) }

        let names = styleChain.map { $0.name.lowercased() }
        if names.contains(where: { n in ["source code", "html preformatted", "preformatted text", "code", "code block", "verbatim"].contains(n) || n.hasPrefix("code ") }) {
            return (.code, styleId)
        }

        // Numbering: direct numPr wins over the style's.
        let numPr = pPr?.child("w:numPr")
        let numId = OOXMLValue.int(numPr?.child("w:numId")?["w:val"]) ?? styleChain.lazy.compactMap(\.numId).first
        let ilvl = OOXMLValue.int(numPr?.child("w:ilvl")?["w:val"]) ?? styleChain.lazy.compactMap(\.ilvl).first ?? 0
        if let numId, numId != 0 {
            let level = min(max(ilvl, 0), 8)
            let fmt = numLevel(numId: numId, ilvl: level)?.format ?? "bullet"
            if fmt != "none" { return (.list(ordered: fmt != "bullet", level: level, numId: numId), styleId) }
        }

        if names.contains(where: { n in ["quote", "intense quote", "block text", "quotations", "block quotation", "引用文", "引用"].contains(n) }) {
            return (.quote, styleId)
        }
        return (.plain, styleId)
    }

    static func headingLevel(fromName name: String) -> Int? {
        for prefix in ["heading", "見出し"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return 1 }
            let digits = rest.precomposedStringWithCompatibilityMapping
            if let n = Int(digits), (1...9).contains(n) { return min(n, 6) }
        }
        return nil
    }

    private enum Piece { case run(DocRun), image(DocImage), pageBreak, blocks([DocBlock]) }

    func readParagraph(_ p: XNode, into out: inout [DocBlock]) {
        let pPr = p.child("w:pPr")
        let (kind, styleId) = classify(p)
        var paraRun = DocxRunProps()
        if case .heading = kind {} else if let styleId { paraRun = resolvedRun(style: styleId) }
        let base = paraRun.over(defaults)

        var pieces: [Piece] = []
        collectInline(p, base: base, link: nil, into: &pieces)

        let styleBreak = styleId.flatMap { chain($0).lazy.compactMap(\.pageBreakBefore).first } ?? false
        let directBreak = pPr?.child("w:pageBreakBefore").map { OOXMLValue.onOff($0["w:val"]) }
        if directBreak ?? styleBreak { appendPageBreak(&out) }

        let align = alignment(pPr?.child("w:jc")?["w:val"]) ?? styleId.flatMap { chain($0).lazy.compactMap(\.alignment).first } ?? .left
        var indent: Double = 0
        if case .plain = kind, let ind = pPr?.child("w:ind"), let left = OOXMLValue.twips(ind["w:left"] ?? ind["w:start"]), left > 0 {
            indent = left / 20
        }

        var listNumber: Int?
        if case .list(let ordered, let level, let numId) = kind {
            let n = nextNumber(numId: numId, level: level)
            if ordered { listNumber = n }
        }

        // A paragraph without visible content is either a blank line inside a code block or,
        // with a bottom border, a horizontal rule (LibreOffice may also put a page break into it).
        let hasContent = pieces.contains { piece in
            switch piece {
            case .run(let r): return kind.isCode ? !r.text.isEmpty : !r.text.trimmingCharacters(in: .whitespaces).isEmpty
            case .image, .blocks: return true
            case .pageBreak: return false
            }
        }
        if !hasContent {
            if kind.isCode, case .code(let prev, let lang)? = out.last {
                out[out.count - 1] = .code(prev + "\n", language: lang)
            } else if let bottom = pPr?.child("w:pBdr")?.child("w:bottom"), !["none", "nil"].contains(bottom["w:val"] ?? "none") {
                out.append(.horizontalRule)
            }
        }

        var runs: [DocRun] = []
        func flush() {
            let para = DocParagraph(runs, alignment: align, indent: indent).normalized()
            runs = []
            guard !para.isEmpty || (kind.isCode && !para.runs.isEmpty) else { return }
            switch kind {
            case .heading(let lvl, let title):
                if title && titleFromStyle == nil { titleFromStyle = para.plainText.trimmingCharacters(in: .whitespacesAndNewlines) }
                out.append(.heading(level: lvl, para))
            case .code:
                let text = para.plainText
                if case .code(let prev, let lang)? = out.last { out[out.count - 1] = .code(prev + "\n" + text, language: lang) }
                else { out.append(.code(text, language: nil)) }
            case .quote: out.append(.quote(para))
            case .list(let ordered, let level, _):
                out.append(.listItem(DocListItem(ordered: ordered, level: level, number: listNumber, paragraph: para)))
            case .plain: out.append(.paragraph(para))
            }
        }

        var trailing: [DocBlock] = []
        for piece in pieces {
            switch piece {
            case .run(let r): runs.append(r)
            case .image(let img): flush(); out.append(.image(img))
            case .pageBreak: flush(); appendPageBreak(&out)
            case .blocks(let b): trailing += b
            }
        }
        flush()
        out += trailing

        if let sect = pPr?.child("w:sectPr") {
            notePageSize(sect)
            if (sect.child("w:type")?["w:val"] ?? "nextPage") != "continuous" { appendPageBreak(&out) }
        }
    }

    func appendPageBreak(_ out: inout [DocBlock]) {
        guard let last = out.last else { return } // nothing before it: a break at the very top is meaningless
        if case .pageBreak = last { return }
        out.append(.pageBreak)
    }

    func nextNumber(numId: Int, level: Int) -> Int {
        var c = counters[numId] ?? Array(repeating: nil, count: 9)
        let start = numLevel(numId: numId, ilvl: level)?.start ?? 1
        let n = (c[level] ?? (start - 1)) + 1
        c[level] = n
        for deeper in (level + 1)..<9 { c[deeper] = nil }
        counters[numId] = c
        return n
    }

    // MARK: Inline level

    private func collectInline(_ n: XNode, base: DocxRunProps, link: String?, into pieces: inout [Piece]) {
        for c in n.children {
            switch c.tag {
            case "w:r":
                readRun(c, base: base, link: link ?? fieldLink, into: &pieces)
            case "w:hyperlink":
                var target: String?
                if let id = c["r:id"], let rel = rels[id] { target = rel.target }
                collectInline(c, base: base, link: target ?? link, into: &pieces)
            case "w:fldSimple":
                collectInline(c, base: base, link: DocxParser.hyperlinkTarget(c["w:instr"] ?? "") ?? link, into: &pieces)
            case "w:smartTag", "w:customXml", "w:ins", "w:moveTo", "w:bdo", "w:dir":
                collectInline(c, base: base, link: link, into: &pieces)
            case "w:sdt":
                if let content = c.child("w:sdtContent") { collectInline(content, base: base, link: link, into: &pieces) }
            case "w:ruby":
                if let rb = c.child("w:rubyBase") { collectInline(rb, base: base, link: link, into: &pieces) }
            case "mc:AlternateContent":
                alternate(c) { collectInline($0, base: base, link: link, into: &pieces) }
            default:
                break // pPr, del, moveFrom, bookmarks, proofErr, comment ranges...
            }
        }
    }

    private var fieldLink: String? { fieldStack.last(where: { $0.inResult })?.link }

    /// Markup compatibility: the first mc:Choice (modern DrawingML), else the mc:Fallback (usually VML).
    private func alternate(_ n: XNode, _ body: (XNode) -> Void) {
        if let choice = n.child("mc:Choice") { body(choice) } else if let fb = n.child("mc:Fallback") { body(fb) }
    }

    /// Longest field instruction that is parsed. A real HYPERLINK is far shorter; longer ones are ignored.
    static let maxFieldInstruction = 8192

    static func hyperlinkTarget(_ instr: String) -> String? {
        guard instr.utf8.count <= 4 * maxFieldInstruction else { return nil }
        // Everything below works on Substring slices of the one original string (no copies), so the cost is linear.
        func isSpace(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) } }
        func trimmed(_ s: Substring) -> Substring {
            var s = s
            while let f = s.first, isSpace(f) { s = s.dropFirst() }
            while let l = s.last, isSpace(l) { s = s.dropLast() }
            return s
        }
        let t = trimmed(instr[...])
        guard t.count <= maxFieldInstruction, t.uppercased().hasPrefix("HYPERLINK") else { return nil }
        var rest = trimmed(t.dropFirst("HYPERLINK".count))
        var isAnchor = false
        // Switches like \l "bookmark" (internal) or \o "tooltip" may precede the target.
        while rest.hasPrefix("\\") {
            let sw = rest.prefix(2)
            if sw == "\\l" { isAnchor = true }
            rest = trimmed(rest.dropFirst(2))
            if sw == "\\o" || sw == "\\t" || sw == "\\l" {
                if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
                    if sw == "\\l" { return nil }
                    rest = trimmed(rest[rest.index(after: end)...])
                }
            }
        }
        if isAnchor { return nil }
        if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
            let url = String(rest[rest.index(after: rest.startIndex)..<end])
            return url.isEmpty ? nil : url
        }
        let url = rest.split(separator: " ").first.map(String.init)
        return (url?.isEmpty ?? true) ? nil : url
    }

    private func readRun(_ r: XNode, base: DocxRunProps, link: String?, into pieces: inout [Piece]) {
        let props = r.child("w:rPr").map { runProps($0).over(base) } ?? base
        var text = ""
        var currentLink = link

        func emitText() {
            guard !text.isEmpty else { return }
            if props.hidden == true { text = ""; return }
            pieces.append(.run(makeRun(text, props, link: currentLink)))
            text = ""
        }

        for c in r.children {
            switch c.tag {
            case "w:t":
                if fieldStack.last.map({ !$0.inResult }) ?? false { continue }
                text += c.text
            case "w:tab", "w:ptab": text += "\t"
            case "w:br":
                let type = c["w:type"] ?? "textWrapping"
                if type == "page" { emitText(); pieces.append(.pageBreak) } else { text += "\n" }
            case "w:cr": text += "\n"
            case "w:noBreakHyphen": text += "\u{2011}"
            case "w:fldChar":
                emitText()
                switch c["w:fldCharType"] {
                case "begin": fieldStack.append(("", false, nil))
                case "separate":
                    if var top = fieldStack.popLast() {
                        top.inResult = true
                        top.link = DocxParser.hyperlinkTarget(top.instr)
                        fieldStack.append(top)
                    }
                case "end": _ = fieldStack.popLast()
                default: break
                }
                currentLink = link ?? fieldLink
            case "w:instrText":
                if !fieldStack.isEmpty { fieldStack[fieldStack.count - 1].instr += c.text }
            case "w:drawing":
                emitText()
                readDrawing(c, into: &pieces)
            case "w:pict", "w:object":
                emitText()
                readVML(c, into: &pieces)
            case "mc:AlternateContent":
                emitText()
                alternate(c) { node in
                    for d in node.children {
                        if d.tag == "w:drawing" { readDrawing(d, into: &pieces) } else if d.tag == "w:pict" { readVML(d, into: &pieces) }
                    }
                }
            default: break
            }
        }
        emitText()
    }

    private func makeRun(_ text: String, _ p: DocxRunProps, link: String?) -> DocRun {
        var run = DocRun(text)
        run.bold = p.bold ?? false
        run.italic = p.italic ?? false
        run.underline = (p.underline ?? false) && link == nil
        run.strikethrough = p.strike ?? false
        run.code = p.code ?? false
        if let s = p.size, abs(s - bodySize) > 0.01 { run.fontSize = s }
        if let c = p.color?.uppercased(), c != "AUTO", c != "000000", let color = DocColor(hex: c) {
            // The usual link blues come from hyperlink character styles: presentation, not content.
            if !(link != nil && DocxParser.linkColors.contains(c)) { run.color = color }
        }
        if let h = p.highlight, h != "none", let color = DocColor(hex: h) { run.highlight = color }
        let usesEA = text.unicodeScalars.contains { $0.value >= 0x2E80 }
        let font = usesEA ? (p.eastAsiaFont ?? p.font) : p.font
        let bodyFont = usesEA ? (bodyRun.eastAsiaFont ?? bodyRun.font) : bodyRun.font
        if let f = font, f != bodyFont, !run.code { run.fontName = f }
        if let link, let url = DocxParser.absoluteLink(link) { run.link = url }
        return run
    }

    static let linkColors: Set<String> = ["0563C1", "0000FF", "000080", "0000EE", "1155CC", "0066CC", "467886"]

    static func absoluteLink(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
        return t
    }

    // MARK: Images and text boxes

    private func readDrawing(_ d: XNode, into pieces: inout [Piece]) {
        for holder in d.children where holder.tag == "wp:inline" || holder.tag == "wp:anchor" {
            let extent = holder.child("wp:extent")
            let docPr = holder.child("wp:docPr")
            let alt = docPr?["descr"] ?? docPr?["title"]
            let pics = holder.descendants("pic:pic")
            for pic in pics {
                guard let embed = pic.firstDescendant("a:blip")?["r:embed"] else { continue }
                var w: Double?, h: Double?
                if let ext = pic.child("pic:spPr")?.child("a:xfrm")?.child("a:ext"), pics.count > 1 {
                    w = OOXMLValue.double(ext["cx"]).map { $0 / 12700 }; h = OOXMLValue.double(ext["cy"]).map { $0 / 12700 }
                } else {
                    w = OOXMLValue.double(extent?["cx"]).map { $0 / 12700 }; h = OOXMLValue.double(extent?["cy"]).map { $0 / 12700 }
                }
                if let img = image(rel: embed, width: w, height: h, alt: alt ?? pic.firstDescendant("pic:cNvPr")?["descr"]) {
                    pieces.append(.image(img))
                }
            }
            // Text boxes (wps:txbx / v:textbox) carry their own paragraphs.
            for box in holder.descendants("w:txbxContent") { pieces.append(.blocks(textBoxBlocks(box))) }
        }
    }

    private func readVML(_ n: XNode, into pieces: inout [Piece]) {
        for shape in n.descendants("v:shape") {
            if let data = shape.firstDescendant("v:imagedata"), let id = data["r:id"] ?? data["o:relid"] {
                let size = DocxParser.vmlSize(shape["style"] ?? "")
                if let img = image(rel: id, width: size.map { Double($0.width) }, height: size.map { Double($0.height) }, alt: shape["alt"] ?? data["o:title"]) {
                    pieces.append(.image(img))
                }
            }
        }
        for box in n.descendants("w:txbxContent") { pieces.append(.blocks(textBoxBlocks(box))) }
    }

    private func textBoxBlocks(_ box: XNode) -> [DocBlock] {
        var out: [DocBlock] = []
        for c in blockChildren(box) { readBlock(c, into: &out) }
        return out
    }

    /// Width/height in points from a VML CSS style ("width:120pt;height:3cm"; unitless means px).
    static func vmlSize(_ style: String) -> CGSize? {
        func length(_ v: String) -> Double? {
            if v.hasSuffix("px") { return OOXMLValue.double(String(v.dropLast(2))).map { $0 * 0.75 } }
            if let unitless = OOXMLValue.double(v) { return unitless * 0.75 }
            return OOXMLValue.twips(v).map { $0 / 20 }
        }
        var w: Double?, h: Double?
        for decl in style.split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0] == "width" { w = length(kv[1]) } else if kv[0] == "height" { h = length(kv[1]) }
        }
        if let w, let h, w > 0, h > 0 { return CGSize(width: w, height: h) }
        return nil
    }

    private func image(rel id: String, width: Double?, height: Double?, alt: String?) -> DocImage? {
        guard let rel = rels[id], !rel.external, let data = try? zip.data(rel.target) else { return nil }
        return OfficeImage.docImage(from: data, widthPt: width, heightPt: height, alt: alt)
    }

    // MARK: Tables

    func readTable(_ tbl: XNode) -> DocTable? {
        var rows: [[DocTableCell]] = []
        var headerRows = 0
        var stillHeader = true
        let grid = tbl.child("w:tblGrid")?.children("w:gridCol").compactMap { OOXMLValue.twips($0["w:w"]) } ?? []

        for tr in blockChildren(tbl) where tr.tag == "w:tr" {
            let isHeader = tr.child("w:trPr")?.child("w:tblHeader").map { OOXMLValue.onOff($0["w:val"]) } ?? false
            if stillHeader && isHeader { headerRows += 1 } else { stillHeader = false }
            var cells: [DocTableCell] = []
            for tc in blockChildren(tr) where tc.tag == "w:tc" {
                let tcPr = tc.child("w:tcPr")
                if tcPr?.child("w:hMerge").map({ ($0["w:val"] ?? "continue") == "continue" }) ?? false, !cells.isEmpty {
                    cells[cells.count - 1].colSpan += 1
                    continue
                }
                let span = max(OOXMLValue.int(tcPr?.child("w:gridSpan")?["w:val"]) ?? 1, 1)
                let vContinue = tcPr?.child("w:vMerge").map { ($0["w:val"] ?? "continue") == "continue" } ?? false
                var paras: [DocParagraph] = []
                if !vContinue {
                    var inner: [DocBlock] = []
                    for c in blockChildren(tc) { readBlock(c, into: &inner) }
                    paras = DocxParser.flatten(inner)
                }
                cells.append(DocTableCell(paras, colSpan: min(span, 1000)))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return nil }
        if headerRows == 0, rows.count > 1 {
            let runs = rows[0].flatMap { $0.paragraphs.flatMap(\.runs) }.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if !runs.isEmpty && runs.allSatisfy(\.bold) { headerRows = 1 }
        }
        let colCount = rows.map { $0.reduce(0) { $0 + $1.colSpan } }.max() ?? 0
        return DocTable(rows: rows, headerRows: headerRows, columnWidths: grid.count == colCount && grid.allSatisfy { $0 > 0 } ? grid : nil)
    }

    /// Cell content as plain paragraphs (cells cannot hold lists, nested tables or images in DocModel).
    static func flatten(_ blocks: [DocBlock]) -> [DocParagraph] {
        var out: [DocParagraph] = []
        for b in blocks {
            switch b {
            case .heading(_, let p), .paragraph(let p), .quote(let p): out.append(p)
            case .listItem(let li):
                var p = li.paragraph
                let marker = li.ordered ? "\(li.number ?? 1). " : "• "
                p.runs.insert(DocRun(String(repeating: "  ", count: li.level) + marker), at: 0)
                out.append(p)
            case .code(let s, _): out.append(DocParagraph([DocRun(s, code: true)]))
            case .table(let t):
                for row in t.rows { out.append(DocParagraph(text: row.map(\.text).joined(separator: "\t"))) }
            case .image(let img): if let alt = img.altText, !alt.isEmpty { out.append(DocParagraph(text: alt)) }
            case .pageBreak, .horizontalRule: break
            }
        }
        return out
    }
}

private extension ParaKind {
    var isCode: Bool { if case .code = self { return true }; return false }
}
