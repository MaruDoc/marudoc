import Foundation
import CoreGraphics
import EnsoDoc

/// SpreadsheetML (.xlsx / .xlsm) -> PrintWorkbook: everything SheetPrinter needs to print the visible sheets as Excel
/// would. Values are read exactly as XlsxReader reads them (same number formats, same formula fallback), so the PDF
/// shows the same text as the CSV / Markdown outputs. Hidden sheets are skipped and cells in hidden rows and columns
/// are never stored, so their content cannot reach the page.
public enum XlsxLayoutReader {
    public static func read(_ url: URL) throws -> PrintWorkbook {
        try read(data: try Data.readOffice(url))
    }

    public static func read(data: Data) throws -> PrintWorkbook {
        let zip = try ZipReader(data: data)
        let main = try OPC.mainPart(zip, fallback: "xl/workbook.xml")
        let wb = try XNode.parse(try zip.data(main), part: main)
        guard wb.tag == "x:workbook" else { throw OfficeError.invalidDocument("\(main) is not an Excel workbook") }
        let rels = try OPC.relationships(zip, for: main)
        let relById = Dictionary(rels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let date1904 = OOXMLValue.onOff(wb.child("x:workbookPr")?["date1904"] ?? "0")

        var theme = Theme.office
        if let r = rels.first(where: { $0.isType("theme") }), zip.contains(r.target),
           let node = try? XNode.parse(try zip.data(r.target), part: r.target) {
            theme = Theme(node)
        }
        var shared: [SharedString] = []
        if let r = rels.first(where: { $0.isType("sharedStrings") }), zip.contains(r.target) {
            shared = try sharedStrings(try zip.data(r.target), part: r.target)
        }
        var styles = Styles()
        if let r = rels.first(where: { $0.isType("styles") }), zip.contains(r.target) {
            styles = Styles(try XNode.parse(try zip.data(r.target), part: r.target), theme: theme)
        }
        // Rich-text runs need the fonts and colours, which only the styles part knows.
        let sharedRuns: [[SheetRun]?] = shared.map { s in s.runs.map { runs in runs.map { SheetRun(text: $0.text, font: styles.runFont($0.props, theme: theme)) } } }
        let sharedText = shared.map(\.text)
        let mdw = SheetFonts.maxDigitWidth(styles.defaultFont)

        // Defined names: print areas and print titles, per sheet index (hidden sheets count).
        var printAreas: [Int: String] = [:], printTitles: [Int: String] = [:]
        for d in wb.child("x:definedNames")?.children("x:definedName") ?? [] {
            guard let id = OOXMLValue.int(d["localSheetId"]) else { continue }
            switch d["name"]?.lowercased() {
            case "_xlnm.print_area": printAreas[id] = d.text
            case "_xlnm.print_titles": printTitles[id] = d.text
            default: break
            }
        }

        let sheetNodes = wb.child("x:sheets")?.children("x:sheet") ?? []
        // Charts may take their numbers from any sheet, hidden ones too; those are read on demand.
        var cellCache: [String: PrintSheet] = [:]
        func loadSheet(_ node: XNode, index: Int, forValuesOnly: Bool) throws -> PrintSheet? {
            guard let id = node["r:id"], let rel = relById[id], rel.isType("worksheet"), zip.contains(rel.target) else { return nil }
            let sheet = PrintSheet(name: node["name"] ?? "Sheet\(index + 1)")
            sheet.styles = styles.cellStyles
            sheet.maxDigitWidth = mdw
            try readSheet(try zip.data(rel.target), part: rel.target, into: sheet, shared: sharedText, sharedRuns: sharedRuns,
                          styles: styles, date1904: date1904)
            return sheet
        }
        func sheetByName(_ name: String) -> PrintSheet? {
            if let s = cellCache[name] { return s }
            guard let (i, node) = sheetNodes.enumerated().first(where: { $0.element["name"] == name }),
                  let s = try? loadSheet(node, index: i, forValuesOnly: true) else { return nil }
            cellCache[name] = s
            return s
        }

        var sheets: [PrintSheet] = []
        for (index, s) in sheetNodes.enumerated() {
            let state = (s["state"] ?? "visible").lowercased()
            if state == "hidden" || state == "veryhidden" { continue }
            guard let sheet = try loadSheet(s, index: index, forValuesOnly: false) else { continue }
            cellCache[sheet.name] = sheet
            if let a = printAreas[index] { sheet.pageSetup.printAreas = parseRanges(a).map(\.range) }
            if let t = printTitles[index] {
                for piece in parseRanges(t) {
                    if piece.wholeRows { sheet.pageSetup.titleRows = piece.range.r0...piece.range.r1 }
                    if piece.wholeColumns { sheet.pageSetup.titleColumns = piece.range.c0...piece.range.c1 }
                }
            }
            if let id = sheet.drawingRelID, let ws = relById[s["r:id"] ?? ""] {
                sheet.drawings = drawings(zip, sheetPart: ws.target, relID: id, theme: theme, notDrawn: &sheet.notDrawn) { name, range in
                    guard let src = sheetByName(name) else { return [] }
                    var out: [SheetCell?] = []
                    for r in range.r0...min(range.r1, range.r0 + 10_000) {
                        for c in range.c0...min(range.c1, range.c0 + 1000) { out.append(src.cell(r, c)) }
                    }
                    return out
                }
            }
            sheets.append(sheet)
        }
        return PrintWorkbook(sheets: sheets, defaultFont: styles.defaultFont)
    }

    // MARK: Shared strings

    struct SharedString {
        var text: String
        /// Rich-text runs with their raw run properties, when the string has <r> elements.
        var runs: [(text: String, props: XNode?)]?
    }

    static func sharedStrings(_ data: Data, part: String) throws -> [SharedString] {
        var out: [SharedString] = []
        var text = ""
        var runs: [(text: String, props: XNode?)] = []
        var runText = "", runProps: XNode?
        var inSI = false, inRun = false, collecting = false, phonetic = 0
        var propStack: [XNode] = []
        try OOXMLSAX.run(data, part: part) { sax in
            sax.onStart = { tag, attrs in
                if !propStack.isEmpty {
                    let n = XNode(tag: tag, attrs: attrs)
                    propStack.last?.children.append(n)
                    propStack.append(n)
                    return
                }
                switch tag {
                case "x:si": inSI = true; text = ""; runs = []
                case "x:r": if inSI && phonetic == 0 { inRun = true; runText = ""; runProps = nil }
                case "x:rPr": if inRun { let n = XNode(tag: tag, attrs: attrs); runProps = n; propStack = [n] }
                case "x:rPh": phonetic += 1
                case "x:t": collecting = inSI && phonetic == 0
                default: break
                }
            }
            sax.onEnd = { tag in
                if !propStack.isEmpty { propStack.removeLast(); return }
                switch tag {
                case "x:si":
                    let decoded = XlsxReader.decodeEscapes(text)
                    if runs.count > 1 || runs.contains(where: { $0.props != nil }) {
                        out.append(SharedString(text: decoded, runs: runs.map { (XlsxReader.decodeEscapes($0.text), $0.props) }))
                    } else {
                        out.append(SharedString(text: decoded, runs: nil))
                    }
                    inSI = false
                case "x:r": if inRun { runs.append((runText, runProps)); inRun = false }
                case "x:rPh": phonetic -= 1
                case "x:t": collecting = false
                default: break
                }
            }
            sax.onText = { s in
                if collecting { text += s; if inRun { runText += s } }
            }
        }
        return out
    }

    // MARK: Sheet

    static func readSheet(_ data: Data, part: String, into sheet: PrintSheet, shared: [String], sharedRuns: [[SheetRun]?],
                          styles: Styles, date1904: Bool) throws {
        var row = 0, col = -1
        var type = "n", style = 0
        var value = "", inline = "", formula = "", formulaType = "", formulaIndex = ""
        var inValue = false, sawValue = false, inInline = false, inInlineText = false, inFormula = false, phonetic = 0, inCell = false
        var hiddenColumns: [ClosedRange<Int>] = []
        var sharedFormulas: [String: (text: String, row: Int, col: Int)] = [:]
        var inHeaderFooter: String?
        var headerFooterText = ""
        var inBreaks: String?
        var firstView = true, inView = false
        var defaultColWidth: Double?, baseColWidth = 8.0
        var hasCondFormat = false, hasDataBar = false, hasSparkline = false
        // Conditional formats this renderer applies: "cellIs" against constant numbers.
        var cfRanges: [SheetRange] = []
        var cfRules: [(ranges: [SheetRange], op: String, values: [Double], dxf: Int)] = []
        var cfRule: (op: String, dxf: Int, type: String)?
        var cfFormulas: [String] = []
        var inCFFormula = false, cfFormula = ""
        var otherCF = Set<String>()
        let maxCol = XlsxWriter.maxColumns - 1
        let mdw = sheet.maxDigitWidth

        func widthPoints(_ chars: Double) -> Double {
            // Excel: pixels = Truncate(((256 * width + Truncate(128 / MDW)) / 256) * MDW), at 96 dpi.
            let px = ((256 * chars + (128 / mdw).rounded(.down)) / 256 * mdw).rounded(.down)
            return max(0, px) * 0.75
        }

        try OOXMLSAX.run(data, part: part) { sax in
            sax.onStart = { tag, attrs in
                switch tag {
                case "x:sheetView":
                    inView = firstView
                case "x:pane":
                    guard inView, let state = attrs["state"], state.hasPrefix("frozen") else { break }
                    sheet.frozenRows = max(0, Int(OOXMLValue.double(attrs["ySplit"]) ?? 0))
                    sheet.frozenColumns = max(0, Int(OOXMLValue.double(attrs["xSplit"]) ?? 0))
                case "x:pageSetUpPr":
                    sheet.pageSetup.fitToPage = OOXMLValue.onOff(attrs["fitToPage"] ?? "0")
                case "x:sheetFormatPr":
                    if let h = OOXMLValue.double(attrs["defaultRowHeight"]), h > 0, h < 410 { sheet.defaultRowHeight = h }
                    defaultColWidth = OOXMLValue.double(attrs["defaultColWidth"]).flatMap { $0 >= 0 && $0 < 256 ? $0 : nil }
                    if let b = OOXMLValue.double(attrs["baseColWidth"]), b >= 0, b < 256 { baseColWidth = b }
                    sheet.rowsHiddenByDefault = OOXMLValue.onOff(attrs["zeroHeight"] ?? "0")
                case "x:col":
                    guard let lo = OOXMLValue.int(attrs["min"]), let hi = OOXMLValue.int(attrs["max"]), lo >= 1, hi >= lo else { break }
                    let range = (lo - 1)...min(hi - 1, maxCol)
                    if let h = attrs["hidden"], OOXMLValue.onOff(h) { hiddenColumns.append(range); break }
                    let width = OOXMLValue.double(attrs["width"]).map { $0 >= 0 && $0 < 256 ? widthPoints($0) : nil } ?? nil
                    let s = OOXMLValue.int(attrs["style"])
                    // A width of 0 hides the column as well.
                    if width == 0 { hiddenColumns.append(range); break }
                    // "min=1 max=16384" style ranges are common; only remember what can matter.
                    for c in range where c < 2000 || range.count < 64 {
                        if let width { sheet.columnWidths[c] = width }
                        if let s, s > 0 { sheet.columnStyles[c] = s }
                    }
                case "x:row":
                    row = OOXMLValue.int(attrs["r"]).flatMap { (1...XlsxWriter.maxRows).contains($0) ? $0 : nil } ?? min(row + 1, XlsxWriter.maxRows + 1)
                    col = -1
                    let r0 = row - 1
                    if let h = attrs["hidden"], OOXMLValue.onOff(h) { sheet.hiddenRows.insert(r0) }
                    if let ht = OOXMLValue.double(attrs["ht"]), ht >= 0, ht < 410 {
                        if ht == 0 { sheet.hiddenRows.insert(r0) }
                        sheet.rowHeights[r0] = ht
                        if OOXMLValue.onOff(attrs["customHeight"] ?? "0") { sheet.customRowHeights.insert(r0) }
                    }
                    if OOXMLValue.onOff(attrs["customFormat"] ?? "0"), let s = OOXMLValue.int(attrs["s"]), s > 0 { sheet.rowStyles[r0] = s }
                case "x:c":
                    if let r = attrs["r"], let ref = XlsxReader.parseRef(r) { col = ref.col; row = ref.row } else { col += 1 }
                    if row == 0 { row = 1 }
                    type = attrs["t"] ?? "n"
                    style = OOXMLValue.int(attrs["s"]) ?? 0
                    value = ""; inline = ""; formula = ""; formulaType = ""; formulaIndex = ""; sawValue = false; inCell = true
                case "x:v": inValue = inCell; sawValue = sawValue || inCell
                case "x:f":
                    inFormula = inCell
                    formulaType = attrs["t"] ?? ""; formulaIndex = attrs["si"] ?? ""
                case "x:is": inInline = inCell
                case "x:rPh": phonetic += 1
                case "x:t": inInlineText = inInline && phonetic == 0
                case "x:mergeCell":
                    if let ref = attrs["ref"], let r = parseRange(ref), r.r0 != r.r1 || r.c0 != r.c1 { sheet.merges.append(r) }
                case "x:printOptions":
                    sheet.pageSetup.gridLines = OOXMLValue.onOff(attrs["gridLines"] ?? "0") && OOXMLValue.onOff(attrs["gridLinesSet"] ?? "1")
                    sheet.pageSetup.headings = OOXMLValue.onOff(attrs["headings"] ?? "0")
                    sheet.pageSetup.centerHorizontally = OOXMLValue.onOff(attrs["horizontalCentered"] ?? "0")
                    sheet.pageSetup.centerVertically = OOXMLValue.onOff(attrs["verticalCentered"] ?? "0")
                case "x:pageMargins":
                    let keys = ["left", "right", "top", "bottom", "header", "footer"]
                    let defaults = [0.7, 0.7, 0.75, 0.75, 0.3, 0.3]
                    sheet.pageSetup.margins = keys.enumerated().map { i, k in
                        OOXMLValue.double(attrs[k]).flatMap { $0 >= 0 && $0 < 20 ? $0 : nil } ?? defaults[i]
                    }
                case "x:pageSetup":
                    let p = OOXMLValue.int(attrs["paperSize"])
                    sheet.pageSetup.paperSize = p.flatMap { $0 > 0 ? $0 : nil }
                    if let w = attrs["paperWidth"], let h = attrs["paperHeight"], let ws = measureMM(w), let hs = measureMM(h) {
                        sheet.pageSetup.paperSizeMM = CGSize(width: ws, height: hs)
                    }
                    if let o = attrs["orientation"]?.lowercased(), o == "portrait" || o == "landscape" { sheet.pageSetup.orientation = o }
                    if let s = OOXMLValue.int(attrs["scale"]), (10...400).contains(s) { sheet.pageSetup.scale = s }
                    if let w = OOXMLValue.int(attrs["fitToWidth"]), w >= 0 { sheet.pageSetup.fitToWidth = w }
                    if let h = OOXMLValue.int(attrs["fitToHeight"]), h >= 0 { sheet.pageSetup.fitToHeight = h }
                    sheet.pageSetup.overThenDown = attrs["pageOrder"] == "overThenDown"
                    if OOXMLValue.onOff(attrs["useFirstPageNumber"] ?? "0"), let f = OOXMLValue.int(attrs["firstPageNumber"]) {
                        sheet.pageSetup.firstPageNumber = f
                    }
                case "x:headerFooter":
                    sheet.pageSetup.differentFirst = OOXMLValue.onOff(attrs["differentFirst"] ?? "0")
                    sheet.pageSetup.differentOddEven = OOXMLValue.onOff(attrs["differentOddEven"] ?? "0")
                    sheet.pageSetup.scaleWithDoc = OOXMLValue.onOff(attrs["scaleWithDoc"] ?? "1")
                    sheet.pageSetup.alignWithMargins = OOXMLValue.onOff(attrs["alignWithMargins"] ?? "1")
                case "x:oddHeader", "x:oddFooter", "x:evenHeader", "x:evenFooter", "x:firstHeader", "x:firstFooter":
                    inHeaderFooter = tag; headerFooterText = ""
                case "x:rowBreaks", "x:colBreaks":
                    inBreaks = tag
                case "x:brk":
                    guard let kind = inBreaks, let id = OOXMLValue.int(attrs["id"]), id > 0 else { break }
                    if kind == "x:rowBreaks" { sheet.pageSetup.rowBreaks.insert(id) } else { sheet.pageSetup.columnBreaks.insert(id) }
                case "x:drawing":
                    sheet.drawingRelID = attrs["r:id"]
                case "x:conditionalFormatting":
                    hasCondFormat = true
                    cfRanges = (attrs["sqref"] ?? "").split(separator: " ").compactMap { parseRange(String($0)) }
                case "x:cfRule":
                    cfRule = (attrs["operator"] ?? "", OOXMLValue.int(attrs["dxfId"]) ?? -1, attrs["type"] ?? "")
                    cfFormulas = []
                case "x:formula":
                    if cfRule != nil { inCFFormula = true; cfFormula = "" }
                case "x:dataBar":
                    hasDataBar = true
                default:
                    if tag.hasSuffix(":sparklineGroup") { hasSparkline = true }
                }
            }
            sax.onEnd = { tag in
                switch tag {
                case "x:sheetView": if inView { firstView = false }; inView = false
                case "x:formula": if inCFFormula { cfFormulas.append(cfFormula); inCFFormula = false }
                case "x:cfRule":
                    if let rule = cfRule {
                        let values = cfFormulas.compactMap { OOXMLValue.double($0) }
                        if rule.type == "cellIs", rule.dxf >= 0, !values.isEmpty, values.count == cfFormulas.count { cfRules.append((cfRanges, rule.op, values, rule.dxf)) }
                        else { otherCF.insert(rule.type) }
                    }
                    cfRule = nil
                case "x:v": inValue = false
                case "x:f": inFormula = false
                case "x:t": inInlineText = false
                case "x:rPh": phonetic -= 1
                case "x:is": inInline = false
                case "x:rowBreaks", "x:colBreaks": inBreaks = nil
                case "x:oddHeader": sheet.pageSetup.oddHeader = headerFooterText; inHeaderFooter = nil
                case "x:oddFooter": sheet.pageSetup.oddFooter = headerFooterText; inHeaderFooter = nil
                case "x:evenHeader": sheet.pageSetup.evenHeader = headerFooterText; inHeaderFooter = nil
                case "x:evenFooter": sheet.pageSetup.evenFooter = headerFooterText; inHeaderFooter = nil
                case "x:firstHeader": sheet.pageSetup.firstHeader = headerFooterText; inHeaderFooter = nil
                case "x:firstFooter": sheet.pageSetup.firstFooter = headerFooterText; inHeaderFooter = nil
                case "x:c":
                    inCell = false
                    guard row >= 1, row <= XlsxWriter.maxRows, col >= 0, col <= maxCol else { return }
                    if formulaType == "shared", !formulaIndex.isEmpty {
                        if !formula.isEmpty { sharedFormulas[formulaIndex] = (formula, row, col) }
                        else if let master = sharedFormulas[formulaIndex] {
                            formula = XlsxReader.shiftFormula(master.text, rows: row - master.row, columns: col - master.col)
                        }
                    }
                    let r0 = row - 1
                    // Hidden rows and columns never reach the page, not even as overflowing text.
                    guard !sheet.hiddenRows.contains(r0), !hiddenColumns.contains(where: { $0.contains(col) }) else { return }
                    let format = style >= 0 && style < styles.formats.count ? styles.formats[style] : XlsxReader.CellFormat()
                    var v = XlsxReader.cellValue(type: type, value: value, inline: inline, shared: shared, format: format, date1904: date1904)
                    if v == .empty, !formula.isEmpty, value.isEmpty, !(type == "str" && sawValue) {
                        v = .text("=" + formula)
                    }
                    var cell = SheetCell(text: v.displayString, kind: .text, style: style >= 0 && style < styles.cellStyles.count ? style : 0)
                    switch type {
                    case "b": if v != .empty { cell.kind = .bool }
                    case "e": if v != .empty { cell.kind = .error }
                    case "d": if v != .empty { cell.kind = .number }
                    case "s":
                        if let i = Int(value.trimmingCharacters(in: .whitespaces)), i >= 0, i < sharedRuns.count, let runs = sharedRuns[i] {
                            cell.runs = runs
                        }
                    case "str", "inlineStr": break
                    default:
                        if let d = Double(value.trimmingCharacters(in: .whitespaces)), d.isFinite {
                            cell.kind = .number
                            cell.number = d
                            if let code = format.code ?? styles.rawCodes[style] {
                                cell.formatColor = formatColor(d, code: code, palette: styles.palette)
                            }
                        }
                    }
                    // A cell with neither value nor style adds nothing.
                    if cell.text.isEmpty && cell.style == 0 { return }
                    sheet.set(cell, r0, col)
                default: break
                }
            }
            sax.onText = { s in
                if inValue { value += s } else if inInlineText { inline += s } else if inFormula { formula += s }
                else if inHeaderFooter != nil { headerFooterText += s } else if inCFFormula { cfFormula += s }
            }
        }

        // Default width: the file's, else baseColWidth plus padding rounded up to whole multiples of 8 pixels.
        if let d = defaultColWidth {
            sheet.defaultColumnWidth = widthPoints(d)
        } else {
            let px = ((baseColWidth * mdw + 5) / 8).rounded(.up) * 8
            sheet.defaultColumnWidth = px * 0.75
        }
        for r in hiddenColumns { for c in r where c < 20_000 || r.count < 64 { sheet.hiddenColumns.insert(c) } }
        if hiddenColumns.contains(where: { $0.count >= 64 }) {
            // "Hide every column from here on": remember where it starts.
            sheet.hiddenFrom = hiddenColumns.filter { $0.count >= 64 }.map(\.lowerBound).min()
        }
        // Excel prints a merged block with the format of its top-left cell; the others only add their borders.
        // Simple conditional formats (a number compared with constants) recolour or fill the cells they match.
        var derived: [String: Int] = [:]
        for rule in cfRules where rule.dxf < styles.dxfs.count {
            let d = styles.dxfs[rule.dxf]
            for range in rule.ranges {
                for r in range.r0...min(range.r1, max(sheet.cells.count - 1, range.r0)) where r < sheet.cells.count {
                    for c in range.c0...min(range.c1, range.c0 + 16_384) where c < sheet.cells[r].count {
                        guard var cell = sheet.cells[r][c], let v = cell.number else { continue }
                        let a = rule.values[0], b = rule.values.count > 1 ? rule.values[1] : a
                        let hit: Bool
                        switch rule.op {
                        case "lessThan": hit = v < a
                        case "lessThanOrEqual": hit = v <= a
                        case "greaterThan": hit = v > a
                        case "greaterThanOrEqual": hit = v >= a
                        case "equal": hit = v == a
                        case "notEqual": hit = v != a
                        case "between": hit = v >= min(a, b) && v <= max(a, b)
                        case "notBetween": hit = v < min(a, b) || v > max(a, b)
                        default: hit = false
                        }
                        guard hit else { continue }
                        if let color = d.color { cell.formatColor = color }
                        if d.bold != nil || d.italic != nil || d.fill != nil {
                            let key = "\(cell.style)|\(rule.dxf)"
                            if derived[key] == nil {
                                var st = sheet.styles[cell.style]
                                if let b = d.bold { st.font.bold = b }
                                if let i = d.italic { st.font.italic = i }
                                if let f = d.fill { st.fill = f }
                                sheet.styles.append(st)
                                derived[key] = sheet.styles.count - 1
                            }
                            cell.style = derived[key]!
                        }
                        sheet.cells[r][c] = cell
                    }
                }
            }
        }
        if hasDataBar { sheet.notDrawn.append("data bars") }
        for t in otherCF.sorted() where t != "dataBar" { sheet.notDrawn.append("conditional formatting (\(t))") }
        if hasSparkline { sheet.notDrawn.append("sparklines") }
    }

    /// "297mm", "8.5in" -> millimetres.
    static func measureMM(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("mm"), let v = Double(t.dropLast(2)) { return v }
        if t.hasSuffix("cm"), let v = Double(t.dropLast(2)) { return v * 10 }
        if t.hasSuffix("in"), let v = Double(t.dropLast(2)) { return v * 25.4 }
        return nil
    }

    // MARK: References

    /// "A1:C3" / "B2" -> range (0-based).
    static func parseRange(_ ref: String) -> SheetRange? {
        let parts = ref.replacingOccurrences(of: "$", with: "").split(separator: ":").map(String.init)
        guard let a = parts.first.flatMap(XlsxReader.parseRef) else { return nil }
        let b = parts.count > 1 ? XlsxReader.parseRef(parts[1]) : a
        guard let b else { return nil }
        return SheetRange(r0: a.row - 1, c0: a.col, r1: b.row - 1, c1: b.col)
    }

    struct NamedRange { var sheet: String?; var range: SheetRange; var wholeRows: Bool; var wholeColumns: Bool }

    /// A defined name's value ("'売上'!$A$1:$K$22,'売上'!$3:$3") -> its ranges. Whole rows ("$3:$5") and whole
    /// columns ("$A:$B") are flagged.
    static func parseRanges(_ text: String) -> [NamedRange] {
        var pieces: [String] = []
        var cur = "", inQuote = false
        for ch in text {
            if ch == "'" { inQuote.toggle() }
            if ch == "," && !inQuote { pieces.append(cur); cur = "" } else { cur.append(ch) }
        }
        pieces.append(cur)
        return pieces.compactMap { piece -> NamedRange? in
            var sheet: String?
            var ref = piece.trimmingCharacters(in: .whitespaces)
            if let bang = ref.lastIndex(of: "!") {
                var s = String(ref[..<bang])
                if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 { s = String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
                sheet = s
                ref = String(ref[ref.index(after: bang)...])
            }
            ref = ref.replacingOccurrences(of: "$", with: "")
            let ends = ref.split(separator: ":").map(String.init)
            guard let first = ends.first, !first.isEmpty else { return nil }
            let second = ends.count > 1 ? ends[1] : first
            let maxRow = XlsxWriter.maxRows - 1, maxCol = XlsxWriter.maxColumns - 1
            if first.allSatisfy(\.isNumber), second.allSatisfy(\.isNumber), let a = Int(first), let b = Int(second), a >= 1, b >= 1 {
                return NamedRange(sheet: sheet, range: SheetRange(r0: a - 1, c0: 0, r1: min(b - 1, maxRow), c1: maxCol), wholeRows: true, wholeColumns: false)
            }
            if first.allSatisfy(\.isLetter), second.allSatisfy(\.isLetter),
               let a = XlsxReader.parseRef(first + "1"), let b = XlsxReader.parseRef(second + "1") {
                return NamedRange(sheet: sheet, range: SheetRange(r0: 0, c0: a.col, r1: maxRow, c1: b.col), wholeRows: false, wholeColumns: true)
            }
            guard let r = parseRange(first + ":" + second) else { return nil }
            return NamedRange(sheet: sheet, range: r, wholeRows: false, wholeColumns: false)
        }
    }

    // MARK: Number format colours

    static let namedColors: [String: DocColor] = [
        "black": DocColor(r: 0, g: 0, b: 0), "blue": DocColor(r: 0, g: 0, b: 1), "cyan": DocColor(r: 0, g: 1, b: 1),
        "green": DocColor(r: 0, g: 1, b: 0), "magenta": DocColor(r: 1, g: 0, b: 1), "red": DocColor(r: 1, g: 0, b: 0),
        "white": DocColor(r: 1, g: 1, b: 1), "yellow": DocColor(r: 1, g: 1, b: 0),
    ]

    /// The colour a number format gives `value` ("[Red]" in the section the value falls in), if any.
    static func formatColor(_ value: Double, code: String, palette: [DocColor]) -> DocColor? {
        guard code.contains("[") else { return nil }
        let secs = ExcelNumberFormat.sections(code)
        let section: String
        switch secs.count {
        case 1: section = secs[0]
        case 2: section = value < 0 ? secs[1] : secs[0]
        default: section = value > 0 ? secs[0] : (value < 0 ? secs[1] : secs[2])
        }
        var i = section.startIndex
        while let open = section[i...].firstIndex(of: "[") {
            guard let close = section[open...].firstIndex(of: "]") else { break }
            let tag = section[section.index(after: open)..<close].lowercased()
            if let c = namedColors[tag] { return c }
            if tag.hasPrefix("color"), let n = Int(tag.dropFirst(5)), n >= 1, n + 7 < palette.count { return palette[n + 7] }
            i = section.index(after: close)
        }
        return nil
    }
}

// MARK: - Styles

extension XlsxLayoutReader {

    struct Theme {
        /// lt1, dk1, lt2, dk2, accent1-6, hlink, folHlink: the order SpreadsheetML theme indexes use.
        var colors: [DocColor]
        var minorLatin: String?
        var minorJapanese: String?

        static let office = Theme(colors: ["FFFFFF", "000000", "EEECE1", "1F497D", "4F81BD", "C0504D", "9BBB59", "8064A2", "4BACC6", "F79646", "0000FF", "800080"]
            .compactMap { DocColor(hex: $0) }, minorLatin: "Calibri", minorJapanese: nil)

        init(colors: [DocColor], minorLatin: String?, minorJapanese: String?) {
            self.colors = colors; self.minorLatin = minorLatin; self.minorJapanese = minorJapanese
        }

        init(_ root: XNode) {
            var c = Theme.office.colors
            if let scheme = root.firstDescendant("a:clrScheme") {
                func color(_ name: String) -> DocColor? {
                    guard let n = scheme.child("a:\(name)") else { return nil }
                    if let s = n.child("a:srgbClr")?["val"] { return DocColor(hex: s) }
                    if let s = n.child("a:sysClr")?["lastClr"] { return DocColor(hex: s) }
                    return nil
                }
                let order = ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"]
                for (i, name) in order.enumerated() { if let v = color(name) { c[i] = v } }
            }
            colors = c
            let minor = root.firstDescendant("a:minorFont")
            minorLatin = minor?.child("a:latin")?["typeface"].flatMap { $0.isEmpty ? nil : $0 }
            minorJapanese = minor?.children("a:font").first { $0["script"] == "Jpan" }?["typeface"]
        }

        /// Scheme colour by DrawingML name (charts and shapes).
        func scheme(_ name: String) -> DocColor? {
            let map = ["bg1": 0, "lt1": 0, "tx1": 1, "dk1": 1, "bg2": 2, "lt2": 2, "tx2": 3, "dk2": 3, "accent1": 4, "accent2": 5,
                       "accent3": 6, "accent4": 7, "accent5": 8, "accent6": 9, "hlink": 10, "folHlink": 11]
            return map[name].flatMap { $0 < colors.count ? colors[$0] : nil }
        }
    }

    /// Excel's default 64-colour palette (indexes 0-63); 64 and 65 are the system foreground and background.
    static let defaultPalette: [DocColor] = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
        "000000", "FFFFFF",
    ].compactMap { DocColor(hex: $0) }

    /// Applies an Excel tint (-1...1) to a colour through HLS, as Excel does.
    static func tinted(_ c: DocColor, _ tint: Double) -> DocColor {
        guard tint != 0, tint.isFinite else { return c }
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        var h = 0.0, s = 0.0
        var l = (mx + mn) / 2
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            if mx == c.r { h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0) } else if mx == c.g { h = (c.b - c.r) / d + 2 } else { h = (c.r - c.g) / d + 4 }
            h /= 6
        }
        l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint
        l = min(max(l, 0), 1)
        func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        if s == 0 { return DocColor(r: l, g: l, b: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return DocColor(r: hue(p, q, h + 1.0 / 3), g: hue(p, q, h), b: hue(p, q, h - 1.0 / 3))
    }

    static func color(_ n: XNode?, theme: Theme, palette: [DocColor]) -> DocColor? {
        guard let n else { return nil }
        if OOXMLValue.onOff(n["auto"] ?? "0") { return nil }
        var c: DocColor?
        if let rgb = n["rgb"], rgb.count >= 6 { c = DocColor(hex: String(rgb.suffix(6))) }
        else if let t = OOXMLValue.int(n["theme"]), t >= 0, t < theme.colors.count { c = theme.colors[t] }
        else if let i = OOXMLValue.int(n["indexed"]) {
            if i == 64 || i == 65 { return nil } // system colours: automatic
            if i >= 0, i < palette.count { c = palette[i] }
        }
        guard let base = c else { return nil }
        return tinted(base, OOXMLValue.double(n["tint"]) ?? 0)
    }

    struct Styles {
        var formats: [XlsxReader.CellFormat] = []
        /// The format code of each cell style, also for built-ins that `formats` leaves out (for "[Red]").
        var rawCodes: [Int: String] = [:]
        var cellStyles: [SheetCellStyle] = [SheetCellStyle()]
        var fonts: [SheetFont] = [SheetFont(name: "Calibri", size: 11)]
        var defaultFont = SheetFont(name: "Calibri", size: 11)
        var palette = XlsxLayoutReader.defaultPalette
        var theme = Theme.office
        /// Differential formats used by conditional formatting: font colour, bold, italic, fill.
        var dxfs: [(color: DocColor?, bold: Bool?, italic: Bool?, fill: DocColor?)] = []

        init() {}

        init(_ root: XNode, theme: Theme) {
            self.theme = theme
            formats = XlsxReader.styleFormats(root)
            if let custom = root.child("x:colors")?.child("x:indexedColors")?.children("x:rgbColor"), !custom.isEmpty {
                var p = custom.compactMap { $0["rgb"].flatMap { DocColor(hex: String($0.suffix(6))) } }
                while p.count < 64 { p.append(XlsxLayoutReader.defaultPalette[p.count]) }
                palette = p
            }
            let pal = palette
            fonts = (root.child("x:fonts")?.children("x:font") ?? []).map { XlsxLayoutReader.font($0, theme: theme, palette: pal) }
            if fonts.isEmpty { fonts = [SheetFont(name: "Calibri", size: 11)] }
            let fills: [DocColor?] = (root.child("x:fills")?.children("x:fill") ?? []).map { XlsxLayoutReader.fill($0, theme: theme, palette: pal) }
            let borders: [SheetBorders] = (root.child("x:borders")?.children("x:border") ?? []).map { XlsxLayoutReader.borders($0, theme: theme, palette: pal) }
            var custom: [Int: String] = [:]
            for f in root.child("x:numFmts")?.children("x:numFmt") ?? [] {
                if let id = OOXMLValue.int(f["numFmtId"]) { custom[id] = f["formatCode"] ?? "" }
            }
            let styleFont = root.child("x:cellStyleXfs")?.children("x:xf").first.flatMap { OOXMLValue.int($0["fontId"]) } ?? 0
            defaultFont = styleFont >= 0 && styleFont < fonts.count ? fonts[styleFont] : fonts[0]
            let xfs = root.child("x:cellXfs")?.children("x:xf") ?? []
            dxfs = (root.child("x:dxfs")?.children("x:dxf") ?? []).map { d in
                let font = d.child("x:font")
                let p = d.child("x:fill")?.child("x:patternFill")
                // A differential solid fill keeps its colour in bgColor (fgColor in some writers).
                let fill = p.flatMap { p in p["patternType"] == "none" ? nil : (XlsxLayoutReader.color(p.child("x:bgColor"), theme: theme, palette: pal) ?? XlsxLayoutReader.color(p.child("x:fgColor"), theme: theme, palette: pal)) }
                return (XlsxLayoutReader.color(font?.child("x:color"), theme: theme, palette: pal),
                        font?.child("x:b").map { OOXMLValue.onOff($0["val"]) }, font?.child("x:i").map { OOXMLValue.onOff($0["val"]) }, fill)
            }
            cellStyles = xfs.enumerated().map { i, xf in
                var s = SheetCellStyle()
                let fontId = OOXMLValue.int(xf["fontId"]) ?? 0
                s.font = fontId >= 0 && fontId < fonts.count ? fonts[fontId] : defaultFont
                if let f = OOXMLValue.int(xf["fillId"]), f >= 0, f < fills.count { s.fill = fills[f] }
                if let b = OOXMLValue.int(xf["borderId"]), b >= 0, b < borders.count { s.borders = borders[b] }
                if let a = xf.child("x:alignment") {
                    s.hAlign = SheetHAlign(rawValue: a["horizontal"] ?? "general") ?? .general
                    s.vAlign = SheetVAlign(rawValue: a["vertical"] ?? "bottom") ?? .bottom
                    s.indent = min(max(OOXMLValue.int(a["indent"]) ?? 0, 0), 250)
                    s.wrap = OOXMLValue.onOff(a["wrapText"] ?? "0")
                    s.shrink = OOXMLValue.onOff(a["shrinkToFit"] ?? "0")
                    let rot = OOXMLValue.int(a["textRotation"]) ?? 0
                    s.rotation = rot == 255 ? 255 : (rot > 90 && rot <= 180 ? -(rot - 90) : min(max(rot, 0), 90))
                }
                if let id = OOXMLValue.int(xf["numFmtId"]) {
                    if let c = custom[id] { rawCodes[i] = c } else if id == 38 || id == 40 { rawCodes[i] = id == 38 ? "#,##0_);[Red](#,##0)" : "#,##0.00_);[Red](#,##0.00)" }
                }
                return s
            }
            if cellStyles.isEmpty {
                var s = SheetCellStyle(); s.font = defaultFont
                cellStyles = [s]
            }
        }

        /// The font of a rich-text run: its own properties over the workbook default (Excel starts runs from the
        /// default font, not from the cell's).
        func runFont(_ props: XNode?, theme: Theme) -> SheetFont {
            guard let props else { return defaultFont }
            var f = XlsxLayoutReader.font(props, theme: theme, palette: palette)
            if props.child("x:sz") == nil { f.size = defaultFont.size }
            if props.child("x:rFont") == nil && props.child("x:name") == nil { f.name = defaultFont.name }
            if props.child("x:color") == nil { f.color = defaultFont.color }
            return f
        }
    }

    static func font(_ n: XNode, theme: Theme, palette: [DocColor]) -> SheetFont {
        var f = SheetFont(name: n.child("x:name")?["val"] ?? n.child("x:rFont")?["val"], size: 11)
        if let sz = OOXMLValue.double(n.child("x:sz")?["val"]), sz >= 1, sz <= 409 { f.size = sz }
        f.bold = n.child("x:b").map { OOXMLValue.onOff($0["val"]) } ?? false
        f.italic = n.child("x:i").map { OOXMLValue.onOff($0["val"]) } ?? false
        f.strike = n.child("x:strike").map { OOXMLValue.onOff($0["val"]) } ?? false
        if let u = n.child("x:u") {
            switch u["val"] ?? "single" {
            case "none": f.underline = 0
            case "double", "doubleAccounting": f.underline = 2
            default: f.underline = 1
            }
        }
        switch n.child("x:vertAlign")?["val"] {
        case "superscript": f.baseline = .superscript
        case "subscript": f.baseline = .subscript
        default: break
        }
        f.color = color(n.child("x:color"), theme: theme, palette: palette)
        if let c = f.color, c.isNearlyBlack, c.r == 0, c.g == 0, c.b == 0 { f.color = nil }
        return f
    }

    static func fill(_ n: XNode, theme: Theme, palette: [DocColor]) -> DocColor? {
        if let p = n.child("x:patternFill") {
            let type = p["patternType"] ?? (p.child("x:fgColor") != nil ? "solid" : "none")
            if type == "none" { return nil }
            let fg = color(p.child("x:fgColor"), theme: theme, palette: palette) ?? DocColor(r: 0, g: 0, b: 0)
            let bg = color(p.child("x:bgColor"), theme: theme, palette: palette) ?? DocColor(r: 1, g: 1, b: 1)
            // Pattern fills are printed as the share of foreground they show.
            let share: Double
            switch type {
            case "solid": return fg
            case "gray0625": share = 0.0625
            case "gray125": share = 0.125
            case "lightGray": share = 0.25
            case "mediumGray": share = 0.5
            case "darkGray": share = 0.75
            default: share = 0.375 // stripes, grids, trellis
            }
            return DocColor(r: bg.r + (fg.r - bg.r) * share, g: bg.g + (fg.g - bg.g) * share, b: bg.b + (fg.b - bg.b) * share)
        }
        if let g = n.child("x:gradientFill") {
            let stops = g.children("x:stop").compactMap { color($0.child("x:color"), theme: theme, palette: palette) }
            guard !stops.isEmpty else { return nil }
            let k = Double(stops.count)
            return DocColor(r: stops.map(\.r).reduce(0, +) / k, g: stops.map(\.g).reduce(0, +) / k, b: stops.map(\.b).reduce(0, +) / k)
        }
        return nil
    }

    static func borders(_ n: XNode, theme: Theme, palette: [DocColor]) -> SheetBorders {
        func line(_ e: XNode?) -> SheetBorderLine? {
            guard let e, let s = e["style"], s != "none", let style = SheetBorderStyle(rawValue: s) else { return nil }
            return SheetBorderLine(style: style, color: color(e.child("x:color"), theme: theme, palette: palette))
        }
        var b = SheetBorders()
        b.left = line(n.child("x:left") ?? n.child("x:start"))
        b.right = line(n.child("x:right") ?? n.child("x:end"))
        b.top = line(n.child("x:top"))
        b.bottom = line(n.child("x:bottom"))
        if let d = line(n.child("x:diagonal")) {
            if OOXMLValue.onOff(n["diagonalDown"] ?? "0") { b.diagonalDown = d }
            if OOXMLValue.onOff(n["diagonalUp"] ?? "0") { b.diagonalUp = d }
        }
        return b
    }
}
