import Foundation
import CoreGraphics
import EnsoDoc

/// PresentationML (.pptx) -> DocModel.
///
/// Slides appear in presentation order, separated by `.horizontalRule` (not `.pageBreak`, so short slides do not
/// each take a page when the result is written to a document). Per slide: the title placeholder becomes
/// `.heading(level: 2)`, other text in reading order (top-to-bottom, then left-to-right) becomes paragraphs or
/// list items, tables become `DocTable`, pictures become `DocImage`. Slide font sizes are not carried over
/// (they are sized for projection). Hidden slides are left out.
///
/// Speaker notes are added as `.quote` blocks after each slide's content when `includeNotes` is set; the first
/// notes paragraph of a slide starts with `notesLabel` in bold (e.g. "ノート: …") when one is given, so notes stay
/// recognisable in plain text, where quotes have no marker.
public enum PptxReader {
    public static func read(_ url: URL, includeNotes: Bool = false, notesLabel: String? = nil) throws -> DocModel {
        try read(data: try Data.readOffice(url), includeNotes: includeNotes, notesLabel: notesLabel)
    }

    public static func read(data: Data, includeNotes: Bool = false, notesLabel: String? = nil) throws -> DocModel {
        try PptxParser(zip: try ZipReader(data: data), includeNotes: includeNotes, notesLabel: notesLabel).parse()
    }

    public static func mediaImages(_ url: URL) throws -> [(name: String, data: Data)] {
        try DocxReader.mediaImages(in: try ZipReader(url: url), folder: "ppt/")
    }
}

private final class PptxParser {
    let zip: ZipReader
    let includeNotes: Bool
    let notesLabel: String?
    var title: String?

    init(zip: ZipReader, includeNotes: Bool, notesLabel: String?) {
        self.zip = zip; self.includeNotes = includeNotes; self.notesLabel = notesLabel
    }

    func parse() throws -> DocModel {
        let main = try OPC.mainPart(zip, fallback: "ppt/presentation.xml")
        let pres = try XNode.parse(try zip.data(main), part: main)
        guard pres.tag == "p:presentation" else { throw OfficeError.invalidDocument("\(main) is not a PowerPoint presentation") }
        let rels = Dictionary(try OPC.relationships(zip, for: main).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var blocks: [DocBlock] = []
        for sld in pres.child("p:sldIdLst")?.children("p:sldId") ?? [] {
            if sld["show"] == "0" { continue } // hidden slide (some writers flag it here)
            guard let id = sld["r:id"], let rel = rels[id], !rel.external, zip.contains(rel.target) else { continue }
            // nil = hidden slide. A slide that yields nothing gets no rule either, so no doubled rule is left behind.
            guard let slideBlocks = try readSlide(rel.target), !slideBlocks.isEmpty else { continue }
            if !blocks.isEmpty { blocks.append(.horizontalRule) }
            blocks += slideBlocks
        }
        return DocModel(title: OPC.coreTitle(zip) ?? title, blocks: blocks)
    }

    // MARK: Slide

    private struct Item { let y: Double?; let x: Double?; let order: Int; let blocks: [DocBlock] }

    private var rels: [String: OPCRelationship] = [:]
    private var placeholderFrames: [String: CGRect] = [:]
    /// Bullets set by list styles, per level (0-based). Layout placeholders are keyed like `placeholderFrames`;
    /// master placeholders by `masterKey`. `masterBodyStyle` is the master's `p:txStyles/p:bodyStyle`.
    private var layoutBullets: [String: [Int: Bullet]] = [:]
    private var masterBullets: [String: [Int: Bullet]] = [:]
    private var masterBodyStyle: [Int: Bullet] = [:]
    private var haveMaster = false

    /// Returns nil for a hidden slide.
    func readSlide(_ part: String) throws -> [DocBlock]? {
        let root = try XNode.parse(try zip.data(part), part: part)
        // PowerPoint marks a hidden slide on the slide part's root (<p:sld show="0">), not on p:sldId.
        if !OOXMLValue.onOff(root["show"] ?? "1") { return nil }
        let relList = try OPC.relationships(zip, for: part)
        rels = Dictionary(relList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        placeholderFrames = [:]
        layoutBullets = [:]; masterBullets = [:]; masterBodyStyle = [:]; haveMaster = false
        // Placeholders without their own position inherit it from the layout (and the layout from the master).
        // Bullets are inherited the same way, level by level.
        if let layout = relList.first(where: { $0.isType("slideLayout") }), zip.contains(layout.target) {
            if let master = (try? OPC.relationships(zip, for: layout.target))?.first(where: { $0.isType("slideMaster") }) {
                collectPlaceholders(master.target, isMaster: true)
            }
            collectPlaceholders(layout.target, isMaster: false)
        }

        var titleBlocks: [DocBlock] = []
        var items: [Item] = []
        if let tree = root.child("p:cSld")?.child("p:spTree") { walk(tree, titleBlocks: &titleBlocks, items: &items) }

        var out = titleBlocks
        for item in PptxParser.readingOrder(items) { out += item.blocks }
        if includeNotes, let notes = relList.first(where: { $0.isType("notesSlide") }), zip.contains(notes.target) {
            out += readNotes(notes.target)
        }
        return out
    }

    /// Top to bottom; shapes whose tops are within ~0.1 inch of the row's first shape form a row, read left to right.
    /// Without positions for every shape, the slide's z-order is kept.
    private static func readingOrder(_ items: [Item]) -> [Item] {
        guard items.allSatisfy({ $0.y != nil }) else { return items }
        let byY = items.sorted { ($0.y ?? 0, $0.order) < ($1.y ?? 0, $1.order) }
        var rows: [[Item]] = []
        for item in byY {
            if let top = rows.last?.first?.y, let y = item.y, y - top <= 7 { rows[rows.count - 1].append(item) } else { rows.append([item]) }
        }
        return rows.flatMap { $0.sorted { ($0.x ?? 0, $0.order) < ($1.x ?? 0, $1.order) } }
    }

    private func collectPlaceholders(_ part: String, isMaster: Bool) {
        guard let d = try? zip.data(part), let root = try? XNode.parse(d, part: part) else { return }
        for sp in root.descendants("p:sp") {
            guard let ph = sp.child("p:nvSpPr")?.child("p:nvPr")?.child("p:ph") else { continue }
            if let frame = PptxParser.frame(sp.child("p:spPr")) {
                for key in PptxParser.placeholderKeys(ph) { placeholderFrames[key] = frame }
            }
            let bullets = PptxParser.listStyleBullets(sp.child("p:txBody")?.child("a:lstStyle"))
            if isMaster {
                if masterBullets[PptxParser.masterKey(ph["type"])] == nil { masterBullets[PptxParser.masterKey(ph["type"])] = bullets }
            } else {
                for key in PptxParser.placeholderKeys(ph) where layoutBullets[key] == nil { layoutBullets[key] = bullets }
            }
        }
        if isMaster, let style = root.child("p:txStyles")?.child("p:bodyStyle") {
            haveMaster = true
            masterBodyStyle = PptxParser.listStyleBullets(style)
        }
    }

    static func placeholderKeys(_ ph: XNode) -> [String] {
        var keys: [String] = []
        if let idx = ph["idx"] { keys.append("idx:\(idx)") }
        keys.append("type:\(ph["type"] ?? "body")")
        return keys
    }

    /// The master has one placeholder per kind: layout and slide placeholders of any content type
    /// (body, obj, subTitle, tbl, ...) inherit from its body placeholder, titles from its title.
    static func masterKey(_ type: String?) -> String {
        switch type {
        case "title", "ctrTitle": return "title"
        case "dt", "ftr", "sldNum", "hdr": return type!
        default: return "body"
        }
    }

    static func frame(_ spPr: XNode?) -> CGRect? {
        guard let xfrm = spPr?.child("a:xfrm"), let off = xfrm.child("a:off"), let x = OOXMLValue.double(off["x"]),
              let y = OOXMLValue.double(off["y"]) else { return nil }
        let ext = xfrm.child("a:ext")
        return CGRect(x: x / 12700, y: y / 12700, width: OOXMLValue.double(ext?["cx"]).map { $0 / 12700 } ?? 0,
                      height: OOXMLValue.double(ext?["cy"]).map { $0 / 12700 } ?? 0)
    }

    /// `ink` is set while walking the fallback picture of an ink drawing (`p:contentPart`).
    private func walk(_ tree: XNode, titleBlocks: inout [DocBlock], items: inout [Item], ink: Bool = false) {
        for n in tree.children {
            switch n.tag {
            case "p:sp":
                let ph = n.child("p:nvSpPr")?.child("p:nvPr")?.child("p:ph")
                let type = ph?["type"]
                if let type, ["dt", "ftr", "sldNum", "hdr"].contains(type) { continue }
                var frame = PptxParser.frame(n.child("p:spPr"))
                if frame == nil, let ph { frame = PptxParser.placeholderKeys(ph).lazy.compactMap { self.placeholderFrames[$0] }.first }
                guard let body = n.child("p:txBody") else { continue }
                if type == "title" || type == "ctrTitle" {
                    let runs = paragraphsOf(body).map(\.runs).reduce(into: [DocRun]()) { acc, r in
                        if !acc.isEmpty { acc.append(DocRun(" ")) }
                        acc += r
                    }
                    let p = DocParagraph(runs).normalized()
                    if !p.isEmpty {
                        titleBlocks.append(.heading(level: 2, p))
                        if title == nil { title = p.plainText.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    continue
                }
                let blocks = textBlocks(body, inherited: inheritedBullets(ph: ph, body: body))
                if !blocks.isEmpty { items.append(Item(y: frame.map { Double($0.minY) }, x: frame.map { Double($0.minX) }, order: items.count, blocks: blocks)) }
            case "p:grpSp":
                walk(n, titleBlocks: &titleBlocks, items: &items, ink: ink) // child offsets are in group space; close enough for ordering
            case "p:graphicFrame":
                guard let tbl = n.firstDescendant("a:tbl"), let t = table(tbl) else { continue }
                let f = n.child("p:xfrm").flatMap { x -> CGRect? in
                    guard let off = x.child("a:off"), let ox = OOXMLValue.double(off["x"]), let oy = OOXMLValue.double(off["y"]) else { return nil }
                    return CGRect(x: ox / 12700, y: oy / 12700, width: 0, height: 0)
                }
                items.append(Item(y: f.map { Double($0.minY) }, x: f.map { Double($0.minX) }, order: items.count, blocks: [.table(t)]))
            case "p:pic":
                guard let blip = n.firstDescendant("a:blip"), let embed = blip["r:embed"], let rel = rels[embed], !rel.external,
                      let data = try? zip.data(rel.target) else { continue }
                let frame = PptxParser.frame(n.child("p:spPr"))
                let alt = n.child("p:nvPicPr")?.child("p:cNvPr")?["descr"]
                var adjust = PptxParser.pictureAdjust(blipFill: n.child("p:blipFill"), blip: blip, xfrm: n.child("p:spPr")?.child("a:xfrm"))
                adjust.darkenNearWhite = ink
                if let img = OfficeImage.docImage(from: data, widthPt: frame.map { Double($0.width) }, heightPt: frame.map { Double($0.height) }, alt: alt, adjust: adjust) {
                    items.append(Item(y: frame.map { Double($0.minY) }, x: frame.map { Double($0.minX) }, order: items.count, blocks: [.image(img)]))
                }
            case "mc:AlternateContent":
                // The Choice is the richer form; the Fallback is the same content as plain shapes or a picture.
                // Ink (p:contentPart) cannot be read here, and its Fallback is a picture of the strokes. Any other
                // Choice that yields nothing also falls back.
                let choice = n.child("mc:Choice"), fallback = n.child("mc:Fallback")
                let inkChoice = choice?.contains("p:contentPart") ?? false
                if let choice, !inkChoice {
                    let before = titleBlocks.count + items.count
                    walk(choice, titleBlocks: &titleBlocks, items: &items, ink: ink)
                    if titleBlocks.count + items.count > before { continue }
                }
                if let fallback { walk(fallback, titleBlocks: &titleBlocks, items: &items, ink: ink || inkChoice) }
            default:
                break
            }
        }
    }

    // MARK: Text

    private struct PPara { var runs: [DocRun]; var level: Int; var bullet: Bullet; var alignment: DocAlignment }
    fileprivate enum Bullet { case none, char, number(start: Int), inherit }

    /// The bullet a paragraph property element (a:pPr, a:lvlNpPr) sets, or `.inherit` when it sets none.
    private static func bullet(_ pPr: XNode?) -> Bullet {
        guard let pPr else { return .inherit }
        if pPr.child("a:buNone") != nil { return .none }
        if pPr.child("a:buChar") != nil || pPr.child("a:buBlip") != nil { return .char }
        if let num = pPr.child("a:buAutoNum") { return .number(start: OOXMLValue.clamp(OOXMLValue.int(num["startAt"]) ?? 1, 1, 32767)) }
        return .inherit
    }

    /// Bullets a list style (a:lstStyle, p:bodyStyle) sets, by level (lvl1pPr = level 0).
    private static func listStyleBullets(_ style: XNode?) -> [Int: Bullet] {
        var out: [Int: Bullet] = [:]
        for level in 0..<9 {
            let b = bullet(style?.child("a:lvl\(level + 1)pPr"))
            if case .inherit = b { continue }
            out[level] = b
        }
        return out
    }

    /// What a paragraph without its own bullet setting shows, per level, following PowerPoint's inheritance:
    /// the shape's own list style, then (placeholders only) the layout placeholder, the master placeholder and the
    /// master's body text style. A level nothing sets has no bullet. Without a master body style to go by, the old
    /// rule is kept (body and content placeholders are bulleted).
    private func inheritedBullets(ph: XNode?, body: XNode) -> (Int) -> Bullet {
        let own = PptxParser.listStyleBullets(body.child("a:lstStyle"))
        guard let ph else { return { own[$0] ?? .none } }
        let type = ph["type"]
        let layout = PptxParser.placeholderKeys(ph).lazy.compactMap { self.layoutBullets[$0] }.first ?? [:]
        let masterKey = PptxParser.masterKey(type)
        let master = masterBullets[masterKey] ?? [:]
        let style = masterKey == "body" ? masterBodyStyle : [:]
        let fallback: Bullet = (type == nil || type == "body" || type == "obj") ? .char : .none
        let known = haveMaster
        return { level in
            own[level] ?? layout[level] ?? master[level] ?? style[level] ?? (known ? .none : fallback)
        }
    }

    private func paragraphsOf(_ body: XNode) -> [PPara] {
        body.children("a:p").map { p in
            let pPr = p.child("a:pPr")
            let bullet = PptxParser.bullet(pPr)
            let level = min(max(OOXMLValue.int(pPr?["lvl"]) ?? 0, 0), 8)
            let align: DocAlignment
            switch pPr?["algn"] {
            case "ctr": align = .center
            case "r": align = .right
            case "just", "dist", "justLow", "thaiDist": align = .justify
            default: align = .left
            }
            var runs: [DocRun] = []
            for c in p.children {
                switch c.tag {
                case "a:r", "a:fld":
                    if let r = run(c) { runs.append(r) }
                case "a:br":
                    runs.append(DocRun("\n"))
                default: break
                }
            }
            return PPara(runs: runs, level: level, bullet: bullet, alignment: align)
        }
    }

    private func run(_ r: XNode) -> DocRun? {
        let text = r.child("a:t")?.text ?? ""
        guard !text.isEmpty else { return nil }
        var run = DocRun(text)
        guard let rPr = r.child("a:rPr") else { return run }
        run.bold = OOXMLValue.onOff(rPr["b"] ?? "0")
        run.italic = OOXMLValue.onOff(rPr["i"] ?? "0")
        if let u = rPr["u"], u != "none" { run.underline = true }
        if let s = rPr["strike"], s != "noStrike" { run.strikethrough = true }
        if let hex = rPr.child("a:highlight")?.child("a:srgbClr")?["val"] { run.highlight = DocColor(hex: hex) }
        if let hex = rPr.child("a:solidFill")?.child("a:srgbClr")?["val"], hex.uppercased() != "000000", let c = DocColor(hex: hex) {
            // Slide backgrounds and shape fills are not carried over, so the text lands on a white page. White or
            // pale text that relied on a dark fill would vanish there; a highlighted run keeps its own pairing.
            run.color = run.highlight == nil ? PptxParser.readableOnWhite(c) : c
        }
        for tag in ["a:ea", "a:latin"] {
            if let f = rPr.child(tag)?["typeface"], !f.isEmpty, !f.hasPrefix("+") {
                if tag == "a:ea" && !text.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { continue }
                run.fontName = f
                break
            }
        }
        if let id = rPr.child("a:hlinkClick")?["r:id"], let rel = rels[id], rel.external {
            run.link = rel.target
            run.underline = false
            if let c = run.color, ["0563C1", "0000FF", "467886"].contains(c.hex) { run.color = nil }
        }
        return run
    }

    private func textBlocks(_ body: XNode, inherited: (Int) -> Bullet) -> [DocBlock] {
        var out: [DocBlock] = []
        var counters: [Int: Int] = [:]
        for p in paragraphsOf(body) {
            let para = DocParagraph(p.runs, alignment: p.alignment).normalized()
            if para.isEmpty { continue }
            var bullet = p.bullet
            if case .inherit = bullet { bullet = inherited(p.level) }
            switch bullet {
            case .char:
                out.append(.listItem(DocListItem(ordered: false, level: p.level, paragraph: para)))
            case .number(let start):
                let n = counters[p.level].map { $0 + 1 } ?? start
                counters[p.level] = n
                counters = counters.filter { $0.key <= p.level }
                out.append(.listItem(DocListItem(ordered: true, level: p.level, number: n, paragraph: para)))
            case .none, .inherit:
                out.append(.paragraph(para))
            }
        }
        return out
    }

    // MARK: Colour and pictures

    /// Minimum contrast ratio against white (WCAG 2 formula) for text colours. 3:1 is WCAG's floor for large text
    /// and graphics; it keeps pure red (4.0:1), Office's dark red, blues and greens as they are.
    static let minContrast = 3.0

    static func contrastOnWhite(_ c: DocColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        return 1.05 / (l + 0.05)
    }

    /// A text colour that can be read on a white page: colours with enough contrast are kept; pale greys and white
    /// become the default text colour (nil); pale but clearly coloured text (yellow, light blue...) is darkened
    /// just enough to reach `minContrast`, keeping its hue.
    static func readableOnWhite(_ c: DocColor) -> DocColor? {
        if contrastOnWhite(c) >= minContrast { return c }
        if max(c.r, c.g, c.b) - min(c.r, c.g, c.b) < 0.15 { return nil }
        var lo = 0.0, hi = 1.0   // scale factor: lo always readable, hi not
        for _ in 0..<24 {
            let k = (lo + hi) / 2
            if contrastOnWhite(DocColor(r: c.r * k, g: c.g * k, b: c.b * k)) >= minContrast { lo = k } else { hi = k }
        }
        return DocColor(r: c.r * lo, g: c.g * lo, b: c.b * lo)
    }

    /// Crop (a:srcRect), rotation and flips (a:xfrm) and transparency (a:alphaModFix) of a picture.
    static func pictureAdjust(blipFill: XNode?, blip: XNode, xfrm: XNode?) -> OfficeImage.Adjust {
        var a = OfficeImage.Adjust()
        if let r = blipFill?.child("a:srcRect") {
            func f(_ k: String) -> Double { (OOXMLValue.double(r[k]) ?? 0) / 100_000 }
            a.crop = (f("l"), f("t"), f("r"), f("b"))
        }
        if let xfrm {
            a.rotation = (OOXMLValue.double(xfrm["rot"]) ?? 0) / 60_000
            a.flipH = OOXMLValue.onOff(xfrm["flipH"] ?? "0")
            a.flipV = OOXMLValue.onOff(xfrm["flipV"] ?? "0")
        }
        if let amt = OOXMLValue.double(blip.child("a:alphaModFix")?["amt"] ?? "100000") {
            a.opacity = min(max(amt / 100_000, 0), 1)
        }
        return a
    }

    private func table(_ tbl: XNode) -> DocTable? {
        var rows: [[DocTableCell]] = []
        for tr in tbl.children("a:tr") {
            var cells: [DocTableCell] = []
            for tc in tr.children("a:tc") {
                if OOXMLValue.onOff(tc["hMerge"] ?? "0") { continue }
                let span = max(OOXMLValue.int(tc["gridSpan"]) ?? 1, 1)
                var paras: [DocParagraph] = []
                if !OOXMLValue.onOff(tc["vMerge"] ?? "0"), let body = tc.child("a:txBody") {
                    paras = paragraphsOf(body).map { DocParagraph($0.runs, alignment: $0.alignment).normalized() }.filter { !$0.isEmpty }
                }
                cells.append(DocTableCell(paras, colSpan: min(span, 1000)))
                cells[cells.count - 1].rowSpan = min(max(OOXMLValue.int(tc["rowSpan"]) ?? 1, 1), 10_000)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return nil }
        let header = OOXMLValue.onOff(tbl.child("a:tblPr")?["firstRow"] ?? "0") && rows.count > 1 ? 1 : 0
        let grid = tbl.child("a:tblGrid")?.children("a:gridCol").compactMap { OOXMLValue.double($0["w"]) } ?? []
        let cols = rows.map { $0.reduce(0) { $0 + $1.colSpan } }.max() ?? 0
        return DocTable(rows: rows, headerRows: header, columnWidths: grid.count == cols && grid.allSatisfy { $0 > 0 } ? grid : nil)
    }

    private func readNotes(_ part: String) -> [DocBlock] {
        guard let d = try? zip.data(part), let root = try? XNode.parse(d, part: part) else { return [] }
        var out: [DocBlock] = []
        for sp in root.descendants("p:sp") {
            guard sp.child("p:nvSpPr")?.child("p:nvPr")?.child("p:ph")?["type"] == "body", let body = sp.child("p:txBody") else { continue }
            for p in paragraphsOf(body) {
                var para = DocParagraph(p.runs).normalized()
                if para.isEmpty { continue }
                if out.isEmpty, let label = notesLabel, !label.isEmpty {
                    para.runs.insert(DocRun(label + ": ", bold: true), at: 0)
                }
                out.append(.quote(para))
            }
        }
        return out
    }
}
