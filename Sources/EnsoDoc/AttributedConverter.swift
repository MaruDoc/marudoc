import AppKit

extension NSAttributedString.Key {
    /// Marks a paragraph that should start a new page when the attributed string is paginated. Each break carries its
    /// own value (1, 2, …), so two breaks in a row stay two attribute runs and two pages.
    public static let ensoPageBreak = NSAttributedString.Key("EnsoPageBreak")
    /// On a footnote mark: the note's text (an NSAttributedString), which PDFRenderer sets at the foot of the page.
    public static let ensoFootnote = NSAttributedString.Key("EnsoFootnote")
    /// On a footnote mark: the note's `DocNote.id`, so each mark is a separate attribute run.
    static let ensoNoteID = NSAttributedString.Key("EnsoNoteID")
}

/// DocModel <-> NSAttributedString. The attributed form feeds TextKit (PDF layout, the rich-text editor)
/// and Cocoa's own readers/writers (RTF, RTFD, .doc, .odt, HTML).
public enum AttributedConverter {

    public struct Style {
        public var bodySize: CGFloat
        public var contentWidth: CGFloat
        public var contentHeight: CGFloat
        public var fontName: String?
        /// True when PDFRenderer paginates the result: footnotes then ride on their marks (`.ensoFootnote`) and are
        /// set at the foot of the page. Otherwise (RTF, the editor) they are listed at the end with the endnotes.
        public var paged: Bool
        public init(bodySize: CGFloat = 11, contentWidth: CGFloat = 480, contentHeight: CGFloat = 720, fontName: String? = nil,
                    paged: Bool = false) {
            self.bodySize = bodySize; self.contentWidth = contentWidth; self.contentHeight = contentHeight; self.fontName = fontName
            self.paged = paged
        }
    }

    // MARK: Fonts

    /// The font for `name`, or for the Mac font that stands in for it when it is a Windows-only family, as the
    /// in-app Word editor draws it (ＭＳ 明朝 → Hiragino Mincho, Century → Times New Roman). With `eastAsian` (the
    /// document's East Asian body font) Japanese characters are drawn in that font rather than the system's
    /// fallback, so a Century + ＭＳ 明朝 document prints in Mincho, not Gothic. No usable name: Hiragino Sans.
    static func baseFont(size: CGFloat, name: String?, eastAsian: String? = nil) -> NSFont {
        // Font lookups by family are slow and every run asks again: remembered per name and size.
        let key = "\(name ?? "")|\(eastAsian ?? "")|\(size)"
        fontLock.lock()
        if let hit = baseFontCache[key] { fontLock.unlock(); return hit }
        fontLock.unlock()
        let f = resolveBaseFont(size: size, name: name, eastAsian: eastAsian)
        fontLock.lock(); baseFontCache[key] = f; fontLock.unlock()
        return f
    }

    private static let fontLock = NSLock()
    nonisolated(unsafe) private static var baseFontCache: [String: NSFont] = [:]
    nonisolated(unsafe) private static var styledFontCache: [String: NSFont] = [:]

    private static func resolveBaseFont(size: CGFloat, name: String?, eastAsian: String?) -> NSFont {
        let latin = name.flatMap { installedFont($0, size: size) }
        let ea = eastAsian.flatMap { installedFont($0, size: size) }
        guard let primary = latin ?? ea else { return NSFont(name: "HiraginoSans-W3", size: size) ?? .systemFont(ofSize: size) }
        if let ea, ea.fontName != primary.fontName {
            let d = primary.fontDescriptor.addingAttributes([.cascadeList: [ea.fontDescriptor]])
            return NSFont(descriptor: d, size: size) ?? primary
        }
        return primary
    }

    private static func familyFont(_ name: String, size: CGFloat) -> NSFont? {
        guard NSFontManager.shared.availableMembers(ofFontFamily: name)?.isEmpty == false else { return nil }
        let d = NSFontDescriptor(fontAttributes: [.family: name])
        return NSFont(descriptor: d, size: size)
    }

    static func installedFont(_ name: String, size: CGFloat) -> NSFont? {
        if let f = NSFont(name: name, size: size) { return f }
        if let f = familyFont(name, size: size) { return f }
        let k = fontKey(name)
        if let mac = windowsFonts[k] { return NSFont(name: mac, size: size) ?? familyFont(mac, size: size) }
        if k.contains("明朝") || k.contains("mincho") { return familyFont("Hiragino Mincho ProN", size: size) }
        if k.contains("ゴシック") || k.contains("gothic") || k.contains("ｺﾞｼｯｸ") { return familyFont("Hiragino Sans", size: size) }
        return nil
    }

    private static func fontKey(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }

    /// Windows families and the Mac fonts drawn for them: the same choices as DocxDisplayFonts (EnsoOffice), which
    /// EnsoDoc cannot import.
    static let windowsFonts: [String: String] = {
        var t: [String: String] = [:]
        func map(_ mac: String, _ names: String...) { for n in names { t[fontKey(n)] = mac } }
        map("YuMincho", "游明朝", "Yu Mincho", "游明朝 Demibold", "游明朝 Light", "Yu Mincho Demibold", "Yu Mincho Light")
        map("YuGothic", "游ゴシック", "Yu Gothic", "游ゴシック Medium", "游ゴシック Light", "Yu Gothic Medium", "Yu Gothic Light", "Yu Gothic UI")
        map("Hiragino Mincho ProN", "ＭＳ 明朝", "MS Mincho", "ＭＳ Ｐ明朝", "MS PMincho", "HG明朝E", "HGP明朝E", "BIZ UD明朝", "BIZ UDP明朝", "IPA明朝", "IPAex明朝")
        map("Hiragino Sans", "ＭＳ ゴシック", "MS Gothic", "ＭＳ Ｐゴシック", "MS PGothic", "MS UI Gothic", "メイリオ", "Meiryo", "Meiryo UI",
            "BIZ UDゴシック", "BIZ UDPゴシック", "HGゴシックE", "HGPゴシックE", "HG丸ｺﾞｼｯｸM-PRO", "IPAゴシック", "IPAexゴシック")
        map("Helvetica Neue", "Calibri", "Calibri Light", "Segoe UI", "Aptos", "Aptos Display", "Arial Nova", "Tahoma")
        map("Georgia", "Cambria", "Cambria Math", "Constantia")
        map("Times New Roman", "Century", "Century Schoolbook", "Book Antiqua", "Garamond")
        map("Menlo", "Consolas", "Courier New", "Lucida Console")
        return t
    }()

    static func font(_ base: NSFont, size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        let cascade = (base.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])?.first
        let key = "\(base.fontName)|\(cascade?.postscriptName ?? "")|\(size)|\(bold)|\(italic)|\(mono)"
        fontLock.lock()
        if let hit = styledFontCache[key] { fontLock.unlock(); return hit }
        fontLock.unlock()
        let f = styledFont(base, size: size, bold: bold, italic: italic, mono: mono)
        fontLock.lock(); styledFontCache[key] = f; fontLock.unlock()
        return f
    }

    private static func styledFont(_ base: NSFont, size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        var f: NSFont = mono ? (NSFont(name: "Menlo-Regular", size: size * 0.92) ?? .monospacedSystemFont(ofSize: size * 0.92, weight: .regular))
                             : (NSFont(descriptor: base.fontDescriptor, size: size) ?? base)
        let fm = NSFontManager.shared
        if bold { f = emboldened(f) }
        if italic {
            let i = fm.convert(f, toHaveTrait: .italicFontMask)
            if i.fontDescriptor.symbolicTraits.contains(.italic) { f = i }
        }
        // Converting the face drops the East Asian cascade (see baseFont): put it back, bold where the text is bold.
        if !mono, bold || italic, let ea = (base.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])?.first,
           let eaFont = NSFont(descriptor: ea, size: f.pointSize) {
            let styled = bold ? emboldened(eaFont) : eaFont
            f = NSFont(descriptor: f.fontDescriptor.addingAttributes([.cascadeList: [styled.fontDescriptor]]), size: f.pointSize) ?? f
        }
        return f
    }

    /// The bold face; Japanese families whose bold NSFontManager does not find get their heavier weight by name.
    static func emboldened(_ f: NSFont) -> NSFont {
        let b = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        if b.fontDescriptor.symbolicTraits.contains(.bold) { return b }
        let heavier = ["HiraginoSans": "HiraginoSans-W6", "HiraMinProN": "HiraMinProN-W6", "YuMin": "YuMin-Demibold", "YuGo": "YuGo-Bold"]
        for (prefix, name) in heavier where f.fontName.hasPrefix(prefix) {
            if let h = NSFont(name: name, size: f.pointSize) { return h }
        }
        return f
    }

    static func nsColor(_ c: DocColor) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    /// Word's hyperlink blue, for links that carry no colour of their own.
    static let linkColor = NSColor(srgbRed: 0x05 / 255, green: 0x63 / 255, blue: 0xC1 / 255, alpha: 1)

    // MARK: DocModel -> NSAttributedString

    public static func attributedString(from model: DocModel, style: Style = Style()) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = style.bodySize
        let base = baseFont(size: body, name: style.fontName ?? model.bodyFontName, eastAsian: style.fontName == nil ? model.bodyEastAsianFontName : nil)
        var tableCounter = 0
        var pendingPageBreak = false
        var breakCount = 0
        let notesByID = Dictionary(model.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

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

        /// Runs as attributed text. Superscript and subscript use a smaller font with the `.superscript` attribute (RTF
        /// keeps it as \\super / \\sub); ruby, which TextKit cannot draw, is written as base（reading）; inline pictures
        /// become attachments no wider than `maxImageWidth`; a footnote mark in paged output carries its note.
        func styled(_ runs: [DocRun], size: CGFloat, forceBold: Bool = false, color: NSColor? = nil, paragraph: NSParagraphStyle,
                    extra: [NSAttributedString.Key: Any] = [:], maxImageWidth: CGFloat? = nil) -> NSMutableAttributedString {
            let s = NSMutableAttributedString()
            for run in runs {
                var rs = CGFloat(run.fontSize ?? Double(size))
                if run.baseline != .normal { rs = (rs * 0.68 * 2).rounded() / 2 }
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
                if let link = run.link, let url = LinkPolicy.openableURL(link) {
                    attrs[.link] = url
                    // Links look like links on paper too (TextKit only styles them inside a text view).
                    if run.color == nil { attrs[.foregroundColor] = linkColor }
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                switch run.baseline {
                case .normal: break
                case .superscript: attrs[.superscript] = 1
                case .subscript: attrs[.superscript] = -1
                }
                if style.paged, let id = run.noteID, let note = notesByID[id], note.kind == .footnote {
                    attrs[.ensoFootnote] = noteText(note)
                    attrs[.ensoNoteID] = id
                }
                for (k, v) in extra { attrs[k] = v }
                if let img = run.image, let att = attachment(img, maxWidth: maxImageWidth ?? style.contentWidth) {
                    let a = NSMutableAttributedString(attachment: att)
                    a.addAttributes(attrs, range: NSRange(location: 0, length: a.length))
                    s.append(a)
                    continue
                }
                var text = run.text
                if let r = run.ruby, !r.isEmpty { text += "（\(r)）" }
                s.append(NSAttributedString(string: text, attributes: attrs))
            }
            return s
        }

        func append(runs: [DocRun], size: CGFloat, forceBold: Bool = false, color: NSColor? = nil, paragraph: NSParagraphStyle,
                    extra: [NSAttributedString.Key: Any] = [:], maxImageWidth: CGFloat? = nil) {
            let start = out.length
            out.append(styled(runs, size: size, forceBold: forceBold, color: color, paragraph: paragraph, extra: extra, maxImageWidth: maxImageWidth))
            var endAttrs: [NSAttributedString.Key: Any] = [.font: base.withSize(size), .paragraphStyle: paragraph]
            for (k, v) in extra { endAttrs[k] = v }
            out.append(NSAttributedString(string: "\n", attributes: endAttrs))
            if pendingPageBreak {
                breakCount += 1
                out.addAttribute(.ensoPageBreak, value: breakCount, range: NSRange(location: start, length: out.length - start))
                pendingPageBreak = false
            }
        }

        /// A note as it is listed: the superscript mark, a space, then its paragraphs, in a smaller size.
        func noteText(_ note: DocNote) -> NSAttributedString {
            let size = (body * 0.82 * 2).rounded() / 2
            let ps = paraStyle(after: size * 0.3, lineHeight: 1.25)
            let s = NSMutableAttributedString()
            var first = [DocRun(note.label, baseline: .superscript), DocRun(" ")]
            for (i, p) in note.paragraphs.enumerated() {
                s.append(styled((i == 0 ? first : []) + p.runs, size: size, paragraph: ps, maxImageWidth: style.contentWidth / 2))
                s.append(NSAttributedString(string: "\n", attributes: [.font: base.withSize(size), .paragraphStyle: ps]))
                first = []
            }
            if note.paragraphs.isEmpty {
                s.append(styled(first, size: size, paragraph: ps))
                s.append(NSAttributedString(string: "\n", attributes: [.font: base.withSize(size), .paragraphStyle: ps]))
            }
            return s
        }

        func attachment(_ img: DocImage, maxWidth: CGFloat) -> NSTextAttachment? {
            guard let image = NSImage(data: img.data) else { return nil }
            var w = CGFloat(img.displayWidth), h = CGFloat(img.displayHeight)
            let k = min(1, max(maxWidth, 8) / max(w, 1), style.contentHeight * 0.9 / max(h, 1))
            w *= k; h *= k
            let att = NSTextAttachment()
            att.image = image
            att.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            return att
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
                // The source's marker ("(1)", "①", "第１条", "1.1") when it has one. A wide marker widens the hanging
                // indent rather than pushing the text to the next default tab stop.
                let marker = li.markerText(bullet: list.marker(forItemNumber: 1))
                let wider = max(0, (marker as NSString).size(withAttributes: [.font: base]).width - 14)
                let indent = CGFloat(li.level + 1) * 22 + wider
                ps.textLists = Array(repeating: list, count: li.level + 1)
                ps.headIndent = indent
                ps.firstLineHeadIndent = indent - 22 - wider
                ps.tabStops = [NSTextTab(textAlignment: .left, location: indent - 16 - wider), NSTextTab(textAlignment: .left, location: indent)]
                var runs = li.paragraph.runs
                runs.insert(DocRun("\t\(marker)\t"), at: 0)
                append(runs: runs, size: body, paragraph: ps)
            case .quote(let p):
                let ps = paraStyle(indent: 18)
                // A fixed grey: the page is always white, and a dynamic system colour turns near-white in Dark Mode.
                append(runs: p.runs, size: body, color: NSColor(white: 0.4, alpha: 1), paragraph: ps)
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
                // Tables that carry the source's column widths (pptx, docx, PDF) keep their proportions; the others
                // are laid out by content exactly as before.
                let widths = columnPercentages(t, columns: cols, contentWidth: style.contentWidth)
                if widths != nil { table.layoutAlgorithm = .fixedLayoutAlgorithm }
                func setWidth(_ block: NSTextTableBlock, _ col: Int, _ span: Int) {
                    guard let widths else { return }
                    let lo = min(col, cols), hi = min(col + span, cols)
                    // A merged cell also covers the padding and borders between the columns it spans.
                    let gaps = Double(max(hi - lo - 1, 0)) * cellOverheadPercent(contentWidth: style.contentWidth)
                    block.setValue(widths[lo..<hi].reduce(0, +) + gaps, type: .percentageValueType, for: .width)
                }
                // Vertically merged cells span their rows; the placeholders they cover are not drawn.
                let spans = t.verticalSpans()
                for (r, row) in t.rows.enumerated() {
                    var col = 0
                    for (i, cell) in row.enumerated() {
                        let span = max(1, cell.colSpan)
                        if spans.covered[r][i] { col += span; continue }
                        let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: spans.rowSpan[r][i], startingColumn: col, columnSpan: span)
                        block.setWidth(0.5, type: .absoluteValueType, for: .border)
                        block.setBorderColor(NSColor(white: 0.62, alpha: 1))
                        block.setWidth(4, type: .absoluteValueType, for: .padding)
                        setWidth(block, col, span)
                        if r < t.headerRows { block.backgroundColor = NSColor(white: 0.93, alpha: 1) }
                        // The cell's alignment (GFM ":---:", docx w:jc) is its first paragraph's.
                        let ps = paraStyle(cell.paragraphs.first?.alignment ?? .left, after: 0, lineHeight: 1.2)
                        ps.textBlocks = [block]
                        let runs = cell.paragraphs.enumerated().flatMap { (i, p) in (i > 0 ? [DocRun("\u{2028}")] : []) + p.runs }
                        // Pictures in a cell fit the cell's share of the width.
                        let share = widths.map { w in CGFloat(w[min(col, cols - 1)..<min(col + span, cols)].reduce(0, +)) / 100 }
                            ?? CGFloat(span) / CGFloat(cols)
                        append(runs: runs.isEmpty ? [DocRun("")] : runs, size: body * 0.95, forceBold: r < t.headerRows, paragraph: ps,
                               maxImageWidth: max(style.contentWidth * share - 10, 8))
                        col += span
                    }
                    // Pad short rows so TextKit keeps the grid.
                    while col < cols {
                        let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: col, columnSpan: 1)
                        block.setWidth(0.5, type: .absoluteValueType, for: .border)
                        block.setBorderColor(NSColor(white: 0.62, alpha: 1))
                        if widths != nil {
                            // Same padding as real cells, or the fixed widths would not line up with the rows above.
                            block.setWidth(4, type: .absoluteValueType, for: .padding)
                            setWidth(block, col, 1)
                        }
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
                    breakCount += 1
                    out.addAttribute(.ensoPageBreak, value: breakCount, range: NSRange(location: start, length: out.length - start))
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
        // Notes not set at the foot of a page: endnotes always, footnotes unless PDFRenderer places them (a footnote
        // whose mark did not survive, for instance inside a code block, is listed too). A short rule, then the notes.
        let attached = Set(attachedFootnotes(out))
        let listed = model.orderedNotes.filter { $0.kind == .endnote || !attached.contains($0.id) }
        if !listed.isEmpty {
            let block = NSTextBlock()
            block.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(NSColor(white: 0.7, alpha: 1))
            block.setValue(30, type: .percentageValueType, for: .width)
            let ps = paraStyle(before: body * 0.8, after: body * 0.6, lineHeight: 0.5)
            ps.textBlocks = [block]
            append(runs: [DocRun(" ")], size: body * 0.5, paragraph: ps)
            for note in listed { out.append(noteText(note)) }
        }
        return out
    }

    /// The ids of the footnotes riding on marks in `attr` (paged output only).
    static func attachedFootnotes(_ attr: NSAttributedString) -> [Int] {
        var ids: [Int] = []
        attr.enumerateAttribute(.ensoNoteID, in: NSRange(location: 0, length: attr.length)) { v, _, _ in
            if let id = v as? Int { ids.append(id) }
        }
        return ids
    }

    /// Each column's share of the table, as percentages of the content width, from `columnWidths`; nil when the
    /// table has none (or they do not fit its columns). Like the Word writer, only ratios are used, and every column
    /// keeps at least 40 % of an even share so a hairline column cannot squeeze its text to a character per line.
    /// The percentages leave room for the cells' padding and borders, which TextKit adds outside a block's width.
    static func columnPercentages(_ t: DocTable, columns n: Int, contentWidth: CGFloat) -> [Double]? {
        guard let w = t.columnWidths, w.count == n, n > 0, w.allSatisfy({ $0 > 0 && $0.isFinite }) else { return nil }
        let top = w.max() ?? 1
        var share = w.map { $0 / top }
        let minShare = 0.4 / Double(n)
        let total = share.reduce(0, +)
        share = share.map { max(minShare, $0 / total) }
        let sum = share.reduce(0, +)
        let usable = max(100 - Double(n) * cellOverheadPercent(contentWidth: contentWidth), 50)
        return share.map { $0 / sum * usable }
    }

    /// A cell's 4 pt padding on each side plus its 0.5 pt borders, as a percentage of the content width.
    static func cellOverheadPercent(contentWidth: CGFloat) -> Double { 9 / Double(max(contentWidth, 100)) * 100 }

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
            // A cell spanning rows has no blocks in the rows it covers: put empty placeholders there, as DocModel wants.
            for (r, cells) in tableRows {
                for (c, cell) in cells where cell.rowSpan > 1 {
                    for k in 1..<min(cell.rowSpan, 10_000) where tableRows[r + k] != nil && tableRows[r + k]?[c] == nil {
                        tableRows[r + k]?[c] = DocTableCell([], colSpan: cell.colSpan)
                    }
                }
            }
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
                let p = paragraph(attr, contentRange, body: body, alignment: ps?.alignment, images: true)
                var cell = tableRows[tb.startingRow, default: [:]][tb.startingColumn] ?? DocTableCell([], colSpan: tb.columnSpan, rowSpan: max(tb.rowSpan, 1))
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
                var found: String?
                if let m = text.range(of: #"^\t?[^\t]{0,8}\t"#, options: .regularExpression) {
                    let marker = text[m].trimmingCharacters(in: .whitespaces)
                    found = marker
                    number = Int(marker.trimmingCharacters(in: CharacterSet(charactersIn: ".)").union(.whitespaces)))
                    text.removeSubrange(m)
                    p = stripPrefix(p, count: text.count)
                }
                let ordered = ![NSTextList.MarkerFormat.disc, .circle, .square, .hyphen, .box, .check, .diamond].contains(list.markerFormat)
                // Keep a marker that is not the plain "1." or a round bullet ("(1)", "①", "Ⅱ.", "➢").
                var marker: String?
                if let m = found, !m.isEmpty, !(ordered && m.range(of: #"^[0-9]+\.$"#, options: .regularExpression) != nil),
                   !["•", "◦", "▪", "-", "–", "·", "●", "○"].contains(m) {
                    marker = m
                }
                model.blocks.append(.listItem(DocListItem(ordered: ordered, level: lists.count - 1, number: ordered ? number : nil, paragraph: p, marker: marker)))
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

    /// `images`: attachments become inline picture runs (table cells); otherwise the caller makes them image blocks.
    static func paragraph(_ attr: NSAttributedString, _ range: NSRange, body: CGFloat, alignment: NSTextAlignment?, images: Bool = false) -> DocParagraph {
        var runs: [DocRun] = []
        attr.enumerateAttributes(in: range) { attrs, r, _ in
            var text = (attr.string as NSString).substring(with: r)
            text = text.replacingOccurrences(of: "\u{2028}", with: "\n")
            if images, let att = attrs[.attachment] as? NSTextAttachment, let img = docImage(att) {
                runs.append(DocRun("", image: img))
                text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
                if text.isEmpty { return }
            }
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
                // The link blue added above is presentation, not the text's colour.
                if !dc.isNearlyBlack, !(attrs[.link] != nil && dc.hex == "0563C1") { run.color = dc }
            }
            if let c = (attrs[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB), c.alphaComponent > 0.2,
               !(c.redComponent > 0.97 && c.greenComponent > 0.97 && c.blueComponent > 0.97), !run.code {
                run.highlight = DocColor(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
            }
            if let l = attrs[.link] { run.link = (l as? URL)?.absoluteString ?? (l as? String) }
            // Superscript / subscript: Cocoa's attribute (RTF \\super, \\sub), or a raised smaller run (RTF \\up, \\dn).
            let sup = (attrs[.superscript] as? NSNumber)?.intValue ?? 0
            let offset = (attrs[.baselineOffset] as? NSNumber)?.doubleValue ?? 0
            let smaller = (attrs[.font] as? NSFont).map { $0.pointSize < body - 0.5 } ?? false
            if sup > 0 || (offset > 0.5 && smaller) { run.baseline = .superscript } else if sup < 0 || (offset < -0.5 && smaller) { run.baseline = .subscript }
            // The smaller size is how a script is drawn, not a size of its own.
            if run.baseline != .normal, smaller { run.fontSize = nil }
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
