import Foundation
import CoreGraphics
import EnsoDoc

/// DocModel -> WordprocessingML (.docx).
/// Element order inside pPr / rPr / tblPr / tcPr follows the schema sequence; Word reports
/// "unreadable content" when it does not.
public enum DocxWriter {
    public static func write(_ model: DocModel, to url: URL) throws {
        try data(model).writeOffice(to: url)
    }

    public static func data(_ model: DocModel) throws -> Data {
        let b = DocxBuilder(model: model)
        let body = b.body()

        let zip = ZipWriter()
        var defaults: [(String, String)] = []
        if b.media.contains(where: { $0.format == .png }) { defaults.append(("png", "image/png")) }
        if b.media.contains(where: { $0.format == .jpeg }) { defaults.append(("jpeg", "image/jpeg")) }
        let wml = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        try zip.add(path: "[Content_Types].xml", text: OPC.contentTypes(defaults: defaults, overrides: [
            ("word/document.xml", "\(wml).document.main+xml"),
            ("word/styles.xml", "\(wml).styles+xml"),
            ("word/numbering.xml", "\(wml).numbering+xml"),
            ("word/settings.xml", "\(wml).settings+xml"),
            ("docProps/core.xml", OPC.coreContentType),
            ("docProps/app.xml", OPC.appContentType),
        ]))
        try zip.add(path: "_rels/.rels", text: OPC.packageRels(main: "word/document.xml"))
        try zip.add(path: "docProps/core.xml", text: OPC.coreProperties(title: model.title))
        try zip.add(path: "docProps/app.xml", text: OPC.appProperties())
        try zip.add(path: "word/document.xml", text: b.documentXML(body: body))
        try zip.add(path: "word/styles.xml", text: b.stylesXML())
        try zip.add(path: "word/numbering.xml", text: b.numberingXML())
        try zip.add(path: "word/settings.xml", text: b.settingsXML())
        try zip.add(path: "word/_rels/document.xml.rels", text: b.rels.xml)
        for m in b.media {
            try zip.add(path: "word/media/\(m.name)", data: m.data, compress: false)
        }
        return try zip.finalize()
    }
}

private struct DocxMedia { let name: String; let data: Data; let format: DocImageFormat }

private final class DocxBuilder {
    let model: DocModel
    var rels = OPC.RelsBuilder()
    var media: [DocxMedia] = []

    // Page geometry in twips.
    let pageW: Int, pageH: Int, margin: Int
    var textWidth: Int { pageW - 2 * margin }
    var textHeight: Int { pageH - 2 * margin }

    let bodyHalfPoints: Int
    let bodyFonts: (latin: String, eastAsia: String)
    let hasJapanese: Bool

    private var linkIds: [String: String] = [:]
    private var drawingId = 0
    private var fontCache: [String: FontNameMapper.Family?] = [:]

    // Numbering: abstractNum 0 / num 1 are the shared bullet list; each ordered list gets its own pair.
    private var orderedLists: [(abstractId: Int, numId: Int, level: Int, start: Int)] = []
    private var bulletUsed = false
    static let bulletNumId = 1

    init(model: DocModel) {
        self.model = model
        let size = model.pageSize.flatMap { $0.width > 36 && $0.height > 36 && $0.width < 20000 && $0.height < 20000 ? $0 : nil } ?? DocModel.a4
        pageW = Int((size.width * 20).rounded())
        pageH = Int((size.height * 20).rounded())
        margin = min(1134, min(pageW, pageH) / 6) // 20 mm, smaller for tiny pages
        bodyHalfPoints = Int((min(max(model.bodyFontSize, 6), 72) * 2).rounded())

        var latin = "Arial", eastAsia = "Yu Gothic"
        if let name = model.bodyFontName, let found = FontNameMapper.family(for: name) {
            let fam = FontNameMapper.portable(found)
            if fam.isEastAsian { eastAsia = fam.name } else { latin = fam.name }
        }
        bodyFonts = (latin, eastAsia)
        hasJapanese = DocxBuilder.containsJapanese(model)
        _ = rels.add(RelType.styles, "styles.xml")
        _ = rels.add(RelType.numbering, "numbering.xml")
        _ = rels.add(RelType.settings, "settings.xml")
    }

    // MARK: Body

    func body() -> String {
        var out = ""
        var listStack: [(ordered: Bool, numId: Int)?] = []
        var pendingBreak = false
        var previousWasTable = false

        // The last page break is dropped: it would only produce an empty trailing page.
        var blocks = model.blocks
        while let last = blocks.last, case .pageBreak = last { blocks.removeLast() }

        for block in blocks {
            if case .listItem = block {} else { listStack.removeAll() }
            if case .pageBreak = block {
                if pendingBreak { out += "<w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>" }
                pendingBreak = true
                continue
            }
            let breakBefore = pendingBreak
            pendingBreak = false

            switch block {
            case .heading(let level, let p):
                let lvl = min(max(level, 1), 6)
                out += paragraph(p, style: "Heading\(lvl)", pageBreakBefore: breakBefore)
            case .paragraph(let p):
                let indent = p.indent.isFinite && p.indent > 0 ? min(Int((p.indent * 20).rounded()), textWidth * 3 / 4) : nil
                out += paragraph(p, style: nil, pageBreakBefore: breakBefore, indent: indent)
            case .quote(let p):
                out += paragraph(p, style: "Quote", pageBreakBefore: breakBefore)
            case .listItem(let item):
                let lvl = min(max(item.level, 0), 8)
                if listStack.count > lvl + 1 { listStack.removeLast(listStack.count - lvl - 1) }
                while listStack.count < lvl + 1 { listStack.append(nil) }
                let numId: Int
                if let cur = listStack[lvl], cur.ordered == item.ordered {
                    numId = cur.numId
                } else {
                    numId = item.ordered ? newOrderedList(level: lvl, start: max(item.number ?? 1, 0)) : bulletList()
                    listStack[lvl] = (item.ordered, numId)
                }
                out += paragraph(item.paragraph, style: "ListParagraph", pageBreakBefore: breakBefore, numPr: (numId, lvl))
            case .code(let text, _):
                out += codeBlock(text, pageBreakBefore: breakBefore)
            case .table(let t):
                if breakBefore { out += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
                else if previousWasTable { out += "<w:p><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:p>" } // keeps tables apart
                out += table(t)
            case .image(let img):
                out += imageParagraph(img, pageBreakBefore: breakBefore)
            case .horizontalRule:
                out += "<w:p><w:pPr>\(breakBefore ? "<w:pageBreakBefore/>" : "")<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"A6A6A6\"/></w:pBdr><w:spacing w:before=\"120\" w:after=\"240\"/><w:rPr><w:sz w:val=\"8\"/><w:szCs w:val=\"8\"/></w:rPr></w:pPr></w:p>"
            case .pageBreak:
                break
            }
            if case .table = block { previousWasTable = true } else { previousWasTable = false }
        }
        // Word always ends the body (and anything after a table) with a paragraph mark.
        if previousWasTable || out.isEmpty { out += "<w:p/>" }
        return out
    }

    func documentXML(body: String) -> String {
        var s = xmlHeader
        s += "<w:document xmlns:w=\"\(NS.w)\" xmlns:r=\"\(NS.r)\" xmlns:wp=\"\(NS.wp)\" xmlns:a=\"\(NS.a)\" xmlns:pic=\"\(NS.pic)\"><w:body>"
        s += body
        let orient = pageW > pageH ? " w:orient=\"landscape\"" : ""
        s += "<w:sectPr><w:pgSz w:w=\"\(pageW)\" w:h=\"\(pageH)\"\(orient)/>"
        s += "<w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\" w:header=\"\(margin / 2)\" w:footer=\"\(margin / 2)\" w:gutter=\"0\"/>"
        s += "<w:cols w:space=\"425\"/><w:docGrid w:linePitch=\"360\"/></w:sectPr>"
        return s + "</w:body></w:document>"
    }

    // MARK: Paragraphs

    private func pPr(style: String?, pageBreakBefore: Bool = false, numPr: (Int, Int)? = nil,
                     spacing: String? = nil, indent: Int? = nil, alignment: DocAlignment = .left) -> String {
        var s = ""
        if let style { s += "<w:pStyle w:val=\"\(style)\"/>" }
        if pageBreakBefore { s += "<w:pageBreakBefore/>" }
        if let (numId, lvl) = numPr { s += "<w:numPr><w:ilvl w:val=\"\(lvl)\"/><w:numId w:val=\"\(numId)\"/></w:numPr>" }
        if let spacing { s += spacing }
        if let indent { s += "<w:ind w:left=\"\(indent)\"/>" }
        switch alignment {
        case .left: break
        case .center: s += "<w:jc w:val=\"center\"/>"
        case .right: s += "<w:jc w:val=\"right\"/>"
        case .justify: s += "<w:jc w:val=\"both\"/>"
        }
        return s.isEmpty ? "" : "<w:pPr>\(s)</w:pPr>"
    }

    private func paragraph(_ p: DocParagraph, style: String?, pageBreakBefore: Bool = false, numPr: (Int, Int)? = nil,
                           spacing: String? = nil, indent: Int? = nil, forceBold: Bool = false) -> String {
        "<w:p>" + pPr(style: style, pageBreakBefore: pageBreakBefore, numPr: numPr, spacing: spacing,
                      indent: indent, alignment: p.alignment) + runs(p, forceBold: forceBold) + "</w:p>"
    }

    private func codeBlock(_ text: String, pageBreakBefore: Bool) -> String {
        var t = text
        while t.hasSuffix("\n") { t.removeLast() }
        let run = t.isEmpty ? "" : "<w:r>" + runContent(t) + "</w:r>"
        return "<w:p>" + pPr(style: "SourceCode", pageBreakBefore: pageBreakBefore) + run + "</w:p>"
    }

    // MARK: Runs

    private func runs(_ p: DocParagraph, forceBold: Bool) -> String {
        let list = p.normalized().runs
        var out = ""
        var i = 0
        while i < list.count {
            if let url = list[i].link.flatMap(sanitizedURL) {
                var group = ""
                while i < list.count, list[i].link.flatMap(sanitizedURL) == url {
                    group += run(list[i], forceBold: forceBold, isLink: true)
                    i += 1
                }
                out += "<w:hyperlink r:id=\"\(linkId(url))\" w:history=\"1\">\(group)</w:hyperlink>"
            } else {
                out += run(list[i], forceBold: forceBold, isLink: false)
                i += 1
            }
        }
        return out
    }

    private func run(_ r: DocRun, forceBold: Bool, isLink: Bool) -> String {
        guard !r.text.isEmpty else { return "" }
        var p = ""
        if isLink { p += "<w:rStyle w:val=\"Hyperlink\"/>" } else if r.code { p += "<w:rStyle w:val=\"VerbatimChar\"/>" }

        if r.code && isLink {
            p += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"
        } else if !r.code, let name = r.fontName, let found = family(name) {
            let fam = FontNameMapper.portable(found)
            if fam.isEastAsian {
                if fam.name != bodyFonts.eastAsia || fam.name != bodyFonts.latin {
                    let n = XMLEsc.attr(fam.name)
                    p += "<w:rFonts w:ascii=\"\(n)\" w:eastAsia=\"\(n)\" w:hAnsi=\"\(n)\"/>"
                }
            } else if fam.name != bodyFonts.latin {
                let n = XMLEsc.attr(fam.name)
                p += "<w:rFonts w:ascii=\"\(n)\" w:hAnsi=\"\(n)\" w:cs=\"\(n)\"/>"
            }
        }
        if r.bold || forceBold { p += "<w:b/><w:bCs/>" }
        if r.italic { p += "<w:i/><w:iCs/>" }
        if r.strikethrough { p += "<w:strike/>" }
        if r.code { p += "<w:noProof/>" }
        if let c = r.color, !c.isNearlyBlack, c.a > 0 { p += "<w:color w:val=\"\(c.hex)\"/>" }
        if let size = r.fontSize, size.isFinite, size > 0 {
            let hp = Int((min(max(size, 1), 1638) * 2).rounded())
            if hp != bodyHalfPoints { p += "<w:sz w:val=\"\(hp)\"/><w:szCs w:val=\"\(hp)\"/>" }
        }
        var shading: String?
        if let h = r.highlight, h.a > 0 {
            if let name = DocxBuilder.highlightName(h) { p += "<w:highlight w:val=\"\(name)\"/>" } else {
                shading = "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(h.hex)\"/>"
            }
        }
        if r.underline && !isLink { p += "<w:u w:val=\"single\"/>" }
        if let shading { p += shading }
        return "<w:r>" + (p.isEmpty ? "" : "<w:rPr>\(p)</w:rPr>") + runContent(r.text) + "</w:r>"
    }

    /// Run text with line breaks and tabs as their own elements.
    private func runContent(_ text: String) -> String {
        var out = ""
        var buf = ""
        func flush() {
            if !buf.isEmpty { out += "<w:t xml:space=\"preserve\">\(XMLEsc.text(buf))</w:t>"; buf = "" }
        }
        var lastWasCR = false
        for u in text.unicodeScalars {
            switch u {
            case "\r": flush(); out += "<w:br/>"; lastWasCR = true; continue
            case "\n": if !lastWasCR { flush(); out += "<w:br/>" }
            case "\u{0B}", "\u{2028}", "\u{2029}", "\u{85}": flush(); out += "<w:br/>"
            case "\t": flush(); out += "<w:tab/>"
            case "\u{0C}": flush(); out += "<w:br w:type=\"page\"/>"
            default: buf.unicodeScalars.append(u)
            }
            lastWasCR = false
        }
        flush()
        return out
    }

    private func family(_ name: String) -> FontNameMapper.Family? {
        if let cached = fontCache[name] { return cached }
        let f = FontNameMapper.family(for: name)
        fontCache[name] = f
        return f
    }

    private static let highlightPalette: [(String, String)] = [
        ("FFFF00", "yellow"), ("00FF00", "green"), ("00FFFF", "cyan"), ("FF00FF", "magenta"), ("0000FF", "blue"),
        ("FF0000", "red"), ("000080", "darkBlue"), ("008080", "darkCyan"), ("008000", "darkGreen"),
        ("800080", "darkMagenta"), ("800000", "darkRed"), ("808000", "darkYellow"), ("808080", "darkGray"),
        ("C0C0C0", "lightGray"), ("000000", "black"),
    ]

    static func highlightName(_ c: DocColor) -> String? { highlightPalette.first { $0.0 == c.hex }?.1 }

    // MARK: Hyperlinks

    private func sanitizedURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
        if s.lowercased().hasPrefix("www.") { s = "http://" + s }
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let scheme = s[..<colon].lowercased()
        guard ["http", "https", "mailto", "ftp", "tel", "file", "sms"].contains(scheme) else { return nil }
        // A '%' that does not start an escape would make the relationship target an invalid URI.
        s = s.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
        return s.addingPercentEncoding(withAllowedCharacters: DocxBuilder.urlAllowed)
    }

    /// RFC 3986 characters (plus '%' so existing escapes survive); everything else is percent-encoded.
    static let urlAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%")

    private func linkId(_ url: String) -> String {
        if let id = linkIds[url] { return id }
        let id = rels.add(RelType.hyperlink, url, external: true)
        linkIds[url] = id
        return id
    }

    // MARK: Tables

    /// Word cannot show tables wider than 63 columns; the overflow is folded into the last column.
    static let maxColumns = 63

    private static func limitColumns(_ t: DocTable) -> DocTable {
        guard t.columnCount > maxColumns else { return t }
        var out = t
        out.columnWidths = nil
        out.rows = t.rows.map { row in
            var cells: [DocTableCell] = []
            var col = 0
            for cell in row {
                let span = max(cell.colSpan, 1)
                if col + span <= maxColumns - 1 { cells.append(cell); col += span; continue }
                if col < maxColumns {
                    cells.append(DocTableCell(cell.paragraphs, colSpan: 1)); col = maxColumns
                } else if var last = cells.popLast() {
                    let text = ([last.text] + [cell.text]).filter { !$0.isEmpty }.joined(separator: "\t")
                    last.paragraphs = [DocParagraph(text: text)]
                    cells.append(last)
                }
            }
            return cells
        }
        return out
    }

    private func table(_ input: DocTable) -> String {
        let t = DocxBuilder.limitColumns(input)
        let rows = t.rows.filter { !$0.isEmpty }
        let n = max(t.columnCount, 1)
        guard !rows.isEmpty else { return "" }
        let widths = columnWidths(t, columns: n)

        var s = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(widths.reduce(0, +))\" w:type=\"dxa\"/>"
        s += "<w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map {
            "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"808080\"/>"
        }.joined() + "</w:tblBorders>"
        s += "<w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr>"
        s += "<w:tblGrid>" + widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"

        let headerRows = min(max(t.headerRows, 0), rows.count)
        for (ri, row) in rows.enumerated() {
            let isHeader = ri < headerRows
            s += "<w:tr>"
            if isHeader { s += "<w:trPr><w:tblHeader/></w:trPr>" }
            var col = 0
            for cell in row where col < n {
                let span = min(max(cell.colSpan, 1), n - col)
                s += tableCell(cell.paragraphs, width: widths[col..<(col + span)].reduce(0, +), span: span, header: isHeader)
                col += span
            }
            while col < n {
                s += tableCell([], width: widths[col], span: 1, header: isHeader)
                col += 1
            }
            s += "</w:tr>"
        }
        return s + "</w:tbl>"
    }

    private func tableCell(_ paragraphs: [DocParagraph], width: Int, span: Int, header: Bool) -> String {
        var s = "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
        if span > 1 { s += "<w:gridSpan w:val=\"\(span)\"/>" }
        if header { s += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/>" }
        s += "</w:tcPr>"
        let spacing = "<w:spacing w:before=\"40\" w:after=\"40\" w:line=\"240\" w:lineRule=\"auto\"/>"
        let paras = paragraphs.isEmpty ? [DocParagraph([])] : paragraphs
        for p in paras { s += paragraph(p, style: nil, spacing: spacing, forceBold: header) }
        return s + "</w:tc>"
    }

    /// Explicit relative widths when given, otherwise weighted by content length (like HTML auto layout).
    private func columnWidths(_ t: DocTable, columns n: Int) -> [Int] {
        var weights: [Double]
        if let w = t.columnWidths, w.count == n, w.allSatisfy({ $0 > 0 && $0.isFinite }) {
            weights = w
        } else {
            weights = Array(repeating: 3, count: n)
            for row in t.rows {
                var col = 0
                for cell in row where col < n {
                    if cell.colSpan <= 1 {
                        let len = cell.paragraphs.map { Double(TextWidth.columns($0.plainText)) }.max() ?? 0
                        weights[col] = max(weights[col], min(len, 40))
                    }
                    col += max(cell.colSpan, 1)
                }
            }
            weights = weights.map { $0.squareRoot() }
        }
        // Widths come from the file and can be anything finite (1e305 overflows the sums below), so only their
        // ratios are used: scale by the largest, drop non-finite values, and keep every column at a minimum width.
        weights = weights.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let top = weights.max() ?? 0
        weights = top > 0 ? weights.map { $0 / top } : Array(repeating: 1, count: n)
        let total = weights.reduce(0, +)
        let width = Double(max(textWidth, 100 * n))
        let minW = width * 0.4 / Double(n)
        var out = weights.map { max(minW, width * $0 / total) }
        let sum = out.reduce(0, +)
        if sum.isFinite, sum > 0 {
            let scale = width / sum
            out = out.map { $0 * scale }
        }
        return out.map { SafeInt.round($0, 100, 1_000_000_000) }
    }

    // MARK: Images

    private func imageParagraph(_ img: DocImage, pageBreakBefore: Bool) -> String {
        guard let prepared = OfficeImage.prepare(img) else {
            let alt = img.altText ?? ""
            return alt.isEmpty ? "" : paragraph(DocParagraph(text: alt), style: nil, pageBreakBefore: pageBreakBefore)
        }
        let name = "image\(media.count + 1).\(prepared.format.fileExtension)"
        media.append(DocxMedia(name: name, data: prepared.data, format: prepared.format))
        let rid = rels.add(RelType.image, "media/\(name)")
        drawingId += 1

        var w = img.displayWidth, h = img.displayHeight
        if !(w > 0 && h > 0 && w.isFinite && h.isFinite) {
            w = Double(prepared.width) * 0.75; h = Double(prepared.height) * 0.75
        }
        let maxW = Double(textWidth) / 20, maxH = Double(textHeight) / 20 * 0.95
        let scale = min(1, maxW / w, maxH / h)
        let cx = max(Int((w * scale * 12700).rounded()), 1), cy = max(Int((h * scale * 12700).rounded()), 1)
        let descr = XMLEsc.attr(img.altText ?? "")

        var s = "<w:p>" + pPr(style: nil, pageBreakBefore: pageBreakBefore) + "<w:r><w:drawing>"
        s += "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
        s += "<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
        s += "<wp:docPr id=\"\(drawingId)\" name=\"Picture \(drawingId)\" descr=\"\(descr)\"/>"
        s += "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
        s += "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
        s += "<pic:nvPicPr><pic:cNvPr id=\"\(drawingId)\" name=\"\(name)\" descr=\"\(descr)\"/><pic:cNvPicPr/></pic:nvPicPr>"
        s += "<pic:blipFill><a:blip r:embed=\"\(rid)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
        s += "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
        s += "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
        return s
    }

    // MARK: Numbering

    private func bulletList() -> Int { bulletUsed = true; return DocxBuilder.bulletNumId }

    private func newOrderedList(level: Int, start: Int) -> Int {
        let abstractId = orderedLists.count + 1
        let numId = orderedLists.count + 2
        orderedLists.append((abstractId, numId, level, start))
        return numId
    }

    func numberingXML() -> String {
        var s = xmlHeader + "<w:numbering xmlns:w=\"\(NS.w)\">"
        s += abstractNum(id: 0, ordered: false, startLevel: 0, start: 1)
        for l in orderedLists { s += abstractNum(id: l.abstractId, ordered: true, startLevel: l.level, start: l.start) }
        s += "<w:num w:numId=\"\(DocxBuilder.bulletNumId)\"><w:abstractNumId w:val=\"0\"/></w:num>"
        for l in orderedLists { s += "<w:num w:numId=\"\(l.numId)\"><w:abstractNumId w:val=\"\(l.abstractId)\"/></w:num>" }
        return s + "</w:numbering>"
    }

    private func abstractNum(id: Int, ordered: Bool, startLevel: Int, start: Int) -> String {
        var s = "<w:abstractNum w:abstractNumId=\"\(id)\">"
        s += String(format: "<w:nsid w:val=\"%08X\"/>", 0x2A6C_0000 + id)
        s += "<w:multiLevelType w:val=\"hybridMultilevel\"/>"
        let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
        let formats = ["decimal", "lowerLetter", "lowerRoman"]
        for lvl in 0..<9 {
            let left = 720 * (lvl + 1)
            s += "<w:lvl w:ilvl=\"\(lvl)\">"
            s += "<w:start w:val=\"\(lvl == startLevel ? start : 1)\"/>"
            if ordered {
                s += "<w:numFmt w:val=\"\(formats[lvl % 3])\"/><w:lvlText w:val=\"%\(lvl + 1).\"/><w:lvlJc w:val=\"left\"/>"
                s += "<w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr>"
            } else {
                s += "<w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(bullets[lvl % 3])\"/><w:lvlJc w:val=\"left\"/>"
                s += "<w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr>"
                s += "<w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\" w:hint=\"default\"/></w:rPr>"
            }
            s += "</w:lvl>"
        }
        return s + "</w:abstractNum>"
    }

    // MARK: Styles & settings

    func stylesXML() -> String {
        let body = bodyHalfPoints
        func hp(_ factor: Double) -> Int { Int((Double(body) * factor).rounded()) }
        let latin = XMLEsc.attr(bodyFonts.latin), ea = XMLEsc.attr(bodyFonts.eastAsia)
        let lang = hasJapanese ? "<w:lang w:val=\"en-US\" w:eastAsia=\"ja-JP\" w:bidi=\"ar-SA\"/>" : "<w:lang w:val=\"en-US\" w:bidi=\"ar-SA\"/>"
        let mono = "<w:rFonts w:ascii=\"Courier New\" w:eastAsia=\"MS Gothic\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"

        var s = xmlHeader + "<w:styles xmlns:w=\"\(NS.w)\" xmlns:r=\"\(NS.r)\">"
        s += "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"\(latin)\" w:eastAsia=\"\(ea)\" w:hAnsi=\"\(latin)\" w:cs=\"\(latin)\"/>"
        s += "<w:sz w:val=\"\(body)\"/><w:szCs w:val=\"\(body)\"/>\(lang)</w:rPr></w:rPrDefault>"
        s += "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"288\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"

        s += "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        s += "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/><w:uiPriority w:val=\"1\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"
        s += "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/><w:unhideWhenUsed/>"
        s += "<w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
        s += "<w:style w:type=\"numbering\" w:default=\"1\" w:styleId=\"NoList\"><w:name w:val=\"No List\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"

        s += "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"10\"/><w:qFormat/>"
        s += "<w:pPr><w:spacing w:after=\"240\" w:line=\"240\" w:lineRule=\"auto\"/><w:contextualSpacing/></w:pPr><w:rPr><w:b/><w:bCs/><w:kern w:val=\"28\"/><w:sz w:val=\"\(hp(2.3))\"/><w:szCs w:val=\"\(hp(2.3))\"/></w:rPr></w:style>"

        let headingSizes = [1.75, 1.45, 1.25, 1.1, 1.0, 1.0]
        for lvl in 1...6 {
            s += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(lvl)\"><w:name w:val=\"heading \(lvl)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/>"
            s += lvl == 1 ? "" : "<w:unhideWhenUsed/>"
            s += "<w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(lvl <= 2 ? 360 : 240)\" w:after=\"120\"/><w:outlineLvl w:val=\"\(lvl - 1)\"/></w:pPr>"
            s += "<w:rPr><w:b/><w:bCs/>\(lvl == 6 ? "<w:i/><w:iCs/>" : "")<w:sz w:val=\"\(hp(headingSizes[lvl - 1]))\"/><w:szCs w:val=\"\(hp(headingSizes[lvl - 1]))\"/></w:rPr></w:style>"
        }

        s += "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"29\"/><w:qFormat/>"
        s += "<w:pPr><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"BFBFBF\"/></w:pBdr><w:spacing w:before=\"120\" w:after=\"120\"/><w:ind w:left=\"567\" w:right=\"284\"/></w:pPr>"
        s += "<w:rPr><w:color w:val=\"404040\"/></w:rPr></w:style>"

        s += "<w:style w:type=\"paragraph\" w:styleId=\"SourceCode\"><w:name w:val=\"Source Code\"/><w:basedOn w:val=\"Normal\"/><w:uiPriority w:val=\"39\"/><w:qFormat/>"
        s += "<w:pPr><w:pBdr><w:top w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"D9D9D9\"/><w:left w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"D9D9D9\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"D9D9D9\"/><w:right w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"D9D9D9\"/></w:pBdr>"
        s += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F5F5F5\"/><w:spacing w:before=\"120\" w:after=\"200\" w:line=\"240\" w:lineRule=\"auto\"/><w:ind w:left=\"113\" w:right=\"113\"/></w:pPr>"
        s += "<w:rPr>\(mono)<w:noProof/><w:sz w:val=\"\(hp(0.9))\"/><w:szCs w:val=\"\(hp(0.9))\"/></w:rPr></w:style>"

        s += "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:uiPriority w:val=\"34\"/><w:qFormat/>"
        s += "<w:pPr><w:spacing w:after=\"60\"/><w:ind w:left=\"720\"/></w:pPr></w:style>"

        s += "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:basedOn w:val=\"DefaultParagraphFont\"/><w:uiPriority w:val=\"99\"/><w:unhideWhenUsed/>"
        s += "<w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"

        s += "<w:style w:type=\"character\" w:styleId=\"VerbatimChar\"><w:name w:val=\"Verbatim Char\"/><w:basedOn w:val=\"DefaultParagraphFont\"/><w:uiPriority w:val=\"39\"/>"
        s += "<w:rPr>\(mono)<w:noProof/><w:sz w:val=\"\(hp(0.9))\"/><w:szCs w:val=\"\(hp(0.9))\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/></w:rPr></w:style>"

        s += "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:basedOn w:val=\"TableNormal\"/><w:uiPriority w:val=\"39\"/>"
        s += "<w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr>"
        s += "<w:tblPr><w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map {
            "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
        }.joined() + "</w:tblBorders></w:tblPr></w:style>"

        return s + "</w:styles>"
    }

    func settingsXML() -> String {
        var s = xmlHeader + "<w:settings xmlns:w=\"\(NS.w)\">"
        s += "<w:zoom w:percent=\"100\"/><w:defaultTabStop w:val=\"720\"/>"
        s += "<w:characterSpacingControl w:val=\"\(hasJapanese ? "compressPunctuation" : "doNotCompress")\"/>"
        s += "<w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat>"
        return s + "</w:settings>"
    }

    private static func containsJapanese(_ model: DocModel) -> Bool {
        func jp(_ s: String) -> Bool {
            s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xFF66...0xFF9F).contains($0.value) }
        }
        if let t = model.title, jp(t) { return true }
        for b in model.blocks {
            switch b {
            case .heading(_, let p), .paragraph(let p), .quote(let p): if jp(p.plainText) { return true }
            case .listItem(let li): if jp(li.paragraph.plainText) { return true }
            case .code(let s, _): if jp(s) { return true }
            case .table(let t): if t.rows.contains(where: { $0.contains { jp($0.text) } }) { return true }
            default: break
            }
        }
        return false
    }
}

/// Display width in "columns": East Asian wide/fullwidth characters count as 2.
enum TextWidth {
    static func columns(_ s: String) -> Int {
        var n = 0
        for u in s.unicodeScalars { n += isWide(u.value) ? 2 : 1 }
        return n
    }

    static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
