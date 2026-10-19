import Foundation

/// What a .docx contains beyond what DocModel / a rich-text editor round-trips.
public struct DocxComplexity: Sendable, Equatable {
    public var hasImages = false
    public var hasTables = false
    public var hasHeadersOrFooters = false
    public var hasFootnotes = false
    public var hasComments = false
    public var hasTrackedChanges = false
    public var hasTextBoxesOrShapes = false
    /// Floating (anchored) pictures or shapes positioned relative to the page.
    public var hasFloatingObjects = false
    public var hasMultipleSections = false
    /// Fields other than hyperlinks (page numbers, dates, cross references) or a table of contents.
    public var hasFieldsOrTOC = false
    public var hasEquations = false
    /// Charts, SmartArt, OLE objects, embedded documents.
    public var hasEmbeddedObjects = false

    public init() {}

    /// No feature that a plain rich-text round trip would lose.
    public var isSimple: Bool { features.isEmpty }

    /// English names of the features present, in a stable order.
    public var features: [String] {
        var f: [String] = []
        if hasImages { f.append("images") }
        if hasTables { f.append("tables") }
        if hasHeadersOrFooters { f.append("headers/footers") }
        if hasFootnotes { f.append("footnotes") }
        if hasComments { f.append("comments") }
        if hasTrackedChanges { f.append("tracked changes") }
        if hasTextBoxesOrShapes { f.append("text boxes/shapes") }
        if hasFloatingObjects { f.append("floating objects") }
        if hasMultipleSections { f.append("multiple sections") }
        if hasFieldsOrTOC { f.append("fields/table of contents") }
        if hasEquations { f.append("equations") }
        if hasEmbeddedObjects { f.append("embedded objects") }
        return f
    }
}

public enum DocxInspector {
    public static func inspect(_ url: URL) throws -> DocxComplexity {
        try inspect(data: try Data.readOffice(url))
    }

    public static func inspect(data: Data) throws -> DocxComplexity {
        let zip = try ZipReader(data: data)
        let main = try OPC.mainPart(zip, fallback: "word/document.xml")
        let rels = Dictionary(try OPC.relationships(zip, for: main).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var c = DocxComplexity()

        var sections = 0
        var headerIds: [String] = []
        var vmlShapes = 0, vmlImages = 0
        var instr: String?
        var inInstrText = false
        try OOXMLSAX.run(try zip.data(main), part: main) { sax in
            sax.onStart = { tag, attrs in
                switch tag {
                case "a:blip": c.hasImages = true
                case "v:imagedata": c.hasImages = true; vmlImages += 1
                case "w:tbl": c.hasTables = true
                case "w:sectPr": sections += 1
                case "w:headerReference", "w:footerReference": if let id = attrs["r:id"] { headerIds.append(id) }
                case "w:footnoteReference", "w:endnoteReference": c.hasFootnotes = true
                case "w:commentRangeStart", "w:commentReference": c.hasComments = true
                case "w:ins", "w:del", "w:moveFrom", "w:moveTo", "w:rPrChange", "w:pPrChange", "w:sectPrChange",
                     "w:tblPrChange", "w:trPrChange", "w:tcPrChange", "w:numberingChange", "w:cellIns", "w:cellDel":
                    c.hasTrackedChanges = true
                case "w:txbxContent", "wps:wsp", "wpg:wgp", "wpc:wpc", "v:rect", "v:oval", "v:line", "v:roundrect",
                     "v:polyline", "v:group", "v:textbox":
                    c.hasTextBoxesOrShapes = true
                case "v:shape": vmlShapes += 1
                case "wp:anchor": c.hasFloatingObjects = true
                case "w:fldSimple":
                    if DocxInspector.isNonLinkField(attrs["w:instr"] ?? "") { c.hasFieldsOrTOC = true }
                case "w:fldChar":
                    if attrs["w:fldCharType"] == "begin" { instr = "" }
                    else if attrs["w:fldCharType"] == "separate" || attrs["w:fldCharType"] == "end" {
                        if let i = instr, DocxInspector.isNonLinkField(i) { c.hasFieldsOrTOC = true }
                        instr = nil
                    }
                case "w:docPartGallery":
                    if (attrs["w:val"] ?? "").lowercased().contains("table of contents") { c.hasFieldsOrTOC = true }
                case "w:instrText": inInstrText = true
                case "m:oMath", "m:oMathPara": c.hasEquations = true
                case "w:object", "w:altChunk", "w:control": c.hasEmbeddedObjects = true
                case "a:graphicData":
                    let uri = attrs["uri"] ?? ""
                    if uri.hasSuffix("/chart") || uri.hasSuffix("/diagram") || uri.contains("chartex") { c.hasEmbeddedObjects = true }
                default: break
                }
            }
            sax.onEnd = { tag in if tag == "w:instrText" { inInstrText = false } }
            sax.onText = { s in if inInstrText, instr != nil { instr? += s } }
        }
        if vmlShapes > vmlImages { c.hasTextBoxesOrShapes = true }
        c.hasMultipleSections = sections > 1

        // Word often keeps empty header parts around; only count ones with content.
        for id in Set(headerIds) {
            guard let rel = rels[id], let d = try? zip.data(rel.target), let root = try? XNode.parse(d, part: rel.target) else { continue }
            let text = root.allText("w:t").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || root.contains("w:drawing") || root.contains("w:pict") || root.contains("w:fldSimple") || root.contains("w:fldChar") {
                c.hasHeadersOrFooters = true
                break
            }
        }
        return c
    }

    static func isNonLinkField(_ instr: String) -> Bool {
        let t = instr.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return !t.isEmpty && !t.hasPrefix("HYPERLINK")
    }
}
