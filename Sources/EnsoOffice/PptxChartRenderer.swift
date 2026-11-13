import Foundation
import CoreGraphics
import CoreText

/// Charts (c:chart) drawn from the values cached in the chart part: bar / column (clustered, stacked, 100%), line,
/// area, pie and doughnut, with title, axes, gridlines, legend and simple data labels. Other chart types are
/// reported, not guessed.
extension SlideRenderer {

    private struct Series {
        var name: String
        var values: [Double?]
        var categories: [String]
        var spPr: XNode?
        var points: [Int: XNode] = [:]
        var labels: XNode?
        var marker = true
    }

    private struct Plot {
        var kind: String          // bar, line, area, pie, doughnut
        var horizontal = false
        var grouping = "clustered"
        var series: [Series] = []
        var gapWidth = 150.0
        var overlap = 0.0
        var holeSize = 50.0
        var firstSliceAngle = 0.0
        var varyColors = false
        var labels: XNode?
    }

    func drawChart(_ data: XNode, frame: CGRect, layer: Layer) {
        guard let rid = data.children.first(where: { $0.localName == "chart" })?["r:id"], let rel = pkg.rels(layer.part)[rid],
              let space = pkg.xml(rel.target), let chart = space.child("c:chart"), let area = chart.child("c:plotArea") else {
            gap("charts without data"); return
        }
        let colors = layer.colors
        // Chart-wide text size: c:txPr of the chart space, else 10 pt.
        let baseSize = (OOXMLValue.double(space.child("c:txPr")?.firstDescendant("a:defRPr")?["sz"]) ?? 1000) / 100
        let textColor = colors.color(in: space.child("c:txPr")?.firstDescendant("a:defRPr")?.child("a:solidFill")) ?? DColor(hex: "595959")!
        let fontName = scope.theme.minorLatin.isEmpty ? "Helvetica Neue" : scope.theme.minorLatin

        // Chart area fill and outline.
        if let spPr = space.child("c:spPr") {
            let path = CGPath(rect: frame, transform: nil)
            if let f = fillElement(in: spPr) { paint(path, fill: f, colors: colors, part: layer.part, bounds: frame) }
            if let ln = spPr.child("a:ln"), let st = lineStyle(ln, colors: colors) { stroke(path, st, isLine: false, draw: true) }
        }

        var plots: [Plot] = []
        for c in area.children {
            var p: Plot
            switch c.localName {
            case "barChart", "bar3DChart": p = Plot(kind: "bar"); p.horizontal = c.child("c:barDir")?["val"] == "bar"
            case "lineChart", "line3DChart", "stockChart": p = Plot(kind: "line")
            case "areaChart", "area3DChart": p = Plot(kind: "area")
            case "pieChart", "pie3DChart", "ofPieChart": p = Plot(kind: "pie")
            case "doughnutChart": p = Plot(kind: "doughnut")
            case "scatterChart", "radarChart", "bubbleChart", "surfaceChart", "surface3DChart":
                gap("charts of type \(c.localName)"); continue
            default: continue
            }
            p.grouping = c.child("c:grouping")?["val"] ?? (p.kind == "bar" ? "clustered" : "standard")
            p.gapWidth = OOXMLValue.double(c.child("c:gapWidth")?["val"]) ?? 150
            p.overlap = OOXMLValue.double(c.child("c:overlap")?["val"]) ?? (p.grouping == "clustered" ? 0 : 100)
            p.holeSize = OOXMLValue.double(c.child("c:holeSize")?["val"]) ?? 50
            p.firstSliceAngle = OOXMLValue.double(c.child("c:firstSliceAng")?["val"]) ?? 0
            p.varyColors = OOXMLValue.onOff(c.child("c:varyColors")?["val"] ?? (p.kind == "pie" || p.kind == "doughnut" ? "1" : "0"))
            p.labels = c.child("c:dLbls")
            for ser in c.children("c:ser") {
                var s = Series(name: SlideRenderer.chartText(ser.child("c:tx")), values: SlideRenderer.chartNumbers(ser.child("c:val") ?? ser.child("c:yVal")),
                               categories: SlideRenderer.chartStrings(ser.child("c:cat") ?? ser.child("c:xVal")), spPr: ser.child("c:spPr"))
                for dp in ser.children("c:dPt") { if let i = OOXMLValue.int(dp.child("c:idx")?["val"]) { s.points[i] = dp.child("c:spPr") } }
                s.labels = ser.child("c:dLbls")
                if ser.child("c:marker")?.child("c:symbol")?["val"] == "none" { s.marker = false }
                if c.child("c:marker")?["val"] == "0" { s.marker = false }
                p.series.append(s)
            }
            if !p.series.isEmpty { plots.append(p) }
        }
        guard !plots.isEmpty else { return }

        // Title and legend take their room first.
        var inner = frame.insetBy(dx: 6, dy: 6)
        let titleNode = chart.child("c:title")
        var title: String?
        if let t = titleNode {
            let rich = t.child("c:tx")?.firstDescendant("c:rich")
            let s = rich.map { $0.allText("a:t") } ?? ""
            title = s.isEmpty ? (plots.first?.series.count == 1 ? plots.first?.series.first?.name : nil) ?? "Chart Title" : s
        }
        if let title, !title.isEmpty {
            let size = (OOXMLValue.double(titleNode?.firstDescendant("a:defRPr")?["sz"] ?? titleNode?.firstDescendant("a:rPr")?["sz"]) ?? baseSize * 120) / 100
            let tsize = size > 0 ? size : baseSize * 1.2
            drawLabel(title, size: tsize, color: textColor, font: fontName, at: CGPoint(x: inner.midX, y: inner.minY + tsize * 0.6), align: .center)
            inner.origin.y += tsize * 1.6; inner.size.height -= tsize * 1.6
        }
        let allSeries = plots.flatMap(\.series)
        let isPie = plots[0].kind == "pie" || plots[0].kind == "doughnut"
        let legendNames: [String] = isPie ? (plots[0].series.first?.categories ?? []) : allSeries.map(\.name)
        let legendSize = (OOXMLValue.double(chart.child("c:legend")?.firstDescendant("a:defRPr")?["sz"]) ?? baseSize * 100) / 100
        func seriesColor(_ i: Int) -> DColor {
            let accents = ["accent1", "accent2", "accent3", "accent4", "accent5", "accent6"]
            var c = colors.scheme(accents[i % 6]) ?? .black
            let round = i / 6
            if round > 0 { c = ColorResolver.apply([XNode(tag: round % 2 == 1 ? "a:shade" : "a:tint", attrs: ["val": "60000"])], to: c) }
            return c
        }
        func fill(of s: Series, index i: Int, point: Int?) -> DColor {
            if let point, let sp = s.points[point], let f = sp.child("a:solidFill"), let c = colors.color(in: f) { return c }
            if let sp = s.spPr, let f = sp.child("a:solidFill"), let c = colors.color(in: f) { return c }
            if let sp = s.spPr, let g = sp.child("a:gradFill"), let c = colors.color(in: g.child("a:gsLst")?.children("a:gs").first) { return c }
            return seriesColor(point ?? i)
        }
        var legendEntries: [(String, DColor)] = []
        if isPie { legendEntries = legendNames.enumerated().map { ($0.element, fill(of: plots[0].series[0], index: 0, point: $0.offset)) } } else {
            var k = 0
            for p in plots { for s in p.series { legendEntries.append((s.name, fill(of: s, index: k, point: nil))); k += 1 } }
        }
        if let legend = chart.child("c:legend"), !legendEntries.isEmpty {
            let pos = legend.child("c:legendPos")?["val"] ?? "r"
            let rowH = legendSize * 1.5
            if pos == "b" || pos == "t" {
                let widths = legendEntries.map { textWidth($0.0, size: legendSize, font: fontName) + legendSize * 1.6 }
                var x = inner.midX - widths.reduce(0, +) / 2
                let y = pos == "b" ? inner.maxY - rowH / 2 : inner.minY + rowH / 2
                for (i, e) in legendEntries.enumerated() {
                    ctx.setFillColor(e.1.cgColor); ctx.fill(CGRect(x: x, y: y - legendSize * 0.35, width: legendSize * 0.7, height: legendSize * 0.7))
                    drawLabel(e.0, size: legendSize, color: textColor, font: fontName, at: CGPoint(x: x + legendSize, y: y), align: .left)
                    x += widths[i]
                }
                if pos == "b" { inner.size.height -= rowH * 1.3 } else { inner.origin.y += rowH * 1.3; inner.size.height -= rowH * 1.3 }
            } else {
                let w = (legendEntries.map { textWidth($0.0, size: legendSize, font: fontName) }.max() ?? 0) + legendSize * 1.6
                let x = pos == "l" ? inner.minX : inner.maxX - w
                var y = inner.midY - Double(legendEntries.count) * rowH / 2 + rowH / 2
                for e in legendEntries {
                    ctx.setFillColor(e.1.cgColor); ctx.fill(CGRect(x: x, y: y - legendSize * 0.35, width: legendSize * 0.7, height: legendSize * 0.7))
                    drawLabel(e.0, size: legendSize, color: textColor, font: fontName, at: CGPoint(x: x + legendSize, y: y), align: .left)
                    y += rowH
                }
                if pos == "l" { inner.origin.x += w + 8 }
                inner.size.width -= w + 8
            }
        }

        if isPie {
            drawPie(plots[0], in: inner, fill: { fill(of: $0, index: 0, point: $1) }, labelSize: baseSize, textColor: textColor, font: fontName)
            return
        }

        // Value axis range over every plot.
        var lo = 0.0, hi = 0.0
        for p in plots {
            let n = p.series.map(\.values.count).max() ?? 0
            if p.grouping == "percentStacked" { hi = max(hi, 1); continue }
            if p.grouping == "stacked" {
                for i in 0..<n {
                    var pos = 0.0, neg = 0.0
                    for s in p.series { if i < s.values.count, let v = s.values[i] { if v >= 0 { pos += v } else { neg += v } } }
                    hi = max(hi, pos); lo = min(lo, neg)
                }
            } else {
                for s in p.series { for v in s.values.compactMap({ $0 }) { hi = max(hi, v); lo = min(lo, v) } }
            }
        }
        let valAx = area.children("c:valAx").first
        if let m = OOXMLValue.double(valAx?.child("c:scaling")?.child("c:max")?["val"]) { hi = m }
        if let m = OOXMLValue.double(valAx?.child("c:scaling")?.child("c:min")?["val"]) { lo = m }
        let (axLo, axHi, step) = SlideRenderer.niceAxis(lo, hi, fixedMin: valAx?.child("c:scaling")?.child("c:min") != nil, fixedMax: valAx?.child("c:scaling")?.child("c:max") != nil,
                                                       major: OOXMLValue.double(valAx?.child("c:majorUnit")?["val"]))
        let percent = plots.contains { $0.grouping == "percentStacked" }
        let fmt = valAx?.child("c:numFmt")?["formatCode"]
        func label(_ v: Double) -> String { percent ? "\(Int((v * 100).rounded()))%" : SlideRenderer.formatNumber(v, fmt) }
        let catAx = area.children.first { $0.localName == "catAx" || $0.localName == "dateAx" }
        let showVal = valAx.map { !OOXMLValue.onOff($0.child("c:delete")?["val"] ?? "0") && $0.child("c:tickLblPos")?["val"] != "none" } ?? false
        let showCat = catAx.map { !OOXMLValue.onOff($0.child("c:delete")?["val"] ?? "0") && $0.child("c:tickLblPos")?["val"] != "none" } ?? false
        let horizontal = plots.contains { $0.horizontal }
        let categories = allSeries.first(where: { !$0.categories.isEmpty })?.categories ?? []
        let nCat = max(allSeries.map(\.values.count).max() ?? 0, categories.count, 1)
        let ticks = stride(from: axLo, through: axHi + step * 0.001, by: step).map { $0 }
        let valLabelW = showVal ? (ticks.map { textWidth(label($0), size: baseSize, font: fontName) }.max() ?? 0) + 6 : 0
        let catLabelH = showCat ? baseSize * 1.6 : 0
        let catLabelW = showCat && horizontal ? (categories.map { textWidth($0, size: baseSize, font: fontName) }.max() ?? 0) + 6 : 0
        var plotRect: CGRect
        if horizontal {
            plotRect = CGRect(x: inner.minX + catLabelW, y: inner.minY + 4, width: inner.width - catLabelW - 8, height: inner.height - (showVal ? baseSize * 1.6 : 0) - 4)
        } else {
            plotRect = CGRect(x: inner.minX + valLabelW, y: inner.minY + baseSize * 0.6, width: inner.width - valLabelW - 8, height: inner.height - catLabelH - baseSize * 0.6)
        }
        if let layout = area.child("c:layout")?.child("c:manualLayout"), let x = OOXMLValue.double(layout.child("c:x")?["val"]),
           let y = OOXMLValue.double(layout.child("c:y")?["val"]), let w = OOXMLValue.double(layout.child("c:w")?["val"]), let h = OOXMLValue.double(layout.child("c:h")?["val"]),
           layout.child("c:layoutTarget")?["val"] == "inner" {
            plotRect = CGRect(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y, width: frame.width * w, height: frame.height * h)
        }
        guard plotRect.width > 4, plotRect.height > 4 else { return }
        func valPos(_ v: Double) -> Double {
            let t = (v - axLo) / max(axHi - axLo, 1e-12)
            return horizontal ? Double(plotRect.minX) + t * Double(plotRect.width) : Double(plotRect.maxY) - t * Double(plotRect.height)
        }
        // Gridlines and value labels.
        let grid = DColor(hex: "D9D9D9")!.cgColor
        for t in ticks {
            let p = valPos(t)
            if valAx?.child("c:majorGridlines") != nil {
                ctx.setStrokeColor(grid); ctx.setLineWidth(0.75)
                if horizontal { ctx.strokeLineSegments(between: [CGPoint(x: p, y: plotRect.minY), CGPoint(x: p, y: plotRect.maxY)]) }
                else { ctx.strokeLineSegments(between: [CGPoint(x: plotRect.minX, y: p), CGPoint(x: plotRect.maxX, y: p)]) }
            }
            if showVal {
                if horizontal { drawLabel(label(t), size: baseSize, color: textColor, font: fontName, at: CGPoint(x: p, y: plotRect.maxY + baseSize * 0.9), align: .center) }
                else { drawLabel(label(t), size: baseSize, color: textColor, font: fontName, at: CGPoint(x: plotRect.minX - 4, y: p), align: .right) }
            }
        }
        // Category axis line and labels.
        let band = (horizontal ? Double(plotRect.height) : Double(plotRect.width)) / Double(nCat)
        ctx.setStrokeColor(DColor(hex: "BFBFBF")!.cgColor); ctx.setLineWidth(0.75)
        let zero = valPos(min(max(0, axLo), axHi))
        if horizontal { ctx.strokeLineSegments(between: [CGPoint(x: zero, y: plotRect.minY), CGPoint(x: zero, y: plotRect.maxY)]) }
        else { ctx.strokeLineSegments(between: [CGPoint(x: plotRect.minX, y: zero), CGPoint(x: plotRect.maxX, y: zero)]) }
        if showCat {
            for i in 0..<nCat where i < categories.count {
                let c = (horizontal ? Double(plotRect.minY) : Double(plotRect.minX)) + band * (Double(i) + 0.5)
                if horizontal { drawLabel(categories[i], size: baseSize, color: textColor, font: fontName, at: CGPoint(x: plotRect.minX - 4, y: c), align: .right) }
                else { drawLabel(categories[i], size: baseSize, color: textColor, font: fontName, at: CGPoint(x: c, y: plotRect.maxY + baseSize * 0.9), align: .center) }
            }
        }

        var seriesIndex = 0
        for p in plots {
            let n = p.series.count
            switch p.kind {
            case "bar":
                let groupW = band / (1 + p.gapWidth / 100)
                let stacked = p.grouping != "clustered"
                let overlap = stacked ? 1.0 : p.overlap / 100
                let barW = stacked ? groupW : groupW / (Double(n) - overlap * Double(n - 1))
                var posBase = [Double](repeating: 0, count: nCat), negBase = [Double](repeating: 0, count: nCat)
                for (si, s) in p.series.enumerated() {
                    for i in 0..<min(s.values.count, nCat) {
                        guard var v = s.values[i] else { continue }
                        if p.grouping == "percentStacked" {
                            let total = p.series.compactMap { i < $0.values.count ? $0.values[i].map(abs) : nil }.reduce(0, +)
                            v = total > 0 ? v / total : 0
                        }
                        var start = 0.0
                        if stacked { start = v >= 0 ? posBase[i] : negBase[i]; if v >= 0 { posBase[i] += v } else { negBase[i] += v } }
                        let center = (horizontal ? Double(plotRect.minY) : Double(plotRect.minX)) + band * (Double(i) + 0.5)
                        let offset = stacked ? -barW / 2 : -groupW / 2 + Double(si) * barW * (1 - overlap)
                        let a = valPos(start), b = valPos(start + v)
                        let r = horizontal ? CGRect(x: min(a, b), y: center + offset, width: abs(b - a), height: barW)
                                           : CGRect(x: center + offset, y: min(a, b), width: barW, height: abs(b - a))
                        let col = fill(of: s, index: seriesIndex + si, point: p.varyColors && n == 1 ? i : nil)
                        ctx.setFillColor(col.cgColor); ctx.fill(r)
                        if let ln = (s.points[i] ?? s.spPr)?.child("a:ln"), let st = lineStyle(ln, colors: colors) { stroke(CGPath(rect: r, transform: nil), st, isLine: false, draw: true) }
                        if SlideRenderer.showsValue(s.labels ?? p.labels) {
                            let tp = horizontal ? CGPoint(x: max(a, b) + 4 + textWidth(label(v), size: baseSize, font: fontName) / 2, y: r.midY) : CGPoint(x: r.midX, y: min(a, b) - baseSize * 0.7)
                            drawLabel(SlideRenderer.formatNumber(s.values[i] ?? 0, nil), size: baseSize, color: textColor, font: fontName, at: tp, align: .center)
                        }
                    }
                }
            case "line", "area":
                var base = [Double](repeating: 0, count: nCat)
                for (si, s) in p.series.enumerated() {
                    let col = fill(of: s, index: seriesIndex + si, point: nil)
                    var pts: [CGPoint] = []
                    for i in 0..<min(s.values.count, nCat) {
                        guard var v = s.values[i] else { continue }
                        if p.grouping == "stacked" || p.grouping == "percentStacked" { v += base[i]; base[i] = v }
                        let c = Double(plotRect.minX) + band * (Double(i) + 0.5)
                        pts.append(horizontal ? CGPoint(x: valPos(v), y: c) : CGPoint(x: c, y: valPos(v)))
                    }
                    guard pts.count > 0 else { continue }
                    let path = CGMutablePath()
                    path.addLines(between: pts)
                    if p.kind == "area" {
                        let a = CGMutablePath(); a.move(to: CGPoint(x: pts[0].x, y: zero)); a.addLines(between: pts); a.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: zero)); a.closeSubpath()
                        ctx.addPath(a); ctx.setFillColor(col.cgColor); ctx.fillPath()
                    } else {
                        var st = LineStyle(); st.width = 2.25; st.color = col; st.cap = .round
                        if let ln = s.spPr?.child("a:ln"), let own = lineStyle(ln, colors: colors) { st = own }
                        stroke(path, st, isLine: false, draw: true)
                        if s.marker {
                            ctx.setFillColor(col.cgColor)
                            for pt in pts { ctx.fillEllipse(in: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)) }
                        }
                    }
                    if SlideRenderer.showsValue(s.labels ?? p.labels) {
                        for (k, pt) in pts.enumerated() where k < s.values.count {
                            drawLabel(SlideRenderer.formatNumber(s.values[k] ?? 0, nil), size: baseSize, color: textColor, font: fontName, at: CGPoint(x: pt.x, y: pt.y - baseSize * 0.9), align: .center)
                        }
                    }
                }
            default: break
            }
            seriesIndex += n
        }
    }

    private func drawPie(_ p: Plot, in r: CGRect, fill: (Series, Int) -> DColor, labelSize: Double, textColor: DColor, font: String) {
        guard let s = p.series.first else { return }
        let vals = s.values.map { max($0 ?? 0, 0) }
        let total = vals.reduce(0, +)
        guard total > 0 else { return }
        let radius = min(r.width, r.height) / 2 * 0.9
        let c = CGPoint(x: r.midX, y: r.midY)
        var ang = (p.firstSliceAngle - 90) * .pi / 180
        let hole = p.kind == "doughnut" ? radius * p.holeSize / 100 : 0
        for (i, v) in vals.enumerated() where v > 0 {
            let sweep = v / total * 2 * .pi
            let path = CGMutablePath()
            path.addArc(center: c, radius: radius, startAngle: ang, endAngle: ang + sweep, clockwise: false)
            if hole > 0 { path.addArc(center: c, radius: hole, startAngle: ang + sweep, endAngle: ang, clockwise: true) } else { path.addLine(to: c) }
            path.closeSubpath()
            ctx.addPath(path); ctx.setFillColor(fill(s, i).cgColor); ctx.fillPath()
            ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1); ctx.strokePath()
            let labels = s.labels ?? p.labels
            if SlideRenderer.showsValue(labels) || OOXMLValue.onOff(labels?.child("c:showPercent")?["val"] ?? "0") {
                let mid = ang + sweep / 2
                let rr = hole > 0 ? (radius + hole) / 2 : radius * 0.65
                let text = OOXMLValue.onOff(labels?.child("c:showPercent")?["val"] ?? "0") ? "\(Int((v / total * 100).rounded()))%" : SlideRenderer.formatNumber(v, nil)
                drawLabel(text, size: labelSize, color: .white, font: font, at: CGPoint(x: c.x + rr * cos(mid), y: c.y + rr * sin(mid)), align: .center)
            }
            ang += sweep
        }
    }

    static func showsValue(_ labels: XNode?) -> Bool {
        guard let labels, labels.child("c:delete").map({ !OOXMLValue.onOff($0["val"] ?? "1") }) ?? true else { return false }
        return OOXMLValue.onOff(labels.child("c:showVal")?["val"] ?? "0")
    }

    static func chartText(_ tx: XNode?) -> String {
        guard let tx else { return "" }
        if let v = tx.firstDescendant("c:v") { return v.text }
        return tx.allText("a:t")
    }

    static func chartStrings(_ n: XNode?) -> [String] {
        guard let n else { return [] }
        // Multi-level categories: the innermost level.
        let cache = n.firstDescendant("c:strCache") ?? n.firstDescendant("c:numCache") ?? n.firstDescendant("c:strLit") ?? n.firstDescendant("c:numLit")
            ?? n.firstDescendant("c:lvl")
        guard let cache else { return [] }
        let count = min(OOXMLValue.int(cache.child("c:ptCount")?["val"]) ?? 0, 10_000)
        var out = [String](repeating: "", count: count)
        for pt in cache.children("c:pt") {
            guard let i = OOXMLValue.int(pt["idx"]), i >= 0, i < 10_000 else { continue }
            if i >= out.count { out += [String](repeating: "", count: i - out.count + 1) }
            out[i] = pt.child("c:v")?.text ?? ""
        }
        return out
    }

    static func chartNumbers(_ n: XNode?) -> [Double?] {
        guard let cache = n?.firstDescendant("c:numCache") ?? n?.firstDescendant("c:numLit") else { return [] }
        let count = min(OOXMLValue.int(cache.child("c:ptCount")?["val"]) ?? 0, 10_000)
        var out = [Double?](repeating: nil, count: count)
        for pt in cache.children("c:pt") {
            guard let i = OOXMLValue.int(pt["idx"]), i >= 0, i < 10_000 else { continue }
            if i >= out.count { out += [Double?](repeating: nil, count: i - out.count + 1) }
            out[i] = OOXMLValue.double(pt.child("c:v")?.text)
        }
        return out
    }

    /// Axis bounds and major unit the way Office picks them: zero-based when the data allows, a 1/2/5 step giving
    /// about five to ten intervals, and the top rounded up past the largest value.
    static func niceAxis(_ lo0: Double, _ hi0: Double, fixedMin: Bool, fixedMax: Bool, major: Double?) -> (Double, Double, Double) {
        var lo = lo0, hi = hi0
        if hi <= lo { hi = lo + 1 }
        let range = hi - lo
        var step = major ?? 0
        if step <= 0 {
            let raw = range / 7
            let mag = pow(10, floor(log10(raw)))
            step = [1.0, 2, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? 10 * mag
        }
        if !fixedMax { hi = (ceil((hi + range * 0.05) / step - 1e-9)) * step }
        if !fixedMin { lo = floor(lo / step + 1e-9) * step }
        let count = (hi - lo) / step
        if count > 200 { step = (hi - lo) / 10 }
        return (lo, hi, step)
    }

    static func formatNumber(_ v: Double, _ fmt: String?) -> String {
        if let fmt, fmt.contains("%") { return "\(Int((v * 100).rounded()))%" }
        if v == v.rounded(), abs(v) < 1e15 {
            let i = Int(v)
            if let fmt, fmt.contains("#,##0") || fmt.contains(",") {
                let f = NumberFormatter(); f.numberStyle = .decimal
                return f.string(from: NSNumber(value: i)) ?? "\(i)"
            }
            return "\(i)"
        }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: Plain labels

    func textWidth(_ s: String, size: Double, font: String) -> Double {
        CTLineGetTypographicBounds(labelLine(s, size: size, color: .black, font: font), nil, nil, nil)
    }

    private func labelLine(_ s: String, size: Double, color: DColor, font: String) -> CTLine {
        let out = NSMutableAttributedString()
        let latin = fonts.face(font, size: size, bold: false, italic: false, eastAsian: false)
        let ea = fonts.face(scope.theme.minorEA.isEmpty ? (scope.theme.minorScripts["Jpan"] ?? "Hiragino Sans") : scope.theme.minorEA, size: size, bold: false, italic: false, eastAsian: true)
        for sc in s.unicodeScalars {
            var f = DocxDisplayFonts.isEastAsian(sc) ? ea : latin
            if SlideFonts.sharedGlyphScalars.contains(sc.value), SlideFonts.sharesGlyphs(f.font) { f = fonts.textLayerSafeFace(for: f, scalar: sc, size: size, bold: false) }
            out.append(NSAttributedString(string: String(sc), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f.font,
                                                                           NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]))
        }
        return CTLineCreateWithAttributedString(out as CFAttributedString)
    }

    enum LabelAlign { case left, center, right }

    /// One line of real text centred vertically on `at`.
    func drawLabel(_ s: String, size: Double, color: DColor, font: String, at p: CGPoint, align: LabelAlign) {
        guard !s.isEmpty else { return }
        let line = labelLine(s, size: size, color: color, font: font)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        let x = align == .left ? Double(p.x) : align == .center ? Double(p.x) - w / 2 : Double(p.x) - w
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: Double(p.y) + size * 0.35)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
