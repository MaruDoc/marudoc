import Foundation
import CoreText
import CoreGraphics
import EnsoDoc

/// Draws the common chart types (column, bar, line, area, pie, doughnut, scatter) from the values cached in the file,
/// or read from the sheet when the file has no cache. Plain Excel-like look: title, value axis with gridlines,
/// category labels, legend. Text is real text.
struct SheetChartPainter {
    let ctx: CGContext

    static let fallbackColors = ["4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47"].compactMap { DocColor(hex: $0) }

    func color(_ chart: SheetChart, _ i: Int) -> CGColor {
        if i < chart.series.count, let c = chart.series[i].color { return SheetText.cg(c) }
        let p = chart.palette.count >= 6 ? chart.palette : SheetChartPainter.fallbackColors
        let base = p[i % p.count]
        // Past the six accents Excel darkens them.
        let c = i >= p.count ? XlsxLayoutReader.tinted(base, -0.25) : base
        return SheetText.cg(c)
    }

    private func line(_ text: String, size: Double, bold: Bool = false, color: CGColor = CGColor(gray: 0.25, alpha: 1)) -> (CTLine, Double, Double, Double) {
        var f = SheetFont(name: nil, size: size)
        f.bold = bold
        let l = CTLineCreateWithAttributedString(SheetFonts.attributed([(text, f, color)]))
        var a: CGFloat = 0, d: CGFloat = 0, lead: CGFloat = 0
        let w = CTLineGetTypographicBounds(l, &a, &d, &lead)
        return (l, Double(w), Double(a), Double(d))
    }

    private func text(_ s: String, size: Double, at p: CGPoint, align: Int, bold: Bool = false, maxWidth: Double? = nil) {
        let (l, w, a, d) = line(s, size: size, bold: bold)
        var x = Double(p.x) - (align == 0 ? 0 : (align == 1 ? w / 2 : w))
        if let maxWidth, w > maxWidth { x = Double(p.x) - maxWidth / 2 }
        ctx.textPosition = CGPoint(x: x, y: Double(p.y) - (a - d) / 2)
        CTLineDraw(l, ctx)
        ctx.textMatrix = .identity
    }

    func draw(_ chart: SheetChart, in rect: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState(); ctx.textMatrix = .identity }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
        ctx.setLineWidth(0.6)
        ctx.stroke(rect.insetBy(dx: 0.3, dy: 0.3))
        ctx.clip(to: rect)
        let base = max(7, min(10, Double(rect.height) / 22))
        var area = rect.insetBy(dx: 8, dy: 8)
        if let t = chart.title, !t.isEmpty {
            let size = base * 1.4
            text(t, size: size, at: CGPoint(x: area.midX, y: area.maxY - size * 0.7), align: 1, bold: true)
            area.size.height -= size * 1.6
        }
        let pie = chart.kind == .pie || chart.kind == .doughnut
        // Legend: series names (categories for pies).
        let legendItems: [String] = pie ? (chart.series.first?.categories ?? []) : chart.series.map(\.name)
        if let pos = chart.legend, !legendItems.isEmpty {
            let entryH = base * 1.5
            let widths = legendItems.map { line($0, size: base).1 + base * 1.6 }
            if pos == "b" || pos == "t" {
                let total = widths.reduce(0, +)
                var x = Double(area.midX) - total / 2
                let y = pos == "b" ? Double(area.minY) + entryH / 2 : Double(area.maxY) - entryH / 2
                for (i, item) in legendItems.enumerated() {
                    ctx.setFillColor(color(chart, pie ? i : i))
                    ctx.fill(CGRect(x: x, y: y - base * 0.35, width: base * 0.7, height: base * 0.7))
                    text(item, size: base, at: CGPoint(x: x + base, y: y), align: 0)
                    x += widths[i]
                }
                if pos == "b" { area.origin.y += entryH * 1.3 }
                area.size.height -= entryH * 1.3
            } else {
                let lw = min((widths.max() ?? 0) + 4, Double(area.width) * 0.35)
                let x = pos == "l" ? Double(area.minX) : Double(area.maxX) - lw
                var y = Double(area.midY) + Double(legendItems.count - 1) * entryH / 2
                for (i, item) in legendItems.enumerated() {
                    ctx.setFillColor(color(chart, i))
                    ctx.fill(CGRect(x: x, y: y - base * 0.35, width: base * 0.7, height: base * 0.7))
                    text(item, size: base, at: CGPoint(x: x + base, y: y), align: 0)
                    y -= entryH
                }
                if pos == "l" { area.origin.x += lw + 6 }
                area.size.width -= lw + 6
            }
        }
        guard area.width > 20, area.height > 20 else { return }
        if pie { drawPie(chart, in: area, labelSize: base) } else { drawAxes(chart, in: area, labelSize: base) }
    }

    func drawPie(_ chart: SheetChart, in area: CGRect, labelSize: Double) {
        guard let s = chart.series.first else { return }
        let values = s.values.map { max($0 ?? 0, 0) }
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        let radius = min(area.width, area.height) / 2 * 0.9
        let center = CGPoint(x: area.midX, y: area.midY)
        var angle = CGFloat.pi / 2
        for (i, v) in values.enumerated() where v > 0 {
            let sweep = CGFloat(v / total) * 2 * .pi
            let path = CGMutablePath()
            path.move(to: center)
            path.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle - sweep, clockwise: true)
            path.closeSubpath()
            // Each slice takes the next palette colour, as in Excel.
            ctx.setFillColor(color(chart.withoutSeriesColors, i))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(0.75)
            ctx.addPath(path)
            ctx.strokePath()
            angle -= sweep
        }
        if chart.kind == .doughnut {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: center.x - radius * 0.5, y: center.y - radius * 0.5, width: radius, height: radius))
        }
    }

    /// Nice axis bounds and step.
    static func axis(_ lo: Double, _ hi: Double) -> (Double, Double, Double) {
        var lo = lo, hi = hi
        if lo > 0 { lo = 0 }
        if hi < 0 { hi = 0 }
        if hi == lo { hi = lo + 1 }
        let raw = (hi - lo) / 5
        let mag = pow(10, floor(log10(raw)))
        let n = raw / mag
        let step = (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * mag
        return (floor(lo / step) * step, ceil(hi / step) * step, step)
    }

    static func label(_ v: Double, format: String?) -> String {
        if let format, let s = ExcelNumberFormat.render(v, code: format) { return s }
        return CellValue.generalString(abs(v) < 1e-12 ? 0 : v)
    }

    func drawAxes(_ chart: SheetChart, in area0: CGRect, labelSize: Double) {
        let series = chart.series
        let n = series.map { max($0.values.count, $0.categories.count) }.max() ?? 0
        guard n > 0 else { return }
        var lo = 0.0, hi = 0.0
        if chart.stacked && !chart.percentStacked {
            for i in 0..<n {
                var pos = 0.0, neg = 0.0
                for s in series { let v = i < s.values.count ? (s.values[i] ?? 0) : 0; if v >= 0 { pos += v } else { neg += v } }
                hi = max(hi, pos); lo = min(lo, neg)
            }
        } else if chart.percentStacked {
            lo = 0; hi = 1
        } else {
            let all = series.flatMap { $0.values.compactMap { $0 } }
            lo = all.min() ?? 0; hi = all.max() ?? 1
        }
        var (amin, amax, step) = SheetChartPainter.axis(chart.valueMin ?? lo, chart.valueMax ?? hi)
        if let m = chart.valueMin { amin = m }
        if let m = chart.valueMax { amax = m }
        if amax <= amin { amax = amin + step }
        let horizontal = chart.kind == .bar
        let fmt = chart.percentStacked ? "0%" : chart.valueFormat
        // Room for the value labels and the category labels.
        let ticks = Int(((amax - amin) / step).rounded())
        let valueLabels = (0...max(ticks, 0)).map { SheetChartPainter.label(amin + Double($0) * step, format: fmt) }
        let valueLabelW = (valueLabels.map { line($0, size: labelSize).1 }.max() ?? 10) + 4
        let cats = (0..<n).map { i in series.first.flatMap { i < $0.categories.count ? $0.categories[i] : nil } ?? String(i + 1) }
        let catLabelW = (cats.map { line($0, size: labelSize).1 }.max() ?? 10) + 6
        var plot = area0
        if horizontal {
            plot.origin.x += min(catLabelW, Double(area0.width) * 0.35); plot.size.width -= min(catLabelW, Double(area0.width) * 0.35)
            plot.origin.y += labelSize * 1.6; plot.size.height -= labelSize * 1.6
        } else {
            plot.origin.x += valueLabelW; plot.size.width -= valueLabelW
            plot.origin.y += labelSize * 1.8; plot.size.height -= labelSize * 1.8
        }
        guard plot.width > 10, plot.height > 10 else { return }
        func pos(_ v: Double) -> CGFloat {
            let t = (v - amin) / (amax - amin)
            return horizontal ? plot.minX + CGFloat(t) * plot.width : plot.minY + CGFloat(t) * plot.height
        }
        // Gridlines and value labels.
        ctx.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        ctx.setLineWidth(0.5)
        for k in 0...max(ticks, 0) {
            let v = amin + Double(k) * step
            let p = pos(v)
            if horizontal {
                ctx.move(to: CGPoint(x: p, y: plot.minY)); ctx.addLine(to: CGPoint(x: p, y: plot.maxY))
            } else {
                ctx.move(to: CGPoint(x: plot.minX, y: p)); ctx.addLine(to: CGPoint(x: plot.maxX, y: p))
            }
        }
        ctx.strokePath()
        for k in 0...max(ticks, 0) {
            let p = pos(amin + Double(k) * step)
            if horizontal { text(valueLabels[k], size: labelSize, at: CGPoint(x: p, y: plot.minY - CGFloat(labelSize)), align: 1) }
            else { text(valueLabels[k], size: labelSize, at: CGPoint(x: plot.minX - 3, y: p), align: 2) }
        }
        // Category axis line and labels.
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        ctx.setLineWidth(0.6)
        let zero = pos(max(amin, min(0, amax)))
        if horizontal { ctx.move(to: CGPoint(x: zero, y: plot.minY)); ctx.addLine(to: CGPoint(x: zero, y: plot.maxY)) }
        else { ctx.move(to: CGPoint(x: plot.minX, y: zero)); ctx.addLine(to: CGPoint(x: plot.maxX, y: zero)) }
        ctx.strokePath()
        let slot = (horizontal ? plot.height : plot.width) / CGFloat(n)
        for (i, c) in cats.enumerated() {
            if horizontal {
                text(c, size: labelSize, at: CGPoint(x: plot.minX - 3, y: plot.maxY - slot * (CGFloat(i) + 0.5)), align: 2)
            } else if n <= 40 {
                text(c, size: labelSize, at: CGPoint(x: plot.minX + slot * (CGFloat(i) + 0.5), y: plot.minY - CGFloat(labelSize)), align: 1, maxWidth: Double(slot))
            }
        }
        switch chart.kind {
        case .column, .bar:
            let groups = chart.stacked ? 1 : max(series.count, 1)
            // Excel's default gap between groups is 150 % of a bar.
            let barW = slot / (CGFloat(groups) + 1.5)
            for i in 0..<n {
                var posAcc = 0.0, negAcc = 0.0
                let total = chart.percentStacked ? series.reduce(0.0) { $0 + abs(i < $1.values.count ? ($1.values[i] ?? 0) : 0) } : 1
                for (k, s) in series.enumerated() {
                    guard i < s.values.count, var v = s.values[i] else { continue }
                    if chart.percentStacked { v = total > 0 ? v / total : 0 }
                    var a = 0.0, b = v
                    if chart.stacked { if v >= 0 { a = posAcc; posAcc += v; b = posAcc } else { a = negAcc; negAcc += v; b = negAcc } }
                    let slotStart = (horizontal ? plot.maxY - slot * CGFloat(i + 1) : plot.minX + slot * CGFloat(i))
                    let offset = chart.stacked ? (slot - barW) / 2 : (slot - barW * CGFloat(groups)) / 2 + barW * CGFloat(k)
                    let p0 = pos(max(min(a, amax), amin)), p1 = pos(max(min(b, amax), amin))
                    let r = horizontal
                        ? CGRect(x: min(p0, p1), y: slotStart + offset, width: abs(p1 - p0), height: barW)
                        : CGRect(x: slotStart + offset, y: min(p0, p1), width: barW, height: abs(p1 - p0))
                    ctx.setFillColor(color(chart, k))
                    ctx.fill(r)
                }
            }
        case .line, .area, .scatter:
            for (k, s) in series.enumerated() {
                var pts: [CGPoint] = []
                for i in 0..<n {
                    guard i < s.values.count, let v = s.values[i] else { continue }
                    pts.append(CGPoint(x: plot.minX + slot * (CGFloat(i) + 0.5), y: pos(max(min(v, amax), amin))))
                }
                guard !pts.isEmpty else { continue }
                if chart.kind == .area, let f = pts.first, let l = pts.last {
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: f.x, y: zero))
                    for p in pts { path.addLine(to: p) }
                    path.addLine(to: CGPoint(x: l.x, y: zero))
                    path.closeSubpath()
                    ctx.setFillColor(color(chart, k))
                    ctx.addPath(path); ctx.fillPath()
                    continue
                }
                ctx.setStrokeColor(color(chart, k))
                ctx.setLineWidth(1.5)
                if chart.kind == .line {
                    ctx.move(to: pts[0]); for p in pts.dropFirst() { ctx.addLine(to: p) }
                    ctx.strokePath()
                }
                ctx.setFillColor(color(chart, k))
                for p in pts { ctx.fillEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)) }
            }
        default:
            break
        }
    }
}

extension SheetChart {
    /// The chart with series colours removed (pie slices then take the palette).
    var withoutSeriesColors: SheetChart {
        var c = self
        c.series = series.map { var s = $0; s.color = nil; return s }
        return c
    }
}
