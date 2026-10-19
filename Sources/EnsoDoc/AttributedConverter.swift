import AppKit

extension NSAttributedString.Key {
    /// Marks a paragraph that should start a new page when the attributed string is paginated.
    public static let ensoPageBreak = NSAttributedString.Key("EnsoPageBreak")
}

/// DocModel <-> NSAttributedString. The attributed form feeds TextKit (PDF layout, the rich-text editor)
/// and Cocoa's own readers/writers (RTF, RTFD, .doc, .odt, HTML).
public enum AttributedConverter {

    public struct Style {
        public var bodySize: CGFloat
        public var contentWidth: CGFloat
        public var contentHeight: CGFloat
        public var fontName: String?
        public init(bodySize: CGFloat = 11, contentWidth: CGFloat = 480, contentHeight: CGFloat = 720, fontName: String? = nil) {
            self.bodySize = bodySize; self.contentWidth = contentWidth; self.contentHeight = contentHeight; self.fontName = fontName
        }
    }

    // MARK: Fonts

    static func baseFont(size: CGFloat, name: String?) -> NSFont {
        if let name, let f = NSFont(name: name, size: size) { return f }
        if let name, let family = familyFont(name, size: size) { return family }
        return NSFont(name: "HiraginoSans-W3", size: size) ?? .systemFont(ofSize: size)
    }

    private static func familyFont(_ name: String, size: CGFloat) -> NSFont? {
        let d = NSFontDescriptor(fontAttributes: [.family: name])
        return NSFont(descriptor: d, size: size)
    }

    static func font(_ base: NSFont, size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        var f: NSFont = mono ? (NSFont(name: "Menlo-Regular", size: size * 0.92) ?? .monospacedSystemFont(ofSize: size * 0.92, weight: .regular))
                             : (NSFont(descriptor: base.fontDescriptor, size: size) ?? base)
        let fm = NSFontManager.shared
        if bold {
            let b = fm.convert(f, toHaveTrait: .boldFontMask)
            if b.fontDescriptor.symbolicTraits.contains(.bold) { f = b }
            else if f.fontName.hasPrefix("HiraginoSans"), let w6 = NSFont(name: "HiraginoSans-W6", size: f.pointSize) { f = w6 }
        }
        if italic {
            let i = fm.convert(f, toHaveTrait: .italicFontMask)
            if i.fontDescriptor.symbolicTraits.contains(.italic) { f = i }
        }
        return f
    }

    static func nsColor(_ c: DocColor) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    // MARK: DocModel -> NSAttributedString

    public static func attributedString(from model: DocModel, style: Style = Style()) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = style.bodySize
        let base = baseFont(size: body, name: style.fontName ?? model.bodyFontName)
        var tableCounter = 0
        var pendingPageBreak = false

        func paraStyle(_ align: DocAlignment = .left, before: CGFloat = 0, after: CGFloat? = nil, indent: CGFloat = 0, lineHeight: CGFloat = 1.4) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.alignment = { switch align { case .left: return .natural; case .center: return .center; case .right: return .right; case .justify: return .justified } }()
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after ?? body * 0.65
            p.lineHeightMultiple = lineHeight
            p.headIndent = indent
            p.firstLineHeadIndent = indent
            return p
        }

        func append(runs: [DocRun], size: CGFloat, forceBold: Bool = false, color: NSColor? = nil, paragraph: NSParagraphStyle, extra: [NSAttributedString.Key: Any] = [:]) {
            let start = out.length
            for run in runs {
                let rs = CGFloat(run.fontSize ?? Double(size))
                let runBase = run.fontName.map { baseFont(size: rs, name: $0) } ?? base
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font(runBase, size: rs, bold: forceBold || run.bold, italic: run.italic, mono: run.code),
                    .paragraphStyle: paragraph,
                ]
                if let c = run.color { attrs[.foregroundColor] = nsColor(c) } else if let color { attrs[.foregroundColor] = color }
                if let h = run.highlight { attrs[.backgroundColor] = nsColor(h) }
                if run.code { attrs[.backgroundColor] = NSColor(white: 0.5, alpha: 0.12) }
                if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link, let url = LinkPolicy.openableURL(link) { attrs[.link] = url }
                for (k, v) in extra { attrs[k] = v }
                out.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            var endAttrs: [NSAttributedString.Key: Any] = [.font: base.withSize(size), .paragraphStyle: paragraph]
            for (k, v) in extra { endAttrs[k] = v }
            out.append(NSAttributedString(string: "\n", attributes: endAttrs))
            if pendingPageBreak {
                out.addAttribute(.ensoPageBreak, value: true, range: NSRange(location: start, length: out.length - start))
                pendingPageBreak = false
            }
        }

        for block in model.blocks {
            switch block {
            case .heading(let level, let p):
                let scale: CGFloat = [1.9, 1.5, 1.25, 1.1, 1.0, 1.0][max(0, min(5, level - 1))]
                let size = (body * scale).rounded()
                let ps = paraStyle(p.alignment, before: out.length == 0 ? 0 : size * 0.9, after: size * 0.4, lineHeight: 1.2)
                ps.headerLevel = level
                append(runs: p.runs.map { var r = $0; r.fontSize = nil; return r }, size: size, forceBold: true, paragraph: ps)
            case .paragraph(let p):
                append(runs: p.runs, size: body, paragraph: paraStyle(p.alignment, indent: CGFloat(p.indent)))
            case .listItem(let li):
                let list = NSTextList(markerFormat: li.ordered ? .decimal : (li.level % 2 == 0 ? .disc : .circle), options: 0)
                let ps = paraStyle(after: body * 0.25)
                let indent = CGFloat(li.level + 1) * 22
                ps.textLists = Array(repeating: list, count: li.level + 1)
                ps.headIndent = indent
                ps.firstLineHeadIndent = indent - 22
                ps.tabStops = [NSTextTab(textAlignment: .left, location: indent - 16), NSTextTab(textAlignment: .left, location: indent)]
                let marker = li.ordered ? "\(li.number ?? 1)." : list.marker(forItemNumber: 1)
                var runs = li.paragraph.runs
                runs.insert(DocRun("\t\(marker)\t"), at: 0)
                append(runs: runs, size: body, paragraph: ps)
            case .quote(let p):
                let ps = paraStyle(indent: 18)
                append(runs: p.runs, size: body, color: .secondaryLabelColor, paragraph: ps)
            case .code(let s, _):
                let ps = paraStyle(after: 0, lineHeight: 1.15)
                let lines = s.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    let last = i == lines.count - 1
                    let p = (ps.mutableCopy() as! NSMutableParagraphStyle)
                    if last { p.paragraphSpacing = body * 0.8 }
                    append(runs: [DocRun(line.isEmpty ? " " : line, code: true)], size: body, paragraph: p)
                }
            case .table(let t):
                tableCounter += 1
                let cols = max(1, t.columnCount)
                let table = NSTextTable()
                table.numberOfColumns = cols
                table.layoutAlgorithm = .automaticLayoutAlgorithm
                table.collapsesBorders = true
                table.setContentWidth(100, type: .percentageValueType)
                for (r, row) in t.rows.enumerated() {
                    var col = 0
                    for cell in row {
                        let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: col, columnSpan: max(1, cell.colSpan))
                        block.setWidth(0.5, type: .absoluteValueType, for: .border)
                        block.setBorderColor(NSColor(white: 0.62, alpha: 1))
                        block.setWidth(4, type: .absoluteValueType, for: .padding)
                        if r < t.headerRows { block.backgroundColor = NSColor(white: 0.93, alpha: 1) }
                        let ps = paraStyle(after: 0, lineHeight: 1.2)
                        ps.textBlocks = [block]
                        let runs = cell.paragraphs.enumerated().flatMap { (i, p) in (i > 0 ? [DocRun("\u{2028}")] : []) + p.runs }
                        append(runs: runs.isEmpty ? [DocRun("")] : runs, size: body * 0.95, forceBold: r < t.headerRows, paragraph: ps)
                        col += max(1, cell.colSpan)
                    }
                    // Pad short rows so TextKit keeps the grid.
                    while col < cols {
                        let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: col, columnSpan: 1)
                        block.setWidth(0.5, type: .absoluteValueType, for: .border)
                        block.setBorderColor(NSColor(white: 0.62, alpha: 1))
                        let ps = paraStyle(after: 0); ps.textBlocks = [block]
                        append(runs: [DocRun("")], size: body * 0.95, paragraph: ps)
                        col += 1
                    }
                }
                // Space after the table.
                append(runs: [], size: body * 0.6, paragraph: paraStyle(after: 0))
            case .image(let img):
                guard let image = NSImage(data: img.data) else { continue }
                var w = CGFloat(img.displayWidth), h = CGFloat(img.displayHeight)
                let maxW = style.contentWidth, maxH = style.contentHeight * 0.92
                let k = min(1, maxW / max(w, 1), maxH / max(h, 1))
                w *= k; h *= k
                let att = NSTextAttachment()
                att.image = image
                att.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                let ps = paraStyle(.center, before: body * 0.4, after: body * 0.8, lineHeight: 1)
                let s = NSMutableAttributedString(attachment: att)
                s.addAttributes([.paragraphStyle: ps], range: NSRange(location: 0, length: s.length))
                let start = out.length
                out.append(s)
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: ps, .font: base]))
                if pendingPageBreak {
                    out.addAttribute(.ensoPageBreak, value: true, range: NSRange(location: start, length: out.length - start))
                    pendingPageBreak = false
                }
            case .pageBreak:
                pendingPageBreak = true
            case .horizontalRule:
                let block = NSTextBlock()
                block.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(NSColor(white: 0.7, alpha: 1))
                block.setValue(100, type: .percentageValueType, for: .width)
                let ps = paraStyle(after: body * 0.8, lineHeight: 0.5)
                ps.textBlocks = [block]
                append(runs: [DocRun(" ")], size: body * 0.5, paragraph: ps)
            }
        }
        return out
    }

    // MARK: NSAttributedString -> DocModel

    public static func model(from attr: NSAttributedString, title: String? = nil) -> DocModel {
        let ns = attr.string as NSString
        let length = ns.length
        // Body size = most common size by character count.
        var sizeCount: [CGFloat: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: length)) { v, r, _ in
            if let f = v as? NSFont { sizeCount[(f.pointSize * 2).rounded() / 2, default: 0] += r.length }
        }
        let body = sizeCount.max(by: { $0.value < $1.value })?.key ?? 12
        var fontCount: [String: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: length)) { v, r, _ in
            if let f = v as? NSFont, let fam = f.familyName { fontCount[fam, default: 0] += r.length }
        }

        var model = DocModel(title: title, bodyFontSize: Double(body), bodyFontName: fontCount.max(by: { $0.value < $1.value })?.key)
        var tableRows: [Int: [Int: DocTableCell]] = [:]
        var currentTable: NSTextTable?
        var tableHeaderRows = 0

        func flushTable() {
            guard currentTable != nil else { return }
            let rows = tableRows.keys.sorted().map { r -> [DocTableCell] in
                let cells = tableRows[r]!
                return cells.keys.sorted().map { cells[$0]! }
            }
            if !rows.isEmpty { model.blocks.append(.table(DocTable(rows: rows, headerRows: tableHeaderRows))) }
            tableRows = [:]; currentTable = nil; tableHeaderRows = 0
        }

        var location = 0
        while location < length {
            let pr = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(pr)
            var contentRange = pr
            while contentRange.length > 0, let last = ns.substring(with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)).unicodeScalars.first,
                  CharacterSet.newlines.contains(last) { contentRange.length -= 1 }
            let ps = attr.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle

            // Tables
            if let tb = ps?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                if currentTable !== tb.table { flushTable(); currentTable = tb.table }
                let p = paragraph(attr, contentRange, body: body, alignment: ps?.alignment)
                var cell = tableRows[tb.startingRow, default: [:]][tb.startingColumn] ?? DocTableCell([], colSpan: tb.columnSpan)
                cell.paragraphs.append(p)
                tableRows[tb.startingRow, default: [:]][tb.startingColumn] = cell
                if tb.startingRow == 0, p.runs.allSatisfy({ $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }), !p.isEmpty { tableHeaderRows = 1 }
                continue
            }
            flushTable()

            if attr.attribute(.ensoPageBreak, at: pr.location, effectiveRange: nil) != nil, !model.blocks.isEmpty {
                model.blocks.append(.pageBreak)
            }

            // Attachments (images) — may be mixed with text in the same paragraph.
            var hasImage = false
            attr.enumerateAttribute(.attachment, in: contentRange) { v, _, _ in
                guard let att = v as? NSTextAttachment, let img = docImage(att) else { return }
                model.blocks.append(.image(img)); hasImage = true
            }

            var p = paragraph(attr, contentRange, body: body, alignment: ps?.alignment)
            p.runs = p.runs.map { var r = $0; r.text = r.text.replacingOccurrences(of: "\u{FFFC}", with: ""); return r }.filter { !$0.text.isEmpty }
            if p.isEmpty { continue }
            _ = hasImage

            if let lists = ps?.textLists, let list = lists.last {
                // Strip the "\t•\t" / "\t1.\t" marker Cocoa keeps in the text.
                var text = p.plainText
                var number: Int?
                if let m = text.range(of: #"^\t?[^\t]{0,8}\t"#, options: .regularExpression) {
                    let marker = text[m].trimmingCharacters(in: .whitespaces)
                    number = Int(marker.trimmingCharacters(in: CharacterSet(charactersIn: ".)").union(.whitespaces)))
                    text.removeSubrange(m)
                    p = stripPrefix(p, count: text.count)
                }
                let ordered = ![NSTextList.MarkerFormat.disc, .circle, .square, .hyphen, .box, .check, .diamond].contains(list.markerFormat)
                model.blocks.append(.listItem(DocListItem(ordered: ordered, level: lists.count - 1, number: ordered ? number : nil, paragraph: p)))
                continue
            }

            let maxSize = p.runs.map { $0.fontSize ?? Double(body) }.max() ?? Double(body)
            let allBold = p.runs.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            let text = p.plainText
            let short = text.count <= 80 && !text.hasSuffix("。") && !text.hasSuffix(".")
            if let hl = ps?.headerLevel, hl > 0 {
                model.blocks.append(.heading(level: hl, unsized(p)))
            } else if short && maxSize >= Double(body) * 1.6 {
                model.blocks.append(.heading(level: 1, unsized(p)))
            } else if short && maxSize >= Double(body) * 1.3 {
                model.blocks.append(.heading(level: 2, unsized(p)))
            } else if short && (maxSize >= Double(body) * 1.12 || (allBold && text.count <= 30)) {
                model.blocks.append(.heading(level: 3, unsized(p)))
            } else if ps.map({ $0.headIndent >= 12 && $0.firstLineHeadIndent >= 12 }) == true,
                      p.runs.first?.color.map({ !$0.isNearlyBlack }) == true {
                model.blocks.append(.quote(p))
            } else if p.runs.allSatisfy({ $0.code }) {
                model.blocks.append(.code(text, language: nil))
            } else {
                model.blocks.append(.paragraph(p))
            }
        }
        flushTable()
        // Merge consecutive code lines into one block.
        var merged: [DocBlock] = []
        for b in model.blocks {
            if case .code(let s, let l) = b, case .code(let prev, _)? = merged.last {
                merged[merged.count - 1] = .code(prev + "\n" + s, language: l)
            } else { merged.append(b) }
        }
        model.blocks = merged
        return model
    }

    private static func unsized(_ p: DocParagraph) -> DocParagraph {
        var q = p
        q.runs = p.runs.map { var r = $0; r.fontSize = nil; r.bold = false; return r }
        return q.normalized()
    }

    private static func stripPrefix(_ p: DocParagraph, count keep: Int) -> DocParagraph {
        // Drop characters from the front until only `keep` remain.
        var drop = p.plainText.count - keep
        var q = p
        var runs: [DocRun] = []
        for var r in p.runs {
            if drop > 0 {
                if r.text.count <= drop { drop -= r.text.count; continue }
                r.text = String(r.text.dropFirst(drop)); drop = 0
            }
            runs.append(r)
        }
        q.runs = runs
        return q
    }

    static func paragraph(_ attr: NSAttributedString, _ range: NSRange, body: CGFloat, alignment: NSTextAlignment?) -> DocParagraph {
        var runs: [DocRun] = []
        attr.enumerateAttributes(in: range) { attrs, r, _ in
            var text = (attr.string as NSString).substring(with: r)
            text = text.replacingOccurrences(of: "\u{2028}", with: "\n")
            var run = DocRun(text)
            if let f = attrs[.font] as? NSFont {
                let traits = f.fontDescriptor.symbolicTraits
                let name = f.fontName.lowercased()
                run.bold = traits.contains(.bold) || name.contains("bold") || name.hasSuffix("-w6") || name.hasSuffix("-w7") || name.hasSuffix("-w8") || name.contains("heavy") || name.contains("black")
                run.italic = traits.contains(.italic)
                run.code = traits.contains(.monoSpace) && !(f.familyName ?? "").contains("Osaka")
                if abs(f.pointSize - body) > 0.6 { run.fontSize = Double(f.pointSize) }
                if !run.code, let fam = f.familyName, !fam.hasPrefix(".") { run.fontName = fam }
            }
            if let u = attrs[.underlineStyle] as? Int, u != 0, attrs[.link] == nil { run.underline = true }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { run.strikethrough = true }
            if let c = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                let dc = DocColor(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
                if !dc.isNearlyBlack { run.color = dc }
            }
            if let c = (attrs[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB), c.alphaComponent > 0.2,
               !(c.redComponent > 0.97 && c.greenComponent > 0.97 && c.blueComponent > 0.97), !run.code {
                run.highlight = DocColor(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
            }
            if let l = attrs[.link] { run.link = (l as? URL)?.absoluteString ?? (l as? String) }
            runs.append(run)
        }
        let align: DocAlignment = {
            switch alignment {
            case .center?: return .center
            case .right?: return .right
            case .justified?: return .justify
            default: return .left
            }
        }()
        return DocParagraph(runs, alignment: align).normalized()
    }

    static func docImage(_ att: NSTextAttachment) -> DocImage? {
        // Attachments come from the document. Encoded bytes are checked against the pixel limit from their header
        // before anything is decoded; an already decoded image is checked by its pixel size. Oversized ones are skipped.
        var image: NSImage?
        if let ready = att.image {
            image = ready
        } else if let data = att.fileWrapper?.regularFileContents ?? att.contents {
            guard ImageCodec.isWithinLimits(data) else { return nil }
            image = NSImage(data: data)
        }
        guard let img = image else { return nil }
        for rep in img.representations where rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            guard SafeInt.isReasonablePixelSize(rep.pixelsWide, rep.pixelsHigh) else { return nil }
        }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              SafeInt.isReasonablePixelSize(cg.width, cg.height) else { return nil }
        let size = att.bounds.size != .zero ? att.bounds.size : img.size
        return ImageCodec.docImage(from: cg, displayWidth: Double(size.width), displayHeight: Double(size.height))
    }
}
