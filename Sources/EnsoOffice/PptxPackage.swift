import Foundation
import CoreGraphics
import ImageIO
import EnsoDoc

/// Read-only access to the parts of a .pptx that the slide renderer needs, with each part parsed once.
final class PptxPackage {
    let zip: ZipReader
    let main: String
    let presentation: XNode
    /// Slide size in points (EMU / 12700).
    let slideSize: CGSize
    /// Every slide in presentation order, hidden ones included (their numbers still count).
    let slides: [Entry]
    let defaultTextStyle: XNode?
    let tableStyles: XNode?

    struct Entry {
        let part: String
        /// The number PowerPoint shows for the slide (sldNum fields): position plus firstSlideNum - 1.
        let number: Int
        let hidden: Bool
    }

    private var xmlCache: [String: XNode] = [:]
    private var missing: Set<String> = []
    private var relsCache: [String: [String: OPCRelationship]] = [:]
    private var themeCache: [String: DrawingTheme] = [:]
    private var imageCache: [String: CGImage] = [:]
    private var badImages: Set<String> = []

    init(data: Data) throws {
        zip = try ZipReader(data: data)
        main = try OPC.mainPart(zip, fallback: "ppt/presentation.xml")
        presentation = try XNode.parse(try zip.data(main), part: main)
        guard presentation.tag == "p:presentation" else { throw OfficeError.invalidDocument("\(main) is not a PowerPoint presentation") }
        let size = presentation.child("p:sldSz")
        let cx = OOXMLValue.double(size?["cx"]) ?? 9_144_000, cy = OOXMLValue.double(size?["cy"]) ?? 6_858_000
        // Slide sizes outside PowerPoint's own limits (1 inch .. 56 inches) are clamped.
        slideSize = CGSize(width: min(max(cx, 914_400), 51_206_400) / 12700, height: min(max(cy, 914_400), 51_206_400) / 12700)
        defaultTextStyle = presentation.child("p:defaultTextStyle")

        let rels = Dictionary(try OPC.relationships(zip, for: main).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let first = OOXMLValue.int(presentation["firstSlideNum"]) ?? 1
        var list: [Entry] = []
        var position = 0
        for sld in presentation.child("p:sldIdLst")?.children("p:sldId") ?? [] {
            guard let id = sld["r:id"], let rel = rels[id], !rel.external, zip.contains(rel.target) else { continue }
            position += 1
            list.append(Entry(part: rel.target, number: position + first - 1, hidden: !OOXMLValue.onOff(sld["show"] ?? "1")))
        }
        slides = list
        if let ts = rels.values.first(where: { $0.isType("tableStyles") }), zip.contains(ts.target) {
            tableStyles = try? XNode.parse(try zip.data(ts.target), part: ts.target)
        } else { tableStyles = nil }
    }

    func xml(_ part: String) -> XNode? {
        if let x = xmlCache[part] { return x }
        if missing.contains(part) { return nil }
        guard zip.contains(part), let d = try? zip.data(part), let x = try? XNode.parse(d, part: part) else {
            missing.insert(part); return nil
        }
        xmlCache[part] = x
        return x
    }

    func rels(_ part: String) -> [String: OPCRelationship] {
        if let r = relsCache[part] { return r }
        let list = (try? OPC.relationships(zip, for: part)) ?? []
        let r = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        relsCache[part] = r
        return r
    }

    func related(_ part: String, type: String) -> String? {
        rels(part).values.first(where: { $0.isType(type) && !$0.external }).map(\.target)
    }

    func theme(forMaster master: String) -> DrawingTheme {
        if let t = themeCache[master] { return t }
        let t = related(master, type: "theme").flatMap { xml($0) }.map { DrawingTheme($0) } ?? DrawingTheme.fallback
        themeCache[master] = t
        return t
    }

    /// The picture in a media part, decoded once and shared by every use. JPEG data stays JPEG in the PDF because the
    /// image keeps its original data provider. Returns nil for formats macOS cannot draw (EMF, WMF, JPEG XR).
    func image(_ part: String) -> CGImage? {
        if let i = imageCache[part] { return i }
        if badImages.contains(part) { return nil }
        guard let data = try? zip.data(part), let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0, ImageCodec.isWithinLimits(src),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            badImages.insert(part); return nil
        }
        imageCache[part] = img
        return img
    }

    /// EXIF orientation (1...8) of a media part; 1 when absent.
    func orientation(_ part: String) -> Int {
        guard let data = try? zip.data(part), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let o = props[kCGImagePropertyOrientation] as? NSNumber else { return 1 }
        return min(max(o.intValue, 1), 8)
    }

    func data(_ part: String) -> Data? { try? zip.data(part) }
}

/// Everything one slide's shapes resolve against: its layout and master, their placeholders, the theme and the
/// colour mapping in force.
final class SlideScope {
    let pkg: PptxPackage
    let slidePart: String
    let slide: XNode
    let layoutPart: String?
    let layout: XNode?
    let masterPart: String?
    let master: XNode?
    let theme: DrawingTheme
    let number: Int
    /// Colour maps for shapes of the master, of the layout and of the slide.
    let masterColors: ColorResolver, layoutColors: ColorResolver, slideColors: ColorResolver

    private var layoutPh: [XNode] = []
    private var masterPh: [XNode] = []

    init(pkg: PptxPackage, slidePart: String, slide: XNode, number: Int) {
        self.pkg = pkg; self.slidePart = slidePart; self.slide = slide; self.number = number
        layoutPart = pkg.related(slidePart, type: "slideLayout")
        layout = layoutPart.flatMap { pkg.xml($0) }
        masterPart = layoutPart.flatMap { pkg.related($0, type: "slideMaster") }
        master = masterPart.flatMap { pkg.xml($0) }
        theme = masterPart.map { pkg.theme(forMaster: $0) } ?? DrawingTheme.fallback

        var map = ColorResolver.defaultMap
        if let cm = master?.child("p:clrMap") { for (k, v) in cm.attrs { map[k] = v } }
        masterColors = ColorResolver(theme: theme, map: map)
        func override(_ root: XNode?, _ base: [String: String]) -> [String: String] {
            guard let o = root?.child("p:clrMapOvr")?.child("a:overrideClrMapping") else { return base }
            var m = base
            for (k, v) in o.attrs { m[k] = v }
            return m
        }
        let layoutMap = override(layout, map)
        layoutColors = ColorResolver(theme: theme, map: layoutMap)
        slideColors = ColorResolver(theme: theme, map: override(slide, layoutMap))

        layoutPh = SlideScope.placeholders(layout)
        masterPh = SlideScope.placeholders(master)
    }

    private static func placeholders(_ root: XNode?) -> [XNode] {
        guard let tree = root?.child("p:cSld")?.child("p:spTree") else { return [] }
        var out: [XNode] = []
        func walk(_ n: XNode) {
            for c in n.children {
                if c.tag == "p:grpSp" { walk(c); continue }
                if c.tag == "p:sp" || c.tag == "p:pic" || c.tag == "p:graphicFrame", placeholder(c) != nil { out.append(c) }
            }
        }
        walk(tree)
        return out
    }

    static func placeholder(_ shape: XNode) -> XNode? {
        let nv = shape.child("p:nvSpPr") ?? shape.child("p:nvPicPr") ?? shape.child("p:nvGraphicFramePr") ?? shape.child("p:nvCxnSpPr")
        return nv?.child("p:nvPr")?.child("p:ph")
    }

    /// The master placeholder class of a placeholder type.
    static func masterClass(_ type: String?) -> String {
        switch type ?? "obj" {
        case "title", "ctrTitle": return "title"
        case "dt", "ftr", "sldNum", "hdr": return type!
        default: return "body"
        }
    }

    /// Layout placeholder for a slide placeholder: same idx first, then same type.
    func layoutPlaceholder(for ph: XNode) -> XNode? {
        if let idx = ph["idx"], let hit = layoutPh.first(where: { SlideScope.placeholder($0)?["idx"] == idx }) {
            // An idx match of an incompatible kind (a title matched to a body) is not inheritance.
            let a = SlideScope.masterClass(ph["type"]), b = SlideScope.masterClass(SlideScope.placeholder(hit)?["type"])
            if a == b || (ph["type"] == nil) || (a == "body" && b == "body") { return hit }
        }
        let type = ph["type"] ?? "obj"
        let sameType: (XNode) -> Bool = { n in
            let t = SlideScope.placeholder(n)?["type"] ?? "obj"
            if t == type { return true }
            if ["title", "ctrTitle"].contains(t) && ["title", "ctrTitle"].contains(type) { return true }
            return false
        }
        if let hit = layoutPh.first(where: sameType) { return hit }
        if ["body", "obj"].contains(type), ph["idx"] == nil {
            return layoutPh.first { ["body", "obj"].contains(SlideScope.placeholder($0)?["type"] ?? "obj") }
        }
        return nil
    }

    func masterPlaceholder(type: String?) -> XNode? {
        let cls = SlideScope.masterClass(type)
        return masterPh.first { SlideScope.masterClass(SlideScope.placeholder($0)?["type"]) == cls }
    }

    /// Text style of the master for a placeholder type (or for a shape that is not a placeholder: nil).
    func masterTextStyle(placeholderType type: String?, isPlaceholder: Bool) -> XNode? {
        let styles = master?.child("p:txStyles")
        guard isPlaceholder else { return styles?.child("p:otherStyle") }
        switch SlideScope.masterClass(type) {
        case "title": return styles?.child("p:titleStyle")
        case "body": return styles?.child("p:bodyStyle")
        default: return styles?.child("p:otherStyle")
        }
    }
}
