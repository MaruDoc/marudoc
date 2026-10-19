import AppKit
import EnsoDoc

/// Turns an edited attributed string back into WordprocessingML body XML.
final class DocxBodyWriter {
    let w: String
    let namespaces: String
    let zip: ZipReader
    let mainPart: String
    var newMedia: [(id: String, target: String, data: Data)] = []

    private var pre: String { w.isEmpty ? "" : w + ":" }

    init(prefix: String, namespaces: String, zip: ZipReader, mainPart: String) {
        self.w = prefix
        self.namespaces = namespaces
        self.zip = zip
        self.mainPart = mainPart
    }

    // Element order the schema requires inside pPr / rPr (Word rejects files that break it).
    static let pPrOrder = ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl", "numPr", "suppressLineNumbers",
                           "pBdr", "shd", "tabs", "suppressAutoHyphens", "kinsoku", "wordWrap", "overflowPunct", "topLinePunct", "autoSpaceDE",
                           "autoSpaceDN", "bidi", "adjustRightInd", "snapToGrid", "spacing", "ind", "contextualSpacing", "mirrorIndents",
                           "suppressOverlap", "jc", "textDirection", "textAlignment", "textboxTightWrap", "outlineLvl", "divId", "cnfStyle",
                           "rPr", "sectPr", "pPrChange"]
    static let rPrOrder = ["rStyle", "rFonts", "b", "bCs", "i", "iCs", "caps", "smallCaps", "strike", "dstrike", "outline", "shadow", "emboss",
                           "imprint", "noProof", "snapToGrid", "vanish", "webHidden", "color", "spacing", "w", "kern", "position", "sz", "szCs",
                           "highlight", "u", "effect", "bdr", "shd", "fitText", "vertAlign", "rtl", "cs", "em", "lang", "eastAsianLayout",
                           "specVanish", "oMath"]

    // MARK: Body

    func body(from text: NSAttributedString) throws -> String {
        var out = ""
        let ns = text.string as NSString
        var loc = 0
        var group: (table: NSTextTable, ranges: [NSRange])?
        func flush() {
            if let g = group { out += tableXML(g.table, g.ranges, text) }
            group = nil
        }
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if pr.length == 0 { break }
            loc = NSMaxRange(pr)
            let ps = text.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
            if let block = ps?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                if group?.table !== block.table { flush(); group = (block.table, []) }
                group?.ranges.append(pr)
                continue
            }
            flush()
            out += paragraphXML(pr, text)
        }
        flush()
        return out
    }

    // MARK: Paragraphs

    func paragraphXML(_ pr: NSRange, _ text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var content = pr
        if content.length > 0 {
            let last = ns.character(at: NSMaxRange(content) - 1)
            if last == 0x0A || last == 0x2029 || last == 0x0D {
                // An unknown block element stored on the whole paragraph is written back as it was.
                if let raw = text.attribute(.docxRaw, at: NSMaxRange(content) - 1, effectiveRange: nil) as? String { return raw }
                content.length -= 1
            }
        }
        let ps = text.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
        let rawPPr = text.attribute(.docxPPr, at: pr.location, effectiveRange: nil) as? String
        let origSig = text.attribute(.docxPSig, at: pr.location, effectiveRange: nil) as? String
        let nowSig = DocxDocument.paragraphSignature(ps)

        var hasMarker = false
        if content.length > 0 {
            text.enumerateAttribute(.docxSynthetic, in: content) { v, r, _ in
                if v != nil, ns.substring(with: r) != "\u{0C}" { hasMarker = true }
            }
        }
        let pPr = paragraphProperties(raw: rawPPr, origSig: origSig, nowSig: nowSig, style: ps, hasMarker: hasMarker)
        return "<\(pre)p>" + pPr + runsXML(content, text) + "</\(pre)p>"
    }

    private func paragraphProperties(raw: String?, origSig: String?, nowSig: String, style: NSParagraphStyle?, hasMarker: Bool) -> String {
        let changed = origSig != nil && origSig != nowSig
        let dropNumbering = raw?.contains(":numPr") == true && !hasMarker && origSig != nil
        if let raw, !raw.isEmpty, !changed, !dropNumbering { return raw }
        if (raw ?? "").isEmpty, origSig != nil, !changed { return "" }

        let el = fragment(raw?.isEmpty == false ? raw! : "<\(pre)pPr/>") ?? XMLElement(name: "\(pre)pPr")
        if dropNumbering { remove(el, "numPr") }
        if changed || origSig == nil, let p = style {
            let o = Self.parse(origSig), n = Self.parse(nowSig)
            let all = origSig == nil
            if all || o[0] != n[0] {
                let jc: String = { switch p.alignment { case .center: return "center"; case .right: return "right"; case .justified: return "both"; default: return "left" } }()
                set(el, element("jc", ["val": jc]), order: Self.pPrOrder)
            }
            if all || o[1] != n[1] || o[2] != n[2] || o[3] != n[3] {
                var a = ["left": tw(p.headIndent), "right": tw(-min(0, p.tailIndent))]
                let delta = p.firstLineHeadIndent - p.headIndent
                if delta >= 0 { a["firstLine"] = tw(delta) } else { a["hanging"] = tw(-delta) }
                set(el, element("ind", a), order: Self.pPrOrder)
            }
            if all || o[4] != n[4] || o[5] != n[5] || o[6] != n[6] || o[7] != n[7] || o[8] != n[8] {
                let sp = child(el, "spacing") ?? element("spacing", [:])
                if all || o[4] != n[4] { setAttr(sp, "before", tw(p.paragraphSpacingBefore)); removeAttr(sp, "beforeLines") }
                if all || o[5] != n[5] { setAttr(sp, "after", tw(p.paragraphSpacing)); removeAttr(sp, "afterLines") }
                if all || o[6] != n[6] || o[7] != n[7] || o[8] != n[8] {
                    if p.minimumLineHeight > 0 && p.minimumLineHeight == p.maximumLineHeight {
                        setAttr(sp, "line", tw(p.minimumLineHeight)); setAttr(sp, "lineRule", "exact")
                    } else if p.minimumLineHeight > 0 {
                        setAttr(sp, "line", tw(p.minimumLineHeight)); setAttr(sp, "lineRule", "atLeast")
                    } else if p.lineHeightMultiple > 0 {
                        setAttr(sp, "line", String(SafeInt.round(Double(p.lineHeightMultiple * 240), 0, 1_000_000))); setAttr(sp, "lineRule", "auto")
                    }
                }
                set(el, sp, order: Self.pPrOrder)
            }
        }
        return el.childCount == 0 ? "" : el.xmlString(options: .nodeCompactEmptyElement)
    }

    // MARK: Runs

    private struct Piece { var kind: Kind; var text: String; var rPr: String; var link: String?
        enum Kind { case text, raw, image(NSTextAttachment) }
    }

    private func runsXML(_ range: NSRange, _ text: NSAttributedString) -> String {
        guard range.length > 0 else { return "" }
        let ns = text.string as NSString
        var pieces: [Piece] = []
        var lastRaw: String?
        text.enumerateAttributes(in: range) { attrs, r, _ in
            if attrs[.docxSynthetic] != nil { lastRaw = nil; return }
            if let raw = attrs[.docxRaw] as? String {
                if raw != lastRaw { pieces.append(Piece(kind: .raw, text: raw, rPr: "", link: nil)) }
                lastRaw = raw
                return
            }
            lastRaw = nil
            let s = ns.substring(with: r)
            if let att = attrs[.attachment] as? NSTextAttachment {
                for _ in 0..<s.utf16.count { pieces.append(Piece(kind: .image(att), text: "", rPr: rPr(attrs), link: nil)) }
                return
            }
            let rp = rPr(attrs)
            let link = attrs[.docxLinkID] as? String
            if let last = pieces.last, case .text = last.kind, last.rPr == rp, last.link == link {
                pieces[pieces.count - 1].text += s
            } else {
                pieces.append(Piece(kind: .text, text: s, rPr: rp, link: link))
            }
        }
        var out = ""
        var openLink: String?
        for p in pieces {
            if p.link != openLink {
                if openLink != nil { out += "</\(pre)hyperlink>" }
                if let l = p.link { out += "<\(pre)hyperlink r:id=\"\(XMLEsc.attr(l))\">" }
                openLink = p.link
            }
            switch p.kind {
            case .raw: out += p.text
            case .image(let att): out += imageRun(att, rPr: p.rPr)
            case .text: out += "<\(pre)r>" + p.rPr + contentXML(p.text) + "</\(pre)r>"
            }
        }
        if openLink != nil { out += "</\(pre)hyperlink>" }
        return out
    }

    private func contentXML(_ s: String) -> String {
        var out = "", buf = ""
        func flush() {
            if !buf.isEmpty { out += "<\(pre)t xml:space=\"preserve\">\(XMLEsc.text(buf))</\(pre)t>"; buf = "" }
        }
        for ch in s {
            switch ch {
            case "\t": flush(); out += "<\(pre)tab/>"
            case "\u{2028}", "\u{0B}": flush(); out += "<\(pre)br/>"
            case "\u{0C}": flush(); out += "<\(pre)br \(pre)type=\"page\"/>"
            case "\u{2011}": flush(); out += "<\(pre)noBreakHyphen/>"
            case "\u{00AD}": flush(); out += "<\(pre)softHyphen/>"
            case "\u{200B}": continue
            default: buf.append(ch)
            }
        }
        flush()
        return out
    }

    /// The run's rPr: original XML when the user didn't touch its look, otherwise the original with the changes applied.
    private func rPr(_ attrs: [NSAttributedString.Key: Any]) -> String {
        let raw = attrs[.docxRPr] as? String
        let origSig = attrs[.docxRSig] as? String
        let nowSig = DocxDocument.runSignature(attrs)
        if let raw, origSig == nil || origSig == nowSig { return raw }
        let o = Self.parse(origSig), n = Self.parse(nowSig)
        let all = origSig == nil
        let el = fragment(raw?.isEmpty == false ? raw! : "<\(pre)rPr/>") ?? XMLElement(name: "\(pre)rPr")
        let font = attrs[.font] as? NSFont
        let oldFont = o.count > 1 ? NSFont(name: o[0], size: CGFloat(Double(o[1]) ?? 10.5)) : nil
        if let font, all || o[0] != n[0] {
            let isBold = Self.isBold(font), wasBold = oldFont.map(Self.isBold) ?? false
            let isItalic = Self.isItalic(font), wasItalic = oldFont.map(Self.isItalic) ?? false
            if all || isBold != wasBold { if isBold { set(el, element("b", [:]), order: Self.rPrOrder) } else { remove(el, "b"); if !all { set(el, element("b", ["val": "0"]), order: Self.rPrOrder) } } }
            if all || isItalic != wasItalic { if isItalic { set(el, element("i", [:]), order: Self.rPrOrder) } else { remove(el, "i"); if !all { set(el, element("i", ["val": "0"]), order: Self.rPrOrder) } } }
        }
        if let font, all || o[1] != n[1] {
            let shrunk = (attrs[.baselineOffset] as? CGFloat ?? 0) != 0
            let size = shrunk ? font.pointSize / 0.65 : font.pointSize
            set(el, element("sz", ["val": String(SafeInt.round(Double(size * 2), 0, 1_000_000))]), order: Self.rPrOrder)
        }
        if !all && o[2] != n[2] || all && attrs[.foregroundColor] != nil {
            if let c = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                set(el, element("color", ["val": Self.hex(c)]), order: Self.rPrOrder)
            }
        }
        if !all && o[3] != n[3] {
            remove(el, "highlight")
            if let c = (attrs[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                set(el, element("shd", ["val": "clear", "color": "auto", "fill": Self.hex(c)]), order: Self.rPrOrder)
            } else { remove(el, "shd") }
        }
        if all || o[4] != n[4] {
            let u = (attrs[.underlineStyle] as? Int ?? 0) != 0
            if u { set(el, element("u", ["val": "single"]), order: Self.rPrOrder) } else if !all { set(el, element("u", ["val": "none"]), order: Self.rPrOrder) }
        }
        if all || o[5] != n[5] {
            let s = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
            if s { set(el, element("strike", [:]), order: Self.rPrOrder) } else { remove(el, "strike") }
        }
        return el.childCount == 0 ? "" : el.xmlString(options: .nodeCompactEmptyElement)
    }

    static func isBold(_ f: NSFont) -> Bool {
        let n = f.fontName.lowercased()
        return f.fontDescriptor.symbolicTraits.contains(.bold) || n.contains("bold") || n.contains("-w6") || n.contains("-w7") || n.contains("-w8") || n.contains("demibold") || n.contains("heavy") || n.contains("black")
    }

    static func isItalic(_ f: NSFont) -> Bool {
        f.fontDescriptor.symbolicTraits.contains(.italic) || f.fontDescriptor.matrix != nil
    }

    static func hex(_ c: NSColor) -> String {
        func b(_ v: CGFloat) -> Int { SafeInt.round(Double(v * 255), 0, 255) }
        return String(format: "%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }

    static func parse(_ sig: String?) -> [String] { (sig ?? "").components(separatedBy: "|") + Array(repeating: "", count: 10) }

    private func tw(_ points: CGFloat) -> String { String(SafeInt.round(Double(points * 20), -1_000_000_000, 1_000_000_000)) }

    // MARK: Images

    private func imageRun(_ att: NSTextAttachment, rPr: String) -> String {
        if let d = att as? DocxImageAttachment, let raw = d.runXML { return raw }
        guard let image = att.image ?? att.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return "" }
        let n = newMedia.count + 1
        let id = "rIdMaruDoc\(n)"
        let target = "media/marudoc_image\(n).png"
        newMedia.append((id, target, png))
        let size = att.bounds.size != .zero ? att.bounds.size : image.size
        let cx = SafeInt.round(Double(size.width * 12700), 0, 1_000_000_000), cy = SafeInt.round(Double(size.height * 12700), 0, 1_000_000_000)
        return """
        <\(pre)r>\(rPr)<\(pre)drawing><wp:inline distT="0" distB="0" distL="0" distR="0" xmlns:wp="\(NS.wp)"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(9000 + n)" name="Picture \(n)"/><a:graphic xmlns:a="\(NS.a)"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="\(NS.pic)"><pic:nvPicPr><pic:cNvPr id="0" name="image\(n).png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(id)" xmlns:r="\(NS.r)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></\(pre)drawing></\(pre)r>
        """
    }

    // MARK: Tables

    private func tableXML(_ table: NSTextTable, _ ranges: [NSRange], _ text: NSAttributedString) -> String {
        var order: [ObjectIdentifier] = []
        var cells: [ObjectIdentifier: (block: NSTextTableBlock, ranges: [NSRange])] = [:]
        for r in ranges {
            guard let ps = text.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle,
                  let b = ps.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first else { continue }
            let key = ObjectIdentifier(b)
            if cells[key] == nil { order.append(key); cells[key] = (b, []) }
            cells[key]?.ranges.append(r)
        }
        let docxTable = table as? DocxTable
        var xml = "<\(pre)tbl>"
        xml += docxTable?.tblPr ?? "<\(pre)tblPr><\(pre)tblW \(pre)w=\"0\" \(pre)type=\"auto\"/></\(pre)tblPr>"
        if let grid = docxTable?.tblGrid { xml += grid } else {
            xml += "<\(pre)tblGrid>" + String(repeating: "<\(pre)gridCol/>", count: max(1, table.numberOfColumns)) + "</\(pre)tblGrid>"
        }
        let byRow = Dictionary(grouping: order.compactMap { cells[$0] }, by: { $0.block.startingRow })
        for row in byRow.keys.sorted() {
            xml += "<\(pre)tr>" + (docxTable?.rowPr[row] ?? "")
            for cell in byRow[row]!.sorted(by: { $0.block.startingColumn < $1.block.startingColumn }) {
                xml += "<\(pre)tc>"
                if let tcPr = (cell.block as? DocxCellBlock)?.tcPr { xml += tcPr }
                else if cell.block.columnSpan > 1 { xml += "<\(pre)tcPr><\(pre)gridSpan \(pre)val=\"\(cell.block.columnSpan)\"/></\(pre)tcPr>" }
                let paras = cell.ranges.map { paragraphXML($0, text) }.joined()
                xml += paras.isEmpty ? "<\(pre)p/>" : paras
                xml += "</\(pre)tc>"
            }
            xml += "</\(pre)tr>"
        }
        return xml + "</\(pre)tbl>"
    }

    // MARK: XML editing

    private var scratchDocs: [XMLDocument] = []

    private func fragment(_ xml: String) -> XMLElement? {
        guard let doc = try? XMLDocument(xmlString: "<marudoc-root \(namespaces)>\(xml)</marudoc-root>", options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]),
              let el = doc.rootElement()?.elementKids.first else { return nil }
        scratchDocs.append(doc)   // keep the owning document alive while the element is edited
        return el
    }

    private func element(_ local: String, _ attrs: [String: String]) -> XMLElement {
        let e = XMLElement(name: pre + local)
        for (k, v) in attrs.sorted(by: { $0.key < $1.key }) {
            e.addAttribute(XMLNode.attribute(withName: pre + k, stringValue: v) as! XMLNode)
        }
        return e
    }

    private func child(_ parent: XMLElement, _ local: String) -> XMLElement? { parent.kid(local) }

    private func remove(_ parent: XMLElement, _ local: String) {
        for (i, c) in (parent.children ?? []).enumerated().reversed() where (c as? XMLElement)?.localName == local { parent.removeChild(at: i) }
    }

    private func setAttr(_ e: XMLElement, _ local: String, _ value: String) {
        if let a = e.attributes?.first(where: { $0.localName == local }) { a.stringValue = value }
        else { e.addAttribute(XMLNode.attribute(withName: pre + local, stringValue: value) as! XMLNode) }
    }

    private func removeAttr(_ e: XMLElement, _ local: String) {
        if let a = e.attributes?.first(where: { $0.localName == local }), let name = a.name { e.removeAttribute(forName: name) }
    }

    /// Replaces (or inserts) a child at the position the schema order requires.
    private func set(_ parent: XMLElement, _ child: XMLElement, order: [String]) {
        let local = child.localName ?? ""
        if child.parent === parent { return }
        if let i = (parent.children ?? []).firstIndex(where: { ($0 as? XMLElement)?.localName == local }) {
            parent.replaceChild(at: i, with: child)
            return
        }
        let rank = order.firstIndex(of: local) ?? order.count
        let kids = parent.children ?? []
        let at = kids.firstIndex { node in
            guard let e = node as? XMLElement, let r = order.firstIndex(of: e.localName ?? "") else { return false }
            return r > rank
        } ?? kids.count
        parent.insertChild(child, at: at)
    }
}
