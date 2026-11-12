import Foundation

// MARK: - Writer

public enum MarkdownWriter {

    /// Markdown has no ruby, sub/superscript or list marker syntax, so: super/subscripts are written as inline
    /// <sup>…</sup> / <sub>…</sub> (GFM shows them, MaruDoc reads them back); ruby as base（reading）; footnotes and
    /// endnotes as GFM footnotes [^1] with the definitions at the end (endnotes keep their own labels, "i", "ii", and
    /// get an "e" in front only if a footnote already uses the label); a list item whose source marker is not plain
    /// "1." or "1)" ("(1)", "①", "第１条") becomes "- (1) text", keeping the list and the visible marker.
    public static func string(from model: DocModel, imageDirectoryName: String? = nil) -> (text: String, images: [(name: String, data: Data)]) {
        var out: [String] = []
        var images: [(String, Data)] = []
        var lastWasList = false
        var orderedCounters: [Int: Int] = [:]
        let labels = noteLabels(model)
        func addImage(_ img: DocImage) -> String {
            let name = String(format: "image-%03d.%@", images.count + 1, img.format.fileExtension)
            images.append((name, img.data))
            let path = imageDirectoryName.map { "\($0)/\(name)" } ?? name
            return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        }
        func inline(_ runs: [DocRun], inTable: Bool = false) -> String {
            MarkdownWriter.inline(runs, inTable: inTable, noteLabels: labels, image: addImage)
        }

        func push(_ block: String, list: Bool = false) {
            if !(list && lastWasList), !out.isEmpty { out.append("") }
            out.append(block)
            lastWasList = list
        }

        for block in model.blocks {
            switch block {
            case .heading(let level, let p):
                orderedCounters = [:]
                // Headings are bold already; "**" inside them is noise.
                let runs = p.runs.map { r -> DocRun in var r = r; r.bold = false; return r }
                push(String(repeating: "#", count: max(1, min(6, level))) + " " + inline(runs).replacingOccurrences(of: "\n", with: " "))
            case .paragraph(let p):
                orderedCounters = [:]
                var text = inline(p.runs)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                // Every line (hard breaks start new ones) is checked for "#", "-", "+" and "1." openers.
                text = escapeLineStarts(text)
                push(text.replacingOccurrences(of: "\n", with: "  \n"))
            case .listItem(let li):
                let indent = String(repeating: "    ", count: li.level)
                var marker = "-"
                var text = escapeLineStarts(inline(li.paragraph.runs).replacingOccurrences(of: "\n", with: " "))
                if li.ordered {
                    let n = li.number ?? ((orderedCounters[li.level] ?? 0) + 1)
                    orderedCounters[li.level] = n
                    marker = "\(n)."
                }
                if let m = li.marker {
                    // "1)" is CommonMark and ☐ / ☑ are GFM task items; any other source marker is kept as text in a
                    // bullet item.
                    if li.ordered, let n = li.number, m == "\(n))" { marker = m } else if !li.ordered, m == "☐" || m == "☑" {
                        text = (m == "☑" ? "[x] " : "[ ] ") + text
                    } else {
                        marker = "-"
                        if !m.isEmpty { text = escape(oneLine(m)) + " " + text }
                    }
                }
                // Deeper counters restart when we go back up.
                for k in orderedCounters.keys where k > li.level { orderedCounters[k] = nil }
                push(indent + marker + " " + text, list: true)
            case .quote(let p):
                orderedCounters = [:]
                push(escapeLineStarts(inline(p.runs)).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n"))
            case .code(let s, let lang):
                orderedCounters = [:]
                // The fence must be longer than any backtick run inside, so the content can never close it early.
                let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: s) + 1))
                let info = (lang ?? "").filter { $0 != "`" && !$0.isNewline }
                push(fence + info + "\n" + s + "\n" + fence)
            case .table(let t):
                orderedCounters = [:]
                push(table(t, cell: { inline($0, inTable: true) }))
            case .image(let img):
                orderedCounters = [:]
                // Alt text comes from the document: one line, with Markdown punctuation escaped, so it cannot start a block.
                let alt = escape(oneLine(img.altText ?? ""))
                push("![\(alt)](\(addImage(img)))")
            case .pageBreak:
                orderedCounters = [:]
                push("---")
            case .horizontalRule:
                orderedCounters = [:]
                push("---")
            }
        }
        // Collapse "---" at the very end.
        while out.last == "---" || out.last == "" { out.removeLast() }
        // Note definitions: footnotes, then endnotes; further paragraphs of a note are indented to stay in it.
        for n in model.orderedNotes {
            let paras = n.paragraphs.map { escapeLineStarts(inline($0.runs)).replacingOccurrences(of: "\n", with: "  \n    ") }
            out.append("")
            out.append("[^\(labels[n.id] ?? n.label)]: " + (paras.first ?? "") + paras.dropFirst().map { "\n\n    " + $0 }.joined())
        }
        return (out.joined(separator: "\n") + "\n", images)
    }

    /// Footnote labels for [^…]: the note's own label, with spaces and brackets removed; an endnote whose label a
    /// footnote already uses gets an "e" in front.
    static func noteLabels(_ model: DocModel) -> [Int: String] {
        var labels: [Int: String] = [:], used = Set<String>()
        for n in model.orderedNotes {
            var l = n.label.filter { !$0.isWhitespace && !"[]^\\".contains($0) }
            if l.isEmpty { l = String(n.id) }
            if used.contains(l) { l = (n.kind == .endnote ? "e" : "f") + l }
            while used.contains(l) { l += "-\(n.id)" }
            used.insert(l)
            labels[n.id] = l
        }
        return labels
    }

    static func table(_ t: DocTable, cell: ([DocRun]) -> String = { inline($0, inTable: true) }) -> String {
        let cols = max(1, t.columnCount)
        var rows: [[String]] = t.rows.map { row in
            var cells: [String] = []
            for c in row {
                cells.append(escapeCell(c.paragraphs.map { cell($0.runs) }.joined(separator: "<br>")))
                for _ in 1..<max(1, c.colSpan) { cells.append("") }
            }
            while cells.count < cols { cells.append("") }
            return cells
        }
        if rows.isEmpty { return "" }
        let header = rows.removeFirst()
        // A column whose cells (after the header) are all centred or right-aligned gets GFM's ":---:" / "---:".
        var aligns = Array(repeating: " --- ", count: cols)
        for col in 0..<cols {
            var seen = Set<DocAlignment>()
            for row in t.rows.dropFirst() {
                var c = 0
                for cell in row {
                    if c == col, !cell.paragraphs.allSatisfy(\.isEmpty) { seen.insert(cell.paragraphs.first?.alignment ?? .left) }
                    c += max(1, cell.colSpan)
                }
            }
            if seen == [.center] { aligns[col] = " :---: " } else if seen == [.right] { aligns[col] = " ---: " }
        }
        var lines = ["| " + header.joined(separator: " | ") + " |",
                     "|" + aligns.joined(separator: "|") + "|"]
        lines += rows.map { "| " + $0.joined(separator: " | ") + " |" }
        return lines.joined(separator: "\n")
    }

    /// Each line terminator becomes one space; other spaces are kept as they are.
    static func oneLineKeepingSpaces(_ s: String) -> String {
        unifyBreaks(s).replacingOccurrences(of: "\n", with: " ")
    }

    static func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
    }

    static func longestRun(of ch: Character, in s: String) -> Int {
        var best = 0, cur = 0
        for c in s { if c == ch { cur += 1; best = max(best, cur) } else { cur = 0 } }
        return best
    }

    /// Link destination as `<...>` with the characters that could end it early percent-encoded; nil for unsafe schemes.
    static func destination(_ link: String) -> String? {
        guard let safe = HTMLWriter.safeHref(link) else { return nil }
        var out = ""
        for u in safe.unicodeScalars {
            switch u {
            case "<", ">", "\\", "\n", "\r", " ": out += String(format: "%%%02X", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return "<\(out)>"
    }

    /// Backslash-escapes characters that would start Markdown syntax. `|` is left for `escapeCell` inside tables.
    /// `~` is always escaped; `&` only where it would read as an entity; `!` only before a link (`![x](y)` would be an image).
    static func escape(_ s: String, inTable: Bool = false, beforeLink: Bool = false) -> String {
        var r = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            var esc = "\\`*_[]<>~".contains(ch) || (ch == "|" && !inTable)
            if ch == "!" { esc = i == chars.count - 1 && beforeLink }
            if ch == "&" { esc = isEntity(chars, at: i) }
            if esc { r.append("\\") }
            r.append(ch)
        }
        return r
    }

    /// `&name;`, `&#123;` or `&#x1F;` starting at `i`.
    private static func isEntity(_ c: [Character], at i: Int) -> Bool {
        var j = i + 1
        guard j < c.count else { return false }
        if c[j] == "#" {
            j += 1
            let hex = j < c.count && (c[j] == "x" || c[j] == "X")
            if hex { j += 1 }
            let start = j
            while j < c.count, hex ? c[j].isHexDigit : (c[j].isASCII && c[j].isNumber) { j += 1 }
            return j > start && j < c.count && c[j] == ";"
        }
        let start = j
        while j < c.count, c[j].isASCII, c[j].isLetter || c[j].isNumber { j += 1 }
        return j > start && j < c.count && c[j] == ";"
    }

    /// A line starting with "#", "-", "+" or "1." (after up to three spaces) would become a heading, list or rule.
    /// ">" is already escaped by `escape`. Applied to every line, not only the first.
    static func escapeLineStarts(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let body = line.drop(while: { $0 == " " })
            let lead = line.prefix(line.count - body.count)
            guard let first = body.first else { return line }
            if "#+-".contains(first) { return String(lead) + "\\" + body }
            if first.isASCII, first.isNumber {
                let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
                let rest = body.dropFirst(digits.count)
                if let d = rest.first, d == "." || d == ")", rest.count == 1 || rest.dropFirst().first == " " {
                    return String(lead) + digits + "\\" + rest
                }
            }
            return line
        }.joined(separator: "\n")
    }

    /// Line terminators other than "\n" (CR, NEL, VT, FF, U+2028, U+2029) end a line in Markdown too.
    private static func isBreakScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// Every kind of line terminator becomes a single "\n" (CRLF counts once).
    static func unifyBreaks(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var previousCR = false
        for u in s.unicodeScalars {
            if isBreakScalar(u) {
                if !(u.value == 0x0A && previousCR) { out.append("\n") }
                previousCR = u.value == 0x0D
            } else {
                out.append(u); previousCR = false
            }
        }
        return String(out)
    }

    /// Line terminators and runs of whitespace around them become one space, for text that must stay on one line.
    static func oneLine(_ s: String) -> String {
        unifyBreaks(s).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `noteLabels` maps note ids to their [^label]; `image` stores an inline picture and returns its path (without it
    /// a picture is written as its alt text).
    public static func inline(_ runs: [DocRun], inTable: Bool = false, noteLabels: [Int: String] = [:],
                              image: ((DocImage) -> String)? = nil) -> String {
        var s = ""
        // Code spans are written on one line: a line break inside backticks would start the next line at column 0,
        // where "<script" opens an HTML block. Other text keeps its breaks as plain "\n".
        let cleaned = runs.map { r -> DocRun in
            var r = r
            r.text = r.code ? oneLineKeepingSpaces(r.text) : unifyBreaks(r.text)
            return r
        }
        let normalized = DocParagraph(cleaned).normalized().runs
        for (index, run) in normalized.enumerated() {
            if let id = run.noteID {
                s += "[^\(noteLabels[id] ?? run.text.filter { !$0.isWhitespace && !"[]^\\".contains($0) })]"
                continue
            }
            if let img = run.image {
                let alt = escape(oneLine(run.text), inTable: inTable)
                s += image.map { "![\(alt)](\($0(img)))" } ?? alt
                continue
            }
            if run.code {
                // CommonMark: the delimiter is one backtick longer than the longest run inside; edge backticks need a space.
                let tick = String(repeating: "`", count: longestRun(of: "`", in: run.text) + 1)
                let pad = run.text.hasPrefix("`") || run.text.hasSuffix("`") ? " " : ""
                s += tick + pad + run.text + pad + tick
                continue
            }
            // Keep surrounding whitespace outside the emphasis markers, otherwise Markdown ignores them.
            let core = run.text.trimmingCharacters(in: .whitespaces)
            if core.isEmpty { s += run.text; continue }
            let lead = String(run.text.prefix(while: { $0 == " " }))
            let trail = String(run.text.reversed().prefix(while: { $0 == " " }))
            let nextIsLink = index + 1 < normalized.count && !normalized[index + 1].code && normalized[index + 1].link != nil
            var t = escape(core, inTable: inTable, beforeLink: nextIsLink)
            if let r = run.ruby, !r.isEmpty { t += "（" + escape(r, inTable: inTable) + "）" }
            switch run.baseline {
            case .normal: break
            case .superscript: t = "<sup>\(t)</sup>"
            case .subscript: t = "<sub>\(t)</sub>"
            }
            if run.strikethrough { t = "~~\(t)~~" }
            if run.bold && run.italic { t = "***\(t)***" } else if run.bold { t = "**\(t)**" } else if run.italic { t = "*\(t)*" }
            if let link = run.link, let dest = destination(link) { t = "[\(t)](\(dest))" }
            s += lead + t + trail
        }
        return s
    }
}

// MARK: - Reader

public enum MarkdownReader {

    /// Parses CommonMark + GFM tables with Apple's parser and maps presentation intents to DocModel blocks.
    /// `baseURL` resolves relative image paths. Apple's parser leaves HTML to the caller: HTML blocks are read with
    /// HTMLReader (their text and structure, never anything remote), and the common inline tags are applied
    /// (<br>, <sup>, <sub>, <kbd>, <u>, <mark>, <s>, <b>, <i>, <a href>) or dropped keeping their text (<span> and others).
    /// YAML / TOML front matter is metadata: its `title` becomes the document title and it is not shown as text.
    public static func model(from markdown: String, baseURL: URL? = nil) -> DocModel {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        let (afterFront, frontTitle) = frontMatter(markdown)
        let (markdown, definitions) = footnoteDefinitions(afterFront)
        guard let attr = try? AttributedString(markdown: markdown, options: options, baseURL: baseURL) else {
            var plain = PlainTextReader.model(from: markdown)
            if let frontTitle { plain.title = frontTitle }
            return plain
        }

        var model = DocModel()
        var html = InlineHTML()
        var htmlBlock = ""
        func flushHTMLBlock() {
            guard !htmlBlock.isEmpty else { return }
            if let m = try? HTMLReader.model(from: Data(htmlBlock.utf8), baseURL: baseURL) { model.blocks += m.blocks }
            htmlBlock = ""
        }
        // Current block being assembled.
        var currentKey: Int? = nil
        var currentRuns: [DocRun] = []
        var currentKind: PresentationIntent? = nil
        // Table assembly
        var tableID: Int? = nil
        var tableRows: [[DocTableCell]] = []
        var tableHeaderRows = 0
        var rowID: Int? = nil
        var cellID: Int? = nil
        var cellRuns: [DocRun] = []
        var cellColumn = 0
        var tableColumns = 0
        var tableAlignments: [DocAlignment] = []

        func flushCell() {
            html = InlineHTML()
            guard cellID != nil else { return }
            if tableRows.isEmpty { cellRuns = []; cellID = nil; return }
            // Place the cell by its column index so a missing or empty cell doesn't shift the rest of the row.
            var row = tableRows[tableRows.count - 1]
            while row.count < cellColumn { row.append(DocTableCell([DocParagraph([]).normalized()])) }
            // GFM column alignment (":---:", "---:") becomes the cell's paragraph alignment.
            let align = cellColumn < tableAlignments.count ? tableAlignments[cellColumn] : .left
            if row.count == cellColumn { row.append(DocTableCell([DocParagraph(cellRuns, alignment: align).normalized()])) }
            tableRows[tableRows.count - 1] = row
            cellRuns = []; cellID = nil
        }
        func flushTable() {
            flushCell()
            // Pad every row to the header's column count.
            let cols = max(tableColumns, tableRows.map(\.count).max() ?? 0)
            for i in tableRows.indices { while tableRows[i].count < cols { tableRows[i].append(DocTableCell([DocParagraph([]).normalized()])) } }
            if !tableRows.isEmpty { model.blocks.append(.table(DocTable(rows: tableRows, headerRows: tableHeaderRows))) }
            tableRows = []; tableHeaderRows = 0; tableID = nil; rowID = nil; tableColumns = 0
        }
        func flushBlock() {
            html = InlineHTML()
            guard let intent = currentKind else { currentRuns = []; return }
            let para = DocParagraph(currentRuns).normalized()
            var kindHandled = false
            var listDepth = 0
            var ordered = false
            var ordinal: Int? = nil
            var inQuote = false
            for comp in intent.components {
                switch comp.kind {
                case .listItem(let o): if ordinal == nil { ordinal = o }
                case .orderedList: if listDepth == 0 { ordered = true }; listDepth += 1
                case .unorderedList: listDepth += 1
                case .blockQuote: inQuote = true
                default: break
                }
            }
            if let first = intent.components.first {
                switch first.kind {
                case .header(let level):
                    model.blocks.append(.heading(level: level, para)); kindHandled = true
                case .codeBlock(let lang):
                    var text = para.plainText
                    if text.hasSuffix("\n") { text.removeLast() }
                    model.blocks.append(.code(text, language: lang)); kindHandled = true
                case .thematicBreak:
                    model.blocks.append(.horizontalRule); kindHandled = true
                default: break
                }
            }
            if !kindHandled {
                if listDepth > 0 {
                    // GFM task items: "[ ]" / "[x]" at the start become the item's marker ☐ / ☑.
                    var item = DocListItem(ordered: ordered, level: listDepth - 1, number: ordered ? ordinal : nil, paragraph: para)
                    if let first = para.runs.first, !first.code, first.text.count >= 3 {
                        let head = first.text.prefix(4)
                        let mark: String? = head.hasPrefix("[ ]") ? "☐" : (head.hasPrefix("[x]") || head.hasPrefix("[X]")) ? "☑" : nil
                        if let mark, head.count == 3 || head.last == " " {
                            item.marker = mark
                            item.paragraph.runs[0].text = String(first.text.dropFirst(head.count))
                            item.paragraph = item.paragraph.normalized()
                        }
                    }
                    model.blocks.append(.listItem(item))
                } else if inQuote {
                    model.blocks.append(.quote(para))
                } else if !para.isEmpty {
                    model.blocks.append(.paragraph(para))
                }
            }
            currentRuns = []; currentKind = nil; currentKey = nil
        }

        for run in attr.runs {
            let text = String(attr[run.range].characters)
            let intent = run.presentationIntent
            var docRun = DocRun(text)
            if let inline = run.inlinePresentationIntent {
                docRun.bold = inline.contains(.stronglyEmphasized)
                docRun.italic = inline.contains(.emphasized)
                docRun.code = inline.contains(.code)
                docRun.strikethrough = inline.contains(.strikethrough)
                if inline.contains(.lineBreak) { docRun.text = "\n" }
                if inline.contains(.softBreak) { docRun.text = " " }
            }
            // Same rule as HTMLWriter: relative paths and #fragments survive, schemed links only for http, https and mailto (the text stays otherwise).
            if let link = run.link, LinkPolicy.isSafeHref(link.relativeString) { docRun.link = link.relativeString }
            let isTag = run.inlinePresentationIntent?.contains(.inlineHTML) ?? false

            // HTML blocks: collected while consecutive, then read as HTML.
            if run.inlinePresentationIntent?.contains(.blockHTML) ?? false {
                flushBlock()
                if tableID != nil { flushTable() }
                htmlBlock += text
                continue
            }
            flushHTMLBlock()

            // Images become their own block.
            if let imageURL = run.imageURL {
                flushBlock()
                // Same rules as HTML: only a regular file (<= 100 MB) inside the Markdown file's folder, symlinks resolved.
                // The source text is used, not the parser's resolved URL, so ../ and file:// are judged as written.
                // The file is opened once and the opened descriptor is checked (HTMLReader.readLocalImage).
                if let base = baseURL, let data = HTMLReader.readLocalImage(imageURL.relativeString, base: base),
                   let cg = ImageCodec.decode(data),
                   var img = ImageCodec.docImage(from: cg) {
                    img.altText = text
                    model.blocks.append(.image(img))
                }
                continue
            }

            // Table cells
            if let intent, let tbl = intent.components.first(where: { if case .table = $0.kind { return true }; return false }) {
                if tableID != tbl.identity {
                    flushBlock(); flushTable(); tableID = tbl.identity
                    if case .table(let cols) = tbl.kind {
                        tableColumns = cols.count
                        tableAlignments = cols.map { c -> DocAlignment in
                            switch c.alignment { case .center: return .center; case .right: return .right; default: return .left }
                        }
                    }
                }
                // Components run innermost-first; handle row before cell.
                for comp in intent.components.reversed() {
                    switch comp.kind {
                    case .tableHeaderRow:
                        if rowID != comp.identity { flushCell(); rowID = comp.identity; tableRows.append([]); tableHeaderRows = 1 }
                    case .tableRow:
                        if rowID != comp.identity { flushCell(); rowID = comp.identity; tableRows.append([]) }
                    case .tableCell(let col):
                        if cellID != comp.identity { flushCell(); cellID = comp.identity; cellColumn = col }
                    default: break
                    }
                }
                if html.apply(&docRun, isTag: isTag) { cellRuns.append(docRun) }
                continue
            } else if tableID != nil {
                flushTable()
            }

            let key = intent?.components.first?.identity
            if key != currentKey { flushBlock(); currentKey = key; currentKind = intent }
            if html.apply(&docRun, isTag: isTag) { currentRuns.append(docRun) }
        }
        flushBlock()
        flushTable()
        flushHTMLBlock()
        if !definitions.isEmpty { linkFootnotes(&model, definitions, baseURL: baseURL) }
        if let frontTitle { model.title = frontTitle } else if case .heading(_, let p)? = model.blocks.first { model.title = p.plainText }
        return model
    }

    /// GFM footnote definitions ("[^label]: text", continued by indented lines), outside fenced code. Returns the
    /// source without them and the definitions in order.
    static func footnoteDefinitions(_ s: String) -> (String, [(label: String, text: String)]) {
        guard s.contains("[^") else { return (s, []) }
        var kept: [Substring] = [], defs: [(String, String)] = []
        var fence: String?
        var current: (label: String, lines: [String])?
        func close() { if let c = current { defs.append((c.label, c.lines.joined(separator: "\n"))) }; current = nil }
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.drop(while: { $0 == " " })
            if let f = fence {
                if t.hasPrefix(f) { fence = nil }
                kept.append(line); continue
            }
            if current != nil {
                if line.hasPrefix("    ") || line.hasPrefix("\t") { current!.lines.append(String(line.drop(while: { $0 == " " || $0 == "\t" }))); continue }
                if t.isEmpty { current!.lines.append(""); continue }
                close()
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); kept.append(line); continue }
            if line.count - t.count <= 3, t.hasPrefix("[^"), let end = t.firstIndex(of: "]"), t[t.index(after: end)...].hasPrefix(":") {
                let label = String(t[t.index(t.startIndex, offsetBy: 2)..<end])
                if !label.isEmpty, !label.contains(where: { $0.isWhitespace }) {
                    current = (label, [String(t[t.index(end, offsetBy: 2)...].drop(while: { $0 == " " || $0 == "\t" }))])
                    continue
                }
            }
            kept.append(line)
        }
        close()
        while let last = defs.last?.1, last.hasSuffix("\n") { defs[defs.count - 1].1.removeLast() }
        return (kept.joined(separator: "\n"), defs)
    }

    /// Turns "[^label]" in text into note marks numbered in order of first use (as GFM shows them), with the
    /// definition as the note. Definitions nothing refers to are kept as paragraphs at the end.
    static func linkFootnotes(_ model: inout DocModel, _ defs: [(label: String, text: String)], baseURL: URL?) {
        var byLabel: [String: String] = [:]
        for d in defs where byLabel[d.label] == nil { byLabel[d.label] = d.text }
        var ids: [String: Int] = [:]
        func mark(_ p: DocParagraph) -> DocParagraph {
            var out: [DocRun] = []
            for run in p.runs {
                guard !run.code, run.image == nil, run.noteID == nil, run.text.contains("[^") else { out.append(run); continue }
                var rest = Substring(run.text)
                while let open = rest.range(of: "[^"), let close = rest[open.upperBound...].firstIndex(of: "]") {
                    let label = String(rest[open.upperBound..<close])
                    guard let text = byLabel[label] else {
                        var r = run; r.text = String(rest[..<rest.index(after: close)]); out.append(r)
                        rest = rest[rest.index(after: close)...]; continue
                    }
                    if open.lowerBound > rest.startIndex { var r = run; r.text = String(rest[..<open.lowerBound]); out.append(r) }
                    let id: Int
                    if let known = ids[label] { id = known } else {
                        id = model.notes.count + 1
                        ids[label] = id
                        let note = MarkdownReader.model(from: text, baseURL: baseURL)
                        let paras = note.blocks.compactMap { b -> DocParagraph? in
                            switch b {
                            case .paragraph(let q), .heading(_, let q), .quote(let q): return q
                            case .listItem(let li): return li.paragraph
                            case .code(let c, _): return DocParagraph([DocRun(c, code: true)])
                            default: return nil
                            }
                        }
                        model.notes.append(DocNote(id: id, kind: .footnote, label: String(model.notes.count + 1), paragraphs: paras))
                    }
                    var m = run
                    m.text = model.notes.first(where: { $0.id == id })?.label ?? label
                    m.noteID = id; m.baseline = .superscript; m.link = nil
                    out.append(m)
                    rest = rest[rest.index(after: close)...]
                }
                if !rest.isEmpty { var r = run; r.text = String(rest); out.append(r) }
            }
            var q = p; q.runs = out; return q
        }
        model.blocks = model.blocks.map { b in
            switch b {
            case .paragraph(let p): return .paragraph(mark(p))
            case .heading(let l, let p): return .heading(level: l, mark(p))
            case .quote(let p): return .quote(mark(p))
            case .listItem(var li): li.paragraph = mark(li.paragraph); return .listItem(li)
            case .table(var t): t.rows = t.rows.map { $0.map { var c = $0; c.paragraphs = c.paragraphs.map(mark); return c } }; return .table(t)
            default: return b
            }
        }
        for d in defs where ids[d.label] == nil { model.blocks.append(.paragraph(DocParagraph(text: "[^\(d.label)]: " + d.text))) }
    }

    /// YAML ("---") or TOML ("+++") front matter on the very first line (Jekyll, Hugo, Obsidian): every line up to the
    /// closing fence must be a key, a list item, an indented continuation or a comment, else it is ordinary Markdown.
    /// Returns the text after it and the `title` value.
    static func frontMatter(_ s: String) -> (body: String, title: String?) {
        var text = Substring(s)
        if text.hasPrefix("\u{FEFF}") { text = text.dropFirst() }
        let lines = text.split(separator: "\n", maxSplits: 2000, omittingEmptySubsequences: false)
        func trimmed(_ l: Substring) -> String { l.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r"))) }
        guard let first = lines.first.map(trimmed), first == "---" || first == "+++" else { return (s, nil) }
        let yaml = first == "---"
        var title: String?
        var sawKey = false
        for i in 1..<min(lines.count, 1000) {
            let t = trimmed(lines[i])
            if t == first || (yaml && t == "...") {
                guard sawKey else { return (s, nil) }
                return (lines.count > i + 1 ? lines[(i + 1)...].joined(separator: "\n") : "", title)
            }
            let raw = lines[i]
            if t.isEmpty || t.hasPrefix("#") || raw.hasPrefix(" ") || raw.hasPrefix("\t") || t == "-" || t.hasPrefix("- ") { continue }
            if !yaml, t.hasPrefix("["), t.hasSuffix("]") { continue }
            guard let sep = t.firstIndex(of: yaml ? ":" : "="),
                  t[..<sep].trimmingCharacters(in: .whitespaces).range(of: #"^[A-Za-z0-9_.\-]+$"#, options: .regularExpression) != nil else { return (s, nil) }
            sawKey = true
            if title == nil, t[..<sep].trimmingCharacters(in: .whitespaces).lowercased() == "title" {
                var v = t[t.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                if v.count >= 2, let q = v.first, (q == "\"" || q == "'"), v.last == q { v = String(v.dropFirst().dropLast()) }
                if !v.isEmpty, v != "|", v != ">" { title = v }
            }
        }
        return (s, nil)
    }
}

/// The state of inline HTML tags inside one Markdown paragraph or table cell. Apple's parser hands each tag over as a
/// run of its own (`.inlineHTML`); text runs between tags take the formatting the open tags give.
struct InlineHTML {
    var sup = 0, sub = 0, code = 0, underline = 0, mark = 0, strike = 0, bold = 0, italic = 0, skip = 0
    var links: [String?] = []

    /// Applies or updates the state for one run. Returns false when the run is consumed (a tag that is not text).
    mutating func apply(_ run: inout DocRun, isTag: Bool) -> Bool {
        guard isTag else {
            if skip > 0 { return false }
            if sup > 0 { run.baseline = .superscript } else if sub > 0 { run.baseline = .subscript }
            if code > 0 { run.code = true }
            if underline > 0 { run.underline = true }
            if mark > 0, run.highlight == nil { run.highlight = DocColor(r: 1, g: 1, b: 0) }
            if strike > 0 { run.strikethrough = true }
            if bold > 0 { run.bold = true }
            if italic > 0 { run.italic = true }
            if run.link == nil, let l = links.last(where: { $0 != nil }) ?? nil { run.link = l }
            return true
        }
        let tag = run.text
        guard let m = tag.range(of: #"^<\s*(/?)\s*([A-Za-z][A-Za-z0-9]*)"#, options: .regularExpression) else { return false } // comments, <!…>, <?…>
        let head = tag[m]
        let closing = head.contains("/")
        let name = head.drop(while: { $0 == "<" || $0 == "/" || $0.isWhitespace }).lowercased()
        let d = closing ? -1 : 1
        func bump(_ v: inout Int) { v = max(0, v + d) }
        switch name {
        case "br":
            run = DocRun("\n")
            return skip == 0
        case "sup": bump(&sup)
        case "sub": bump(&sub)
        case "kbd", "code", "samp", "tt": bump(&code)
        case "u", "ins": bump(&underline)
        case "mark": bump(&mark)
        case "s", "del", "strike": bump(&strike)
        case "b", "strong": bump(&bold)
        case "i", "em", "cite", "var": bump(&italic)
        case "rp": bump(&skip)
        case "rt":
            // Ruby readings follow their base in parentheses, as MaruDoc writes ruby to text.
            run = DocRun(closing ? "）" : "（")
            return skip == 0
        case "a":
            if closing { _ = links.popLast() } else {
                let href = HTMLAttribute.value("href", in: tag)
                links.append(href.flatMap { LinkPolicy.isSafeHref($0) ? $0 : nil })
            }
        case "img":
            // No picture is fetched from inline HTML; its alt text stays.
            if let alt = HTMLAttribute.value("alt", in: tag), !alt.isEmpty, skip == 0 { run = DocRun(alt); return true }
        default: break // <span>, <font>, <small>, … : the tag goes, its text stays
        }
        return false
    }
}

enum HTMLAttribute {
    /// The value of attribute `name` in a start tag, entity-decoded for the common entities.
    static func value(_ name: String, in tag: String) -> String? {
        let pattern = "(?i)\\s\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for g in 2...4 {
            if let r = Range(m.range(at: g), in: tag) {
                return String(tag[r]).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&amp;", with: "&")
            }
        }
        return nil
    }
}

// MARK: - Plain text

public enum PlainTextReader {
    /// Paragraphs are separated by blank lines; single newlines are kept inside the paragraph.
    public static func model(from text: String) -> DocModel {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [DocBlock] = []
        for chunk in normalized.components(separatedBy: "\u{0C}") {
            if !blocks.isEmpty { blocks.append(.pageBreak) }
            for para in chunk.components(separatedBy: "\n\n") {
                let t = para.trimmingCharacters(in: .newlines)
                if t.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                blocks.append(.paragraph(DocParagraph(text: t)))
            }
        }
        return DocModel(blocks: blocks, bodyFontSize: 11)
    }

    /// Decodes text files that may be UTF-8, UTF-16, Shift_JIS (CP932), EUC-JP or ISO-2022-JP.
    public static func decode(_ data: Data) -> String { decodeDetectingEncoding(data).text }

    /// The text, the encoding it was read with, and whether it had a byte order mark. In order:
    ///   1. a BOM (UTF-8, UTF-16 LE/BE);
    ///   2. NUL bytes, which no 8-bit Japanese text has: UTF-16 without a BOM, LE or BE by score;
    ///   3. 7-bit data with JIS escape sequences: ISO-2022-JP;
    ///   4. valid UTF-8 (other Japanese encodings practically never are);
    ///   5. Shift_JIS or EUC-JP, whichever decodes into more plausible Japanese text (kana, kanji and CJK punctuation
    ///      score; half-width punctuation and control characters, which the wrong one of the two produces, count
    ///      against); a tie stays Shift_JIS, as before.
    /// Before, the first of Shift_JIS / EUC-JP that decoded at all won, so short kana-heavy EUC-JP came out as
    /// half-width katakana.
    public static func decodeDetectingEncoding(_ data: Data) -> (text: String, encoding: String.Encoding, hadBOM: Bool) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8, true) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return (String(data: data, encoding: .utf16) ?? "", .utf16, true) }
        if data.contains(0) {
            var best: (String, String.Encoding, Int)?
            for enc in [String.Encoding.utf16BigEndian, .utf16LittleEndian] where data.count % 2 == 0 {
                if let s = String(data: data, encoding: enc) {
                    let sc = score(s)
                    if best == nil || sc > best!.2 { best = (s, enc, sc) }
                }
            }
            if let u8 = String(data: data, encoding: .utf8), best == nil || score(u8) >= best!.2 { return (u8, .utf8, false) }
            if let best { return (best.0, best.1, false) }
        }
        if data.contains(0x1B), !data.contains(where: { $0 >= 0x80 }), isoJISEscapes(data),
           let s = String(data: data, encoding: .iso2022JP) {
            return (s, .iso2022JP, false)
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8, false) }
        let sjis = String(data: data, encoding: .shiftJIS), euc = String(data: data, encoding: .japaneseEUC)
        switch (sjis, euc) {
        case let (s?, e?): return score(e) > score(s) ? (e, .japaneseEUC, false) : (s, .shiftJIS, false)
        case let (s?, nil): return (s, .shiftJIS, false)
        case let (nil, e?): return (e, .japaneseEUC, false)
        default: return (String(decoding: data, as: UTF8.self), .utf8, false)
        }
    }

    /// ESC $ B, ESC $ @, ESC $ ( D, ESC ( J, ESC ( I: the escape sequences of ISO-2022-JP.
    static func isoJISEscapes(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(1 << 20))
        for i in b.indices where b[i] == 0x1B && i + 2 < b.count {
            switch (b[i + 1], b[i + 2]) {
            case (0x24, 0x42), (0x24, 0x40), (0x24, 0x28), (0x28, 0x4A), (0x28, 0x49): return true
            default: continue
            }
        }
        return false
    }

    /// How much a decoded text looks like real (Japanese or ASCII) text. Only compared between decodings of the same
    /// bytes, on the first 200 000 characters.
    static func score(_ s: String) -> Int {
        var total = 0, n = 0
        for u in s.unicodeScalars {
            n += 1
            if n > 200_000 { break }
            let v = u.value
            switch v {
            case 0x09, 0x0A, 0x0D, 0x0C: total += 1
            case 0x00..<0x20, 0x7F: total -= 10
            case 0x20..<0x7F: total += 1
            case 0x3041...0x309F, 0x30A1...0x30FC: total += 3            // hiragana, katakana
            case 0x3000...0x303F, 0xFF01...0xFF5E: total += 2            // CJK punctuation, full-width ASCII
            case 0x4E00...0x9FFF: total += 2                             // kanji
            // EUC-JP kana read as Shift_JIS turns every A4/A5 lead byte into half-width "､" / "･": that punctuation in
            // bulk is the tell. Half-width katakana letters are ordinary in old Shift_JIS files.
            case 0xFF61...0xFF65: total -= 3
            case 0xFF66...0xFF9F: total += 1
            case 0xE000...0xF8FF, 0xFFFD: total -= 5                     // private use, replacement
            case 0x0080...0x00FF, 0x3400...0x4DBF, 0xA000...0xABFF, 0xAC00...0xD7A3, 0xF900...0xFAFF: total -= 2
            default: break
            }
        }
        return total
    }
}

public enum PlainTextWriter {
    public static func string(from model: DocModel) -> String { model.plainText + "\n" }
}
