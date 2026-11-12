import Foundation
import CoreGraphics
import EnsoDoc

/// WordprocessingML (.docx) -> DocModel. Headers, footers and comments are not part of the body and are skipped;
/// DocxInspector reports their presence. Footnotes and endnotes become `DocModel.notes` with marks in the text.
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
    /// w:vertAlign: "superscript", "subscript" or "baseline".
    var vertAlign: String?

    /// `self` wins over `base` where set.
    func over(_ base: DocxRunProps) -> DocxRunProps {
        DocxRunProps(bold: bold ?? base.bold, italic: italic ?? base.italic, underline: underline ?? base.underline,
                     strike: strike ?? base.strike, hidden: hidden ?? base.hidden, size: size ?? base.size,
                     color: color ?? base.color, highlight: highlight ?? base.highlight, font: font ?? base.font,
                     eastAsiaFont: eastAsiaFont ?? base.eastAsiaFont, code: code ?? base.code,
                     vertAlign: vertAlign ?? base.vertAlign)
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

/// One level of a numbering definition: number format, start value, level text ("%1.", "(%1)", "第%1条", or the bullet
/// character), legal-style numbering (all levels decimal) and the bullet's font (symbol fonts are mapped to Unicode).
private struct NumLevel { var format: String; var start: Int; var text: String? = nil; var legal = false; var font: String? = nil }

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

    /// Footnote and endnote parts: note id -> its w:footnote / w:endnote element, and the part's own relationships
    /// (links inside a note resolve against them, not against the body's).
    var noteParts: [DocNote.Kind: (notes: [String: XNode], rels: [String: OPCRelationship])] = [:]
    var notes: [DocNote] = []
    /// "footnote:<w:id>" -> DocNote.id, so a note is read once.
    var noteIDs: [String: Int] = [:]
    var noteCounters: [DocNote.Kind: Int] = [:]
    /// Number format and start of each kind; Word's defaults unless settings.xml says otherwise.
    var noteFormats: [DocNote.Kind: (format: String, start: Int)] = [.footnote: ("decimal", 1), .endnote: ("lowerRoman", 1)]
    /// True while a note's own content is read: a reference inside a note is not followed (no recursion).
    var readingNote = false

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
        // Notes are optional content: a damaged notes part costs the notes, never the document.
        for (kind, type) in [(DocNote.Kind.footnote, "footnotes"), (.endnote, "endnotes")] {
            guard let rel = relList.first(where: { $0.isType(type) }), zip.contains(rel.target),
                  let root = try? XNode.parse(try zip.data(rel.target), part: rel.target) else { continue }
            var byId: [String: XNode] = [:]
            // Separators and continuation notices (w:type set) are layout, not notes.
            for n in root.children where (n.tag == "w:footnote" || n.tag == "w:endnote") && (n["w:type"] ?? "normal") == "normal" {
                if let id = n["w:id"] { byId[id] = n }
            }
            var noteRels: [String: OPCRelationship] = [:]
            for r in (try? OPC.relationships(zip, for: rel.target)) ?? [] { noteRels[r.id] = r }
            noteParts[kind] = (byId, noteRels)
        }
        if !noteParts.isEmpty, let st = relList.first(where: { $0.isType("settings") }), let d = try? zip.data(st.target),
           let root = try? XNode.parse(d, part: st.target) {
            for (kind, tag) in [(DocNote.Kind.footnote, "w:footnotePr"), (.endnote, "w:endnotePr")] {
                guard let pr = root.child(tag), var f = noteFormats[kind] else { continue }
                if let fmt = pr.child("w:numFmt")?["w:val"] { f.format = fmt }
                if let start = OOXMLValue.int(pr.child("w:numStart")?["w:val"]) { f.start = OOXMLValue.clamp(start, 0, 32767) }
                noteFormats[kind] = f
            }
        }

        let doc = try XNode.parse(try zip.data(mainPart), part: mainPart)
        guard doc.tag == "w:document" else { throw OfficeError.invalidDocument("\(mainPart) is not a Word document") }
        guard let body = doc.child("w:body") else { return DocModel() }
        for child in blockChildren(body) { readBlock(child, into: &blocks) }

        return DocModel(title: OPC.coreTitle(zip) ?? titleFromStyle, blocks: blocks, pageSize: pageSize,
                        bodyFontSize: bodySize, bodyFontName: bodyRun.font, notes: notes, bodyEastAsianFontName: bodyRun.eastAsiaFont)
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
                                        start: OOXMLValue.clamp(OOXMLValue.int(l.child("w:start")?["w:val"]) ?? 1, 0, 32767),
                                        text: l.child("w:lvlText")?["w:val"],
                                        legal: l.child("w:isLgl").map { OOXMLValue.onOff($0["w:val"]) } ?? false,
                                        font: l.child("w:rPr")?.child("w:rFonts").flatMap { $0["w:ascii"] ?? $0["w:hAnsi"] })
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
            case "w:vertAlign": p.vertAlign = c["w:val"]
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
        var listMarker: (marker: String?, numbering: DocListNumbering?) = (nil, nil)
        if case .list(let ordered, let level, let numId) = kind {
            let n = nextNumber(numId: numId, level: level)
            if ordered { listNumber = n }
            listMarker = marker(numId: numId, level: level)
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
                out.append(.listItem(DocListItem(ordered: ordered, level: level, number: listNumber, paragraph: para,
                                                 marker: listMarker.marker, numbering: listMarker.numbering)))
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

    /// The marker Word shows for the item just counted by `nextNumber`: the level text with each %k replaced by level
    /// k's counter in level k's number format ("(%1)" -> "(2)", "%1.%2" -> "1.3", "第%1条" -> "第１条"), and for bullets
    /// the level text itself with symbol-font characters mapped to Unicode. nil where it is the writers' default
    /// ("1." for a decimal "%1.", a plain round bullet), so ordinary lists come out exactly as before.
    func marker(numId: Int, level: Int) -> (marker: String?, numbering: DocListNumbering?) {
        guard let lvl = numLevel(numId: numId, ilvl: level), let text = lvl.text else { return (nil, nil) }
        if lvl.format == "bullet" {
            let mark = DocxSymbols.mapText(text, font: lvl.font).trimmingCharacters(in: .whitespaces)
            return (mark.isEmpty || DocxParser.plainBullets.contains(mark) ? nil : mark, nil)
        }
        let c = counters[numId] ?? []
        var out = ""
        var chars = text.makeIterator()
        while let ch = chars.next() {
            guard ch == "%" else { out.append(ch); continue }
            guard let d = chars.next() else { out.append(ch); break }
            guard let k = d.wholeNumberValue, (1...9).contains(k) else { out.append(ch); out.append(d); continue }
            let ref = numLevel(numId: numId, ilvl: k - 1)
            let value = (k - 1 < c.count ? c[k - 1] : nil) ?? ref?.start ?? 1
            out += DocxParser.formatNumber(value, format: lvl.legal ? "decimal" : (ref?.format ?? "decimal"))
        }
        let n = (level < c.count ? c[level] : nil) ?? 1
        if out == "\(n)." { return (nil, nil) }
        return (out, DocListNumbering(format: lvl.format, pattern: text))
    }

    static let plainBullets: Set<String> = ["•", "·", "∙", "●", "○", "◦", "o", "-", "–", "・"]

    /// A number in an OOXML number format (ST_NumberFormat). Formats not listed print as decimal.
    static func formatNumber(_ n: Int, format: String) -> String {
        func roman(_ v: Int) -> String? {
            guard (1...3999).contains(v) else { return nil }
            let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                          (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
            var v = v, s = ""
            for (k, r) in table { while v >= k { s += r; v -= k } }
            return s
        }
        func letters(_ v: Int, _ base: UInt32) -> String? {
            // Word: A…Z, then AA…ZZ, AAA… (the same letter repeated).
            guard v >= 1, v <= 26 * 50 else { return nil }
            return String(repeating: String(UnicodeScalar(base + UInt32((v - 1) % 26))!), count: (v - 1) / 26 + 1)
        }
        func fromList(_ v: Int, _ list: [Character]) -> String? {
            guard v >= 1 else { return nil }
            return String(list[(v - 1) % list.count])
        }
        func ideographDigits(_ v: Int) -> String? {
            guard v >= 0 else { return nil }
            let d: [Character] = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
            return String(String(v).compactMap { $0.wholeNumberValue.map { d[$0] } })
        }
        func counting(_ v: Int, _ digits: [String], _ ten: String) -> String? {
            // 一, 十, 十一, 二十三, 百五, 千二百: the usual Japanese counting form up to 9999.
            guard (1...9999).contains(v) else { return nil }
            var s = ""
            for (unit, name) in [(1000, "千"), (100, "百"), (10, ten)] {
                let q = (v / unit) % 10
                if q == 0 { continue }
                s += (q == 1 ? "" : digits[q]) + name
            }
            if v % 10 > 0 { s += digits[v % 10] }
            return s
        }
        let kanji = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let result: String?
        switch format {
        case "decimalZero": result = n >= 0 && n < 10 ? "0\(n)" : nil
        case "decimalFullWidth", "decimalFullWidth2":
            result = n >= 0 ? String(String(n).unicodeScalars.map { Character(UnicodeScalar($0.value - 0x30 + 0xFF10)!) }) : nil
        case "decimalEnclosedCircle", "decimalEnclosedCircleChinese":
            switch n {
            case 1...20: result = String(UnicodeScalar(0x2460 + UInt32(n - 1))!)
            case 21...35: result = String(UnicodeScalar(0x3251 + UInt32(n - 21))!)
            case 36...50: result = String(UnicodeScalar(0x32B1 + UInt32(n - 36))!)
            default: result = nil
            }
        case "decimalEnclosedFullstop": result = (1...20).contains(n) ? String(UnicodeScalar(0x2488 + UInt32(n - 1))!) : "\(n)."
        case "decimalEnclosedParen": result = (1...20).contains(n) ? String(UnicodeScalar(0x2474 + UInt32(n - 1))!) : "(\(n))"
        case "upperRoman": result = roman(n)
        case "lowerRoman": result = roman(n)?.lowercased()
        case "upperLetter": result = letters(n, 0x41)
        case "lowerLetter": result = letters(n, 0x61)
        case "aiueo": result = fromList(n, Array(DocxParser.aiueoHalf))
        case "aiueoFullWidth": result = fromList(n, Array(DocxParser.aiueo))
        case "iroha": result = fromList(n, Array(DocxParser.iroha).map { DocxParser.halfWidthKana[$0] ?? $0 })
        case "irohaFullWidth": result = fromList(n, Array(DocxParser.iroha))
        case "ideographDigital", "japaneseDigitalTenThousand": result = ideographDigits(n)
        case "japaneseCounting", "chineseCounting", "chineseCountingThousand", "taiwaneseCounting", "taiwaneseCountingThousand":
            result = counting(n, kanji, "十")
        case "japaneseLegal": result = counting(n, ["", "壱", "弐", "参", "四", "伍", "六", "七", "八", "九"], "拾")
        case "ideographTraditional": result = fromList(n, Array("甲乙丙丁戊己庚辛壬癸"))
        case "ideographZodiac": result = fromList(n, Array("子丑寅卯辰巳午未申酉戌亥"))
        case "ordinal":
            let suffix: String
            switch (n % 100, n % 10) {
            case (11...13, _): suffix = "th"
            case (_, 1): suffix = "st"
            case (_, 2): suffix = "nd"
            case (_, 3): suffix = "rd"
            default: suffix = "th"
            }
            result = "\(n)\(suffix)"
        case "none": result = ""
        default: result = nil
        }
        return result ?? String(n)
    }

    static let aiueo = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン"
    static let aiueoHalf = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝ"
    static let iroha = "イロハニホヘトチリヌルヲワカヨタレソツネナラムウヰノオクヤマケフコエテアサキユメミシヱヒモセス"
    static let halfWidthKana: [Character: Character] = Dictionary(uniqueKeysWithValues: Swift.zip(aiueo, aiueoHalf))

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
                readRuby(c, base: base, link: link, into: &pieces)
            case "m:oMath", "m:oMathPara":
                // Equations as linear text where they stand; typesetting is out of reach, losing them is not.
                let text = DocxMath.linear(c)
                if !text.isEmpty { pieces.append(.run(makeRun(text, base, link: link ?? fieldLink))) }
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
            case "w:sym":
                if fieldStack.last.map({ !$0.inResult }) ?? false { continue }
                text += DocxSymbols.symbol(c["w:char"], font: c["w:font"] ?? props.font)
            case "w:ruby":
                emitText()
                readRuby(c, base: props, link: currentLink, into: &pieces)
            case "w:footnoteReference", "w:endnoteReference":
                emitText()
                if let mark = noteReference(c, kind: c.tag == "w:footnoteReference" ? .footnote : .endnote, props: props, link: currentLink) {
                    pieces.append(.run(mark))
                }
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

    /// A ruby group: the base text (with the base run's formatting) carrying the reading. A base without text keeps
    /// the reading as plain text, so nothing written in the source is lost.
    private func readRuby(_ ruby: XNode, base: DocxRunProps, link: String?, into pieces: inout [Piece]) {
        var baseParts: [Piece] = [], readingParts: [Piece] = []
        if let rb = ruby.child("w:rubyBase") { collectInline(rb, base: base, link: link, into: &baseParts) }
        if let rt = ruby.child("w:rt") { collectInline(rt, base: base, link: link, into: &readingParts) }
        let reading = readingParts.compactMap { piece -> String? in if case .run(let r) = piece { return r.text }; return nil }.joined()
        let runs = baseParts.compactMap { piece -> DocRun? in if case .run(let r) = piece { return r }; return nil }
        if var first = runs.first {
            first.text = runs.map(\.text).joined()
            if !reading.trimmingCharacters(in: .whitespaces).isEmpty { first.ruby = reading }
            pieces.append(.run(first))
        } else if !reading.isEmpty {
            pieces.append(.run(makeRun(reading, base, link: link)))
        }
        for piece in baseParts { if case .run = piece { continue }; pieces.append(piece) }
    }

    /// A footnote or endnote mark: reads the note on first use (numbered in mark order, like Word) and returns the
    /// superscript mark run that points to it. nil when the note does not exist, is hidden, or the mark sits inside
    /// another note.
    private func noteReference(_ ref: XNode, kind: DocNote.Kind, props: DocxRunProps, link: String?) -> DocRun? {
        guard !readingNote, props.hidden != true, let id = ref["w:id"], let part = noteParts[kind], let node = part.notes[id] else { return nil }
        let key = "\(kind.rawValue):\(id)"
        let note: DocNote
        if let known = noteIDs[key], let existing = notes.first(where: { $0.id == known }) {
            note = existing
        } else {
            let n = (noteCounters[kind] ?? 0) + 1
            noteCounters[kind] = n
            let f = noteFormats[kind] ?? ("decimal", 1)
            let label = DocxParser.formatNumber(f.start + n - 1, format: f.format)
            // The note is read with its own part's relationships and a clean field state; the body's are restored.
            let savedRels = rels, savedFields = fieldStack
            rels = part.rels; fieldStack = []; readingNote = true
            var inner: [DocBlock] = []
            for c in blockChildren(node) { readBlock(c, into: &inner) }
            rels = savedRels; fieldStack = savedFields; readingNote = false
            var paras = DocxParser.flatten(inner)
            // The note's own number (w:footnoteRef) is not text; drop the space Word puts after it.
            if !paras.isEmpty {
                var runs = paras[0].runs
                while let first = runs.first, first.image == nil, first.noteID == nil {
                    let t = String(first.text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" }))
                    if t.isEmpty { runs.removeFirst() } else { runs[0].text = t; break }
                }
                paras[0].runs = runs
            }
            note = DocNote(id: notes.count + 1, kind: kind, label: label, paragraphs: paras.filter { !$0.isEmpty })
            notes.append(note)
            noteIDs[key] = note.id
        }
        var mark = makeRun(note.label, props, link: link)
        mark.baseline = .superscript
        mark.noteID = note.id
        return mark
    }

    private func makeRun(_ text: String, _ p: DocxRunProps, link: String?) -> DocRun {
        // Text in a symbol font (Wingdings check marks, Symbol Greek) is shown by Word as the font's glyph: carry the
        // Unicode character it stands for, not the letter that selects it.
        let symbolFont = DocxSymbols.isSymbolFont(p.font) && !text.unicodeScalars.contains { $0.value >= 0x2E80 && !(0xF000...0xF0FF).contains($0.value) }
        var run = DocRun(symbolFont ? DocxSymbols.mapText(text, font: p.font) : text)
        switch p.vertAlign {
        case "superscript": run.baseline = .superscript
        case "subscript": run.baseline = .subscript
        default: break
        }
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
        if let f = font, f != bodyFont, !run.code, !symbolFont { run.fontName = f }
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

        // Vertical merges: "restart" opens a merged cell, "continue" cells below it are covered. Covered cells stay as
        // empty placeholders; the opening cell gets the row span (counted per grid column below).
        var merges: [[(col: Int, restart: Bool, covered: Bool)]] = []
        for tr in blockChildren(tbl) where tr.tag == "w:tr" {
            let isHeader = tr.child("w:trPr")?.child("w:tblHeader").map { OOXMLValue.onOff($0["w:val"]) } ?? false
            if stillHeader && isHeader { headerRows += 1 } else { stillHeader = false }
            var cells: [DocTableCell] = []
            var rowMerges: [(col: Int, restart: Bool, covered: Bool)] = []
            for tc in blockChildren(tr) where tc.tag == "w:tc" {
                let tcPr = tc.child("w:tcPr")
                if tcPr?.child("w:hMerge").map({ ($0["w:val"] ?? "continue") == "continue" }) ?? false, !cells.isEmpty {
                    cells[cells.count - 1].colSpan += 1
                    continue
                }
                let span = max(OOXMLValue.int(tcPr?.child("w:gridSpan")?["w:val"]) ?? 1, 1)
                let vMerge = tcPr?.child("w:vMerge").map { $0["w:val"] ?? "continue" }
                let vContinue = vMerge == "continue"
                var paras: [DocParagraph] = []
                if !vContinue {
                    var inner: [DocBlock] = []
                    for c in blockChildren(tc) { readBlock(c, into: &inner) }
                    paras = DocxParser.flatten(inner)
                }
                rowMerges.append((cells.reduce(0) { $0 + $1.colSpan }, vMerge == "restart", vContinue))
                cells.append(DocTableCell(paras, colSpan: min(span, 1000)))
            }
            if !cells.isEmpty { rows.append(cells); merges.append(rowMerges) }
        }
        guard !rows.isEmpty else { return nil }
        for r in rows.indices {
            for i in rows[r].indices where merges[r][i].restart {
                var span = 1
                while r + span < rows.count, merges[r + span].contains(where: { $0.covered && $0.col == merges[r][i].col }) { span += 1 }
                rows[r][i].rowSpan = span
            }
        }
        if headerRows == 0, rows.count > 1 {
            let runs = rows[0].flatMap { $0.paragraphs.flatMap(\.runs) }.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if !runs.isEmpty && runs.allSatisfy(\.bold) { headerRows = 1 }
        }
        let colCount = rows.map { $0.reduce(0) { $0 + $1.colSpan } }.max() ?? 0
        return DocTable(rows: rows, headerRows: headerRows, columnWidths: grid.count == colCount && grid.allSatisfy { $0 > 0 } ? grid : nil)
    }

    /// Cell (and note) content as paragraphs: cells cannot hold lists or nested tables in DocModel, so those become
    /// text; a picture becomes a paragraph holding it as an inline picture run.
    static func flatten(_ blocks: [DocBlock]) -> [DocParagraph] {
        var out: [DocParagraph] = []
        for b in blocks {
            switch b {
            case .heading(_, let p), .paragraph(let p), .quote(let p): out.append(p)
            case .listItem(let li):
                var p = li.paragraph
                let marker = li.markerText(bullet: "•") + " "
                p.runs.insert(DocRun(String(repeating: "  ", count: li.level) + marker), at: 0)
                out.append(p)
            case .code(let s, _): out.append(DocParagraph([DocRun(s, code: true)]))
            case .table(let t):
                for row in t.rows { out.append(DocParagraph(text: row.map(\.text).joined(separator: "\t"))) }
            case .image(let img): out.append(DocParagraph([DocRun(img.altText ?? "", image: img)]))
            case .pageBreak, .horizontalRule: break
            }
        }
        return out
    }
}

private extension ParaKind {
    var isCode: Bool { if case .code = self { return true }; return false }
}

// MARK: - Symbol fonts

/// Characters of the classic symbol fonts as Unicode. Word stores them as the font's code (w:sym w:char="F0FC", or
/// text "ü" in Wingdings); without the mapping a check mark becomes nothing or a stray letter. Codes a table does not
/// know become U+FFFD, a visible placeholder.
enum DocxSymbols {
    static let placeholder = "\u{FFFD}"

    static func table(_ font: String?) -> [UInt32: String]? {
        guard let f = font?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        switch f {
        case "wingdings": return wingdings
        case "wingdings 2": return wingdings2
        case "webdings": return webdings
        case "symbol": return symbol
        default: return nil
        }
    }

    static func isSymbolFont(_ font: String?) -> Bool { table(font) != nil }

    /// w:sym: `char` is hex, in the font's own code (F0xx or 00xx) for symbol fonts, otherwise a Unicode code point.
    static func symbol(_ char: String?, font: String?) -> String {
        guard let hex = char, let code = UInt32(hex, radix: 16) else { return placeholder }
        let low = (0xF000...0xF0FF).contains(code) ? code - 0xF000 : code
        if let t = table(font) { return low < 0x100 ? (t[low] ?? placeholder) : character(code) }
        // Not a known symbol font: a private-use code means a glyph only that font has.
        return (0xF000...0xF0FF).contains(code) ? placeholder : character(code)
    }

    private static func character(_ code: UInt32) -> String {
        guard code >= 0x20, let u = UnicodeScalar(code), !(0xE000...0xF8FF).contains(code) else { return placeholder }
        return String(u)
    }

    /// Text set in a symbol font: each code (plain or F0xx) through the font's table; other characters unchanged.
    static func mapText(_ s: String, font: String?) -> String {
        guard let t = table(font) else { return s }
        var out = ""
        for u in s.unicodeScalars {
            let low = (0xF000...0xF0FF).contains(u.value) ? u.value - 0xF000 : u.value
            if low < 0x100, low >= 0x20 { out += t[low] ?? placeholder } else { out.unicodeScalars.append(u) }
        }
        return out
    }

    private static func range(_ start: UInt32, _ chars: String) -> [UInt32: String] {
        var d: [UInt32: String] = [:]
        for (i, c) in chars.enumerated() where c != "_" { d[start + UInt32(i)] = String(c) }
        return d
    }

    /// Wingdings (Unicode's Wingdings mapping; arrows outside the BMP use the BMP arrow of the same direction).
    static let wingdings: [UInt32: String] = {
        var d: [UInt32: String] = [0x20: " ", 0xA0: " "]
        d.merge([0x22: "✂", 0x23: "✁", 0x28: "☎", 0x29: "✆", 0x2A: "✉", 0x36: "⌛", 0x3E: "✇", 0x3F: "✍", 0x41: "✌", 0x45: "☜", 0x46: "☞", 0x47: "☝",
                 0x48: "☟", 0x49: "✋", 0x4A: "☺", 0x4C: "☹", 0x4E: "☠", 0x51: "✈", 0x52: "☼", 0x54: "❄", 0x56: "✞",
                 0x58: "✠", 0x59: "✡", 0x5A: "☪", 0x5B: "☯", 0x5C: "ॐ", 0x5D: "☸"], uniquingKeysWith: { $1 })
        d.merge(range(0x5E, "♈♉♊♋♌♍♎♏♐♑♒♓"), uniquingKeysWith: { $1 })
        d.merge(range(0x6C, "●❍■□□❑❒⬧⧫◆❖⬥⌧_⌘"), uniquingKeysWith: { $1 })
        d.merge(range(0x80, "⓪①②③④⑤⑥⑦⑧⑨⑩⓿❶❷❸❹❺❻❼❽❾❿"), uniquingKeysWith: { $1 })
        d.merge(range(0x9E, "·•▪○__◉◎_▪◻_✦★✶✴✹✵_⌖⟡⌑_✪✰"), uniquingKeysWith: { $1 })
        d.merge([0xD5: "⌫", 0xD6: "⌦", 0xD8: "➢"], uniquingKeysWith: { $1 })
        d.merge(range(0xDF, "←→↑↓↖↗↙↘⬅➡⬆⬇⬉⬈⬋⬊⇦⇨⇧⇩⬄⇳⬀⬁⬃⬂▭▫✗✓☒☑"), uniquingKeysWith: { $1 })
        return d
    }()

    /// Wingdings 2: the form characters (check marks, crossed and checked boxes, the empty box).
    static let wingdings2: [UInt32: String] = [0x20: " ", 0xA0: " ", 0x4F: "✗", 0x50: "✓", 0x51: "☒", 0x52: "☑",
                                               0x53: "☒", 0x54: "☒", 0xA3: "□"]

    static let webdings: [UInt32: String] = [0x20: " ", 0xA0: " ", 0x61: "✓", 0x72: "✕"]

    /// Symbol (Adobe Symbol encoding): ASCII punctuation and digits as themselves except where Symbol differs,
    /// Greek for the letters, mathematical signs above 0xA0.
    static let symbol: [UInt32: String] = {
        var d: [UInt32: String] = [:]
        for c in UInt32(0x20)...0x3F { d[c] = String(UnicodeScalar(c)!) }
        d.merge([0x22: "∀", 0x24: "∃", 0x27: "∋", 0x2A: "∗", 0x2D: "−", 0x40: "≅", 0x5B: "[", 0x5C: "∴", 0x5D: "]",
                 0x5E: "⊥", 0x5F: "_", 0x7B: "{", 0x7C: "|", 0x7D: "}", 0x7E: "∼", 0xA0: " "], uniquingKeysWith: { $1 })
        d.merge(range(0x41, "ΑΒΧΔΕΦΓΗΙϑΚΛΜΝΟΠΘΡΣΤΥςΩΞΨΖ"), uniquingKeysWith: { $1 })
        d.merge(range(0x61, "αβχδεφγηιϕκλμνοπθρστυϖωξψζ"), uniquingKeysWith: { $1 })
        d.merge(range(0xA1, "ϒ′≤⁄∞ƒ♣♦♥♠↔←↑→↓°±″≥×∝∂•÷≠≡≈…⏐⎯↵ℵℑℜ℘⊗⊕∅∩∪⊃⊇⊄⊂⊆∈∉∠∇®©™∏√⋅¬∧∨⇔⇐⇑⇒⇓◊〈®©™∑"), uniquingKeysWith: { $1 })
        d.merge([0xF1: "〉", 0xF2: "∫"], uniquingKeysWith: { $1 })
        return d
    }()
}

// MARK: - Equations

/// OMML (m:oMath) as linear text: fractions "a/b" with parentheses where an operand is not a single term, "x^2",
/// "x_i", "√(x+1)", "∑_(i=1)^n x_i", delimiters as written, matrices row by row "[a, b; c, d]", equation arrays one
/// row per line. Every m:t is kept, so no text of an equation is lost even where the layout is.
enum DocxMath {
    static func linear(_ n: XNode) -> String {
        switch n.tag {
        case "m:t", "w:t": return n.text
        case "m:oMathPara":
            return n.children.filter { $0.tag == "m:oMath" }.map(linear).joined(separator: "\n")
        case "m:f":
            let num = part(n, "m:num"), den = part(n, "m:den")
            return wrap(num) + "/" + wrap(den)
        case "m:sSup": return wrap(part(n, "m:e")) + "^" + wrap(part(n, "m:sup"))
        case "m:sSub": return wrap(part(n, "m:e")) + "_" + wrap(part(n, "m:sub"))
        case "m:sSubSup": return wrap(part(n, "m:e")) + "_" + wrap(part(n, "m:sub")) + "^" + wrap(part(n, "m:sup"))
        case "m:sPre": return "_" + wrap(part(n, "m:sub")) + "^" + wrap(part(n, "m:sup")) + wrap(part(n, "m:e"))
        case "m:rad":
            let deg = part(n, "m:deg"), e = wrap(part(n, "m:e"))
            switch deg {
            case "": return "√" + e
            case "3": return "∛" + e
            case "4": return "∜" + e
            default: return wrap(deg) + "√" + e
            }
        case "m:nary":
            let pr = n.child("m:naryPr")
            let chr = pr?.child("m:chr")?["m:val"] ?? "∫"
            let sub = part(n, "m:sub"), sup = part(n, "m:sup")
            var s = chr.isEmpty ? "∫" : chr
            if !sub.isEmpty { s += "_" + wrap(sub) }
            if !sup.isEmpty { s += "^" + wrap(sup) }
            let e = part(n, "m:e")
            return e.isEmpty ? s : s + " " + e
        case "m:d":
            let pr = n.child("m:dPr")
            let beg = pr?.child("m:begChr").map { $0["m:val"] ?? "" } ?? "("
            let end = pr?.child("m:endChr").map { $0["m:val"] ?? "" } ?? ")"
            let sep = pr?.child("m:sepChr").map { $0["m:val"] ?? "" } ?? "|"
            let es = n.children.filter { $0.tag == "m:e" }
            // A matrix inside brackets takes the brackets as its own.
            if es.count == 1, let only = es.first, only.children.count == 1, let m = only.children.first, m.tag == "m:m" {
                return beg + rows(m) + end
            }
            return beg + es.map(linear).joined(separator: sep) + end
        case "m:m": return "[" + rows(n) + "]"
        case "m:eqArr": return n.children.filter { $0.tag == "m:e" }.map(linear).joined(separator: "\n")
        case "m:func":
            let name = part(n, "m:fName"), e = part(n, "m:e")
            return name + (e.hasPrefix("(") || e.hasPrefix("[") || e.isEmpty ? "" : " ") + e
        case "m:limLow": return part(n, "m:e") + "_" + wrap(part(n, "m:lim"))
        case "m:limUpp": return part(n, "m:e") + "^" + wrap(part(n, "m:lim"))
        case "m:acc":
            let chr = n.child("m:accPr")?.child("m:chr")?["m:val"] ?? "\u{0302}"
            let e = part(n, "m:e")
            // A combining accent goes after a single character; anything else is written after the term.
            return e.count == 1 && chr.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark }) ? e + chr : wrap(e) + chr
        case "m:bar":
            let e = part(n, "m:e")
            return e.count == 1 ? e + "\u{0305}" : e
        case "m:phant":
            let show = n.child("m:phantPr")?.child("m:show")?["m:val"]
            return show == "0" || show == "off" ? "" : part(n, "m:e")
        default:
            // Property elements carry no text; everything else (m:r, m:e, m:box, m:groupChr, m:oMath, …) is its parts.
            if n.tag.hasSuffix("Pr") { return "" }
            return n.children.map(linear).joined()
        }
    }

    private static func part(_ n: XNode, _ tag: String) -> String {
        n.child(tag).map(linear) ?? ""
    }

    private static func rows(_ m: XNode) -> String {
        m.children.filter { $0.tag == "m:mr" }.map { $0.children.filter { $0.tag == "m:e" }.map(linear).joined(separator: ", ") }
            .joined(separator: "; ")
    }

    /// Parentheses unless the operand is one term: a single character, a number, a word, or already bracketed.
    static func wrap(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "" }
        if t.count == 1 { return t }
        if t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) { return t }
        if let f = t.first, let l = t.last, ["(": ")", "[": "]", "{": "}", "|": "|"][f] == l, balanced(t) { return t }
        return "(" + t + ")"
    }

    /// True when the first bracket closes only at the end ("(a)+(b)" is not one bracketed term).
    private static func balanced(_ t: String) -> Bool {
        var depth = 0
        for (i, c) in t.enumerated() {
            if "([{".contains(c) { depth += 1 } else if ")]}".contains(c) { depth -= 1 }
            if depth == 0 && i < t.count - 1 { return t.first == "|" }
        }
        return depth == 0 || t.first == "|"
    }
}
