import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// Draws PowerPoint slides as they look: one PDF page per visible slide, page size = slide size, text kept as real
/// text. Backgrounds, master and layout graphics, shapes, pictures, tables, SmartArt and charts are drawn from the
/// DrawingML; what cannot be drawn is reported in `Result.notDrawn` instead of disappearing silently.
public enum PptxSlideRenderer {

    public struct Result {
        public var pdf: Data
        public var pageCount: Int
        public var pageSize: CGSize
        /// Kinds of content that were left out, each with the slide numbers where they occur.
        public var notDrawn: [String: [Int]]
        /// Text bodies in substitute fonts that were shrunk to stay inside their boxes.
        public var fitted: [Fit] = []
    }

    public struct Fit {
        public let slide: Int
        /// Font scale used (1 = only the line spacing was reduced).
        public let scale: Double
        /// Wrapping text (fitted by height) or a label (fitted by width).
        public let wraps: Bool
        /// False when even the floor does not fit: the text is then drawn at full size and reported.
        public let fits: Bool
    }

    public static func renderPDF(contentsOf url: URL, progress: ((Double) -> Void)? = nil, cancelled: (() -> Bool)? = nil) throws -> Result {
        try renderPDF(data: try Data.readOffice(url), title: url.deletingPathExtension().lastPathComponent, progress: progress, cancelled: cancelled)
    }

    public static func renderPDF(data: Data, title: String? = nil, progress: ((Double) -> Void)? = nil, cancelled: (() -> Bool)? = nil) throws -> Result {
        let pkg = try PptxPackage(data: data)
        let r = SlideRenderer(pkg: pkg)
        return try r.renderPDF(title: OPC.coreTitle(pkg.zip) ?? title, progress: progress, cancelled: cancelled)
    }
}

final class SlideRenderer {
    let pkg: PptxPackage
    let fonts = SlideFonts()
    lazy var text = SlideTextLayout(fonts: fonts)
    var ctx: CGContext!
    var isPDF = true
    /// Content that was not drawn: kind -> slide numbers.
    var gaps: [String: Set<Int>] = [:]
    var unknownPresets: Set<String> = []
    var fitted: [PptxSlideRenderer.Fit] = []
    var currentSlide = 0
    var scope: SlideScope!

    init(pkg: PptxPackage) { self.pkg = pkg }

    func gap(_ kind: String) { gaps[kind, default: []].insert(currentSlide) }

    func renderPDF(title: String?, progress: ((Double) -> Void)?, cancelled: (() -> Bool)?) throws -> PptxSlideRenderer.Result {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pkg.slideSize)
        var info: [CFString: Any] = [kCGPDFContextCreator: "MaruDoc"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { throw OfficeError.io("PDF context") }
        ctx = pdf
        isPDF = true
        var pages = 0
        let visible = pkg.slides.filter { !$0.hidden }
        for (i, entry) in visible.enumerated() {
            if cancelled?() == true { throw CancellationError() }
            guard let root = pkg.xml(entry.part), root.tag == "p:sld" else {
                // A slide part that cannot be read still gets its page, so page numbers keep matching the deck.
                if pkg.zip.contains(entry.part) {
                    currentSlide = entry.number; gap("unreadable slide")
                    pdf.beginPDFPage(nil); pdf.endPDFPage(); pages += 1
                }
                continue
            }
            // PowerPoint marks a hidden slide on the slide part's root.
            if !OOXMLValue.onOff(root["show"] ?? "1") { continue }
            pdf.beginPDFPage(nil)
            drawSlide(root, entry: entry)
            pdf.endPDFPage()
            pages += 1
            progress?(Double(i + 1) / Double(max(visible.count, 1)))
        }
        if pages == 0 {
            // Nothing visible (an empty deck, or every slide hidden): one blank slide-sized page, as before.
            pdf.beginPDFPage(nil); pdf.endPDFPage(); pages = 1
        }
        pdf.closePDF()
        ctx = nil
        if !unknownPresets.isEmpty { gaps["shape presets drawn as rectangles: " + unknownPresets.sorted().joined(separator: ", ")] = gaps["unknown preset"] ?? [] }
        gaps["unknown preset"] = nil
        return PptxSlideRenderer.Result(pdf: data as Data, pageCount: pages, pageSize: pkg.slideSize,
                                        notDrawn: gaps.mapValues { $0.sorted() }, fitted: fitted)
    }

    /// Draws one slide into the current page (or bitmap) of `ctx`, whose origin is the slide's bottom-left.
    func drawSlide(_ root: XNode, entry: PptxPackage.Entry) {
        currentSlide = entry.number
        let s = SlideScope(pkg: pkg, slidePart: entry.part, slide: root, number: entry.number)
        scope = s
        let size = pkg.slideSize
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        drawBackground(s)

        let showMaster = OOXMLValue.onOff(root["showMasterSp"] ?? "1")
        let layoutShowsMaster = OOXMLValue.onOff(s.layout?["showMasterSp"] ?? "1")
        if showMaster && layoutShowsMaster, let m = s.master, let part = s.masterPart, let tree = m.child("p:cSld")?.child("p:spTree") {
            drawTree(tree, layer: Layer(kind: .master, part: part, colors: s.masterColors), map: .identity, mirrored: false)
        }
        if showMaster, let l = s.layout, let part = s.layoutPart, let tree = l.child("p:cSld")?.child("p:spTree") {
            drawTree(tree, layer: Layer(kind: .layout, part: part, colors: s.layoutColors), map: .identity, mirrored: false)
        }
        if let tree = root.child("p:cSld")?.child("p:spTree") {
            drawTree(tree, layer: Layer(kind: .slide, part: entry.part, colors: s.slideColors), map: .identity, mirrored: false)
        }
        ctx.restoreGState()
    }

    // MARK: Background

    func drawBackground(_ s: SlideScope) {
        let candidates: [(XNode?, String?, ColorResolver)] = [(s.slide, s.slidePart, s.slideColors), (s.layout, s.layoutPart, s.layoutColors),
                                                              (s.master, s.masterPart, s.masterColors)]
        for (root, part, colors) in candidates {
            guard let bg = root?.child("p:cSld")?.child("p:bg"), let part else { continue }
            let rect = CGRect(origin: .zero, size: pkg.slideSize)
            let path = CGPath(rect: rect, transform: nil)
            if let pr = bg.child("p:bgPr") {
                paint(path, fill: fillElement(in: pr), colors: colors, part: part, bounds: rect)
            } else if let ref = bg.child("p:bgRef") {
                let idx = OOXMLValue.int(ref["idx"]) ?? 0
                let c = colors.with(phClr: colors.color(in: ref))
                if let style = themeFill(idx, c) { paint(path, fill: style, colors: c, part: part, bounds: rect) }
                else if let col = c.phClr { paint(path, fill: nil, colors: c, part: part, bounds: rect, solid: col) }
            }
            return
        }
    }

    /// Theme fill style for a style index: 1-999 the fill styles, 1001+ the background fill styles.
    func themeFill(_ idx: Int, _ colors: ColorResolver) -> XNode? {
        let t = scope.theme
        if idx >= 1001 { let i = idx - 1001; return i < t.bgFillStyles.count ? t.bgFillStyles[i] : nil }
        if idx >= 1 { let i = idx - 1; return i < t.fillStyles.count ? t.fillStyles[i] : nil }
        return nil
    }

    // MARK: Shape tree

    struct Layer {
        enum Kind { case master, layout, slide, diagram }
        var kind: Kind
        var part: String
        var colors: ColorResolver
        /// a:grpFill resolves to the enclosing group's fill.
        var groupFill: (XNode, ColorResolver)?
    }

    /// `map` takes child coordinates (in points) to the drawing space of the parent; groups add their rotation and flips
    /// to the CTM so that child shapes keep their own sizes.
    func drawTree(_ tree: XNode, layer: Layer, map: CGAffineTransform, mirrored: Bool) {
        for n in tree.children {
            switch n.localName {
            case "sp":
                if layer.kind != .slide && layer.kind != .diagram, SlideScope.placeholder(n) != nil { continue }
                drawShape(n, layer: layer, map: map, mirrored: mirrored)
            case "cxnSp":
                drawShape(n, layer: layer, map: map, mirrored: mirrored)
            case "pic":
                if layer.kind != .slide && layer.kind != .diagram, SlideScope.placeholder(n) != nil { continue }
                drawPicture(n, layer: layer, map: map, mirrored: mirrored)
            case "grpSp":
                drawGroup(n, layer: layer, map: map, mirrored: mirrored)
            case "graphicFrame":
                if layer.kind != .slide, SlideScope.placeholder(n) != nil { continue }
                drawGraphicFrame(n, layer: layer, map: map, mirrored: mirrored)
            case "AlternateContent":
                let choice = n.child("mc:Choice"), fallback = n.child("mc:Fallback")
                if let choice, SlideRenderer.canDraw(choice) {
                    drawTree(choice, layer: layer, map: map, mirrored: mirrored)
                } else if let fallback {
                    drawTree(fallback, layer: layer, map: map, mirrored: mirrored)
                } else if choice?.contains("p:contentPart") == true { gap("ink without a picture") }
            case "contentPart":
                gap("ink without a picture")
            default:
                break
            }
        }
    }

    /// An mc:Choice is drawn when it holds ordinary shapes; ink (p:contentPart) and equations (a14:m) are drawn from
    /// the Fallback, which carries a picture of them.
    static func canDraw(_ choice: XNode) -> Bool {
        var ok = true
        func walk(_ n: XNode) {
            for c in n.children {
                if c.localName == "contentPart" { ok = false; return }
                if c.tag.hasPrefix("http://schemas.microsoft.com/office/drawing/2010/main:m") && c.localName == "m" { ok = false; return }
                walk(c)
            }
        }
        walk(choice)
        return ok
    }

    static func kid(_ n: XNode?, _ local: String) -> XNode? { n?.children.first { $0.localName == Substring(local) && !$0.tag.hasPrefix("a:") } }

    struct Xfrm {
        var rect: CGRect
        var rot: Double = 0
        var flipH = false, flipV = false
    }

    static func xfrm(_ x: XNode?) -> Xfrm? {
        guard let x, let off = x.child("a:off"), let ext = x.child("a:ext") else { return nil }
        let r = CGRect(x: (OOXMLValue.double(off["x"]) ?? 0) / 12700, y: (OOXMLValue.double(off["y"]) ?? 0) / 12700,
                       width: max((OOXMLValue.double(ext["cx"]) ?? 0) / 12700, 0), height: max((OOXMLValue.double(ext["cy"]) ?? 0) / 12700, 0))
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite else { return nil }
        return Xfrm(rect: r, rot: (OOXMLValue.double(x["rot"]) ?? 0) / 60000,
                    flipH: OOXMLValue.onOff(x["flipH"] ?? "0"), flipV: OOXMLValue.onOff(x["flipV"] ?? "0"))
    }

    /// Enters a shape's local space (origin top-left, size w x h): rotation about the centre, then flips.
    func enterShape(_ x: Xfrm, map: CGAffineTransform) -> CGRect {
        let r = x.rect.applying(map)
        ctx.translateBy(x: r.midX, y: r.midY)
        if x.rot != 0 { ctx.rotate(by: x.rot * .pi / 180) }
        if x.flipH || x.flipV { ctx.scaleBy(x: x.flipH ? -1 : 1, y: x.flipV ? -1 : 1) }
        ctx.translateBy(x: -r.width / 2, y: -r.height / 2)
        return CGRect(origin: .zero, size: r.size)
    }

    func drawGroup(_ g: XNode, layer: Layer, map: CGAffineTransform, mirrored: Bool) {
        let spPr = SlideRenderer.kid(g, "grpSpPr")
        if SlideRenderer.kid(g, "nvGrpSpPr")?.child("p:cNvPr")?["hidden"].map({ OOXMLValue.onOff($0) }) == true { return }
        guard let xf = spPr?.child("a:xfrm"), let x = SlideRenderer.xfrm(xf) else {
            drawTree(g, layer: layer, map: map, mirrored: mirrored)
            return
        }
        let chOff = xf.child("a:chOff"), chExt = xf.child("a:chExt")
        let cx = (OOXMLValue.double(chOff?["x"]) ?? Double(x.rect.minX * 12700)) / 12700, cy = (OOXMLValue.double(chOff?["y"]) ?? Double(x.rect.minY * 12700)) / 12700
        let cw = (OOXMLValue.double(chExt?["cx"]) ?? Double(x.rect.width * 12700)) / 12700, ch = (OOXMLValue.double(chExt?["cy"]) ?? Double(x.rect.height * 12700)) / 12700
        ctx.saveGState()
        let local = enterShape(x, map: map)
        let sx = cw > 0 ? local.width / cw : 1, sy = ch > 0 ? local.height / ch : 1
        let childMap = CGAffineTransform(translationX: -cx, y: -cy).concatenating(CGAffineTransform(scaleX: sx, y: sy))
        var l = layer
        if let f = fillElement(in: spPr) { l.groupFill = (f, layer.colors) }
        drawTree(g, layer: l, map: childMap, mirrored: mirrored != (x.flipH != x.flipV))
        ctx.restoreGState()
    }

    // MARK: Shapes

    /// A shape with what it inherits: for slide placeholders, the matching layout and master placeholders.
    struct Resolved {
        var chain: [XNode]
        var xfrm: Xfrm?
        var spPrs: [XNode]
        var style: XNode?
        var phType: String?
        var isPlaceholder: Bool
        var layoutPh: XNode?, masterPh: XNode?
    }

    func resolve(_ n: XNode, layer: Layer) -> Resolved {
        var chain = [n]
        var phType: String?
        var lph: XNode?, mph: XNode?
        let ph = SlideScope.placeholder(n)
        if let ph, layer.kind == .slide {
            lph = scope.layoutPlaceholder(for: ph)
            phType = ph["type"] ?? lph.flatMap { SlideScope.placeholder($0)?["type"] }
            mph = scope.masterPlaceholder(type: lph.flatMap { SlideScope.placeholder($0)?["type"] } ?? phType)
            chain += [lph, mph].compactMap { $0 }
        } else if let ph {
            phType = ph["type"]
        }
        let spPrs = chain.compactMap { SlideRenderer.kid($0, "spPr") }
        var x: Xfrm?
        for s in spPrs { if let v = SlideRenderer.xfrm(s.child("a:xfrm")) { x = v; break } }
        if x == nil, n.localName == "graphicFrame" { x = SlideRenderer.xfrm(n.child("p:xfrm")) }
        let style = chain.lazy.compactMap { SlideRenderer.kid($0, "style") }.first
        return Resolved(chain: chain, xfrm: x, spPrs: spPrs, style: style, phType: phType, isPlaceholder: ph != nil, layoutPh: lph, masterPh: mph)
    }

    func isHidden(_ n: XNode) -> Bool {
        let nv = n.children.first { $0.localName.hasPrefix("nv") }
        return nv?.children.first { $0.localName == "cNvPr" }?["hidden"].map { OOXMLValue.onOff($0) } ?? false
    }

    func drawShape(_ n: XNode, layer: Layer, map: CGAffineTransform, mirrored: Bool) {
        if isHidden(n) { return }
        let r = resolve(n, layer: layer)
        guard let x = r.xfrm else {
            // A shape without a position (no xfrm anywhere in its chain) has nowhere to go.
            if SlideRenderer.kid(n, "txBody").map({ !$0.allText("a:t").isEmpty }) == true { gap("text without a position") }
            return
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let box = enterShape(x, map: map)
        let w = Double(box.width), h = Double(box.height)
        let geoSpPr = r.spPrs.first { $0.child("a:prstGeom") != nil || $0.child("a:custGeom") != nil }
        var unknown = Set<String>()
        let geo = DrawingGeometry.geometry(geoSpPr, w: w, h: h, unknown: &unknown)
        if !unknown.isEmpty { unknownPresets.formUnion(unknown); gap("unknown preset") }

        let fill = resolvedFill(r, layer: layer)
        let line = resolvedLine(r, colors: layer.colors)
        let shadow = resolvedShadow(r, colors: layer.colors)
        drawGeometry(geo, fill: fill, line: line, shadow: shadow, layer: layer, bounds: box)

        // Text
        let txBody = SlideRenderer.kid(n, "txBody")
        if let txBody {
            let txXfrm = SlideRenderer.kid(n, "txXfrm").flatMap { SlideRenderer.xfrm($0) }
            drawText(txBody, resolved: r, layer: layer, box: box, geoText: geo.textRect, txXfrm: txXfrm, shapeXfrm: x, map: map, mirrored: mirrored != (x.flipH != x.flipV))
        }
    }

    // MARK: Fill and line resolution

    /// The fill element directly inside a spPr / bgPr / tcPr.
    func fillElement(in n: XNode?) -> XNode? {
        n?.children.first { ["a:noFill", "a:solidFill", "a:gradFill", "a:blipFill", "a:pattFill", "a:grpFill"].contains($0.tag) }
    }

    struct Fill {
        var node: XNode?
        var colors: ColorResolver
        var part: String
    }

    func resolvedFill(_ r: Resolved, layer: Layer) -> Fill? {
        for s in r.spPrs {
            if let f = fillElement(in: s) {
                if f.tag == "a:grpFill" {
                    guard let g = layer.groupFill else { return nil }
                    return Fill(node: g.0, colors: g.1, part: layer.part)
                }
                return Fill(node: f, colors: layer.colors, part: layer.part)
            }
        }
        if let ref = r.style?.child("a:fillRef"), let idx = OOXMLValue.int(ref["idx"]), idx > 0 {
            let c = layer.colors.with(phClr: layer.colors.color(in: ref))
            if let f = themeFill(idx, c) { return Fill(node: f, colors: c, part: layer.part) }
        }
        return nil
    }

    struct Arrow { var type: String; var w: String; var len: String }

    struct LineStyle {
        var width: Double = 0.75
        var color: DColor?
        var gradient: (XNode, ColorResolver)?
        var dash: [Double] = []
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .round
        var head: Arrow?, tail: Arrow?
    }

    func resolvedLine(_ r: Resolved, colors: ColorResolver) -> LineStyle? {
        // Theme line style first, then the shape's own a:ln on top (least specific placeholder first).
        var lns: [(XNode, ColorResolver)] = []
        if let ref = r.style?.child("a:lnRef"), let idx = OOXMLValue.int(ref["idx"]), idx > 0, idx <= scope.theme.lineStyles.count {
            lns.append((scope.theme.lineStyles[idx - 1], colors.with(phClr: colors.color(in: ref))))
        }
        for s in r.spPrs.reversed() { if let ln = s.child("a:ln") { lns.append((ln, colors)) } }
        guard !lns.isEmpty else { return nil }
        var st = LineStyle()
        var visible = false
        var dashName: String?
        var custDash: [Double]?
        for (ln, c) in lns {
            if let w = OOXMLValue.double(ln["w"]) { st.width = w / 12700 }
            switch ln["cap"] { case "rnd": st.cap = .round; case "sq": st.cap = .square; case "flat": st.cap = .butt; default: break }
            if ln.child("a:noFill") != nil { visible = false; st.color = nil; st.gradient = nil }
            if let s = ln.child("a:solidFill") { visible = true; st.color = c.color(in: s) ?? .black; st.gradient = nil }
            if let g = ln.child("a:gradFill") {
                visible = true; st.gradient = (g, c)
                st.color = c.color(in: g.child("a:gsLst")?.children("a:gs").first)
            }
            if let p = ln.child("a:pattFill") { visible = true; st.color = c.color(in: p.child("a:fgClr")) }
            if let d = ln.child("a:prstDash")?["val"] { dashName = d; custDash = nil }
            if let cd = ln.child("a:custDash") {
                custDash = cd.children("a:ds").flatMap { [(OOXMLValue.double($0["d"]) ?? 100_000) / 100_000, (OOXMLValue.double($0["sp"]) ?? 100_000) / 100_000] }
            }
            if ln.child("a:round") != nil { st.join = .round }
            if ln.child("a:bevel") != nil { st.join = .bevel }
            if ln.child("a:miter") != nil { st.join = .miter }
            if let he = ln.child("a:headEnd") { st.head = he["type"].flatMap { $0 == "none" ? nil : Arrow(type: $0, w: he["w"] ?? "med", len: he["len"] ?? "med") } }
            if let te = ln.child("a:tailEnd") { st.tail = te["type"].flatMap { $0 == "none" ? nil : Arrow(type: $0, w: te["w"] ?? "med", len: te["len"] ?? "med") } }
        }
        guard visible, st.color != nil || st.gradient != nil else { return nil }
        if st.width <= 0 { st.width = 0.25 }
        let unit = st.width
        let pattern: [Double]
        if let custDash { pattern = custDash } else {
            switch dashName ?? "solid" {
            case "dot": pattern = [1, 3]
            case "dash": pattern = [4, 3]
            case "lgDash": pattern = [8, 3]
            case "dashDot": pattern = [4, 3, 1, 3]
            case "lgDashDot": pattern = [8, 3, 1, 3]
            case "lgDashDotDot": pattern = [8, 3, 1, 3, 1, 3]
            case "sysDash": pattern = [3, 1]
            case "sysDot": pattern = [1, 1]
            case "sysDashDot": pattern = [3, 1, 1, 1]
            case "sysDashDotDot": pattern = [3, 1, 1, 1, 1, 1]
            default: pattern = []
            }
        }
        st.dash = pattern.map { max($0 * unit, 0.1) }
        return st
    }

    struct Shadow { var offset: CGSize; var blur: Double; var color: DColor }

    func resolvedShadow(_ r: Resolved, colors: ColorResolver) -> Shadow? {
        var effect: XNode?
        var c = colors
        for s in r.spPrs { if let e = s.child("a:effectLst") { effect = e; break } }
        if effect == nil, let ref = r.style?.child("a:effectRef"), let idx = OOXMLValue.int(ref["idx"]), idx > 0, idx <= scope.theme.effectStyles.count {
            effect = scope.theme.effectStyles[idx - 1].child("a:effectLst")
            c = colors.with(phClr: colors.color(in: ref))
        }
        guard let sh = effect?.child("a:outerShdw"), let col = c.color(in: sh) else { return nil }
        let dist = (OOXMLValue.double(sh["dist"]) ?? 0) / 12700, dir = (OOXMLValue.double(sh["dir"]) ?? 0) / 60000 * .pi / 180
        return Shadow(offset: CGSize(width: dist * cos(dir), height: dist * sin(dir)), blur: (OOXMLValue.double(sh["blurRad"]) ?? 0) / 12700, color: col)
    }

    // MARK: Painting

    func drawGeometry(_ geo: ShapeGeometry, fill: Fill?, line: LineStyle?, shadow: Shadow?, layer: Layer, bounds: CGRect) {
        let hasFill = fill?.node.map { $0.tag != "a:noFill" } ?? false
        if let shadow, hasFill || line != nil {
            // Office draws the shadow of the filled shape (or of its outline when unfilled) under it.
            ctx.saveGState()
            let base = ctx.userSpaceToDeviceSpaceTransform
            let off = CGSize(width: shadow.offset.width, height: shadow.offset.height).applying(CGAffineTransform(a: base.a, b: base.b, c: base.c, d: base.d, tx: 0, ty: 0))
            ctx.setShadow(offset: off, blur: shadow.blur * abs(base.a + base.d) / 2, color: shadow.color.cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for gp in geo.paths where gp.fill != .none && hasFill {
                ctx.addPath(gp.path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
            }
            if !hasFill, let line { for gp in geo.paths where gp.stroke { stroke(gp.path, line, isLine: geo.isLine, draw: true) } }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        if let fill, hasFill {
            for gp in geo.paths where gp.fill != .none {
                var solidOverride: DColor?
                if gp.fill != .norm, let n = fill.node, n.tag == "a:solidFill", let base = fill.colors.color(in: n) {
                    let f: Double = gp.fill == .darken ? 0.6 : gp.fill == .darkenLess ? 0.8 : gp.fill == .lighten ? 1.4 : 1.2
                    solidOverride = f < 1 ? DColor(r: base.r * f, g: base.g * f, b: base.b * f, a: base.a) : base.mixed(with: .white, f - 1)
                }
                paint(gp.path, fill: fill.node, colors: fill.colors, part: fill.part, bounds: bounds, solid: solidOverride)
            }
        }
        if let line {
            for gp in geo.paths where gp.stroke { stroke(gp.path, line, isLine: geo.isLine, draw: true) }
        }
    }

    /// Fills `path` with a DrawingML fill element (or `solid` when given).
    func paint(_ path: CGPath, fill: XNode?, colors: ColorResolver, part: String, bounds: CGRect, solid: DColor? = nil) {
        if let solid {
            ctx.addPath(path); ctx.setFillColor(solid.cgColor); ctx.fillPath(); return
        }
        guard let fill else { return }
        switch fill.tag {
        case "a:solidFill":
            guard let c = colors.color(in: fill) else { return }
            ctx.addPath(path); ctx.setFillColor(c.cgColor); ctx.fillPath()
        case "a:gradFill":
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            drawGradient(fill, colors: colors, bounds: bounds)
            ctx.restoreGState()
        case "a:blipFill":
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            drawBlip(fill, part: part, frame: bounds, colors: colors)
            ctx.restoreGState()
        case "a:pattFill":
            let fg = colors.color(in: fill.child("a:fgClr")) ?? .black, bg = colors.color(in: fill.child("a:bgClr")) ?? .white
            let density = SlideRenderer.patternDensity(fill["prst"] ?? "pct50")
            ctx.addPath(path); ctx.setFillColor(bg.mixed(with: fg, density).cgColor); ctx.fillPath()
        default:
            break
        }
    }

    /// Share of the foreground colour in a pattern, used to approximate pattern fills with a flat colour.
    static func patternDensity(_ prst: String) -> Double {
        if prst.hasPrefix("pct"), let v = Double(prst.dropFirst(3)) { return v / 100 }
        if prst.hasPrefix("lt") || prst.hasPrefix("narrow") { return 0.25 }
        if prst.hasPrefix("dk") || prst.hasPrefix("wide") { return 0.6 }
        if prst.hasPrefix("dash") || prst.hasPrefix("dot") { return 0.2 }
        return 0.5
    }

    func gradientStops(_ g: XNode, colors: ColorResolver) -> (CGGradient?, [DColor]) {
        var stops: [(Double, DColor)] = []
        for gs in g.child("a:gsLst")?.children("a:gs") ?? [] {
            if let c = colors.color(in: gs) { stops.append(((OOXMLValue.double(gs["pos"]) ?? 0) / 100_000, c)) }
        }
        stops.sort { $0.0 < $1.0 }
        guard !stops.isEmpty else { return (nil, []) }
        if stops.count == 1 { stops.append((1, stops[0].1)) }
        let cols = stops.map { $0.1.cgColor } as CFArray
        var locs = stops.map { CGFloat(min(max($0.0, 0), 1)) }
        return (CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols, locations: &locs), stops.map(\.1))
    }

    func drawGradient(_ g: XNode, colors: ColorResolver, bounds b: CGRect) {
        let (grad, cols) = gradientStops(g, colors: colors)
        guard let grad else { return }
        _ = cols
        if let path = g.child("a:path") {
            // Radial ("circle"), rectangular and shape gradients: the first stop is at the focus given by fillToRect.
            let ftr = path.child("a:fillToRect")
            func f(_ k: String) -> Double { (OOXMLValue.double(ftr?[k]) ?? 50000) / 100_000 }
            let l = ftr?["l"] == nil ? 0.5 : f("l"), t = ftr?["t"] == nil ? 0.5 : f("t"), r = ftr?["r"] == nil ? 0.5 : f("r"), bt = ftr?["b"] == nil ? 0.5 : f("b")
            let cx = b.minX + b.width * (l + (1 - l - r) / 2), cy = b.minY + b.height * (t + (1 - t - bt) / 2)
            let center = CGPoint(x: cx, y: cy)
            let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)]
            let radius = corners.map { hypot($0.x - cx, $0.y - cy) }.max() ?? 1
            ctx.saveGState()
            if path["path"] == "circle" || path["path"] == "shape" || path["path"] == "rect" {
                // Scale so the gradient follows the box's aspect, as Office does for path gradients.
                let sx = b.width / max(b.height, 0.001)
                ctx.translateBy(x: cx, y: cy); ctx.scaleBy(x: sx >= 1 ? 1 : 1, y: 1); ctx.translateBy(x: -cx, y: -cy)
            }
            ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius * (path["path"] == "circle" ? 1 : 0.75),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
            return
        }
        let lin = g.child("a:lin")
        var ang = (OOXMLValue.double(lin?["ang"]) ?? 0) / 60000 * .pi / 180
        if OOXMLValue.onOff(lin?["scaled"] ?? "0"), b.width > 0, b.height > 0 {
            // A scaled angle is measured in the unit square and stretched with the box.
            ang = atan2(sin(ang) / Double(b.height), cos(ang) / Double(b.width))
        }
        let dx = cos(ang), dy = sin(ang)
        let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)]
        let proj = corners.map { Double($0.x - b.midX) * dx + Double($0.y - b.midY) * dy }
        let lo = proj.min() ?? 0, hi = proj.max() ?? 1
        let start = CGPoint(x: b.midX + lo * dx, y: b.midY + lo * dy), end = CGPoint(x: b.midX + hi * dx, y: b.midY + hi * dy)
        ctx.drawLinearGradient(grad, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: Lines and arrowheads

    func stroke(_ path: CGPath, _ st: LineStyle, isLine: Bool, draw: Bool) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(st.width)
        ctx.setLineCap(st.cap)
        ctx.setLineJoin(st.join)
        ctx.setMiterLimit(8)
        if !st.dash.isEmpty { ctx.setLineDash(phase: 0, lengths: st.dash.map { CGFloat($0) }) }
        let color = (st.color ?? .black).cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        var p = path
        if isLine, st.head != nil || st.tail != nil {
            let pts = SlideRenderer.endpoints(path)
            if let (s0, s1, e0, e1) = pts {
                var trimmed = path
                if let h = st.head { let len = arrowLength(h, st); drawArrow(h, tip: s0, from: s1, st); trimmed = SlideRenderer.trim(trimmed, start: SlideRenderer.backoff(h, len), end: 0) }
                if let t = st.tail { let len = arrowLength(t, st); drawArrow(t, tip: e0, from: e1, st); trimmed = SlideRenderer.trim(trimmed, start: 0, end: SlideRenderer.backoff(t, len)) }
                p = trimmed
            }
        }
        if let (g, c) = st.gradient {
            ctx.addPath(p)
            ctx.replacePathWithStrokedPath()
            let box = ctx.boundingBoxOfPath
            ctx.clip()
            drawGradient(g, colors: c, bounds: box)
            return
        }
        ctx.addPath(p)
        ctx.strokePath()
    }

    static func backoff(_ a: Arrow, _ len: Double) -> Double {
        switch a.type { case "triangle", "arrow": return len * 0.8; case "stealth": return len * 0.6; default: return 0 }
    }

    func arrowSize(_ a: Arrow, _ st: LineStyle) -> (w: Double, len: Double) {
        let base = max(st.width, 1.98)
        func f(_ s: String) -> Double { s == "sm" ? 2 : s == "lg" ? 5 : 3 }
        return (base * f(a.w), base * f(a.len))
    }

    func arrowLength(_ a: Arrow, _ st: LineStyle) -> Double { arrowSize(a, st).len }

    func drawArrow(_ a: Arrow, tip: CGPoint, from: CGPoint, _ st: LineStyle) {
        let (aw, al) = arrowSize(a, st)
        let ang = atan2(tip.y - from.y, tip.x - from.x)
        ctx.saveGState()
        ctx.translateBy(x: tip.x, y: tip.y)
        ctx.rotate(by: ang)
        ctx.setLineDash(phase: 0, lengths: [])
        let p = CGMutablePath()
        switch a.type {
        case "triangle":
            p.move(to: .zero); p.addLine(to: CGPoint(x: -al, y: -aw / 2)); p.addLine(to: CGPoint(x: -al, y: aw / 2)); p.closeSubpath()
            ctx.addPath(p); ctx.fillPath()
        case "stealth":
            p.move(to: .zero); p.addLine(to: CGPoint(x: -al, y: -aw / 2)); p.addLine(to: CGPoint(x: -al * 0.6, y: 0)); p.addLine(to: CGPoint(x: -al, y: aw / 2)); p.closeSubpath()
            ctx.addPath(p); ctx.fillPath()
        case "diamond":
            p.move(to: CGPoint(x: al / 2, y: 0)); p.addLine(to: CGPoint(x: 0, y: -aw / 2)); p.addLine(to: CGPoint(x: -al / 2, y: 0)); p.addLine(to: CGPoint(x: 0, y: aw / 2)); p.closeSubpath()
            ctx.addPath(p); ctx.fillPath()
        case "oval":
            ctx.fillEllipse(in: CGRect(x: -al / 2, y: -aw / 2, width: al, height: aw))
        default: // "arrow": open
            p.move(to: CGPoint(x: -al, y: -aw / 2)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: -al, y: aw / 2))
            ctx.setLineJoin(.miter)
            ctx.addPath(p); ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Start point, the point it heads from, end point and the point it comes from.
    static func endpoints(_ path: CGPath) -> (CGPoint, CGPoint, CGPoint, CGPoint)? {
        var pts: [CGPoint] = []
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: pts.append(e.points[0])
            case .addQuadCurveToPoint: pts.append(e.points[0]); pts.append(e.points[1])
            case .addCurveToPoint: pts.append(e.points[0]); pts.append(e.points[1]); pts.append(e.points[2])
            default: break
            }
        }
        guard pts.count >= 2 else { return nil }
        let s0 = pts[0], e0 = pts[pts.count - 1]
        let s1 = pts.dropFirst().first { hypot($0.x - s0.x, $0.y - s0.y) > 0.01 } ?? pts[1]
        let e1 = pts.dropLast().last { hypot($0.x - e0.x, $0.y - e0.y) > 0.01 } ?? pts[pts.count - 2]
        return (s0, s1, e0, e1)
    }

    /// Shortens an open path at its start and end (straight ends only), so a line stops inside its arrowhead.
    static func trim(_ path: CGPath, start: Double, end: Double) -> CGPath {
        guard start > 0 || end > 0 else { return path }
        var els: [(CGPathElementType, [CGPoint])] = []
        path.applyWithBlock { el in
            let e = el.pointee
            let n: Int
            switch e.type { case .moveToPoint, .addLineToPoint: n = 1; case .addQuadCurveToPoint: n = 2; case .addCurveToPoint: n = 3; default: n = 0 }
            els.append((e.type, (0..<n).map { e.points[$0] }))
        }
        func moved(_ p: CGPoint, toward q: CGPoint, by d: Double) -> CGPoint {
            let len = hypot(q.x - p.x, q.y - p.y)
            guard len > d * 1.2, len > 0 else { return p }
            return CGPoint(x: p.x + (q.x - p.x) * d / len, y: p.y + (q.y - p.y) * d / len)
        }
        if start > 0, els.count >= 2, els[0].0 == .moveToPoint, let next = els[1].1.first {
            els[0].1[0] = moved(els[0].1[0], toward: next, by: start)
        }
        if end > 0, let li = els.lastIndex(where: { $0.0 == .addLineToPoint }), li == els.count - 1, li >= 1, let prev = els[li - 1].1.last {
            els[li].1[0] = moved(els[li].1[0], toward: prev, by: end)
        }
        let out = CGMutablePath()
        for (t, p) in els {
            switch t {
            case .moveToPoint: out.move(to: p[0])
            case .addLineToPoint: out.addLine(to: p[0])
            case .addQuadCurveToPoint: out.addQuadCurve(to: p[1], control: p[0])
            case .addCurveToPoint: out.addCurve(to: p[2], control1: p[0], control2: p[1])
            case .closeSubpath: out.closeSubpath()
            @unknown default: break
            }
        }
        return out
    }
}
