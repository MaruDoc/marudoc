import Foundation
import CoreGraphics

/// Tables (a:tbl) on slides: grid widths, row heights grown to fit their text, merges, cell margins and anchors,
/// explicit fills and borders, and table styles (from the deck, or the built-in ones Office leaves out of the file).
extension SlideRenderer {

    /// Built-in table styles that PowerPoint references by id without always writing their definition.
    static let builtInTableStyles: [String: XNode] = {
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
        func ln(_ w: Int, _ clr: String) -> String { "<a:ln w=\"\(w)\" cmpd=\"sng\"><a:solidFill><a:schemeClr val=\"\(clr)\"/></a:solidFill></a:ln>" }
        func bdr(_ w: Int, _ clr: String, _ sides: [String]) -> String { "<a:tcBdr>" + sides.map { "<a:\($0)>\(ln(w, clr))</a:\($0)>" }.joined() + "</a:tcBdr>" }
        let all = ["left", "right", "top", "bottom", "insideH", "insideV"]
        let none = "<a:tcBdr>" + all.map { "<a:\($0)><a:ln><a:noFill/></a:ln></a:\($0)>" }.joined() + "</a:tcBdr>"
        let text = "<a:tcTxStyle><a:fontRef idx=\"minor\"><a:prstClr val=\"black\"/></a:fontRef><a:schemeClr val=\"dk1\"/></a:tcTxStyle>"
        let bold = "<a:tcTxStyle b=\"on\"><a:fontRef idx=\"minor\"><a:prstClr val=\"black\"/></a:fontRef><a:schemeClr val=\"lt1\"/></a:tcTxStyle>"
        func fill(_ clr: String, _ tint: Int?) -> String {
            "<a:fill><a:solidFill><a:schemeClr val=\"\(clr)\">" + (tint.map { "<a:tint val=\"\($0)\"/>" } ?? "") + "</a:schemeClr></a:solidFill></a:fill>"
        }
        // Medium Style 2 (accent n): the default table style of every Office version since 2007.
        func medium2(_ id: String, _ acc: String) -> String {
            "<a:tblStyle \(ns) styleId=\"\(id)\"><a:wholeTbl>\(text)<a:tcStyle>\(bdr(12700, "lt1", all))\(fill(acc, 20000))</a:tcStyle></a:wholeTbl>"
            + "<a:band1H><a:tcStyle><a:tcBdr/>\(fill(acc, 40000))</a:tcStyle></a:band1H><a:band2H><a:tcStyle><a:tcBdr/></a:tcStyle></a:band2H>"
            + "<a:band1V><a:tcStyle><a:tcBdr/>\(fill(acc, 40000))</a:tcStyle></a:band1V><a:band2V><a:tcStyle><a:tcBdr/></a:tcStyle></a:band2V>"
            + "<a:lastCol>\(bold)<a:tcStyle><a:tcBdr/>\(fill(acc, nil))</a:tcStyle></a:lastCol><a:firstCol>\(bold)<a:tcStyle><a:tcBdr/>\(fill(acc, nil))</a:tcStyle></a:firstCol>"
            + "<a:lastRow>\(bold)<a:tcStyle>\(bdr(38100, "lt1", ["top"]))\(fill(acc, nil))</a:tcStyle></a:lastRow>"
            + "<a:firstRow>\(bold)<a:tcStyle>\(bdr(38100, "lt1", ["bottom"]))\(fill(acc, nil))</a:tcStyle></a:firstRow></a:tblStyle>"
        }
        var xml: [String: String] = [
            "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}": medium2("{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}", "accent1"),
            "{21E4AEA4-8DFA-4A89-87EB-49C32662AFE0}": medium2("{21E4AEA4-8DFA-4A89-87EB-49C32662AFE0}", "accent2"),
            "{F5AB1C69-6EDB-4FF4-983F-18BD219EF322}": medium2("{F5AB1C69-6EDB-4FF4-983F-18BD219EF322}", "accent3"),
            "{00A15C55-8517-42AA-B614-E9B94910E393}": medium2("{00A15C55-8517-42AA-B614-E9B94910E393}", "accent4"),
            "{7DF18680-E054-41AD-8BC1-D1AEF772440D}": medium2("{7DF18680-E054-41AD-8BC1-D1AEF772440D}", "accent5"),
            "{93296810-A885-4BE3-A3E7-6D5BEEA58F35}": medium2("{93296810-A885-4BE3-A3E7-6D5BEEA58F35}", "accent6"),
            "{073A0DAA-6AF3-43AB-8588-CEC1D06C72B9}": medium2("{073A0DAA-6AF3-43AB-8588-CEC1D06C72B9}", "dk1"),
        ]
        let plainText = "<a:tcTxStyle><a:fontRef idx=\"minor\"><a:scrgbClr r=\"0\" g=\"0\" b=\"0\"/></a:fontRef><a:schemeClr val=\"tx1\"/></a:tcTxStyle>"
        xml["{2D5ABB26-0587-4C30-8999-92F81FD0307C}"] = "<a:tblStyle \(ns) styleId=\"{2D5ABB26-0587-4C30-8999-92F81FD0307C}\"><a:wholeTbl>\(plainText)<a:tcStyle>\(none)<a:fill><a:noFill/></a:fill></a:tcStyle></a:wholeTbl></a:tblStyle>"
        xml["{5940675A-B579-460E-94D1-54222C63F5DA}"] = "<a:tblStyle \(ns) styleId=\"{5940675A-B579-460E-94D1-54222C63F5DA}\"><a:wholeTbl>\(plainText)<a:tcStyle>\(bdr(12700, "tx1", all))<a:fill><a:noFill/></a:fill></a:tcStyle></a:wholeTbl></a:tblStyle>"
        return xml.compactMapValues { try? XNode.parse(Data($0.utf8), part: "builtin table style") }
    }()

    func tableStyle(_ tblPr: XNode?) -> XNode? {
        if let inline = tblPr?.child("a:tableStyle") { return inline }
        let id = tblPr?.child("a:tableStyleId")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "{2D5ABB26-0587-4C30-8999-92F81FD0307C}"
        if let s = pkg.tableStyles?.children("a:tblStyle").first(where: { $0["styleId"] == id }) { return s }
        if let s = SlideRenderer.builtInTableStyles[id] { return s }
        // An unknown style id: Medium Style 2 keeps the text readable and the rows apart.
        gap("unknown table styles (drawn as Medium Style 2)")
        return SlideRenderer.builtInTableStyles["{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"]
    }

    private struct Cell {
        var tc: XNode
        var row: Int, col: Int
        var rowSpan = 1, colSpan = 1
        var hidden = false
    }

    private struct Region { var node: XNode; var r0: Int, r1: Int, c0: Int, c1: Int }

    func drawTable(_ tbl: XNode, frame: CGRect, layer: Layer) {
        let tblPr = tbl.child("a:tblPr")
        let widths = (tbl.child("a:tblGrid")?.children("a:gridCol") ?? []).map { max((OOXMLValue.double($0["w"]) ?? 0) / 12700, 0) }
        let trs = tbl.children("a:tr")
        guard !widths.isEmpty, !trs.isEmpty else { return }
        let nCols = widths.count, nRows = trs.count
        var heights = trs.map { max((OOXMLValue.double($0["h"]) ?? 0) / 12700, 0) }

        // Cells on the grid; continuation cells of merges are hidden.
        var cells: [Cell] = []
        for (ri, tr) in trs.enumerated() {
            var ci = 0
            for tc in tr.children("a:tc") {
                guard ci < nCols else { break }
                var c = Cell(tc: tc, row: ri, col: ci)
                c.colSpan = min(max(OOXMLValue.int(tc["gridSpan"]) ?? 1, 1), nCols - ci)
                c.rowSpan = min(max(OOXMLValue.int(tc["rowSpan"]) ?? 1, 1), nRows - ri)
                c.hidden = OOXMLValue.onOff(tc["hMerge"] ?? "0") || OOXMLValue.onOff(tc["vMerge"] ?? "0")
                cells.append(c)
                ci += 1
            }
        }

        let style = tableStyle(tblPr)
        func flag(_ k: String) -> Bool { OOXMLValue.onOff(tblPr?[k] ?? "0") }
        let firstRow = flag("firstRow"), lastRow = flag("lastRow"), firstCol = flag("firstCol"), lastCol = flag("lastCol")
        let bandRow = flag("bandRow"), bandCol = flag("bandCol")
        func regions(_ c: Cell) -> [Region] {
            guard let style else { return [] }
            var out: [Region] = []
            func add(_ tag: String, _ r0: Int, _ r1: Int, _ c0: Int, _ c1: Int) {
                if let n = style.child("a:" + tag) { out.append(Region(node: n, r0: r0, r1: r1, c0: c0, c1: c1)) }
            }
            add("wholeTbl", 0, nRows - 1, 0, nCols - 1)
            let dataRow0 = firstRow ? 1 : 0, dataRowN = lastRow ? nRows - 2 : nRows - 1
            if bandRow, c.row >= dataRow0, c.row <= dataRowN {
                add((c.row - dataRow0) % 2 == 0 ? "band1H" : "band2H", c.row, c.row, 0, nCols - 1)
            }
            let dataCol0 = firstCol ? 1 : 0, dataColN = lastCol ? nCols - 2 : nCols - 1
            if bandCol, c.col >= dataCol0, c.col <= dataColN {
                add((c.col - dataCol0) % 2 == 0 ? "band1V" : "band2V", 0, nRows - 1, c.col, c.col)
            }
            if lastCol, c.col + c.colSpan - 1 == nCols - 1 { add("lastCol", 0, nRows - 1, nCols - 1, nCols - 1) }
            if firstCol, c.col == 0 { add("firstCol", 0, nRows - 1, 0, 0) }
            if lastRow, c.row + c.rowSpan - 1 == nRows - 1 { add("lastRow", nRows - 1, nRows - 1, 0, nCols - 1) }
            if firstRow, c.row == 0 { add("firstRow", 0, 0, 0, nCols - 1) }
            return out
        }

        let otherLists: [XNode] = [scope.masterTextStyle(placeholderType: nil, isPlaceholder: false), pkg.defaultTextStyle].compactMap { $0 }
        func inheritance(_ c: Cell) -> TextInheritance {
            var inh = TextInheritance(colors: layer.colors, theme: scope.theme)
            inh.rels = pkg.rels(layer.part)
            inh.slideNumber = scope.number
            inh.lists = otherLists
            inh.defaultLang = pkg.defaultTextStyle?.child("a:defPPr")?.child("a:defRPr")?["lang"] ?? "ja-JP"
            // Merge the text styles of the regions, later (more specific) ones winning.
            var attrs: [String: String] = [:]
            var font: XNode?, color: XNode?
            for r in regions(c) {
                guard let t = r.node.child("a:tcTxStyle") else { continue }
                for (k, v) in t.attrs { attrs[k] = v }
                if let f = t.children.first(where: { $0.tag == "a:font" || $0.tag == "a:fontRef" }) { font = f }
                if let col = t.children.first(where: { ColorResolver.colorTags.contains($0.tag) }) { color = col }
            }
            let merged = XNode(tag: "a:tcTxStyle", attrs: attrs)
            merged.children = [font, color].compactMap { $0 }
            inh.tableText = merged
            return inh
        }
        func props(_ c: Cell) -> BodyProps {
            let p = c.tc.child("a:tcPr")
            var b = BodyProps()
            func emu(_ k: String, _ d: Double) -> Double { OOXMLValue.double(p?[k]).map { $0 / 12700 } ?? d }
            b.lIns = emu("marL", 7.2); b.rIns = emu("marR", 7.2); b.tIns = emu("marT", 3.6); b.bIns = emu("marB", 3.6)
            b.anchor = p?["anchor"] ?? "t"
            b.anchorCtr = OOXMLValue.onOff(p?["anchorCtr"] ?? "0")
            b.vert = p?["vert"] ?? "horz"
            return b
        }

        // Rows grow to fit their text, as in PowerPoint.
        for c in cells where !c.hidden {
            guard let body = c.tc.child("a:txBody") else { continue }
            let bp = props(c)
            let w = widths[c.col..<(c.col + c.colSpan)].reduce(0, +) - bp.lIns - bp.rIns
            let paras = TextStyler(body: body, inheritance: inheritance(c)).paragraphs(body)
            guard paras.contains(where: { !$0.runs.isEmpty }) else { continue }
            let need = text.layout(paras, width: w, wrap: true).height + bp.tIns + bp.bIns
            let have = heights[c.row..<(c.row + c.rowSpan)].reduce(0, +)
            if need > have + 0.5, bp.vert == "horz" { heights[c.row + c.rowSpan - 1] += need - have }
        }
        var xs = [Double(frame.minX)], ys = [Double(frame.minY)]
        for w in widths { xs.append(xs.last! + w) }
        for h in heights { ys.append(ys.last! + h) }
        func rect(_ c: Cell) -> CGRect {
            CGRect(x: xs[c.col], y: ys[c.row], width: xs[c.col + c.colSpan] - xs[c.col], height: ys[c.row + c.rowSpan] - ys[c.row])
        }

        // Table background, then cell fills.
        if let bg = fillElement(in: tblPr) {
            paint(CGPath(rect: CGRect(x: xs[0], y: ys[0], width: xs[nCols] - xs[0], height: ys[nRows] - ys[0]), transform: nil),
                  fill: bg, colors: layer.colors, part: layer.part, bounds: frame)
        }
        for c in cells where !c.hidden {
            let rr = rect(c)
            var fill: XNode? = fillElement(in: c.tc.child("a:tcPr"))
            var colors = layer.colors
            if fill == nil {
                for r in regions(c).reversed() {
                    guard let ts = r.node.child("a:tcStyle") else { continue }
                    if let f = fillElement(in: ts.child("a:fill")) { fill = f; break }
                    if let ref = ts.child("a:fillRef"), let idx = OOXMLValue.int(ref["idx"]) {
                        colors = layer.colors.with(phClr: layer.colors.color(in: ref))
                        fill = themeFill(idx, colors); break
                    }
                }
            }
            if let fill { paint(CGPath(rect: rr, transform: nil), fill: fill, colors: colors, part: layer.part, bounds: rr) }
        }
        // Text.
        for c in cells where !c.hidden {
            guard let body = c.tc.child("a:txBody") else { continue }
            let rr = rect(c)
            let bp = props(c)
            let area = CGRect(x: rr.minX + bp.lIns, y: rr.minY + bp.tIns, width: rr.width - bp.lIns - bp.rIns, height: rr.height - bp.tIns - bp.bIns)
            drawTextBody(body, inheritance: inheritance(c), props: bp, area: area, mirrored: false, fitToBox: false)
        }
        // Borders on top: explicit cell lines, else the style's lines for the cell's place in each region.
        for c in cells where !c.hidden {
            let rr = rect(c)
            let tcPr = c.tc.child("a:tcPr")
            let sides: [(String, String, CGPoint, CGPoint)] = [
                ("a:lnL", "left", CGPoint(x: rr.minX, y: rr.minY), CGPoint(x: rr.minX, y: rr.maxY)),
                ("a:lnR", "right", CGPoint(x: rr.maxX, y: rr.minY), CGPoint(x: rr.maxX, y: rr.maxY)),
                ("a:lnT", "top", CGPoint(x: rr.minX, y: rr.minY), CGPoint(x: rr.maxX, y: rr.minY)),
                ("a:lnB", "bottom", CGPoint(x: rr.minX, y: rr.maxY), CGPoint(x: rr.maxX, y: rr.maxY)),
            ]
            for (tag, side, a, b) in sides {
                var ln: XNode? = tcPr?.child(tag)
                var lnColors = layer.colors
                if ln == nil || (ln?.children.isEmpty == true && ln?["w"] == nil) {
                    for r in regions(c).reversed() {
                        guard let bdr = r.node.child("a:tcStyle")?.child("a:tcBdr") else { continue }
                        let name: String
                        switch side {
                        case "left": name = c.col == r.c0 ? "left" : "insideV"
                        case "right": name = c.col + c.colSpan - 1 == r.c1 ? "right" : "insideV"
                        case "top": name = c.row == r.r0 ? "top" : "insideH"
                        default: name = c.row + c.rowSpan - 1 == r.r1 ? "bottom" : "insideH"
                        }
                        guard let el = bdr.child("a:" + name) else { continue }
                        if let l = el.child("a:ln") { ln = l; break }
                        if let ref = el.child("a:lnRef"), let idx = OOXMLValue.int(ref["idx"]), idx > 0, idx <= scope.theme.lineStyles.count {
                            ln = scope.theme.lineStyles[idx - 1]; lnColors = layer.colors.with(phClr: layer.colors.color(in: ref)); break
                        }
                    }
                }
                guard let ln, ln.child("a:noFill") == nil, let st = lineStyle(ln, colors: lnColors) else { continue }
                let p = CGMutablePath(); p.move(to: a); p.addLine(to: b)
                stroke(p, st, isLine: false, draw: true)
            }
            for (tag, a, b) in [("a:lnTlToBr", CGPoint(x: rr.minX, y: rr.minY), CGPoint(x: rr.maxX, y: rr.maxY)),
                                ("a:lnBlToTr", CGPoint(x: rr.minX, y: rr.maxY), CGPoint(x: rr.maxX, y: rr.minY))] {
                guard let ln = tcPr?.child(tag), ln.child("a:noFill") == nil, let st = lineStyle(ln, colors: layer.colors) else { continue }
                let p = CGMutablePath(); p.move(to: a); p.addLine(to: b)
                stroke(p, st, isLine: false, draw: true)
            }
        }
    }

    /// A single a:ln element as a line style (nil when it draws nothing).
    func lineStyle(_ ln: XNode, colors: ColorResolver) -> LineStyle? {
        // Cell borders (a:lnL, a:lnT...) and chart lines are a:ln under other names.
        let asLn = XNode(tag: "a:ln", attrs: ln.attrs).with(children: ln.children)
        let r = Resolved(chain: [], xfrm: nil, spPrs: [XNode(tag: "p:spPr", attrs: [:]).with(children: [asLn])], style: nil, phType: nil, isPlaceholder: false)
        return resolvedLine(r, colors: colors)
    }
}

extension XNode {
    func with(children: [XNode]) -> XNode { self.children = children; return self }
}
