import Foundation
import CoreGraphics
import EnsoDoc

// Page layout of a Word document for the PDF renderer (DocModel.pageLayout, DocParagraph.format): sections with their
// page size, margins, document grid, headers and footers, and each paragraph's spacing, line spacing, indents and tab
// stops resolved from docDefaults, the style chain, numbering and direct formatting. The other writers ignore all of it.

/// A tab stop as stored: position in twips, `w:val`, `w:leader`.
struct DocxTab {
    var pos: Double
    var val: String
    var leader: String?
}

/// Paragraph properties as Word stores them (twips, 240ths of a line, hundredths of a character).
struct DocxParaProps {
    var before: Double?, after: Double?, beforeLines: Double?, afterLines: Double?
    var beforeAuto: Bool?, afterAuto: Bool?
    var line: Double?, lineRule: String?
    var left: Double?, right: Double?, firstLine: Double?, hanging: Double?
    var leftChars: Double?, rightChars: Double?, firstLineChars: Double?, hangingChars: Double?
    var tabs: [DocxTab]?
    var snapToGrid: Bool?, keepNext: Bool?, contextual: Bool?
    /// `w:pBdr` edges by name (top, left, bottom, right); width 0 = explicitly none.
    var borders: [String: DocBorders.Edge]?

    init() {}

    init(_ p: XNode) {
        if let s = p.child("w:spacing") {
            before = OOXMLValue.twips(s["w:before"]); after = OOXMLValue.twips(s["w:after"])
            beforeLines = OOXMLValue.double(s["w:beforeLines"]); afterLines = OOXMLValue.double(s["w:afterLines"])
            beforeAuto = s["w:beforeAutospacing"].map { OOXMLValue.onOff($0) }
            afterAuto = s["w:afterAutospacing"].map { OOXMLValue.onOff($0) }
            line = OOXMLValue.double(s["w:line"]); lineRule = s["w:lineRule"]
        }
        if let i = p.child("w:ind") {
            left = OOXMLValue.twips(i["w:left"] ?? i["w:start"]); right = OOXMLValue.twips(i["w:right"] ?? i["w:end"])
            firstLine = OOXMLValue.twips(i["w:firstLine"]); hanging = OOXMLValue.twips(i["w:hanging"])
            leftChars = OOXMLValue.double(i["w:leftChars"] ?? i["w:startChars"])
            rightChars = OOXMLValue.double(i["w:rightChars"] ?? i["w:endChars"])
            firstLineChars = OOXMLValue.double(i["w:firstLineChars"]); hangingChars = OOXMLValue.double(i["w:hangingChars"])
        }
        if let t = p.child("w:tabs") {
            tabs = t.children("w:tab").compactMap { tab in
                OOXMLValue.twips(tab["w:pos"]).map { DocxTab(pos: $0, val: tab["w:val"] ?? "left", leader: tab["w:leader"]) }
            }
        }
        if let b = p.child("w:pBdr") {
            var edges: [String: DocBorders.Edge] = [:]
            for k in b.children {
                let name = ["w:start": "left", "w:end": "right"][k.tag] ?? String(k.localName)
                guard ["top", "left", "bottom", "right"].contains(name) else { continue }
                let v = k["w:val"] ?? "single"
                let size = OOXMLValue.double(k["w:sz"]) ?? 4
                let color = k["w:color"].flatMap { $0 == "auto" ? nil : DocColor(hex: $0) }
                edges[name] = DocBorders.Edge(width: v == "nil" || v == "none" ? 0 : min(max(size, 2), 96) / 8,
                                              space: min(max(OOXMLValue.double(k["w:space"]) ?? 0, 0), 31), color: color)
            }
            borders = edges
        }
        snapToGrid = p.child("w:snapToGrid").map { OOXMLValue.onOff($0["w:val"]) }
        keepNext = p.child("w:keepNext").map { OOXMLValue.onOff($0["w:val"]) }
        contextual = p.child("w:contextualSpacing").map { OOXMLValue.onOff($0["w:val"]) }
    }

    /// `self` (the more specific level) over `base`, the way Word inherits: a length given in twips replaces the
    /// inherited one together with its character-unit twin, and the first-line / hanging group goes as a whole.
    func over(_ base: DocxParaProps) -> DocxParaProps {
        var r = base
        if before != nil || beforeLines != nil { r.before = before; r.beforeLines = beforeLines }
        if after != nil || afterLines != nil { r.after = after; r.afterLines = afterLines }
        r.beforeAuto = beforeAuto ?? base.beforeAuto
        r.afterAuto = afterAuto ?? base.afterAuto
        if line != nil { r.line = line; r.lineRule = lineRule ?? "auto" } else if let lr = lineRule { r.lineRule = lr }
        if left != nil { r.left = left; r.leftChars = leftChars } else if leftChars != nil { r.leftChars = leftChars }
        if right != nil { r.right = right; r.rightChars = rightChars } else if rightChars != nil { r.rightChars = rightChars }
        if firstLine != nil || hanging != nil || firstLineChars != nil || hangingChars != nil {
            r.firstLine = firstLine; r.hanging = hanging; r.firstLineChars = firstLineChars; r.hangingChars = hangingChars
        }
        if let own = tabs {
            // A stop at the same position replaces the inherited one; "clear" removes it.
            var merged = base.tabs ?? []
            for t in own {
                merged.removeAll { abs($0.pos - t.pos) < 1 }
                if t.val != "clear" { merged.append(t) }
            }
            r.tabs = merged
        }
        if let own = borders { r.borders = (base.borders ?? [:]).merging(own) { _, new in new } }
        r.snapToGrid = snapToGrid ?? base.snapToGrid
        r.keepNext = keepNext ?? base.keepNext
        r.contextual = contextual ?? base.contextual
        return r
    }
}

extension DocxParser {

    // MARK: Sections

    /// The section properties in body order: those closing a section inside a paragraph, then the body's own.
    func sectionNodes(_ body: XNode) -> [XNode] {
        var out: [XNode] = []
        for c in blockChildren(body) {
            if c.tag == "w:p", let s = c.child("w:pPr")?.child("w:sectPr") { out.append(s) }
            if c.tag == "w:sectPr" { out.append(c) }
        }
        return out
    }

    /// Page size, margins, grid and numbering of one section (headers and footers come later, in `finishLayout`).
    func sectionGeometry(_ s: XNode) -> DocSection {
        var sec = DocSection()
        if let pg = s.child("w:pgSz"), let w = OOXMLValue.twips(pg["w:w"]), let h = OOXMLValue.twips(pg["w:h"]),
           (1440...115_200).contains(w), (1440...115_200).contains(h) {
            sec.width = w / 20; sec.height = h / 20
        }
        if let m = s.child("w:pgMar") {
            func pt(_ key: String, _ fallback: Double) -> Double { OOXMLValue.twips(m[key]).map { abs($0) / 20 } ?? fallback }
            sec.top = pt("w:top", 72); sec.bottom = pt("w:bottom", 72)
            sec.left = pt("w:left", 72) + pt("w:gutter", 0); sec.right = pt("w:right", 72)
            sec.headerDistance = pt("w:header", 36); sec.footerDistance = pt("w:footer", 36)
        }
        // Margins that leave no room for text fall back to Word's defaults.
        if sec.width - sec.left - sec.right < 36 { sec.left = min(72, sec.width / 4); sec.right = sec.left }
        if sec.height - sec.top - sec.bottom < 36 { sec.top = min(72, sec.height / 4); sec.bottom = sec.top }
        sec.headerDistance = min(sec.headerDistance, sec.height / 3)
        sec.footerDistance = min(sec.footerDistance, sec.height / 3)
        if let g = s.child("w:docGrid"), ["lines", "linesAndChars", "snapToChars"].contains(g["w:type"] ?? ""),
           let pitch = OOXMLValue.twips(g["w:linePitch"]), pitch >= 40, pitch <= 2000 {
            sec.linePitch = pitch / 20
        }
        sec.titlePage = s.child("w:titlePg").map { OOXMLValue.onOff($0["w:val"]) } ?? false
        if let n = s.child("w:pgNumType") {
            sec.pageNumberStart = OOXMLValue.int(n["w:start"]).map { OOXMLValue.clamp($0, 0, 1_000_000) }
            sec.pageNumberFormat = n["w:fmt"]
        }
        return sec
    }

    /// settings.xml: the default tab interval and whether even pages have their own header.
    func readLayoutSettings(_ relList: [OPCRelationship]) {
        guard let st = relList.first(where: { $0.isType("settings") }), let d = try? zip.data(st.target),
              let root = try? XNode.parse(d, part: st.target) else { return }
        if let t = OOXMLValue.twips(root.child("w:defaultTabStop")?["w:val"]), t >= 20, t <= 20 * 720 { defaultTabStop = t / 20 }
        evenAndOddHeaders = root.child("w:evenAndOddHeaders").map { OOXMLValue.onOff($0["w:val"]) } ?? false
    }

    /// The sections with where they start in the blocks and their headers and footers. A section without its own
    /// header or footer of a kind shows the previous section's, as in Word.
    func finishLayout(_ sectNodes: [XNode]) -> DocPageLayout {
        var sections = layoutSections.isEmpty ? [DocSection()] : layoutSections
        for i in sections.indices { sections[i].firstBlock = i < sectionStarts.count ? sectionStarts[i] : blocks.count }
        var parsed: [String: [DocBlock]] = [:]
        var headers: [DocHeaderKind: [DocBlock]] = [:], footers: [DocHeaderKind: [DocBlock]] = [:]
        for (i, node) in sectNodes.enumerated() where i < sections.count {
            sectionIndex = i
            for (tag, isHeader) in [("w:headerReference", true), ("w:footerReference", false)] {
                for ref in node.children(tag) {
                    guard let kind = DocHeaderKind(rawValue: ref["w:type"] ?? "default"), let id = ref["r:id"],
                          let rel = rels[id], !rel.external else { continue }
                    let content = parsed[rel.target] ?? headerFooterBlocks(rel.target)
                    parsed[rel.target] = content
                    if isHeader { headers[kind] = content } else { footers[kind] = content }
                }
            }
            sections[i].headers = headers
            sections[i].footers = footers
        }
        return DocPageLayout(sections: sections, defaultTabStop: defaultTabStop, evenAndOddHeaders: evenAndOddHeaders)
    }

    /// A header or footer part as blocks, read like the body with the part's own relationships. Page fields become
    /// DocField placeholders. Pictures are left out: floating logos would be placed as blocks and push the text down.
    func headerFooterBlocks(_ path: String) -> [DocBlock] {
        guard zip.contains(path), let d = try? zip.data(path), let root = try? XNode.parse(d, part: path) else { return [] }
        var partRels: [String: OPCRelationship] = [:]
        for r in (try? OPC.relationships(zip, for: path)) ?? [] { partRels[r.id] = r }
        let saved = (rels, fieldStack, counters, pendingEmpty, titleFromStyle)
        rels = partRels; fieldStack = []; pendingEmpty = []; readingHeaderFooter = true
        var out: [DocBlock] = []
        for c in blockChildren(root) { readBlock(c, into: &out) }
        (rels, fieldStack, counters, pendingEmpty, titleFromStyle) = saved
        readingHeaderFooter = false
        return out.compactMap { b -> DocBlock? in
            switch b {
            case .image: return nil
            case .table(var t):
                t.rows = t.rows.map { $0.map { cell in
                    var c = cell
                    c.paragraphs = c.paragraphs.map { p in var q = p; q.runs = p.runs.filter { $0.image == nil }; return q }
                    return c
                } }
                return .table(t)
            default: return b
            }
        }
    }

    static func pageFieldToken(_ instr: String) -> Character? {
        let word = instr.trimmingCharacters(in: .whitespaces).split(separator: " ").first?.uppercased()
        switch word {
        case "PAGE": return DocField.page
        case "NUMPAGES": return DocField.numPages
        case "SECTIONPAGES": return DocField.sectionPages
        default: return nil
        }
    }

    // MARK: Paragraphs

    /// docDefaults and the style chain, most general first.
    func styleParaProps(_ id: String?) -> DocxParaProps {
        let key = id ?? ""
        if let hit = paraCache[key] { return hit }
        let r = (id.map { chain($0) } ?? []).reversed().reduce(defaultsPara) { $1.para.over($0) }
        paraCache[key] = r
        return r
    }

    /// The paragraph's layout in points: defaults, style, numbering level, then direct formatting.
    func paragraphFormat(_ pPr: XNode?, styleId: String?, kind: ParaKind) -> DocParagraphFormat {
        var props = styleParaProps(styleId)
        if case .list(_, let level, let numId) = kind, let lp = numLevel(numId: numId, ilvl: level)?.para { props = lp.over(props) }
        if let pPr { props = DocxParaProps(pPr).over(props) }
        let section = sectionIndex < layoutSections.count ? layoutSections[sectionIndex] : layoutSections.last
        let pitch = section?.linePitch
        // Character units (leftChars …) count the paragraph's font size.
        let unit = pPr?.child("w:rPr").flatMap { runProps($0).size } ?? styleId.flatMap { resolvedRun(style: $0).size } ?? bodySize

        var f = DocParagraphFormat()
        f.markFontSize = unit
        // "Lines" for spacing are grid lines, 12 pt without a grid; auto spacing is Word's 14 pt.
        let lineUnit = pitch ?? 12
        if props.beforeAuto == true { f.spaceBefore = 14 }
        else { f.spaceBefore = props.beforeLines.flatMap { $0 != 0 ? $0 / 100 * lineUnit : nil } ?? (props.before ?? 0) / 20 }
        if props.afterAuto == true { f.spaceAfter = 14 }
        else { f.spaceAfter = props.afterLines.flatMap { $0 != 0 ? $0 / 100 * lineUnit : nil } ?? (props.after ?? 0) / 20 }
        f.spaceBefore = min(max(f.spaceBefore, 0), 1584); f.spaceAfter = min(max(f.spaceAfter, 0), 1584)

        if let line = props.line, line > 0 {
            switch props.lineRule ?? "auto" {
            case "exact": f.lineSpacing = .exactly(min(line / 20, 1584))
            case "atLeast": f.lineSpacing = .atLeast(min(line / 20, 1584))
            default: f.lineSpacing = .multiple(min(line / 240, 20))
            }
        }

        // Word writes indents twice, in twips and in characters, and the two can disagree (r05: left 6930 twips with
        // leftChars 1000). The twips value is used when there is one, as Pages and LibreOffice do; characters
        // only when it is missing.
        func chars(_ c: Double?, _ tw: Double?) -> Double? {
            if let tw { return tw / 20 }
            return c.map { $0 / 100 * unit }
        }
        f.leftIndent = chars(props.leftChars, props.left) ?? 0
        f.rightIndent = chars(props.rightChars, props.right) ?? 0
        if let h = chars(props.hangingChars, props.hanging) { f.firstLineIndent = -h }
        else if let fl = chars(props.firstLineChars, props.firstLine) { f.firstLineIndent = fl }
        f.leftIndent = min(max(f.leftIndent, -1584), 1584)
        f.rightIndent = min(max(f.rightIndent, -1584), 1584)
        f.firstLineIndent = min(max(f.firstLineIndent, -1584), 1584)

        f.tabStops = (props.tabs ?? []).compactMap { t -> DocTabStop? in
            let align: DocTabStop.Alignment
            switch t.val {
            case "center": align = .center
            case "right", "end": align = .right
            case "decimal": align = .decimal
            case "left", "start", "num": align = .left
            default: return nil // bar, clear
            }
            let leader: DocTabStop.Leader
            switch t.leader {
            case "dot": leader = .dot
            case "hyphen": leader = .hyphen
            case "underscore", "heavy": leader = .underscore
            case "middleDot": leader = .middleDot
            default: leader = .none
            }
            return DocTabStop(position: min(max(t.pos / 20, 0), 1584), alignment: align, leader: leader)
        }.sorted { $0.position < $1.position }
        if let e = props.borders {
            func edge(_ n: String) -> DocBorders.Edge? { e[n].flatMap { $0.width > 0 ? $0 : nil } }
            let b = DocBorders(top: edge("top"), left: edge("left"), bottom: edge("bottom"), right: edge("right"))
            if !b.isEmpty { f.borders = b }
        }
        f.snapToGrid = props.snapToGrid ?? true
        f.keepWithNext = props.keepNext ?? false
        if props.contextual == true { f.contextualStyle = styleId ?? "" }
        return f
    }
}

extension DocxParser {
    /// Rough height of an empty paragraph, for blank lines under a floating box (`floatingReserve`).
    func emptyParagraphHeight(_ f: DocParagraphFormat) -> Double {
        let size = f.markFontSize ?? bodySize
        let pitch = sectionIndex < layoutSections.count ? layoutSections[sectionIndex].linePitch : nil
        let line: Double
        switch f.lineSpacing {
        case .exactly(let h): line = h
        case .atLeast(let h): line = max(h, size * 1.2)
        case .multiple(let m): line = (pitch.map { max($0, size * 1.2) } ?? size * 1.2) * m
        }
        return line + max(f.spaceBefore, f.spaceAfter)
    }
}

extension DocxParser {
    /// In a header or footer, a text box placed centred or at the right (a page number box) takes its paragraphs
    /// there: the box itself is not drawn, its text is. Elsewhere the blocks are returned unchanged.
    func alignedForHeader(_ blocks: [DocBlock], _ align: String?) -> [DocBlock] {
        guard readingHeaderFooter, let align else { return blocks }
        let target: DocAlignment
        switch align {
        case "center": target = .center
        case "right", "outside": target = .right
        default: return blocks
        }
        return blocks.map { b in
            // Justified (the Normal style of Japanese documents) sets a one-line page number at the left too.
            if case .paragraph(var p) = b, p.alignment == .left || p.alignment == .justify { p.alignment = target; return .paragraph(p) }
            return b
        }
    }

    /// `mso-position-horizontal` of a VML shape style ("center", "right", …).
    static func vmlHorizontalAlign(_ style: String) -> String? {
        for decl in style.split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == "mso-position-horizontal" { return kv[1] }
        }
        return nil
    }
}

extension DocxParser {
    /// The outline of a DrawingML text box (`wps:wsp`): its `a:ln`, or the theme line its style refers to; nil when
    /// the box has no visible outline.
    static func textBoxOutline(_ shape: XNode) -> DocBorders.Edge? {
        if let ln = shape.child("wps:spPr")?.child("a:ln") {
            if ln.child("a:noFill") != nil { return nil }
            let width = OOXMLValue.double(ln["w"]).map { $0 / 12700 } ?? 0.75
            let color = ln.child("a:solidFill")?.child("a:srgbClr")?["val"].flatMap { DocColor(hex: $0) }
            return DocBorders.Edge(width: min(max(width, 0.25), 6), space: 4, color: color)
        }
        if let idx = shape.child("wps:style")?.child("a:lnRef")?["idx"], idx != "0" { return DocBorders.Edge(width: 0.75, space: 4) }
        return nil
    }

    /// The outline of a VML text box (`v:shape`): none when `stroked="f"`, else its stroke weight.
    static func vmlOutline(_ shape: XNode) -> DocBorders.Edge? {
        if let s = shape["stroked"]?.lowercased(), s == "f" || s == "false" { return nil }
        let weight = shape["strokeweight"].flatMap { w -> Double? in
            let t = w.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("pt") { return OOXMLValue.double(String(t.dropLast(2))) }
            return OOXMLValue.twips(t).map { $0 / 20 }
        } ?? 0.75
        return DocBorders.Edge(width: min(max(weight, 0.25), 6), space: 4)
    }

    /// Text box content placed in the text flow, framed like the box when the box has an outline.
    func framed(_ blocks: [DocBlock], _ edge: DocBorders.Edge?) -> [DocBlock] {
        guard let edge else { return blocks }
        boxGroup += 1
        let b = DocBorders(top: edge, left: edge, bottom: edge, right: edge, group: boxGroup)
        func frame(_ p: DocParagraph) -> DocParagraph {
            var q = p
            if var f = q.format, f.borders == nil { f.borders = b; q.format = f }
            return q
        }
        return blocks.map { block in
            switch block {
            case .paragraph(let p): return .paragraph(frame(p))
            case .heading(let l, let p): return .heading(level: l, frame(p))
            case .quote(let p): return .quote(frame(p))
            case .listItem(var li): li.paragraph = frame(li.paragraph); return .listItem(li)
            default: return block
            }
        }
    }
}

extension DocxParser {
    /// An EMF picture, which macOS cannot decode: played by EMFPlayer (the slide renderer's player) into a one-page
    /// PDF that the PDF renderer draws as vectors, and into a PNG (2 px per point, at most 2400 px) for the outputs
    /// that carry pictures as bitmaps. nil when the data is not an EMF the player can play (WMF, EMF+ only, broken).
    static func metafileImage(_ data: Data, widthPt: Double?, heightPt: Double?, alt: String?) -> DocImage? {
        var w = widthPt ?? 0, h = heightPt ?? 0
        if !(w > 0 && h > 0 && w.isFinite && h.isFinite) {
            // No frame in the document: the EMF header's own frame (rclFrame, hundredths of a millimetre).
            let b = [UInt8](data.prefix(40))
            guard b.count >= 40 else { return nil }
            func i32(_ o: Int) -> Double { Double(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)) }
            w = (i32(32) - i32(24)) / 100 / 25.4 * 72
            h = (i32(36) - i32(28)) / 100 / 25.4 * 72
        }
        guard w >= 1, h >= 1, w <= 14_400, h <= 14_400 else { return nil }
        let frame = CGRect(x: 0, y: 0, width: w, height: h)

        // Vector: one PDF page the size of the picture, y axis down as EMFPlayer expects.
        let pdf = NSMutableData()
        var box = frame
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let drawn = EMFPlayer.draw(data, in: frame, crop: (0, 0, 0, 0), ctx: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        guard drawn else { return nil }

        // Bitmap for Word, Markdown, HTML and RTF output.
        let scale = min(2, 2400 / max(w, h))
        let pw = max(1, Int((w * scale).rounded())), ph = max(1, Int((h * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.translateBy(x: 0, y: CGFloat(ph))
        bitmap.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        _ = EMFPlayer.draw(data, in: frame, crop: (0, 0, 0, 0), ctx: bitmap)
        guard let cg = bitmap.makeImage(), let png = ImageCodec.encode(cg, as: .png) else { return nil }
        let altText = alt?.trimmingCharacters(in: .whitespacesAndNewlines)
        var img = DocImage(data: png, format: .png, pixelWidth: pw, pixelHeight: ph, displayWidth: w, displayHeight: h,
                           altText: (altText?.isEmpty ?? true) ? nil : altText)
        img.vectorPDF = pdf as Data
        return img
    }
}
