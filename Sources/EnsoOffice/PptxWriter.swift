import Foundation
import CoreGraphics
import EnsoDoc

/// Images -> PresentationML (.pptx), one picture per slide, aspect-fitted and centred.
public enum PptxWriter {
    /// - Parameters:
    ///   - slideSize: points; clamped to PowerPoint's 1–56 inch range keeping the aspect ratio.
    ///   - notes: optional speaker notes per slide (index-aligned; missing or empty entries get none).
    public static func write(slides: [DocImage], slideSize: CGSize, notes: [String]? = nil, title: String? = nil, to url: URL) throws {
        try data(slides: slides, slideSize: slideSize, notes: notes, title: title).writeOffice(to: url)
    }

    public static func data(slides: [DocImage], slideSize: CGSize, notes: [String]? = nil, title: String? = nil) throws -> Data {
        guard !slides.isEmpty else { throw OfficeError.invalidArgument("a presentation needs at least one slide") }
        let (cx, cy) = slideEMU(slideSize)
        let notesText: [String] = (0..<slides.count).map { i in
            guard let n = notes, i < n.count else { return "" }
            return n[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let hasNotes = notesText.contains { !$0.isEmpty }

        // Media first so the content-type defaults are known.
        var media: [(name: String, data: Data, format: DocImageFormat, w: Int, h: Int)?] = []
        for (i, img) in slides.enumerated() {
            if let p = OfficeImage.prepare(img) {
                media.append(("image\(i + 1).\(p.format.fileExtension)", p.data, p.format, p.width, p.height))
            } else {
                media.append(nil) // undecodable image: the slide stays blank instead of failing the whole file
            }
        }

        let pml = "application/vnd.openxmlformats-officedocument.presentationml"
        var defaults: [(String, String)] = []
        if media.contains(where: { $0?.format == .png }) { defaults.append(("png", "image/png")) }
        if media.contains(where: { $0?.format == .jpeg }) { defaults.append(("jpeg", "image/jpeg")) }
        var overrides: [(String, String)] = [
            ("ppt/presentation.xml", "\(pml).presentation.main+xml"),
            ("ppt/slideMasters/slideMaster1.xml", "\(pml).slideMaster+xml"),
            ("ppt/slideLayouts/slideLayout1.xml", "\(pml).slideLayout+xml"),
            ("ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
            ("ppt/presProps.xml", "\(pml).presProps+xml"),
            ("ppt/viewProps.xml", "\(pml).viewProps+xml"),
            ("ppt/tableStyles.xml", "\(pml).tableStyles+xml"),
            ("docProps/core.xml", OPC.coreContentType),
            ("docProps/app.xml", OPC.appContentType),
        ]
        if hasNotes {
            overrides.append(("ppt/notesMasters/notesMaster1.xml", "\(pml).notesMaster+xml"))
            overrides.append(("ppt/theme/theme2.xml", "application/vnd.openxmlformats-officedocument.theme+xml"))
        }
        for i in slides.indices {
            overrides.append(("ppt/slides/slide\(i + 1).xml", "\(pml).slide+xml"))
            if !notesText[i].isEmpty { overrides.append(("ppt/notesSlides/notesSlide\(i + 1).xml", "\(pml).notesSlide+xml")) }
        }

        let zip = ZipWriter()
        try zip.add(path: "[Content_Types].xml", text: OPC.contentTypes(defaults: defaults, overrides: overrides))
        try zip.add(path: "_rels/.rels", text: OPC.packageRels(main: "ppt/presentation.xml"))
        try zip.add(path: "docProps/core.xml", text: OPC.coreProperties(title: title))
        try zip.add(path: "docProps/app.xml", text: OPC.appProperties(extra: "<Slides>\(slides.count)</Slides>"))

        // presentation.xml and its relationships
        var presRels = OPC.RelsBuilder()
        let masterRel = presRels.add(RelType.slideMaster, "slideMasters/slideMaster1.xml")
        let notesMasterRel = hasNotes ? presRels.add(RelType.notesMaster, "notesMasters/notesMaster1.xml") : nil
        var slideRels: [String] = []
        for i in slides.indices { slideRels.append(presRels.add(RelType.slide, "slides/slide\(i + 1).xml")) }
        _ = presRels.add(RelType.presProps, "presProps.xml")
        _ = presRels.add(RelType.viewProps, "viewProps.xml")
        _ = presRels.add(RelType.theme, "theme/theme1.xml")
        _ = presRels.add(RelType.tableStyles, "tableStyles.xml")

        var pres = xmlHeader + "<p:presentation \(ns) saveSubsetFonts=\"1\">"
        pres += "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"\(masterRel)\"/></p:sldMasterIdLst>"
        if let notesMasterRel { pres += "<p:notesMasterIdLst><p:notesMasterId r:id=\"\(notesMasterRel)\"/></p:notesMasterIdLst>" }
        pres += "<p:sldIdLst>" + slideRels.enumerated().map { "<p:sldId id=\"\(256 + $0.offset)\" r:id=\"\($0.element)\"/>" }.joined() + "</p:sldIdLst>"
        pres += "<p:sldSz cx=\"\(cx)\" cy=\"\(cy)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
        pres += "<p:defaultTextStyle><a:defPPr><a:defRPr lang=\"en-US\"/></a:defPPr></p:defaultTextStyle></p:presentation>"
        try zip.add(path: "ppt/presentation.xml", text: pres)
        try zip.add(path: "ppt/_rels/presentation.xml.rels", text: presRels.xml)

        try zip.add(path: "ppt/presProps.xml", text: xmlHeader + "<p:presentationPr \(ns)/>")
        try zip.add(path: "ppt/viewProps.xml", text: xmlHeader + "<p:viewPr \(ns)><p:normalViewPr><p:restoredLeft sz=\"15620\"/><p:restoredTop sz=\"94660\"/></p:normalViewPr><p:gridSpacing cx=\"76200\" cy=\"76200\"/></p:viewPr>")
        try zip.add(path: "ppt/tableStyles.xml", text: xmlHeader + "<a:tblStyleLst xmlns:a=\"\(NS.a)\" def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>")
        try zip.add(path: "ppt/theme/theme1.xml", text: theme)

        var masterRels = OPC.RelsBuilder()
        let layoutRel = masterRels.add(RelType.slideLayout, "../slideLayouts/slideLayout1.xml")
        _ = masterRels.add(RelType.theme, "../theme/theme1.xml")
        try zip.add(path: "ppt/slideMasters/slideMaster1.xml", text: slideMaster(layoutRel: layoutRel))
        try zip.add(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", text: masterRels.xml)

        var layoutRels = OPC.RelsBuilder()
        _ = layoutRels.add(RelType.slideMaster, "../slideMasters/slideMaster1.xml")
        try zip.add(path: "ppt/slideLayouts/slideLayout1.xml", text: slideLayout)
        try zip.add(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", text: layoutRels.xml)

        if hasNotes {
            var nmRels = OPC.RelsBuilder()
            _ = nmRels.add(RelType.theme, "../theme/theme2.xml")
            try zip.add(path: "ppt/notesMasters/notesMaster1.xml", text: notesMaster)
            try zip.add(path: "ppt/notesMasters/_rels/notesMaster1.xml.rels", text: nmRels.xml)
            try zip.add(path: "ppt/theme/theme2.xml", text: theme)
        }

        for (i, img) in slides.enumerated() {
            var rels = OPC.RelsBuilder()
            _ = rels.add(RelType.slideLayout, "../slideLayouts/slideLayout1.xml")
            var picture = ""
            if let m = media[i] {
                let rid = rels.add(RelType.image, "../media/\(m.name)")
                picture = pictureXML(rid: rid, imageW: m.w, imageH: m.h, slide: (cx, cy), alt: img.altText)
                try zip.add(path: "ppt/media/\(m.name)", data: m.data, compress: false)
            }
            if !notesText[i].isEmpty {
                _ = rels.add(RelType.notesSlide, "../notesSlides/notesSlide\(i + 1).xml")
                var nRels = OPC.RelsBuilder()
                _ = nRels.add(RelType.notesMaster, "../notesMasters/notesMaster1.xml")
                _ = nRels.add(RelType.slide, "../slides/slide\(i + 1).xml")
                try zip.add(path: "ppt/notesSlides/notesSlide\(i + 1).xml", text: notesSlide(notesText[i]))
                try zip.add(path: "ppt/notesSlides/_rels/notesSlide\(i + 1).xml.rels", text: nRels.xml)
            }
            try zip.add(path: "ppt/slides/slide\(i + 1).xml", text: slideXML(picture))
            try zip.add(path: "ppt/slides/_rels/slide\(i + 1).xml.rels", text: rels.xml)
        }
        return try zip.finalize()
    }

    // MARK: Geometry

    static let minEMU = 914_400, maxEMU = 51_206_400

    static func slideEMU(_ size: CGSize) -> (Int, Int) {
        var w = Double(size.width) * 12700, h = Double(size.height) * 12700
        if !(w > 0 && h > 0 && w.isFinite && h.isFinite) { w = 12_192_000; h = 6_858_000 }
        let up = max(1, Double(minEMU) / min(w, h))
        w *= up; h *= up
        let down = min(1, Double(maxEMU) / max(w, h))
        w *= down; h *= down
        return (min(max(Int(w.rounded()), minEMU), maxEMU), min(max(Int(h.rounded()), minEMU), maxEMU))
    }

    private static func pictureXML(rid: String, imageW: Int, imageH: Int, slide: (Int, Int), alt: String?) -> String {
        let sw = Double(slide.0), sh = Double(slide.1)
        let aspect = Double(imageW) / Double(max(imageH, 1))
        var w = sw, h = sw / aspect
        if h > sh { h = sh; w = sh * aspect }
        // Within 1%: fill exactly so rounding never leaves a hairline.
        if abs(w - sw) / sw < 0.01 && abs(h - sh) / sh < 0.01 { w = sw; h = sh }
        let x = Int(((sw - w) / 2).rounded()), y = Int(((sh - h) / 2).rounded())
        var s = "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Picture 1\" descr=\"\(XMLEsc.attr(alt ?? ""))\"/>"
        s += "<p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"
        s += "<p:blipFill><a:blip r:embed=\"\(rid)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
        s += "<p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(Int(w.rounded()))\" cy=\"\(Int(h.rounded()))\"/></a:xfrm>"
        s += "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
        return s
    }

    // MARK: Parts

    private static let ns = "xmlns:a=\"\(NS.a)\" xmlns:r=\"\(NS.r)\" xmlns:p=\"\(NS.p)\""
    private static let groupProps = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
    private static let clrMap = "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
    private static let textFonts = "<a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/>"

    private static func slideXML(_ picture: String) -> String {
        xmlHeader + "<p:sld \(ns)><p:cSld><p:spTree>\(groupProps)\(picture)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
    }

    private static func slideMaster(layoutRel: String) -> String {
        var s = xmlHeader + "<p:sldMaster \(ns)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>\(groupProps)</p:spTree></p:cSld>"
        s += clrMap
        s += "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"\(layoutRel)\"/></p:sldLayoutIdLst>"
        s += "<p:txStyles>"
        s += "<p:titleStyle><a:lvl1pPr algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\"><a:lnSpc><a:spcPct val=\"90000\"/></a:lnSpc><a:spcBef><a:spcPct val=\"0\"/></a:spcBef><a:buNone/><a:defRPr sz=\"4400\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mj-lt\"/><a:ea typeface=\"+mj-ea\"/><a:cs typeface=\"+mj-cs\"/></a:defRPr></a:lvl1pPr></p:titleStyle>"
        s += "<p:bodyStyle><a:lvl1pPr marL=\"228600\" indent=\"-228600\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\"><a:lnSpc><a:spcPct val=\"90000\"/></a:lnSpc><a:spcBef><a:spcPts val=\"1000\"/></a:spcBef><a:buFont typeface=\"Arial\"/><a:buChar char=\"\u{2022}\"/><a:defRPr sz=\"2800\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>\(textFonts)</a:defRPr></a:lvl1pPr></p:bodyStyle>"
        s += "<p:otherStyle><a:defPPr><a:defRPr lang=\"en-US\"/></a:defPPr><a:lvl1pPr marL=\"0\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\"><a:defRPr sz=\"1800\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>\(textFonts)</a:defRPr></a:lvl1pPr></p:otherStyle>"
        s += "</p:txStyles></p:sldMaster>"
        return s
    }

    private static let slideLayout = xmlHeader + "<p:sldLayout \(ns) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(groupProps)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"

    private static let notesMaster: String = {
        var s = xmlHeader + "<p:notesMaster \(ns)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>\(groupProps)"
        s += "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Slide Image Placeholder 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\" noRot=\"1\" noChangeAspect=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"sldImg\" idx=\"2\"/></p:nvPr></p:nvSpPr>"
        s += "<p:spPr><a:xfrm><a:off x=\"1143000\" y=\"685800\"/><a:ext cx=\"4572000\" cy=\"3429000\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln w=\"12700\"><a:solidFill><a:prstClr val=\"black\"/></a:solidFill></a:ln></p:spPr></p:sp>"
        s += "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Notes Placeholder 2\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"body\" sz=\"quarter\" idx=\"3\"/></p:nvPr></p:nvSpPr>"
        s += "<p:spPr><a:xfrm><a:off x=\"685800\" y=\"4400550\"/><a:ext cx=\"5486400\" cy=\"3600450\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>"
        s += "<p:txBody><a:bodyPr vert=\"horz\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\"/><a:lstStyle/><a:p><a:pPr lvl=\"0\"/><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody></p:sp>"
        s += "</p:spTree></p:cSld>\(clrMap)"
        s += "<p:notesStyle><a:lvl1pPr marL=\"0\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\"><a:defRPr sz=\"1200\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>\(textFonts)</a:defRPr></a:lvl1pPr></p:notesStyle>"
        return s + "</p:notesMaster>"
    }()

    private static func notesSlide(_ text: String) -> String {
        let lang = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) } ? "ja-JP" : "en-US"
        var paras = ""
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { paras += "<a:p><a:endParaRPr lang=\"\(lang)\" dirty=\"0\"/></a:p>"; continue }
            paras += "<a:p><a:r><a:rPr lang=\"\(lang)\" dirty=\"0\"/><a:t>\(XMLEsc.text(String(line)))</a:t></a:r></a:p>"
        }
        var s = xmlHeader + "<p:notes \(ns)><p:cSld><p:spTree>\(groupProps)"
        s += "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Slide Image Placeholder 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\" noRot=\"1\" noChangeAspect=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"sldImg\"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>"
        s += "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Notes Placeholder 2\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/>"
        s += "<p:txBody><a:bodyPr/><a:lstStyle/>\(paras)</p:txBody></p:sp>"
        return s + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"
    }

    private static let theme: String = {
        var s = xmlHeader + "<a:theme xmlns:a=\"\(NS.a)\" name=\"Office Theme\"><a:themeElements><a:clrScheme name=\"Office\">"
        s += "<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1><a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>"
        for (n, c) in [("dk2", "44546A"), ("lt2", "E7E6E6"), ("accent1", "4472C4"), ("accent2", "ED7D31"), ("accent3", "A5A5A5"),
                       ("accent4", "FFC000"), ("accent5", "5B9BD5"), ("accent6", "70AD47"), ("hlink", "0563C1"), ("folHlink", "954F72")] {
            s += "<a:\(n)><a:srgbClr val=\"\(c)\"/></a:\(n)>"
        }
        s += "</a:clrScheme><a:fontScheme name=\"Office\">"
        for f in ["majorFont", "minorFont"] {
            s += "<a:\(f)><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/><a:font script=\"Jpan\" typeface=\"Yu Gothic\"/></a:\(f)>"
        }
        s += "</a:fontScheme><a:fmtScheme name=\"Office\"><a:fillStyleLst>"
        s += "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"><a:tint val=\"50000\"/></a:schemeClr></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"><a:shade val=\"80000\"/></a:schemeClr></a:solidFill>"
        s += "</a:fillStyleLst><a:lnStyleLst>"
        for w in [6350, 12700, 19050] {
            s += "<a:ln w=\"\(w)\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
        }
        s += "</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
        s += "<a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"><a:tint val=\"95000\"/></a:schemeClr></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"><a:shade val=\"80000\"/></a:schemeClr></a:solidFill></a:bgFillStyleLst>"
        return s + "</a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
    }()
}
