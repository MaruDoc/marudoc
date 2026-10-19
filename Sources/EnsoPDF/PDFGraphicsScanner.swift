import Foundation
import CoreGraphics
import EnsoDoc

/// Approximate RGB colour of a fill or stroke (device colour spaces only; patterns are unknown).
struct RGBColor: Hashable {
    var r: Double, g: Double, b: Double
    var isNearlyWhite: Bool { r > 0.94 && g > 0.94 && b > 0.94 }
    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
}

/// An axis-aligned ruling line in display space.
struct RuleLine {
    var horizontal: Bool
    /// y for horizontal rules, x for vertical ones.
    var pos: CGFloat
    var lo: CGFloat
    var hi: CGFloat
}

struct ShapeInfo {
    var rect: CGRect
    var isRect: Bool
    var filled: Bool
    var stroked: Bool
    var color: RGBColor?
}

struct ImagePlacement {
    let stream: CGPDFStreamRef
    /// ColorSpace object resolved through the resources at the place of use (nil = read from the image dict).
    let colorSpace: CGPDFObjectRef?
    /// Visible rect (display space, clipped).
    let rect: CGRect
    /// Rect the full image would cover if unclipped.
    let drawnRect: CGRect
    let key: Int
    let isMask: Bool
    let pixelWidth: Int
    let pixelHeight: Int
}

struct PageGraphics {
    var textRuns: [TextRun] = []
    var rules: [RuleLine] = []
    var fills: [ShapeInfo] = []
    var shapes: [ShapeInfo] = []
    var images: [ImagePlacement] = []
    var paintedPaths = 0
}

/// Walks a page content stream (recursing into Form XObjects) with CGPDFScanner, tracking the CTM,
/// a rectangular clip and device colours, and collects image placements, ruling lines and shapes.
final class GraphicsScanner {
    struct GState {
        var ctm: CGAffineTransform = .identity
        var fill: RGBColor? = RGBColor(r: 0, g: 0, b: 0)
        var stroke: RGBColor? = RGBColor(r: 0, g: 0, b: 0)
        var clip: CGRect?   // display space
        // Text state (part of the graphics state).
        var font: PDFFontInfo?
        var fontSize: CGFloat = 0
        var charSpace: CGFloat = 0
        var wordSpace: CGFloat = 0
        var hScale: CGFloat = 1
        var leading: CGFloat = 0
        var rise: CGFloat = 0
        var renderMode = 0
    }

    fileprivate var gs = GState()
    private var stack: [GState] = []
    private var subpaths: [[CGPoint]] = []   // display space
    private var subCurve: [Bool] = []
    private var subRect: [Bool] = []
    fileprivate var pendingClip = false
    private var formStack: [Int] = []
    private var ops = 0
    private let maxOps = 1_500_000
    private let geo: PageGeometry
    fileprivate let wantVectors: Bool
    private var table: CGPDFOperatorTableRef?
    private var pageResources: CGPDFDictionaryRef?
    fileprivate var tm = CGAffineTransform.identity
    fileprivate var tlm = CGAffineTransform.identity
    private var fonts: [Int: PDFFontInfo] = [:]
    fileprivate var result = PageGraphics()

    private init(geo: PageGeometry, vectors: Bool) {
        self.geo = geo
        wantVectors = vectors
    }

    static func scan(page: CGPDFPage, geo: PageGeometry, vectors: Bool = true) -> PageGraphics {
        let st = GraphicsScanner(geo: geo, vectors: vectors)
        guard let table = CGPDFOperatorTableCreate() else { return st.result }
        defer { CGPDFOperatorTableRelease(table) }
        register(table)
        st.table = table
        if let pd = page.dictionary {
            var r: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pd, "Resources", &r) { st.pageResources = r }
        }
        let cs = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(cs) }
        let info = Unmanaged.passUnretained(st).toOpaque()
        let scanner = CGPDFScannerCreate(cs, table, info)
        defer { CGPDFScannerRelease(scanner) }
        _ = withExtendedLifetime(st) { CGPDFScannerScan(scanner) }
        return st.result
    }

    // MARK: Operator table

    fileprivate static func me(_ info: UnsafeMutableRawPointer?) -> GraphicsScanner? {
        guard let info else { return nil }
        let s = Unmanaged<GraphicsScanner>.fromOpaque(info).takeUnretainedValue()
        s.ops += 1
        return s.ops > s.maxOps ? nil : s
    }

    fileprivate static func pop(_ s: CGPDFScannerRef, _ n: Int) -> [CGFloat]? {
        var out = [CGFloat](repeating: 0, count: n)
        var i = n - 1
        while i >= 0 {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(s, &v), v.isFinite else { return nil }
            out[i] = CGFloat(v)
            i -= 1
        }
        return out
    }

    fileprivate static func popAll(_ s: CGPDFScannerRef) -> [CGFloat] {
        var vals: [CGFloat] = []
        var v: CGPDFReal = 0
        while vals.count < 8 && CGPDFScannerPopNumber(s, &v) { vals.insert(CGFloat(v), at: 0) }
        return vals
    }

    fileprivate static func color(from v: [CGFloat]) -> RGBColor? {
        switch v.count {
        case 1: return RGBColor(r: Double(v[0]), g: Double(v[0]), b: Double(v[0]))
        case 3: return RGBColor(r: Double(v[0]), g: Double(v[1]), b: Double(v[2]))
        case 4:
            let k = Double(v[3])
            return RGBColor(r: (1 - Double(v[0])) * (1 - k), g: (1 - Double(v[1])) * (1 - k), b: (1 - Double(v[2])) * (1 - k))
        default: return nil
        }
    }

    private static func register(_ t: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(t, "q") { _, i in GraphicsScanner.me(i)?.push() }
        CGPDFOperatorTableSetCallback(t, "Q") { _, i in GraphicsScanner.me(i)?.popState() }
        CGPDFOperatorTableSetCallback(t, "cm") { s, i in
            guard let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 6) else { return }
            st.gs.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(st.gs.ctm)
        }
        CGPDFOperatorTableSetCallback(t, "m") { s, i in
            guard let st = GraphicsScanner.me(i), st.wantVectors, let v = GraphicsScanner.pop(s, 2) else { return }
            st.moveTo(CGPoint(x: v[0], y: v[1]))
        }
        CGPDFOperatorTableSetCallback(t, "l") { s, i in
            guard let st = GraphicsScanner.me(i), st.wantVectors, let v = GraphicsScanner.pop(s, 2) else { return }
            st.lineTo(CGPoint(x: v[0], y: v[1]), curve: false)
        }
        CGPDFOperatorTableSetCallback(t, "c") { s, i in
            guard let st = GraphicsScanner.me(i), st.wantVectors, let v = GraphicsScanner.pop(s, 6) else { return }
            st.lineTo(CGPoint(x: v[0], y: v[1]), curve: true)
            st.lineTo(CGPoint(x: v[2], y: v[3]), curve: true)
            st.lineTo(CGPoint(x: v[4], y: v[5]), curve: true)
        }
        let curve4: CGPDFOperatorCallback = { s, i in
            guard let st = GraphicsScanner.me(i), st.wantVectors, let v = GraphicsScanner.pop(s, 4) else { return }
            st.lineTo(CGPoint(x: v[0], y: v[1]), curve: true)
            st.lineTo(CGPoint(x: v[2], y: v[3]), curve: true)
        }
        CGPDFOperatorTableSetCallback(t, "v", curve4)
        CGPDFOperatorTableSetCallback(t, "y", curve4)
        CGPDFOperatorTableSetCallback(t, "h") { _, i in GraphicsScanner.me(i)?.closePath() }
        CGPDFOperatorTableSetCallback(t, "re") { s, i in
            guard let st = GraphicsScanner.me(i), st.wantVectors, let v = GraphicsScanner.pop(s, 4) else { return }
            st.rect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
        }
        CGPDFOperatorTableSetCallback(t, "S") { _, i in GraphicsScanner.me(i)?.paint(fill: false, stroke: true) }
        CGPDFOperatorTableSetCallback(t, "s") { _, i in GraphicsScanner.me(i)?.closeAndPaint(fill: false, stroke: true) }
        let fill: CGPDFOperatorCallback = { _, i in GraphicsScanner.me(i)?.paint(fill: true, stroke: false) }
        CGPDFOperatorTableSetCallback(t, "f", fill)
        CGPDFOperatorTableSetCallback(t, "F", fill)
        CGPDFOperatorTableSetCallback(t, "f*", fill)
        let both: CGPDFOperatorCallback = { _, i in GraphicsScanner.me(i)?.paint(fill: true, stroke: true) }
        CGPDFOperatorTableSetCallback(t, "B", both)
        CGPDFOperatorTableSetCallback(t, "B*", both)
        let closeBoth: CGPDFOperatorCallback = { _, i in GraphicsScanner.me(i)?.closeAndPaint(fill: true, stroke: true) }
        CGPDFOperatorTableSetCallback(t, "b", closeBoth)
        CGPDFOperatorTableSetCallback(t, "b*", closeBoth)
        CGPDFOperatorTableSetCallback(t, "n") { _, i in GraphicsScanner.me(i)?.paint(fill: false, stroke: false) }
        let clip: CGPDFOperatorCallback = { _, i in GraphicsScanner.me(i)?.pendingClip = true }
        CGPDFOperatorTableSetCallback(t, "W", clip)
        CGPDFOperatorTableSetCallback(t, "W*", clip)
        CGPDFOperatorTableSetCallback(t, "g") { s, i in guard let st = GraphicsScanner.me(i) else { return }; st.gs.fill = GraphicsScanner.color(from: GraphicsScanner.popAll(s)) }
        CGPDFOperatorTableSetCallback(t, "rg") { s, i in guard let st = GraphicsScanner.me(i) else { return }; st.gs.fill = GraphicsScanner.color(from: GraphicsScanner.popAll(s)) }
        CGPDFOperatorTableSetCallback(t, "k") { s, i in guard let st = GraphicsScanner.me(i) else { return }; st.gs.fill = GraphicsScanner.color(from: GraphicsScanner.popAll(s)) }
        CGPDFOperatorTableSetCallback(t, "G") { s, i in guard let st = GraphicsScanner.me(i) else { return }; st.gs.stroke = GraphicsScanner.color(from: GraphicsScanner.popAll(s)) }
        CGPDFOperatorTableSetCallback(t, "RG") { s, i in guard let st = GraphicsScanner.me(i) else { return }; st.gs.stroke = GraphicsScanner.color(from: GraphicsScanner.popAll(s)) }
        CGPDFOperatorTableSetCallback(t, "K") { s, i in guard let st = GraphicsScanner.me(i) else { return }; st.gs.stroke = GraphicsScanner.color(from: GraphicsScanner.popAll(s)) }
        let fillSC: CGPDFOperatorCallback = { s, i in guard let st = GraphicsScanner.me(i) else { return }; st.gs.fill = GraphicsScanner.color(from: GraphicsScanner.popAll(s)) }
        CGPDFOperatorTableSetCallback(t, "sc", fillSC)
        CGPDFOperatorTableSetCallback(t, "scn", fillSC)
        let strokeSC: CGPDFOperatorCallback = { s, i in guard let st = GraphicsScanner.me(i) else { return }; st.gs.stroke = GraphicsScanner.color(from: GraphicsScanner.popAll(s)) }
        CGPDFOperatorTableSetCallback(t, "SC", strokeSC)
        CGPDFOperatorTableSetCallback(t, "SCN", strokeSC)
        CGPDFOperatorTableSetCallback(t, "cs") { _, i in GraphicsScanner.me(i)?.gs.fill = RGBColor(r: 0, g: 0, b: 0) }
        CGPDFOperatorTableSetCallback(t, "CS") { _, i in GraphicsScanner.me(i)?.gs.stroke = RGBColor(r: 0, g: 0, b: 0) }
        CGPDFOperatorTableSetCallback(t, "sh") { _, i in
            guard let st = GraphicsScanner.me(i), st.wantVectors, let clip = st.gs.clip else { return }
            st.result.fills.append(ShapeInfo(rect: clip, isRect: true, filled: true, stroked: false, color: nil))
            st.result.paintedPaths += 1
        }
        CGPDFOperatorTableSetCallback(t, "Do") { s, i in GraphicsScanner.me(i)?.doXObject(s) }
        registerText(t)
    }

    private static func registerText(_ t: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(t, "BT") { _, i in
            guard let st = GraphicsScanner.me(i) else { return }
            st.tm = .identity; st.tlm = .identity
        }
        CGPDFOperatorTableSetCallback(t, "Tf") { s, i in
            guard let st = GraphicsScanner.me(i) else { return }
            var size: CGPDFReal = 0
            guard CGPDFScannerPopNumber(s, &size) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(s, &name), let name else { return }
            st.gs.fontSize = CGFloat(size)
            st.gs.font = st.font(named: name, cs: CGPDFScannerGetContentStream(s))
        }
        CGPDFOperatorTableSetCallback(t, "Tc") { s, i in if let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 1) { st.gs.charSpace = v[0] } }
        CGPDFOperatorTableSetCallback(t, "Tw") { s, i in if let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 1) { st.gs.wordSpace = v[0] } }
        CGPDFOperatorTableSetCallback(t, "Tz") { s, i in if let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 1) { st.gs.hScale = v[0] / 100 } }
        CGPDFOperatorTableSetCallback(t, "TL") { s, i in if let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 1) { st.gs.leading = v[0] } }
        CGPDFOperatorTableSetCallback(t, "Ts") { s, i in if let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 1) { st.gs.rise = v[0] } }
        CGPDFOperatorTableSetCallback(t, "Tr") { s, i in if let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 1) { st.gs.renderMode = SafeInt.round(Double(v[0]), 0, 7) } }
        CGPDFOperatorTableSetCallback(t, "Td") { s, i in
            guard let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 2) else { return }
            st.moveText(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(t, "TD") { s, i in
            guard let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 2) else { return }
            st.gs.leading = -v[1]
            st.moveText(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(t, "Tm") { s, i in
            guard let st = GraphicsScanner.me(i), let v = GraphicsScanner.pop(s, 6) else { return }
            st.tlm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            st.tm = st.tlm
        }
        CGPDFOperatorTableSetCallback(t, "T*") { _, i in
            guard let st = GraphicsScanner.me(i) else { return }
            st.moveText(0, -st.gs.leading)
        }
        CGPDFOperatorTableSetCallback(t, "Tj") { s, i in
            guard let st = GraphicsScanner.me(i) else { return }
            var str: CGPDFStringRef?
            guard CGPDFScannerPopString(s, &str), let str else { return }
            st.show([.string(str)])
        }
        CGPDFOperatorTableSetCallback(t, "'") { s, i in
            guard let st = GraphicsScanner.me(i) else { return }
            var str: CGPDFStringRef?
            guard CGPDFScannerPopString(s, &str), let str else { return }
            st.moveText(0, -st.gs.leading)
            st.show([.string(str)])
        }
        CGPDFOperatorTableSetCallback(t, "\"") { s, i in
            guard let st = GraphicsScanner.me(i) else { return }
            var str: CGPDFStringRef?
            guard CGPDFScannerPopString(s, &str), let str, let v = GraphicsScanner.pop(s, 2) else { return }
            st.gs.wordSpace = v[0]; st.gs.charSpace = v[1]
            st.moveText(0, -st.gs.leading)
            st.show([.string(str)])
        }
        CGPDFOperatorTableSetCallback(t, "TJ") { s, i in
            guard let st = GraphicsScanner.me(i) else { return }
            var arr: CGPDFArrayRef?
            guard CGPDFScannerPopArray(s, &arr), let arr else { return }
            var parts: [ShowPart] = []
            for k in 0..<min(CGPDFArrayGetCount(arr), 20000) {
                var obj: CGPDFObjectRef?
                guard CGPDFArrayGetObject(arr, k, &obj), let obj else { continue }
                var str: CGPDFStringRef?
                var num: CGPDFReal = 0
                if CGPDFObjectGetValue(obj, .string, &str), let str { parts.append(.string(str)) } else if CGPDFObjectGetValue(obj, .real, &num), num.isFinite { parts.append(.kern(CGFloat(num))) }
            }
            st.show(parts)
        }
    }

    fileprivate enum ShowPart { case string(CGPDFStringRef), kern(CGFloat) }

    fileprivate func moveText(_ tx: CGFloat, _ ty: CGFloat) {
        tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(tlm)
        tm = tlm
    }

    fileprivate func font(named name: UnsafePointer<CChar>, cs: CGPDFContentStreamRef) -> PDFFontInfo? {
        guard let obj = CGPDFContentStreamGetResource(cs, "Font", name) else { return nil }
        var dict: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(obj, .dictionary, &dict), let dict else { return nil }
        let key = unsafeBitCast(dict, to: Int.self)
        if let f = fonts[key] { return f }
        let f = PDFFontInfo.load(dict)
        fonts[key] = f
        return f
    }

    fileprivate func show(_ parts: [ShowPart]) {
        let size = gs.fontSize
        var tx: CGFloat = 0
        let layout = gs.font?.layout ?? .single
        var count = 0, wide = 0
        for part in parts {
            switch part {
            case .kern(let n):
                tx -= n / 1000 * size * gs.hScale
            case .string(let str):
                guard let ptr = CGPDFStringGetBytePtr(str) else { continue }
                let len = CGPDFStringGetLength(str)
                var k = 0
                while k < len {
                    let b0 = Int(ptr[k])
                    let isLead: Bool
                    switch layout {
                    case .single: isLead = false
                    case .double: isLead = true
                    case .shiftJIS: isLead = (0x81...0x9F).contains(b0) || (0xE0...0xFC).contains(b0)
                    case .euc: isLead = b0 == 0x8E || (0xA1...0xFE).contains(b0)
                    }
                    let code: Int
                    if isLead && k + 1 < len { code = b0 << 8 | Int(ptr[k + 1]); k += 2 } else { code = b0; k += 1 }
                    let oneByte = !(isLead && code > 0xFF)
                    if !oneByte || code != 32 { count += 1 }
                    if !oneByte && (layout == .shiftJIS || layout == .euc) { wide += 1 }
                    var adv = (gs.font?.width(code) ?? 0.5) * size + gs.charSpace
                    if oneByte && code == 32 { adv += gs.wordSpace }
                    tx += adv * gs.hScale
                }
            }
        }
        if size != 0, result.textRuns.count < 200_000, size.isFinite, tx.isFinite {
            let m = tm.concatenating(gs.ctm)
            let a = geo.toDisplay(CGPoint(x: 0, y: gs.rise).applying(m))
            let b = geo.toDisplay(CGPoint(x: tx, y: gs.rise).applying(m))
            let up = CGPoint(x: 0, y: size).applying(CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0))
            let right = CGPoint(x: size, y: 0).applying(CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0))
            // Angle between the glyph x and y axes; ~90 degrees unless the text is obliqued.
            let dot = up.x * right.x + up.y * right.y
            let norms = max(1e-6, hypot(up.x, up.y) * hypot(right.x, right.y))
            let slanted = abs(dot / norms) > 0.12
            // Text far outside any page (or non-finite) cannot be real; dropping it also keeps later Int conversions safe.
            let limit: CGFloat = 1e7
            guard [a.x, a.y, b.x, b.y, up.x, up.y].allSatisfy({ $0.isFinite && abs($0) < limit }) else { tm = CGAffineTransform(translationX: tx, y: 0).concatenating(tm); return }
            result.textRuns.append(TextRun(start: a, end: b, size: hypot(up.x, up.y), font: gs.font, renderMode: gs.renderMode, glyphCount: count, wideCount: wide, slanted: slanted))
        }
        tm = CGAffineTransform(translationX: tx, y: 0).concatenating(tm)
    }

    // MARK: State

    fileprivate func push() { stack.append(gs) }
    fileprivate func popState() { if let last = stack.popLast() { gs = last } }

    private func display(_ p: CGPoint) -> CGPoint { geo.toDisplay(p.applying(gs.ctm)) }

    fileprivate func moveTo(_ p: CGPoint) {
        subpaths.append([display(p)])
        subCurve.append(false)
        subRect.append(false)
    }

    fileprivate func lineTo(_ p: CGPoint, curve: Bool) {
        if subpaths.isEmpty { moveTo(p); return }
        subpaths[subpaths.count - 1].append(display(p))
        if curve { subCurve[subCurve.count - 1] = true }
    }

    fileprivate func closePath() {
        guard let first = subpaths.last?.first, let last = subpaths.last?.last, first != last else { return }
        subpaths[subpaths.count - 1].append(first)
    }

    fileprivate func rect(_ r: CGRect) {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
        subpaths.append(pts.map(display))
        subCurve.append(false)
        let t = gs.ctm.concatenating(geo.transform)
        subRect.append((abs(t.b) < 1e-6 && abs(t.c) < 1e-6) || (abs(t.a) < 1e-6 && abs(t.d) < 1e-6))
    }

    fileprivate func closeAndPaint(fill: Bool, stroke: Bool) {
        for k in subpaths.indices {
            if let f = subpaths[k].first, let l = subpaths[k].last, f != l { subpaths[k].append(f) }
        }
        paint(fill: fill, stroke: stroke)
    }

    private static func bbox(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .null }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func isAxisRect(_ pts: [CGPoint]) -> Bool {
        guard pts.count == 4 || pts.count == 5 else { return false }
        for k in 0..<(pts.count - 1) {
            let a = pts[k], b = pts[k + 1]
            if abs(a.x - b.x) > 0.5 && abs(a.y - b.y) > 0.5 { return false }
        }
        return true
    }

    private func clipped(_ r: CGRect) -> CGRect {
        guard let c = gs.clip else { return r }
        return r.intersection(c.insetBy(dx: -0.5, dy: -0.5))
    }

    fileprivate func paint(fill: Bool, stroke: Bool) {
        defer {
            if pendingClip {
                let b = subpaths.map(GraphicsScanner.bbox).reduce(CGRect.null) { $0.union($1) }
                if !b.isNull { gs.clip = gs.clip.map { $0.intersection(b) } ?? b }
                pendingClip = false
            }
            subpaths.removeAll(keepingCapacity: true)
            subCurve.removeAll(keepingCapacity: true)
            subRect.removeAll(keepingCapacity: true)
        }
        guard wantVectors, fill || stroke else { return }
        let fillVisible = fill && !(gs.fill?.isNearlyWhite ?? false)
        let strokeVisible = stroke && !(gs.stroke?.isNearlyWhite ?? false)
        guard fillVisible || strokeVisible else { return }
        result.paintedPaths += 1
        var curveBox = CGRect.null
        var curvePath = false
        for k in subpaths.indices {
            let pts = subpaths[k]
            guard pts.count >= 2 else { continue }
            let box = GraphicsScanner.bbox(pts)
            if subCurve[k] {
                curvePath = true
                curveBox = curveBox.union(box)
                continue
            }
            let rectLike = subRect[k] || GraphicsScanner.isAxisRect(pts)
            if rectLike {
                let r = clipped(box)
                guard !r.isNull, r.width > 0.01 || r.height > 0.01 else { continue }
                if fillVisible {
                    if r.height <= 2.5 && r.width >= 6 {
                        result.rules.append(RuleLine(horizontal: true, pos: r.midY, lo: r.minX, hi: r.maxX))
                    } else if r.width <= 2.5 && r.height >= 6 {
                        result.rules.append(RuleLine(horizontal: false, pos: r.midX, lo: r.minY, hi: r.maxY))
                    } else if r.width > 2.5 && r.height > 2.5 {
                        result.fills.append(ShapeInfo(rect: r, isRect: true, filled: true, stroked: strokeVisible, color: gs.fill))
                    }
                }
                if strokeVisible {
                    if r.width >= 4 {
                        result.rules.append(RuleLine(horizontal: true, pos: r.minY, lo: r.minX, hi: r.maxX))
                        if r.height >= 2.5 { result.rules.append(RuleLine(horizontal: true, pos: r.maxY, lo: r.minX, hi: r.maxX)) }
                    }
                    if r.height >= 4 {
                        result.rules.append(RuleLine(horizontal: false, pos: r.minX, lo: r.minY, hi: r.maxY))
                        if r.width >= 2.5 { result.rules.append(RuleLine(horizontal: false, pos: r.maxX, lo: r.minY, hi: r.maxY)) }
                    }
                    if !fillVisible && r.width > 4 && r.height > 4 {
                        result.shapes.append(ShapeInfo(rect: r, isRect: true, filled: false, stroked: true, color: gs.stroke))
                    }
                }
                continue
            }
            // Polylines / polygons.
            var diagonal = false
            if strokeVisible {
                for j in 0..<(pts.count - 1) {
                    let a = pts[j], b = pts[j + 1]
                    if abs(a.y - b.y) < 1 && abs(a.x - b.x) >= 4 {
                        let r = clipped(CGRect(x: min(a.x, b.x), y: a.y, width: abs(a.x - b.x), height: 0))
                        if !r.isNull { result.rules.append(RuleLine(horizontal: true, pos: a.y, lo: r.minX, hi: r.maxX)) }
                    } else if abs(a.x - b.x) < 1 && abs(a.y - b.y) >= 4 {
                        let r = clipped(CGRect(x: a.x, y: min(a.y, b.y), width: 0, height: abs(a.y - b.y)))
                        if !r.isNull { result.rules.append(RuleLine(horizontal: false, pos: a.x, lo: r.minY, hi: r.maxY)) }
                    } else if hypot(a.x - b.x, a.y - b.y) > 1 {
                        diagonal = true
                    }
                }
            }
            if diagonal || fillVisible {
                let r = clipped(box)
                if !r.isNull && (r.width > 1 || r.height > 1) {
                    result.shapes.append(ShapeInfo(rect: r, isRect: false, filled: fillVisible, stroked: strokeVisible, color: fillVisible ? gs.fill : gs.stroke))
                }
            }
        }
        if curvePath {
            let r = clipped(curveBox)
            if !r.isNull && (r.width > 1 || r.height > 1) {
                result.shapes.append(ShapeInfo(rect: r, isRect: false, filled: fillVisible, stroked: strokeVisible, color: fillVisible ? gs.fill : gs.stroke))
            }
        }
    }

    // MARK: XObjects

    fileprivate func doXObject(_ s: CGPDFScannerRef) {
        var namePtr: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(s, &namePtr), let namePtr else { return }
        let cs = CGPDFScannerGetContentStream(s)
        guard let obj = CGPDFContentStreamGetResource(cs, "XObject", namePtr) else { return }
        var streamRef: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &streamRef), let stream = streamRef,
              let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
        let kind = String(cString: subtype)
        if kind == "Image" {
            recordImage(stream: stream, dict: dict, cs: cs)
        } else if kind == "Form" {
            runForm(stream: stream, dict: dict, parent: cs, scanner: s)
        }
    }

    private func recordImage(stream: CGPDFStreamRef, dict: CGPDFDictionaryRef, cs: CGPDFContentStreamRef) {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(display)
        let drawn = GraphicsScanner.bbox(corners)
        let r = clipped(drawn)
        guard !r.isNull, r.width > 0.5, r.height > 0.5 else { return }
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0
        _ = CGPDFDictionaryGetInteger(dict, "Width", &w)
        _ = CGPDFDictionaryGetInteger(dict, "Height", &h)
        var isMask: CGPDFBoolean = 0
        _ = CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask)
        var csObj: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dict, "ColorSpace", &csObj), let o = csObj {
            var name: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(o, .name, &name), let name, !PDFColorSpace.isDeviceName(String(cString: name)) {
                csObj = CGPDFContentStreamGetResource(cs, "ColorSpace", name)
            } else {
                csObj = nil
            }
        } else {
            csObj = nil
        }
        result.images.append(ImagePlacement(stream: stream, colorSpace: csObj, rect: r, drawnRect: drawn,
                                            key: unsafeBitCast(stream, to: Int.self), isMask: isMask != 0,
                                            pixelWidth: Int(w), pixelHeight: Int(h)))
    }

    private func runForm(stream: CGPDFStreamRef, dict: CGPDFDictionaryRef, parent: CGPDFContentStreamRef, scanner: CGPDFScannerRef) {
        let id = unsafeBitCast(stream, to: Int.self)
        guard !formStack.contains(id), formStack.count < 12, let table else { return }
        var m = CGAffineTransform.identity
        var arr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let arr, CGPDFArrayGetCount(arr) == 6 {
            var v = [CGFloat](repeating: 0, count: 6)
            var ok = true
            for k in 0..<6 {
                var x: CGPDFReal = 0
                if CGPDFArrayGetNumber(arr, k, &x), x.isFinite { v[k] = CGFloat(x) } else { ok = false }
            }
            if ok { m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]) }
        }
        var resRef: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(dict, "Resources", &resRef) { resRef = nil }
        guard let res = resRef ?? pageResources else { return }
        formStack.append(id)
        push()
        gs.ctm = m.concatenating(gs.ctm)
        var bboxArr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "BBox", &bboxArr), let a = bboxArr, CGPDFArrayGetCount(a) == 4 {
            var v = [CGFloat](repeating: 0, count: 4)
            var ok = true
            for k in 0..<4 {
                var x: CGPDFReal = 0
                if CGPDFArrayGetNumber(a, k, &x), x.isFinite { v[k] = CGFloat(x) } else { ok = false }
            }
            if ok {
                let pts = [CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[1]), CGPoint(x: v[2], y: v[3]), CGPoint(x: v[0], y: v[3])].map(display)
                let b = GraphicsScanner.bbox(pts)
                gs.clip = gs.clip.map { $0.intersection(b) } ?? b
            }
        }
        let saved = (subpaths, subCurve, subRect, pendingClip)
        subpaths = []; subCurve = []; subRect = []; pendingClip = false
        let cs2 = CGPDFContentStreamCreateWithStream(stream, res, parent)
        let sc2 = CGPDFScannerCreate(cs2, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(sc2)
        CGPDFScannerRelease(sc2)
        CGPDFContentStreamRelease(cs2)
        (subpaths, subCurve, subRect, pendingClip) = saved
        popState()
        formStack.removeLast()
    }
}
