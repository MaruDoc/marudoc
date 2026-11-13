import Foundation
import CoreGraphics
import EnsoDoc

// Pictures, charts and shapes anchored on a worksheet (xl/drawings/drawingN.xml and the parts it points to).
extension XlsxLayoutReader {

    static let emuPerPoint = 12700.0

    /// Children by local name: the spreadsheet drawing namespace has no short key, so its tags keep the full URI.
    static func kids(_ n: XNode, _ local: String) -> [XNode] { n.children.filter { $0.localName == local } }
    static func kid(_ n: XNode, _ local: String) -> XNode? { n.children.first { $0.localName == local } }

    /// Reads the drawing part of a sheet. `resolve` returns the cells of a range on a named sheet, for charts whose
    /// series carry no cached values.
    static func drawings(_ zip: ZipReader, sheetPart: String, relID: String, theme: Theme, notDrawn: inout [String],
                         resolve: (String, SheetRange) -> [SheetCell?]) -> [SheetDrawing] {
        guard let rels = try? OPC.relationships(zip, for: sheetPart), let rel = rels.first(where: { $0.id == relID }),
              zip.contains(rel.target), let root = try? XNode.parse(try zip.data(rel.target), part: rel.target) else { return [] }
        let drawingRels = (try? OPC.relationships(zip, for: rel.target)) ?? []
        let relByID = Dictionary(drawingRels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [SheetDrawing] = []
        for a in root.children {
            var anchor = SheetAnchor()
            func marker(_ n: XNode?) -> (col: Int, colOff: Double, row: Int, rowOff: Double)? {
                guard let n else { return nil }
                func v(_ name: String) -> Double { kid(n, name).flatMap { Double($0.text.trimmingCharacters(in: .whitespaces)) } ?? 0 }
                return (max(0, Int(v("col"))), v("colOff") / emuPerPoint, max(0, Int(v("row"))), v("rowOff") / emuPerPoint)
            }
            func ext(_ n: XNode?) -> CGSize? {
                guard let n, let cx = OOXMLValue.double(n["cx"]), let cy = OOXMLValue.double(n["cy"]), cx > 0, cy > 0 else { return nil }
                return CGSize(width: cx / emuPerPoint, height: cy / emuPerPoint)
            }
            switch a.localName {
            case "twoCellAnchor":
                guard let f = marker(kid(a, "from")), let t = marker(kid(a, "to")) else { continue }
                anchor.fromCol = f.col; anchor.fromColOffset = f.colOff; anchor.fromRow = f.row; anchor.fromRowOffset = f.rowOff
                anchor.toCol = t.col; anchor.toColOffset = t.colOff; anchor.toRow = t.row; anchor.toRowOffset = t.rowOff
            case "oneCellAnchor":
                guard let f = marker(kid(a, "from")), let size = ext(kid(a, "ext")) else { continue }
                anchor.fromCol = f.col; anchor.fromColOffset = f.colOff; anchor.fromRow = f.row; anchor.fromRowOffset = f.rowOff
                anchor.size = size
            case "absoluteAnchor":
                guard let pos = kid(a, "pos"), let x = OOXMLValue.double(pos["x"]), let y = OOXMLValue.double(pos["y"]),
                      let size = ext(kid(a, "ext")) else { continue }
                anchor.absolute = CGPoint(x: x / emuPerPoint, y: y / emuPerPoint)
                anchor.size = size
            default:
                continue
            }
            // mc:AlternateContent wraps newer objects; its Fallback holds what older readers draw.
            var objects = a.children.filter { ["pic", "graphicFrame", "sp", "grpSp", "cxnSp", "AlternateContent"].contains(String($0.localName)) }
            if let alt = objects.first(where: { $0.localName == "AlternateContent" }) {
                objects = (kid(alt, "Fallback")?.children ?? kid(alt, "Choice")?.children ?? [])
            }
            guard let obj = objects.first else { continue }
            if let content = drawingContent(obj, zip: zip, relByID: relByID, theme: theme, resolve: resolve) {
                if case .unsupported(let what) = content { notDrawn.append(what) }
                out.append(SheetDrawing(anchor: anchor, content: content))
            }
        }
        return out
    }

    static func drawingContent(_ obj: XNode, zip: ZipReader, relByID: [String: OPCRelationship], theme: Theme,
                               resolve: (String, SheetRange) -> [SheetCell?]) -> SheetDrawingContent? {
        switch obj.localName {
        case "pic":
            guard let blip = obj.firstDescendant("a:blip"), let id = blip["r:embed"], let rel = relByID[id], !rel.external,
                  zip.contains(rel.target), let data = try? zip.data(rel.target) else { return .unsupported("picture without image data") }
            guard ImageCodec.decode(data) != nil else { return .unsupported("picture in a format macOS cannot draw (\((rel.target as NSString).pathExtension))") }
            return .picture(data)
        case "graphicFrame":
            guard let gd = obj.firstDescendant("a:graphicData") else { return nil }
            if let c = gd.child("c:chart"), let id = c["r:id"], let rel = relByID[id], zip.contains(rel.target),
               let node = try? XNode.parse(try zip.data(rel.target), part: rel.target) {
                let ch = chart(node, theme: theme, resolve: resolve)
                if ch.kind == .other { return .unsupported("chart of type \(ch.otherType ?? "unknown")") }
                if ch.series.isEmpty || ch.series.allSatisfy({ $0.values.allSatisfy { $0 == nil } }) { return .unsupported("chart without data") }
                return .chart(ch)
            }
            let uri = gd["uri"] ?? ""
            if uri.contains("diagram") { return .unsupported("SmartArt") }
            if uri.contains("chartex") || uri.contains("chartEx") { return .unsupported("chart (new chart types)") }
            return .unsupported("embedded object")
        case "sp":
            let spPr = kid(obj, "spPr")
            let fill = spPr.flatMap { schemeFill($0.child("a:solidFill"), theme: theme) }
            let line = spPr?.child("a:ln").flatMap { $0.child("a:noFill") != nil ? nil : schemeFill($0.child("a:solidFill"), theme: theme) }
            let text = kid(obj, "txBody").map { body in body.children("a:p").map { $0.allText("a:t") }.joined(separator: "\n") } ?? ""
            if fill == nil && line == nil && text.isEmpty { return nil }
            return .shape(fill: fill, line: line, text: text)
        case "grpSp":
            return .unsupported("grouped shapes")
        case "cxnSp":
            return .unsupported("connector line")
        default:
            return nil
        }
    }

    /// a:solidFill with srgbClr / schemeClr / sysClr (lumMod / lumOff / tint / shade roughly applied).
    static func schemeFill(_ n: XNode?, theme: Theme) -> DocColor? {
        guard let n else { return nil }
        var c: DocColor?
        var node: XNode?
        if let s = n.child("a:srgbClr") { c = s["val"].flatMap(DocColor.init(hex:)); node = s }
        else if let s = n.child("a:schemeClr") { c = s["val"].flatMap(theme.scheme); node = s }
        else if let s = n.child("a:sysClr") { c = s["lastClr"].flatMap(DocColor.init(hex:)); node = s }
        else if let s = n.child("a:prstClr") { c = ["black": DocColor(r: 0, g: 0, b: 0), "white": DocColor(r: 1, g: 1, b: 1)][s["val"] ?? ""]; node = s }
        guard var color = c else { return nil }
        if let node {
            let mod = OOXMLValue.double(node.child("a:lumMod")?["val"]).map { $0 / 100_000 }
            let off = OOXMLValue.double(node.child("a:lumOff")?["val"]).map { $0 / 100_000 }
            if let mod { color = tinted(color, off != nil ? (off ?? 0) : -(1 - mod)) }
            if let t = OOXMLValue.double(node.child("a:tint")?["val"]).map({ $0 / 100_000 }) { color = tinted(color, 1 - t) }
            if let s = OOXMLValue.double(node.child("a:shade")?["val"]).map({ $0 / 100_000 }) { color = tinted(color, -(1 - s)) }
        }
        return color
    }

    // MARK: Charts

    static func chart(_ root: XNode, theme: Theme, resolve: (String, SheetRange) -> [SheetCell?]) -> SheetChart {
        var ch = SheetChart()
        ch.palette = Array(theme.colors.dropFirst(4).prefix(6))
        guard let chartNode = root.child("c:chart") else { return ch }
        let plot = chartNode.child("c:plotArea")
        let typeNode = plot?.children.first { $0.tag.hasPrefix("c:") && $0.tag.hasSuffix("Chart") }
        switch typeNode?.localName {
        case "barChart", "bar3DChart":
            ch.kind = typeNode?.child("c:barDir")?["val"] == "bar" ? .bar : .column
        case "lineChart", "line3DChart", "stockChart": ch.kind = .line
        case "areaChart", "area3DChart": ch.kind = .area
        case "pieChart", "pie3DChart", "ofPieChart": ch.kind = .pie
        case "doughnutChart": ch.kind = .doughnut
        case "scatterChart": ch.kind = .scatter
        default:
            ch.kind = .other
            ch.otherType = typeNode.map { String($0.localName) } ?? "unknown"
        }
        let grouping = typeNode?.child("c:grouping")?["val"] ?? "clustered"
        ch.stacked = grouping == "stacked" || grouping == "percentStacked"
        ch.percentStacked = grouping == "percentStacked"

        func strings(_ ref: XNode?) -> [String] {
            guard let ref else { return [] }
            for cacheTag in ["c:strCache", "c:numCache", "c:strLit", "c:numLit"] {
                if let cache = ref.firstDescendant(cacheTag) ?? (ref.tag == cacheTag ? ref : nil) {
                    let n = OOXMLValue.int(cache.child("c:ptCount")?["val"]) ?? 0
                    var out = Array(repeating: "", count: min(max(n, 0), 10_000))
                    for pt in cache.children("c:pt") {
                        guard let i = OOXMLValue.int(pt["idx"]), i >= 0, i < 10_000 else { continue }
                        while out.count <= i { out.append("") }
                        out[i] = pt.child("c:v")?.text ?? ""
                    }
                    if !out.isEmpty { return out }
                }
            }
            if let f = ref.firstDescendant("c:f")?.text, let (sheet, range) = formulaRange(f) {
                return resolve(sheet, range).map { $0?.text ?? "" }
            }
            return []
        }
        func numbers(_ ref: XNode?) -> [Double?] {
            guard let ref else { return [] }
            for cacheTag in ["c:numCache", "c:numLit"] {
                if let cache = ref.firstDescendant(cacheTag) {
                    let n = OOXMLValue.int(cache.child("c:ptCount")?["val"]) ?? 0
                    var out: [Double?] = Array(repeating: nil, count: min(max(n, 0), 10_000))
                    for pt in cache.children("c:pt") {
                        guard let i = OOXMLValue.int(pt["idx"]), i >= 0, i < 10_000 else { continue }
                        while out.count <= i { out.append(nil) }
                        out[i] = OOXMLValue.double(pt.child("c:v")?.text)
                    }
                    if !out.isEmpty { return out }
                }
            }
            if let f = ref.firstDescendant("c:f")?.text, let (sheet, range) = formulaRange(f) {
                return resolve(sheet, range).map { $0?.number }
            }
            return []
        }
        for (i, ser) in (typeNode?.children("c:ser") ?? []).enumerated() {
            let tx = ser.child("c:tx")
            let name = tx.map { t in t.child("c:v")?.text ?? strings(t.child("c:strRef")).first ?? "" } ?? ""
            let cat = ser.child("c:cat") ?? ser.child("c:xVal")
            let val = ser.child("c:val") ?? ser.child("c:yVal")
            let color = ser.child("c:spPr").flatMap { sp in schemeFill(sp.child("a:solidFill"), theme: theme) ?? schemeFill(sp.child("a:ln")?.child("a:solidFill"), theme: theme) }
            ch.series.append(SheetChartSeries(name: name.isEmpty ? "Series \(i + 1)" : name, categories: strings(cat), values: numbers(val), color: color))
        }
        if let t = chartNode.child("c:title") {
            let text = t.allText("a:t")
            if !text.isEmpty { ch.title = text } else if ch.series.count == 1 { ch.title = ch.series[0].name }
        } else if OOXMLValue.onOff(chartNode.child("c:autoTitleDeleted")?["val"] ?? "1") == false, ch.series.count == 1 {
            ch.title = ch.series[0].name
        }
        ch.legend = chartNode.child("c:legend").map { $0.child("c:legendPos")?["val"] ?? "r" }
        if let valAx = plot?.child("c:valAx") {
            ch.valueMin = OOXMLValue.double(valAx.child("c:scaling")?.child("c:min")?["val"])
            ch.valueMax = OOXMLValue.double(valAx.child("c:scaling")?.child("c:max")?["val"])
            if let fmt = valAx.child("c:numFmt")?["formatCode"], fmt.lowercased() != "general" { ch.valueFormat = fmt }
        }
        return ch
    }

    /// "'グラフ'!$B$2:$B$5" -> ("グラフ", B2:B5).
    static func formulaRange(_ f: String) -> (String, SheetRange)? {
        let pieces = parseRanges(f.trimmingCharacters(in: CharacterSet(charactersIn: "() ")))
        guard let p = pieces.first, let sheet = p.sheet, !p.wholeRows, !p.wholeColumns else { return nil }
        return (sheet, p.range)
    }
}
