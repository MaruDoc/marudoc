import Foundation
import CoreGraphics

/// Builds CGPaths in DrawingML terms: y grows downwards, angles are degrees clockwise from the x axis.
struct PathBuilder {
    let path = CGMutablePath()
    private(set) var current = CGPoint.zero
    private var subStart = CGPoint.zero
    private(set) var isEmpty = true

    mutating func move(_ x: Double, _ y: Double) {
        current = CGPoint(x: x, y: y); subStart = current
        path.move(to: current); isEmpty = false
    }

    mutating func line(_ x: Double, _ y: Double) {
        if isEmpty { move(x, y); return }
        current = CGPoint(x: x, y: y)
        path.addLine(to: current)
    }

    mutating func cubic(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double, _ y: Double) {
        if isEmpty { move(x1, y1) }
        current = CGPoint(x: x, y: y)
        path.addCurve(to: current, control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
    }

    mutating func quad(_ x1: Double, _ y1: Double, _ x: Double, _ y: Double) {
        if isEmpty { move(x1, y1) }
        current = CGPoint(x: x, y: y)
        path.addQuadCurve(to: current, control: CGPoint(x: x1, y: y1))
    }

    /// DrawingML arcTo: an arc of the ellipse with radii wR/hR that passes through the current point at angle `st`,
    /// sweeping `sw` degrees (positive = clockwise on the page). Angles are visual angles, as in the presets.
    mutating func arcTo(_ wR: Double, _ hR: Double, _ st: Double, _ sw: Double) {
        if isEmpty { move(Double(current.x), Double(current.y)) }
        guard wR > 0, hR > 0, sw != 0 else { return }
        func param(_ deg: Double) -> Double {
            let a = deg * .pi / 180
            return atan2(wR * sin(a), hR * cos(a))
        }
        let ts = param(st)
        var dt: Double
        if abs(sw) >= 360 { dt = sw > 0 ? 2 * .pi : -2 * .pi } else {
            dt = param(st + sw) - ts
            if sw > 0 { while dt <= 0 { dt += 2 * .pi } } else { while dt >= 0 { dt -= 2 * .pi } }
        }
        let cx = Double(current.x) - wR * cos(ts), cy = Double(current.y) - hR * sin(ts)
        let n = max(1, Int(ceil(abs(dt) / (.pi / 2) - 1e-9)))
        let step = dt / Double(n)
        let k = 4.0 / 3.0 * tan(step / 4)
        var t = ts
        for _ in 0..<n {
            let t2 = t + step
            let p1 = (cx + wR * cos(t), cy + hR * sin(t))
            let p2 = (cx + wR * cos(t2), cy + hR * sin(t2))
            let c1 = (p1.0 - k * wR * sin(t), p1.1 + k * hR * cos(t))
            let c2 = (p2.0 + k * wR * sin(t2), p2.1 - k * hR * cos(t2))
            cubic(c1.0, c1.1, c2.0, c2.1, p2.0, p2.1)
            t = t2
        }
    }

    mutating func close() { path.closeSubpath(); current = subStart }

    mutating func markUsed() { isEmpty = false }

    /// Full ellipse in the rectangle.
    mutating func ellipse(_ r: CGRect) { path.addEllipse(in: r); isEmpty = false }
}

/// One drawn part of a shape: some outlines are not filled (connectors, brackets) and some fills are not outlined
/// or are shaded (the folded corner).
struct GeoPath {
    enum Fill { case none, norm, darken, darkenLess, lighten, lightenLess }
    var path: CGPath
    var fill: Fill = .norm
    var stroke = true
}

struct ShapeGeometry {
    var paths: [GeoPath]
    /// Where text goes, in the shape's own coordinates.
    var textRect: CGRect
    /// The path is an open line (line, connectors, arcs, brackets): arrowheads apply.
    var isLine = false
}

enum DrawingGeometry {

    /// Geometry of a shape of size w x h from its a:prstGeom or a:custGeom element. Unknown presets fall back to
    /// the bounding rectangle so nothing vanishes; `unknown` collects their names.
    static func geometry(_ spPr: XNode?, w: Double, h: Double, unknown: inout Set<String>) -> ShapeGeometry {
        if let cust = spPr?.child("a:custGeom") { return custom(cust, w: w, h: h) }
        let prst = spPr?.child("a:prstGeom")
        let name = prst?["prst"] ?? "rect"
        var adj: [String: Double] = [:]
        for gd in prst?.child("a:avLst")?.children("a:gd") ?? [] {
            if let n = gd["name"], let f = gd["fmla"], f.hasPrefix("val "), let v = Double(f.dropFirst(4).trimmingCharacters(in: .whitespaces)) { adj[n] = v }
        }
        if let g = preset(name, w: w, h: h, adj: adj) { return g }
        unknown.insert(name)
        return rectGeometry(w, h)
    }

    static func rectGeometry(_ w: Double, _ h: Double) -> ShapeGeometry {
        ShapeGeometry(paths: [GeoPath(path: CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil))], textRect: CGRect(x: 0, y: 0, width: w, height: h))
    }

    // MARK: Presets

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func preset(_ name: String, w: Double, h: Double, adj: [String: Double]) -> ShapeGeometry? {
        let ss = min(w, h), hc = w / 2, vc = h / 2
        func a(_ key: String, _ def: Double) -> Double { adj[key] ?? def }
        func pin(_ lo: Double, _ v: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        var p = PathBuilder()
        var text = CGRect(x: 0, y: 0, width: w, height: h)
        func done(_ extra: [GeoPath] = [], fill: GeoPath.Fill = .norm, stroke: Bool = true, line: Bool = false) -> ShapeGeometry {
            ShapeGeometry(paths: [GeoPath(path: p.path, fill: fill, stroke: stroke)] + extra, textRect: text, isLine: line)
        }
        func poly(_ pts: [(Double, Double)]) {
            guard let f = pts.first else { return }
            p.move(f.0, f.1)
            for q in pts.dropFirst() { p.line(q.0, q.1) }
            p.close()
        }
        func roundedRect(_ r: Double) {
            let r = min(r, ss / 2)
            p.move(0, r); p.arcTo(r, r, 180, 90); p.line(w - r, 0); p.arcTo(r, r, 270, 90)
            p.line(w, h - r); p.arcTo(r, r, 0, 90); p.line(r, h); p.arcTo(r, r, 90, 90); p.close()
        }

        switch name {
        case "rect", "flowChartProcess", "actionButtonBlank":
            poly([(0, 0), (w, 0), (w, h), (0, h)])
            return done()

        case "roundRect", "flowChartAlternateProcess":
            let r = ss * pin(0, name == "roundRect" ? a("adj", 16667) : 16667, 50000) / 100_000
            roundedRect(r)
            let il = r * 0.29289
            text = CGRect(x: il, y: il, width: w - 2 * il, height: h - 2 * il)
            return done()

        case "flowChartTerminator":
            roundedRect(min(w, h) / 2)
            return done()

        case "round1Rect":
            let r = ss * pin(0, a("adj", 16667), 50000) / 100_000
            p.move(0, 0); p.line(w - r, 0); p.arcTo(r, r, 270, 90); p.line(w, h); p.line(0, h); p.close()
            return done()

        case "round2SameRect":
            let r1 = ss * pin(0, a("adj1", 16667), 50000) / 100_000, r2 = ss * pin(0, a("adj2", 0), 50000) / 100_000
            p.move(r1, 0); p.line(w - r1, 0); p.arcTo(r1, r1, 270, 90); p.line(w, h - r2); p.arcTo(r2, r2, 0, 90)
            p.line(r2, h); p.arcTo(r2, r2, 90, 90); p.line(0, r1); p.arcTo(r1, r1, 180, 90); p.close()
            return done()

        case "round2DiagRect":
            let r1 = ss * pin(0, a("adj1", 16667), 50000) / 100_000, r2 = ss * pin(0, a("adj2", 0), 50000) / 100_000
            p.move(r1, 0); p.line(w - r2, 0); p.arcTo(r2, r2, 270, 90); p.line(w, h - r1); p.arcTo(r1, r1, 0, 90)
            p.line(r2, h); p.arcTo(r2, r2, 90, 90); p.line(0, r1); p.arcTo(r1, r1, 180, 90); p.close()
            return done()

        case "snip1Rect":
            let d = ss * pin(0, a("adj", 16667), 50000) / 100_000
            poly([(0, 0), (w - d, 0), (w, d), (w, h), (0, h)])
            return done()

        case "snip2SameRect":
            let d1 = ss * pin(0, a("adj1", 16667), 50000) / 100_000, d2 = ss * pin(0, a("adj2", 0), 50000) / 100_000
            poly([(d1, 0), (w - d1, 0), (w, d1), (w, h - d2), (w - d2, h), (d2, h), (0, h - d2), (0, d1)])
            return done()

        case "snip2DiagRect":
            let d1 = ss * pin(0, a("adj1", 0), 50000) / 100_000, d2 = ss * pin(0, a("adj2", 16667), 50000) / 100_000
            poly([(d1, 0), (w - d2, 0), (w, d2), (w, h - d1), (w - d1, h), (d2, h), (0, h - d2), (0, d1)])
            return done()

        case "snipRoundRect":
            let r = ss * pin(0, a("adj1", 16667), 50000) / 100_000, d = ss * pin(0, a("adj2", 16667), 50000) / 100_000
            p.move(r, 0); p.line(w - d, 0); p.line(w, d); p.line(w, h); p.line(0, h); p.line(0, r); p.arcTo(r, r, 180, 90); p.close()
            return done()

        case "ellipse", "flowChartConnector":
            p.ellipse(CGRect(x: 0, y: 0, width: w, height: h))
            let dx = w / 2 * (1 - 0.70711), dy = h / 2 * (1 - 0.70711)
            text = CGRect(x: dx, y: dy, width: w - 2 * dx, height: h - 2 * dy)
            return done()

        case "triangle", "flowChartExtract":
            let x1 = w * pin(0, name == "triangle" ? a("adj", 50000) : 50000, 100_000) / 100_000
            poly([(x1, 0), (w, h), (0, h)])
            text = CGRect(x: x1 / 2, y: h / 2, width: w / 2, height: h / 2)
            return done()

        case "flowChartMerge":
            poly([(0, 0), (w, 0), (hc, h)])
            text = CGRect(x: w / 4, y: 0, width: w / 2, height: h / 2)
            return done()

        case "rtTriangle":
            poly([(0, 0), (w, h), (0, h)])
            text = CGRect(x: w / 12, y: h * 7 / 12, width: w / 2, height: h * 5 / 12 - h / 12)
            return done()

        case "diamond", "flowChartDecision":
            poly([(hc, 0), (w, vc), (hc, h), (0, vc)])
            text = CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2)
            return done()

        case "parallelogram", "flowChartInputOutput":
            let x2 = name == "parallelogram" ? ss * pin(0, a("adj", 25000), 100_000 * w / max(ss, 1e-9)) / 100_000 : w / 5
            poly([(0, h), (x2, 0), (w, 0), (w - x2, h)])
            text = CGRect(x: x2 / 2, y: 0, width: w - x2, height: h)
            return done()

        case "trapezoid":
            let x2 = ss * pin(0, a("adj", 25000), 50000 * w / max(ss, 1e-9)) / 100_000
            poly([(0, h), (x2, 0), (w - x2, 0), (w, h)])
            text = CGRect(x: x2 / 3, y: 0, width: w - 2 * x2 / 3, height: h)
            return done()

        case "flowChartManualOperation":
            poly([(0, 0), (w, 0), (w * 4 / 5, h), (w / 5, h)])
            return done()

        case "pentagon", "heptagon", "decagon", "dodecagon":
            let n = ["pentagon": 5, "heptagon": 7, "decagon": 10, "dodecagon": 12][name]!
            regular(&p, n: n, w: w, h: h)
            return done()

        case "hexagon":
            let x1 = ss * pin(0, a("adj", 25000), 50000 * w / max(ss, 1e-9)) / 100_000
            poly([(0, vc), (x1, 0), (w - x1, 0), (w, vc), (w - x1, h), (x1, h)])
            return done()

        case "flowChartPreparation":
            poly([(0, vc), (w / 5, 0), (w * 4 / 5, 0), (w, vc), (w * 4 / 5, h), (w / 5, h)])
            return done()

        case "octagon":
            let x1 = ss * pin(0, a("adj", 29289), 50000) / 100_000
            poly([(0, x1), (x1, 0), (w - x1, 0), (w, x1), (w, h - x1), (w - x1, h), (x1, h), (0, h - x1)])
            return done()

        case "homePlate":
            let x1 = ss * pin(0, a("adj", 50000), 100_000 * w / max(ss, 1e-9)) / 100_000
            poly([(0, 0), (w - x1, 0), (w, vc), (w - x1, h), (0, h)])
            return done()

        case "chevron":
            let x1 = ss * pin(0, a("adj", 50000), 100_000 * w / max(ss, 1e-9)) / 100_000
            poly([(0, 0), (w - x1, 0), (w, vc), (w - x1, h), (0, h), (x1, vc)])
            return done()

        case "rightArrow", "leftArrow", "notchedRightArrow":
            let a1 = pin(0, a("adj1", 50000), 100_000)
            let a2 = pin(0, a("adj2", 50000), 100_000 * w / max(ss, 1e-9))
            let dy = h * a1 / 200_000, hl = ss * a2 / 100_000
            if name == "leftArrow" {
                poly([(w, vc - dy), (hl, vc - dy), (hl, 0), (0, vc), (hl, h), (hl, vc + dy), (w, vc + dy)])
            } else if name == "rightArrow" {
                poly([(0, vc - dy), (w - hl, vc - dy), (w - hl, 0), (w, vc), (w - hl, h), (w - hl, vc + dy), (0, vc + dy)])
            } else {
                let notch = dy * hl / max(vc, 1e-9)
                poly([(0, vc - dy), (w - hl, vc - dy), (w - hl, 0), (w, vc), (w - hl, h), (w - hl, vc + dy), (0, vc + dy), (notch, vc)])
            }
            return done()

        case "upArrow", "downArrow":
            let a1 = pin(0, a("adj1", 50000), 100_000)
            let a2 = pin(0, a("adj2", 50000), 100_000 * h / max(ss, 1e-9))
            let dx = w * a1 / 200_000, hl = ss * a2 / 100_000
            if name == "upArrow" {
                poly([(hc - dx, h), (hc - dx, hl), (0, hl), (hc, 0), (w, hl), (hc + dx, hl), (hc + dx, h)])
            } else {
                poly([(hc - dx, 0), (hc - dx, h - hl), (0, h - hl), (hc, h), (w, h - hl), (hc + dx, h - hl), (hc + dx, 0)])
            }
            return done()

        case "leftRightArrow":
            let a1 = pin(0, a("adj1", 50000), 100_000)
            let a2 = pin(0, a("adj2", 50000), 50000 * w / max(ss, 1e-9))
            let dy = h * a1 / 200_000, hl = ss * a2 / 100_000
            poly([(0, vc), (hl, 0), (hl, vc - dy), (w - hl, vc - dy), (w - hl, 0), (w, vc), (w - hl, h), (w - hl, vc + dy), (hl, vc + dy), (hl, h)])
            return done()

        case "upDownArrow":
            let a1 = pin(0, a("adj1", 50000), 100_000)
            let a2 = pin(0, a("adj2", 50000), 50000 * h / max(ss, 1e-9))
            let dx = w * a1 / 200_000, hl = ss * a2 / 100_000
            poly([(hc, 0), (w, hl), (hc + dx, hl), (hc + dx, h - hl), (w, h - hl), (hc, h), (0, h - hl), (hc - dx, h - hl), (hc - dx, hl), (0, hl)])
            return done()

        case "line", "straightConnector1":
            p.move(0, 0); p.line(w, h)
            return done(fill: .none, line: true)

        case "bentConnector2":
            p.move(0, 0); p.line(w, 0); p.line(w, h)
            return done(fill: .none, line: true)

        case "bentConnector3":
            let x1 = w * a("adj1", 50000) / 100_000
            p.move(0, 0); p.line(x1, 0); p.line(x1, h); p.line(w, h)
            return done(fill: .none, line: true)

        case "bentConnector4":
            let x1 = w * a("adj1", 50000) / 100_000, y2 = h * a("adj2", 50000) / 100_000
            p.move(0, 0); p.line(x1, 0); p.line(x1, y2); p.line(w, y2); p.line(w, h)
            return done(fill: .none, line: true)

        case "bentConnector5":
            let x1 = w * a("adj1", 50000) / 100_000, y2 = h * a("adj2", 50000) / 100_000, x3 = w * a("adj3", 50000) / 100_000
            p.move(0, 0); p.line(x1, 0); p.line(x1, y2); p.line(x3, y2); p.line(x3, h); p.line(w, h)
            return done(fill: .none, line: true)

        case "curvedConnector2":
            p.move(0, 0); p.cubic(w / 2, 0, w, h / 2, w, h)
            return done(fill: .none, line: true)

        case "curvedConnector3":
            let x2 = w * a("adj1", 50000) / 100_000
            p.move(0, 0); p.cubic(x2 / 2, 0, x2, h / 4, x2, vc); p.cubic(x2, h * 3 / 4, (x2 + w) / 2, h, w, h)
            return done(fill: .none, line: true)

        case "curvedConnector4", "curvedConnector5":
            let x2 = w * a("adj1", 50000) / 100_000, y4 = h * a("adj2", 50000) / 100_000
            p.move(0, 0); p.cubic(x2 / 2, 0, x2, y4 / 2, x2, y4 / 2 + 0.0001)
            p.cubic(x2, y4, (x2 + w) / 2, y4, (x2 + w) / 2 + 0.0001, y4)
            p.cubic(w, y4, w, (y4 + h) / 2, w, h)
            return done(fill: .none, line: true)

        case "wedgeRectCallout", "wedgeRoundRectCallout":
            let dxPos = w * a("adj1", -20833) / 100_000, dyPos = h * a("adj2", 62500) / 100_000
            let xPos = hc + dxPos, yPos = vc + dyPos
            let dq = dxPos * h / max(w, 1e-9), dz = abs(dyPos) - abs(dq)
            let x1 = w * (dxPos > 0 ? 7 : 2) / 12, x2 = w * (dxPos > 0 ? 10 : 5) / 12
            let y1 = h * (dyPos > 0 ? 7 : 2) / 12, y2 = h * (dyPos > 0 ? 10 : 5) / 12
            let xl = dz > 0 ? 0 : (dxPos > 0 ? 0 : xPos)
            let xt = dz > 0 ? (dyPos > 0 ? x1 : xPos) : x1
            let xr = dz > 0 ? w : (dxPos > 0 ? xPos : w)
            let xb = dz > 0 ? (dyPos > 0 ? xPos : x1) : x1
            let yl = dz > 0 ? y1 : (dxPos > 0 ? y1 : yPos)
            let yt = dz > 0 ? (dyPos > 0 ? 0 : yPos) : 0
            let yr = dz > 0 ? y1 : (dxPos > 0 ? yPos : y1)
            let yb = dz > 0 ? (dyPos > 0 ? yPos : h) : h
            let r = name == "wedgeRoundRectCallout" ? min(ss * a("adj3", 16667) / 100_000, ss / 2) : 0
            if r > 0 { p.move(0, r); p.arcTo(r, r, 180, 90) } else { p.move(0, 0) }
            p.line(x1, 0); p.line(xt, yt); p.line(x2, 0)
            if r > 0 { p.line(w - r, 0); p.arcTo(r, r, 270, 90) } else { p.line(w, 0) }
            p.line(w, y1); p.line(xr, yr); p.line(w, y2)
            if r > 0 { p.line(w, h - r); p.arcTo(r, r, 0, 90) } else { p.line(w, h) }
            p.line(x2, h); p.line(xb, yb); p.line(x1, h)
            if r > 0 { p.line(r, h); p.arcTo(r, r, 90, 90) } else { p.line(0, h) }
            p.line(0, y2); p.line(xl, yl); p.line(0, y1); p.close()
            if r > 0 { let il = r * 0.29289; text = CGRect(x: il, y: il, width: w - 2 * il, height: h - 2 * il) }
            return done()

        case "wedgeEllipseCallout":
            let dxPos = w * a("adj1", -20833) / 100_000, dyPos = h * a("adj2", 62500) / 100_000
            let pang = atan2(dyPos * w, dxPos * h) * 180 / .pi
            let st = pang + 11, en = pang - 11
            func pt(_ deg: Double) -> (Double, Double) {
                let t = atan2(w / 2 * sin(deg * .pi / 180), h / 2 * cos(deg * .pi / 180))
                return (hc + w / 2 * cos(t), vc + h / 2 * sin(t))
            }
            let s = pt(st)
            p.move(s.0, s.1)
            var sweep = en - st
            while sweep <= 0 { sweep += 360 }
            p.arcTo(w / 2, h / 2, st, sweep)
            p.line(hc + dxPos, vc + dyPos); p.close()
            let dx = w / 2 * (1 - 0.70711), dy = h / 2 * (1 - 0.70711)
            text = CGRect(x: dx, y: dy, width: w - 2 * dx, height: h - 2 * dy)
            return done()

        case "cloud", "cloudCallout":
            cloud(&p, w: w, h: h)
            var extra: [GeoPath] = []
            if name == "cloudCallout" {
                let tx = hc + w * a("adj1", -20833) / 100_000, ty = vc + h * a("adj2", 62500) / 100_000
                let b = CGMutablePath()
                for (f, r) in [(0.9, ss * 0.03), (0.75, ss * 0.05), (0.58, ss * 0.075)] {
                    let x = hc + (tx - hc) * f, y = vc + (ty - vc) * f
                    b.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                }
                extra.append(GeoPath(path: b))
            }
            text = CGRect(x: w * 0.15, y: h * 0.2, width: w * 0.7, height: h * 0.6)
            return done(extra)

        case "leftBracket", "rightBracket":
            let y1 = min(ss * a("adj", 8333) / 100_000, h / 2)
            var f = PathBuilder()
            if name == "leftBracket" {
                p.move(w, h); p.arcTo(w, y1, 90, 90); p.line(0, y1); p.arcTo(w, y1, 180, 90)
                f.move(w, h); f.arcTo(w, y1, 90, 90); f.line(0, y1); f.arcTo(w, y1, 180, 90); f.close()
            } else {
                p.move(0, 0); p.arcTo(w, y1, 270, 90); p.line(w, h - y1); p.arcTo(w, y1, 0, 90)
                f.move(0, 0); f.arcTo(w, y1, 270, 90); f.line(w, h - y1); f.arcTo(w, y1, 0, 90); f.close()
            }
            return ShapeGeometry(paths: [GeoPath(path: f.path, fill: .norm, stroke: false), GeoPath(path: p.path, fill: .none)], textRect: text, isLine: true)

        case "leftBrace", "rightBrace":
            let y1 = min(ss * a("adj1", 8333) / 100_000, h / 4)
            let y3 = h * pin(0, a("adj2", 50000), 100_000) / 100_000
            let r = w / 2
            if name == "leftBrace" {
                p.move(w, h); p.arcTo(r, y1, 90, 90); p.line(r, y3 + y1); p.arcTo(r, y1, 0, -90)
                p.arcTo(r, y1, 90, -90); p.line(r, y1); p.arcTo(r, y1, 180, 90)
            } else {
                p.move(0, 0); p.arcTo(r, y1, 270, 90); p.line(r, y3 - y1); p.arcTo(r, y1, 180, -90)
                p.arcTo(r, y1, 270, -90); p.line(r, h - y1); p.arcTo(r, y1, 0, 90)
            }
            return done(fill: .none, line: true)

        case "bracketPair":
            let r = min(ss * a("adj", 16667) / 100_000, ss / 2)
            p.move(r, h); p.arcTo(r, r, 90, 90); p.line(0, r); p.arcTo(r, r, 180, 90)
            p.move(w - r, 0); p.arcTo(r, r, 270, 90); p.line(w, h - r); p.arcTo(r, r, 0, 90)
            let il = r * 0.29289
            text = CGRect(x: il, y: il, width: w - 2 * il, height: h - 2 * il)
            return done(fill: .none, line: true)

        case "bracePair":
            let r = min(ss * a("adj", 8333) / 100_000, ss / 4)
            p.move(2 * r, h); p.arcTo(r, r, 90, 90); p.line(r, vc + r); p.arcTo(r, r, 0, -90); p.arcTo(r, r, 90, -90)
            p.line(r, r); p.arcTo(r, r, 180, 90)
            p.move(w - 2 * r, 0); p.arcTo(r, r, 270, 90); p.line(w - r, vc - r); p.arcTo(r, r, 180, -90)
            p.arcTo(r, r, 270, -90); p.line(w - r, h - r); p.arcTo(r, r, 0, 90)
            return done(fill: .none, line: true)

        case "foldedCorner":
            let d = ss * pin(0, a("adj", 16667), 50000) / 100_000
            poly([(0, 0), (w, 0), (w, h - d), (w - d, h), (0, h)])
            var f = PathBuilder()
            let dx = d / 5
            f.move(w - d, h); f.line(w - d + dx, h - d + dx); f.line(w, h - d); f.close()
            text = CGRect(x: 0, y: 0, width: w, height: h - d)
            return done([GeoPath(path: f.path, fill: .darkenLess)])

        case "plus", "mathPlus":
            let x1 = ss * pin(0, a("adj", 25000), 50000) / 100_000
            if name == "plus" {
                poly([(0, x1), (x1, x1), (x1, 0), (w - x1, 0), (w - x1, x1), (w, x1), (w, h - x1), (w - x1, h - x1), (w - x1, h), (x1, h), (x1, h - x1), (0, h - x1)])
            } else {
                let t = ss * 0.2353 / 2, m = ss * 0.0587
                poly([(m, vc - t), (hc - t, vc - t), (hc - t, m), (hc + t, m), (hc + t, vc - t), (w - m, vc - t), (w - m, vc + t), (hc + t, vc + t), (hc + t, h - m), (hc - t, h - m), (hc - t, vc + t), (m, vc + t)])
            }
            return done()

        case "star4", "star5", "star6", "star8", "star10", "star12", "star16", "star24", "star32":
            let n = Int(name.dropFirst(4)) ?? 5
            let defaults: [Int: Double] = [4: 12500, 5: 19098, 6: 28868, 8: 37500, 10: 42533, 12: 37500, 16: 37500, 24: 37500, 32: 37500]
            let inner = pin(0, a("adj", defaults[n] ?? 37500), 50000) / 50000
            var pts: [(Double, Double)] = []
            for i in 0..<(2 * n) {
                let ang = -90.0 + Double(i) * 180 / Double(n)
                let rr = i % 2 == 0 ? 1.0 : inner
                pts.append((hc + w / 2 * rr * cos(ang * .pi / 180), vc + h / 2 * rr * sin(ang * .pi / 180)))
            }
            poly(pts)
            return done()

        case "donut":
            let d = ss * pin(0, a("adj", 25000), 50000) / 100_000
            let m = CGMutablePath()
            m.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: h))
            m.addEllipse(in: CGRect(x: d, y: d, width: max(w - 2 * d, 0), height: max(h - 2 * d, 0)))
            return ShapeGeometry(paths: [GeoPath(path: m)], textRect: text)

        case "frame":
            let d = ss * pin(0, a("adj1", 12500), 50000) / 100_000
            let m = CGMutablePath()
            m.addRect(CGRect(x: 0, y: 0, width: w, height: h))
            m.addRect(CGRect(x: d, y: d, width: max(w - 2 * d, 0), height: max(h - 2 * d, 0)))
            return ShapeGeometry(paths: [GeoPath(path: m)], textRect: text)

        case "arc":
            let st = a("adj1", 16_200_000) / 60000, en = a("adj2", 0) / 60000
            var sw = en - st
            while sw <= 0 { sw += 360 }
            let s = ellipsePoint(st, w, h)
            p.move(s.0, s.1); p.arcTo(w / 2, h / 2, st, sw)
            var f = PathBuilder()
            f.move(s.0, s.1); f.arcTo(w / 2, h / 2, st, sw); f.line(hc, vc); f.close()
            return ShapeGeometry(paths: [GeoPath(path: f.path, fill: .norm, stroke: false), GeoPath(path: p.path, fill: .none)], textRect: text, isLine: true)

        case "pie", "chord":
            let st = a("adj1", name == "pie" ? 0 : 2_700_000) / 60000, en = a("adj2", 16_200_000) / 60000
            var sw = en - st
            while sw <= 0 { sw += 360 }
            let s = ellipsePoint(st, w, h)
            p.move(s.0, s.1); p.arcTo(w / 2, h / 2, st, sw)
            if name == "pie" { p.line(hc, vc) }
            p.close()
            return done()

        case "blockArc":
            let st = a("adj1", 10_800_000) / 60000, en = a("adj2", 0) / 60000
            let d = ss * pin(0, a("adj3", 25000), 50000) / 100_000
            var sw = en - st
            while sw <= 0 { sw += 360 }
            let s = ellipsePoint(st, w, h)
            p.move(s.0, s.1); p.arcTo(w / 2, h / 2, st, sw)
            let iw = max(w / 2 - d, 0.01), ih = max(h / 2 - d, 0.01)
            let e = ellipsePoint(en, 2 * iw, 2 * ih)
            p.line(e.0 + d, e.1 + d); p.arcTo(iw, ih, en, -sw); p.close()
            return done()

        case "can", "flowChartMagneticDisk":
            let y1 = name == "can" ? ss * pin(0, a("adj", 25000), 50000 * h / max(ss, 1e-9)) / 200_000 : h / 6
            p.move(0, y1); p.arcTo(w / 2, y1, 180, -180); p.line(w, h - y1); p.arcTo(w / 2, y1, 0, 180); p.close()
            let top = CGMutablePath()
            top.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: 2 * y1))
            text = CGRect(x: 0, y: 2 * y1, width: w, height: max(h - 3 * y1, 0))
            return done([GeoPath(path: top, fill: .lighten)])

        case "cube":
            let d = ss * pin(0, a("adj", 25000), 100_000) / 100_000
            poly([(0, d), (d, 0), (w, 0), (w, h - d), (w - d, h), (0, h)])
            var t = PathBuilder(); t.move(0, d); t.line(d, 0); t.line(w, 0); t.line(w - d, d); t.close()
            var s = PathBuilder(); s.move(w - d, d); s.line(w, 0); s.line(w, h - d); s.line(w - d, h); s.close()
            text = CGRect(x: 0, y: d, width: w - d, height: h - d)
            return done([GeoPath(path: t.path, fill: .lightenLess), GeoPath(path: s.path, fill: .darkenLess)])

        case "flowChartDocument":
            p.move(0, 0); p.line(w, 0); p.line(w, h * 17322 / 21600)
            p.cubic(w * 10800 / 21600, h * 17322 / 21600, w * 10800 / 21600, h * 23922 / 21600, 0, h * 20172 / 21600)
            p.close()
            text = CGRect(x: 0, y: 0, width: w, height: h * 17322 / 21600)
            return done()

        case "flowChartPredefinedProcess":
            poly([(0, 0), (w, 0), (w, h), (0, h)])
            var l = PathBuilder(); l.move(w / 8, 0); l.line(w / 8, h); l.move(w * 7 / 8, 0); l.line(w * 7 / 8, h)
            text = CGRect(x: w / 8, y: 0, width: w * 3 / 4, height: h)
            return done([GeoPath(path: l.path, fill: .none)])

        case "teardrop":
            let r = min(w, h) / 2
            p.move(0, vc); p.arcTo(w / 2, h / 2, 180, 90); p.line(w, 0); p.line(w, vc); p.arcTo(w / 2, h / 2, 0, 180); p.close()
            _ = r
            return done()

        case "halfFrame", "corner":
            let d1 = ss * a("adj1", name == "corner" ? 50000 : 33333) / 100_000, d2 = ss * a("adj2", name == "corner" ? 50000 : 33333) / 100_000
            if name == "corner" { poly([(0, 0), (d2, 0), (d2, h - d1), (w, h - d1), (w, h), (0, h)]) } else {
                poly([(0, 0), (w, 0), (w - w * d1 / max(h, 1), d1), (d2, d1), (d2, h - h * d2 / max(w, 1)), (0, h)])
            }
            return done()

        default:
            return nil
        }
    }

    /// The point at visual angle `deg` on the ellipse inscribed in w x h.
    static func ellipsePoint(_ deg: Double, _ w: Double, _ h: Double) -> (Double, Double) {
        let a = deg * .pi / 180
        let t = atan2(w / 2 * sin(a), h / 2 * cos(a))
        return (w / 2 + w / 2 * cos(t), h / 2 + h / 2 * sin(t))
    }

    /// Regular n-gon inscribed in the box (pentagon etc. use PowerPoint's stretch so the shape fills its frame).
    private static func regular(_ p: inout PathBuilder, n: Int, w: Double, h: Double) {
        var pts: [(Double, Double)] = []
        for i in 0..<n {
            let ang = -90.0 + Double(i) * 360 / Double(n)
            pts.append((cos(ang * .pi / 180), sin(ang * .pi / 180)))
        }
        let minX = pts.map(\.0).min()!, maxX = pts.map(\.0).max()!, minY = pts.map(\.1).min()!, maxY = pts.map(\.1).max()!
        let scaled = pts.map { ((($0.0 - minX) / (maxX - minX)) * w, (($0.1 - minY) / (maxY - minY)) * h) }
        p.move(scaled[0].0, scaled[0].1)
        for q in scaled.dropFirst() { p.line(q.0, q.1) }
        p.close()
    }

    /// A cloud outline: the union of bumps around an ellipse, close to PowerPoint's preset.
    private static func cloud(_ p: inout PathBuilder, w: Double, h: Double) {
        // Bump centres and radii as fractions of the box, clockwise from the left.
        let bumps: [(Double, Double, Double)] = [
            (0.13, 0.55, 0.13), (0.17, 0.30, 0.14), (0.36, 0.15, 0.15), (0.56, 0.12, 0.14), (0.75, 0.18, 0.13),
            (0.88, 0.36, 0.12), (0.87, 0.60, 0.13), (0.73, 0.81, 0.14), (0.50, 0.86, 0.15), (0.28, 0.82, 0.14),
        ]
        var u = CGPath(ellipseIn: CGRect(x: 0.14 * w, y: 0.16 * h, width: 0.72 * w, height: 0.68 * h), transform: nil)
        for b in bumps {
            u = u.union(CGPath(ellipseIn: CGRect(x: (b.0 - b.2) * w, y: (b.1 - b.2) * h, width: 2 * b.2 * w, height: 2 * b.2 * h), transform: nil))
        }
        p.path.addPath(u)
        p.markUsed()
    }

    // MARK: Custom geometry

    static func custom(_ cust: XNode, w: Double, h: Double) -> ShapeGeometry {
        var guides = GuideEvaluator(w: w, h: h)
        for gd in cust.child("a:avLst")?.children("a:gd") ?? [] { guides.define(gd["name"], gd["fmla"]) }
        for gd in cust.child("a:gdLst")?.children("a:gd") ?? [] { guides.define(gd["name"], gd["fmla"]) }
        var out: [GeoPath] = []
        var allOpen = true
        for path in cust.child("a:pathLst")?.children("a:path") ?? [] {
            let pw = OOXMLValue.double(path["w"]) ?? 0, ph = OOXMLValue.double(path["h"]) ?? 0
            // Path coordinates are in the path's own w x h box, scaled to the shape.
            let sx = pw > 0 ? w / pw : 1, sy = ph > 0 ? h / ph : 1
            var pb = PathBuilder()
            var closed = false
            func pt(_ n: XNode?) -> (Double, Double) {
                (guides.value(n?["x"]) * sx, guides.value(n?["y"]) * sy)
            }
            for c in path.children {
                switch c.tag {
                case "a:moveTo": let q = pt(c.child("a:pt")); pb.move(q.0, q.1)
                case "a:lnTo": let q = pt(c.child("a:pt")); pb.line(q.0, q.1)
                case "a:arcTo":
                    pb.arcTo(guides.value(c["wR"]) * sx, guides.value(c["hR"]) * sy,
                             guides.value(c["stAng"]) / 60000, guides.value(c["swAng"]) / 60000)
                case "a:quadBezTo":
                    let pts = c.children("a:pt").map(pt)
                    if pts.count >= 2 { pb.quad(pts[0].0, pts[0].1, pts[1].0, pts[1].1) }
                case "a:cubicBezTo":
                    let pts = c.children("a:pt").map(pt)
                    if pts.count >= 3 { pb.cubic(pts[0].0, pts[0].1, pts[1].0, pts[1].1, pts[2].0, pts[2].1) }
                case "a:close": pb.close(); closed = true
                default: break
                }
            }
            let fill: GeoPath.Fill
            switch path["fill"] ?? "norm" {
            case "none": fill = .none
            case "darken": fill = .darken
            case "darkenLess": fill = .darkenLess
            case "lighten": fill = .lighten
            case "lightenLess": fill = .lightenLess
            default: fill = .norm
            }
            if closed { allOpen = false }
            out.append(GeoPath(path: pb.path, fill: fill, stroke: OOXMLValue.onOff(path["stroke"] ?? "1")))
        }
        var text = CGRect(x: 0, y: 0, width: w, height: h)
        if let r = cust.child("a:rect"), r["l"] != nil {
            let l = guides.value(r["l"]), t = guides.value(r["t"]), rr = guides.value(r["r"]), b = guides.value(r["b"])
            if rr > l, b > t { text = CGRect(x: l, y: t, width: rr - l, height: b - t) }
        }
        return ShapeGeometry(paths: out, textRect: text, isLine: allOpen && !out.isEmpty)
    }
}

/// Evaluates DrawingML shape guide formulas ("*/ w adj 100000", "+- l 0 x1", ...) for custom geometry.
struct GuideEvaluator {
    private var vars: [String: Double]

    init(w: Double, h: Double) {
        let ss = min(w, h), ls = max(w, h)
        vars = ["w": w, "h": h, "l": 0, "t": 0, "r": w, "b": h, "hc": w / 2, "vc": h / 2, "ss": ss, "ls": ls,
                "cd2": 10_800_000, "cd4": 5_400_000, "cd8": 2_700_000, "3cd4": 16_200_000, "3cd8": 8_100_000,
                "5cd8": 13_500_000, "7cd8": 18_900_000]
        for d in [2, 3, 4, 5, 6, 8, 10, 12, 16, 32] {
            vars["wd\(d)"] = w / Double(d); vars["hd\(d)"] = h / Double(d); vars["ssd\(d)"] = ss / Double(d)
        }
    }

    func value(_ s: String?) -> Double {
        guard let s else { return 0 }
        if let d = Double(s) { return d }
        return vars[s] ?? 0
    }

    mutating func define(_ name: String?, _ fmla: String?) {
        guard let name, let fmla else { return }
        let parts = fmla.split(separator: " ").map(String.init)
        guard let op = parts.first else { return }
        let x = parts.count > 1 ? value(parts[1]) : 0, y = parts.count > 2 ? value(parts[2]) : 0, z = parts.count > 3 ? value(parts[3]) : 0
        let deg = { (v: Double) in v / 60000 * .pi / 180 }
        var v: Double
        switch op {
        case "val": v = x
        case "*/": v = z != 0 ? x * y / z : 0
        case "+-": v = x + y - z
        case "+/": v = z != 0 ? (x + y) / z : 0
        case "?:": v = x > 0 ? y : z
        case "abs": v = abs(x)
        case "at2": v = atan2(y, x) * 180 / .pi * 60000
        case "cat2": v = x * cos(atan2(z, y))
        case "sat2": v = x * sin(atan2(z, y))
        case "cos": v = x * cos(deg(y))
        case "sin": v = x * sin(deg(y))
        case "tan": v = x * tan(deg(y))
        case "max": v = max(x, y)
        case "min": v = min(x, y)
        case "mod": v = (x * x + y * y + z * z).squareRoot()
        case "pin": v = y < x ? x : (y > z ? z : y)
        case "sqrt": v = x >= 0 ? x.squareRoot() : 0
        default: v = 0
        }
        vars[name] = v.isFinite ? v : 0
    }
}
