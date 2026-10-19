import Foundation

// MARK: - Writer

public enum MarkdownWriter {

    public static func string(from model: DocModel, imageDirectoryName: String? = nil) -> (text: String, images: [(name: String, data: Data)]) {
        var out: [String] = []
        var images: [(String, Data)] = []
        var lastWasList = false
        var orderedCounters: [Int: Int] = [:]

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
                if li.ordered {
                    let n = li.number ?? ((orderedCounters[li.level] ?? 0) + 1)
                    orderedCounters[li.level] = n
                    marker = "\(n)."
                }
                // Deeper counters restart when we go back up.
                for k in orderedCounters.keys where k > li.level { orderedCounters[k] = nil }
                push(indent + marker + " " + escapeLineStarts(inline(li.paragraph.runs).replacingOccurrences(of: "\n", with: " ")), list: true)
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
                push(table(t))
            case .image(let img):
                orderedCounters = [:]
                let name = String(format: "image-%03d.%@", images.count + 1, img.format.fileExtension)
                images.append((name, img.data))
                let path = imageDirectoryName.map { "\($0)/\(name)" } ?? name
                // Alt text comes from the document: one line, with Markdown punctuation escaped, so it cannot start a block.
                let alt = escape(oneLine(img.altText ?? ""))
                push("![\(alt)](\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path))")
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
        return (out.joined(separator: "\n") + "\n", images)
    }

    static func table(_ t: DocTable) -> String {
        let cols = max(1, t.columnCount)
        var rows: [[String]] = t.rows.map { row in
            var cells: [String] = []
            for c in row {
                cells.append(escapeCell(c.paragraphs.map { inline($0.runs, inTable: true) }.joined(separator: "<br>")))
                for _ in 1..<max(1, c.colSpan) { cells.append("") }
            }
            while cells.count < cols { cells.append("") }
            return cells
        }
        if rows.isEmpty { return "" }
        let header = rows.removeFirst()
        var lines = ["| " + header.joined(separator: " | ") + " |",
                     "|" + Array(repeating: " --- ", count: cols).joined(separator: "|") + "|"]
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

    public static func inline(_ runs: [DocRun], inTable: Bool = false) -> String {
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
    /// `baseURL` resolves relative image paths.
    public static func model(from markdown: String, baseURL: URL? = nil) -> DocModel {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attr = try? AttributedString(markdown: markdown, options: options, baseURL: baseURL) else {
            return PlainTextReader.model(from: markdown)
        }

        var model = DocModel()
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

        func flushCell() {
            guard cellID != nil else { return }
            if tableRows.isEmpty { cellRuns = []; cellID = nil; return }
            // Place the cell by its column index so a missing or empty cell doesn't shift the rest of the row.
            var row = tableRows[tableRows.count - 1]
            while row.count < cellColumn { row.append(DocTableCell([DocParagraph([]).normalized()])) }
            if row.count == cellColumn { row.append(DocTableCell([DocParagraph(cellRuns).normalized()])) }
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
                    model.blocks.append(.listItem(DocListItem(ordered: ordered, level: listDepth - 1, number: ordered ? ordinal : nil, paragraph: para)))
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
                    if case .table(let cols) = tbl.kind { tableColumns = cols.count }
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
                cellRuns.append(docRun)
                continue
            } else if tableID != nil {
                flushTable()
            }

            let key = intent?.components.first?.identity
            if key != currentKey { flushBlock(); currentKey = key; currentKind = intent }
            currentRuns.append(docRun)
        }
        flushBlock()
        flushTable()
        if case .heading(_, let p)? = model.blocks.first { model.title = p.plainText }
        return model
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

    /// Decodes text files that may be UTF-8, UTF-16 (BOM) or Shift_JIS.
    public static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) ?? "" }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .shiftJIS) { return s }
        if let s = String(data: data, encoding: .japaneseEUC) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum PlainTextWriter {
    public static func string(from model: DocModel) -> String { model.plainText + "\n" }
}
