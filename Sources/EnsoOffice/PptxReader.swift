import Foundation
import CoreGraphics
import EnsoDoc

/// PresentationML (.pptx) -> DocModel.
///
/// Slides appear in presentation order, separated by `.horizontalRule` (not `.pageBreak`, so short slides do not
/// each take a page when the result is written to a document). Per slide: the title placeholder becomes
/// `.heading(level: 2)`, other text in reading order (top-to-bottom, then left-to-right) becomes paragraphs or
/// list items, tables become `DocTable`, pictures become `DocImage`. Slide font sizes are not carried over
/// (they are sized for projection). Speaker notes are added as `.quote` blocks when `includeNotes` is set.
public enum PptxReader {
    public static func read(_ url: URL, includeNotes: Bool = false) throws -> DocModel {
        try read(data: try Data.readOffice(url), includeNotes: includeNotes)
    }

    public static func read(data: Data, includeNotes: Bool = false) throws -> DocModel {
        try PptxParser(zip: try ZipReader(data: data), includeNotes: includeNotes).parse()
    }

    public static func mediaImages(_ url: URL) throws -> [(name: String, data: Data)] {
        try DocxReader.mediaImages(in: try ZipReader(url: url), folder: "ppt/")
    }
}

private final class PptxParser {
    let zip: ZipReader
    let includeNotes: Bool
    var title: String?

    init(zip: ZipReader, includeNotes: Bool) { self.zip = zip; self.includeNotes = includeNotes }

    func parse() throws -> DocModel {
        let main = try OPC.mainPart(zip, fallback: "ppt/presentation.xml")
        let pres = try XNode.parse(try zip.data(main), part: main)
        guard pres.tag == "p:presentation" else { throw OfficeError.invalidDocument("\(main) is not a PowerPoint presentation") }
        let rels = Dictionary(try OPC.relationships(zip, for: main).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var blocks: [DocBlock] = []
        for sld in pres.child("p:sldIdLst")?.children("p:sldId") ?? [] {
            if sld["show"] == "0" { continue } // hidden slide
            guard let id = sld["r:id"], let rel = rels[id], !rel.external, zip.contains(rel.target) else { continue }
            let slideBlocks = try readSlide(rel.target)
            if !blocks.isEmpty { blocks.append(.horizontalRule) }
            blocks += slideBlocks
        }
        return DocModel(title: OPC.coreTitle(zip) ?? title, blocks: blocks)
    }

    // MARK: Slide

    private struct Item { let y: Double?; let x: Double?; let order: Int; let blocks: [DocBlock] }

    private var rels: [String: OPCRelationship] = [:]
    private var placeholderFrames: [String: CGRect] = [:]

    func readSlide(_ part: String) throws -> [DocBlock] {
        let root = try XNode.parse(try zip.data(part), part: part)
        let relList = try OPC.relationships(zip, for: part)
        rels = Dictionary(relList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        placeholderFrames = [:]
        // Placeholders without their own position inherit it from the layout (and the layout from the master).
        if let layout = relList.first(where: { $0.isType("slideLayout") }), zip.contains(layout.target) {
            if let master = (try? OPC.relationships(zip, for: layout.target))?.first(where: { $0.isType("slideMaster") }) {
                collectPlaceholderFrames(master.target)
            }
            collectPlaceholderFrames(layout.target)
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

    private func collectPlaceholderFrames(_ part: String) {
        guard let d = try? zip.data(part), let root = try? XNode.parse(d, part: part) else { return }
        for sp in root.descendants("p:sp") {
            guard let ph = sp.child("p:nvSpPr")?.child("p:nvPr")?.child("p:ph"), let frame = PptxParser.frame(sp.child("p:spPr")) else { continue }
            for key in PptxParser.placeholderKeys(ph) { placeholderFrames[key] = frame }
        }
    }

    static func placeholderKeys(_ ph: XNode) -> [String] {
        var keys: [String] = []
        if let idx = ph["idx"] { keys.append("idx:\(idx)") }
        keys.append("type:\(ph["type"] ?? "body")")
        return keys
    }

    static func frame(_ spPr: XNode?) -> CGRect? {
        guard let xfrm = spPr?.child("a:xfrm"), let off = xfrm.child("a:off"), let x = OOXMLValue.double(off["x"]),
              let y = OOXMLValue.double(off["y"]) else { return nil }
        let ext = xfrm.child("a:ext")
        return CGRect(x: x / 12700, y: y / 12700, width: OOXMLValue.double(ext?["cx"]).map { $0 / 12700 } ?? 0,
                      height: OOXMLValue.double(ext?["cy"]).map { $0 / 12700 } ?? 0)
    }

    private func walk(_ tree: XNode, titleBlocks: inout [DocBlock], items: inout [Item]) {
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
                let bulletsByDefault = ph != nil && (type == nil || type == "body" || type == "obj")
                let blocks = textBlocks(body, bulletsByDefault: bulletsByDefault)
                if !blocks.isEmpty { items.append(Item(y: frame.map { Double($0.minY) }, x: frame.map { Double($0.minX) }, order: items.count, blocks: blocks)) }
            case "p:grpSp":
                walk(n, titleBlocks: &titleBlocks, items: &items) // child offsets are in group space; close enough for ordering
            case "p:graphicFrame":
                guard let tbl = n.firstDescendant("a:tbl"), let t = table(tbl) else { continue }
                let f = n.child("p:xfrm").flatMap { x -> CGRect? in
                    guard let off = x.child("a:off"), let ox = OOXMLValue.double(off["x"]), let oy = OOXMLValue.double(off["y"]) else { return nil }
                    return CGRect(x: ox / 12700, y: oy / 12700, width: 0, height: 0)
                }
                items.append(Item(y: f.map { Double($0.minY) }, x: f.map { Double($0.minX) }, order: items.count, blocks: [.table(t)]))
            case "p:pic":
                guard let embed = n.firstDescendant("a:blip")?["r:embed"], let rel = rels[embed], !rel.external,
                      let data = try? zip.data(rel.target) else { continue }
                let frame = PptxParser.frame(n.child("p:spPr"))
                let alt = n.child("p:nvPicPr")?.child("p:cNvPr")?["descr"]
                if let img = OfficeImage.docImage(from: data, widthPt: frame.map { Double($0.width) }, heightPt: frame.map { Double($0.height) }, alt: alt) {
                    items.append(Item(y: frame.map { Double($0.minY) }, x: frame.map { Double($0.minX) }, order: items.count, blocks: [.image(img)]))
                }
            case "mc:AlternateContent":
                if let choice = n.child("mc:Choice") { walk(choice, titleBlocks: &titleBlocks, items: &items) }
            default:
                break
            }
        }
    }

    // MARK: Text

    private struct PPara { var runs: [DocRun]; var level: Int; var bullet: Bullet; var alignment: DocAlignment }
    private enum Bullet { case none, char, number(start: Int), inherit }

    private func paragraphsOf(_ body: XNode) -> [PPara] {
        body.children("a:p").map { p in
            let pPr = p.child("a:pPr")
            var bullet = Bullet.inherit
            if pPr?.child("a:buNone") != nil { bullet = .none }
            else if pPr?.child("a:buChar") != nil || pPr?.child("a:buBlip") != nil { bullet = .char }
            else if let num = pPr?.child("a:buAutoNum") { bullet = .number(start: OOXMLValue.clamp(OOXMLValue.int(num["startAt"]) ?? 1, 1, 32767)) }
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
        if let hex = rPr.child("a:solidFill")?.child("a:srgbClr")?["val"], hex.uppercased() != "000000" { run.color = DocColor(hex: hex) }
        if let hex = rPr.child("a:highlight")?.child("a:srgbClr")?["val"] { run.highlight = DocColor(hex: hex) }
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

    private func textBlocks(_ body: XNode, bulletsByDefault: Bool) -> [DocBlock] {
        var out: [DocBlock] = []
        var counters: [Int: Int] = [:]
        for p in paragraphsOf(body) {
            let para = DocParagraph(p.runs, alignment: p.alignment).normalized()
            if para.isEmpty { continue }
            switch p.bullet {
            case .char:
                out.append(.listItem(DocListItem(ordered: false, level: p.level, paragraph: para)))
            case .number(let start):
                let n = counters[p.level].map { $0 + 1 } ?? start
                counters[p.level] = n
                counters = counters.filter { $0.key <= p.level }
                out.append(.listItem(DocListItem(ordered: true, level: p.level, number: n, paragraph: para)))
            case .inherit where bulletsByDefault:
                out.append(.listItem(DocListItem(ordered: false, level: p.level, paragraph: para)))
            case .none, .inherit:
                out.append(.paragraph(para))
            }
        }
        return out
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
                let para = DocParagraph(p.runs).normalized()
                if !para.isEmpty { out.append(.quote(para)) }
            }
        }
        return out
    }
}
