import Foundation

/// Self-contained HTML (images inlined as data URIs) with a small, quiet stylesheet.
public enum HTMLWriter {

    public static func string(from model: DocModel) -> String {
        var body: [String] = []
        var openLists: [(ordered: Bool, level: Int)] = []

        func closeLists(to level: Int) {
            while let last = openLists.last, last.level >= level {
                body.append(last.ordered ? "</ol>" : "</ul>")
                openLists.removeLast()
            }
        }

        for block in model.blocks {
            if case .listItem = block {} else { closeLists(to: 0) }
            switch block {
            case .heading(let level, let p):
                let l = max(1, min(6, level))
                let runs = p.runs.map { r -> DocRun in var r = r; r.bold = false; return r }
                body.append("<h\(l)\(align(p))>\(inline(runs))</h\(l)>")
            case .paragraph(let p):
                body.append("<p\(align(p))>\(inline(p.runs))</p>")
            case .listItem(let li):
                if let last = openLists.last, last.level > li.level { closeLists(to: li.level + 1) }
                if let last = openLists.last, last.level == li.level, last.ordered != li.ordered { closeLists(to: li.level) }
                if openLists.last.map({ $0.level < li.level }) ?? true {
                    let start = (li.ordered && (li.number ?? 1) != 1) ? " start=\"\(li.number!)\"" : ""
                    body.append(li.ordered ? "<ol\(start)>" : "<ul>")
                    openLists.append((li.ordered, li.level))
                }
                body.append("<li>\(inline(li.paragraph.runs))</li>")
            case .quote(let p):
                body.append("<blockquote><p>\(inline(p.runs))</p></blockquote>")
            case .code(let s, let lang):
                let cls = lang.map { " class=\"language-\(escape($0))\"" } ?? ""
                body.append("<pre><code\(cls)>\(escape(s))</code></pre>")
            case .table(let t):
                var rows: [String] = []
                for (i, row) in t.rows.enumerated() {
                    let tag = i < t.headerRows ? "th" : "td"
                    let cells = row.map { c -> String in
                        let span = c.colSpan > 1 ? " colspan=\"\(c.colSpan)\"" : ""
                        return "<\(tag)\(span)>" + c.paragraphs.map { inline($0.runs) }.joined(separator: "<br>") + "</\(tag)>"
                    }.joined()
                    rows.append("<tr>\(cells)</tr>")
                }
                if t.headerRows > 0 {
                    let head = rows.prefix(t.headerRows).joined(), rest = rows.dropFirst(t.headerRows).joined()
                    body.append("<table><thead>\(head)</thead><tbody>\(rest)</tbody></table>")
                } else {
                    body.append("<table><tbody>\(rows.joined())</tbody></table>")
                }
            case .image(let img):
                let w = SafeInt.round(img.displayWidth, 0, 100_000)
                body.append("<figure><img src=\"data:\(img.format.mimeType);base64,\(img.data.base64EncodedString())\" width=\"\(w)\" alt=\"\(escape(img.altText ?? ""))\"></figure>")
            case .pageBreak:
                body.append("<div class=\"page-break\"></div>")
            case .horizontalRule:
                body.append("<hr>")
            }
        }
        closeLists(to: 0)

        let title = escape(model.title ?? "")
        let lang = Locale.preferredLanguages.first?.hasPrefix("ja") == true ? "ja" : "en"
        return """
        <!doctype html>
        <html lang="\(lang)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.75 -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Yu Gothic", "Helvetica Neue", Arial, sans-serif; max-width: 46rem; margin: 3rem auto; padding: 0 1.25rem; }
        h1, h2, h3, h4 { line-height: 1.35; margin: 2em 0 .6em; }
        h1 { font-size: 1.8rem; } h2 { font-size: 1.4rem; } h3 { font-size: 1.15rem; }
        table { border-collapse: collapse; margin: 1.2em 0; font-size: .95em; }
        th, td { border: 1px solid #c8c8cc; padding: .35em .7em; vertical-align: top; }
        th { background: rgba(127,127,127,.12); text-align: left; }
        pre { background: rgba(127,127,127,.1); padding: .9em 1em; overflow-x: auto; border-radius: 6px; }
        code { font-family: ui-monospace, Menlo, monospace; font-size: .9em; }
        blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid #c8c8cc; color: #6e6e73; }
        figure { margin: 1.4em 0; } img { max-width: 100%; height: auto; }
        .page-break { break-after: page; height: 0; }
        hr { border: 0; border-top: 1px solid #c8c8cc; margin: 2em 0; }
        </style>
        </head>
        <body>
        \(body.joined(separator: "\n"))
        </body>
        </html>

        """
    }

    static func align(_ p: DocParagraph) -> String {
        switch p.alignment {
        case .left: return ""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        case .justify: return " style=\"text-align:justify\""
        }
    }

    public static func escape(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            default: r.append(ch)
            }
        }
        return r
    }

    /// Link targets that may be written: http, https, mailto, a #fragment or a relative path. javascript:, data:, file: and the like are dropped
    /// (the link text stays). Whitespace and control characters are removed first, as browsers ignore them inside a scheme.
    static func safeHref(_ raw: String) -> String? { LinkPolicy.safeHref(raw) }

    static func inline(_ runs: [DocRun]) -> String {
        DocParagraph(runs).normalized().runs.map { run in
            var t = escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
            if run.code { t = "<code>\(t)</code>" }
            if run.bold { t = "<strong>\(t)</strong>" }
            if run.italic { t = "<em>\(t)</em>" }
            if run.underline { t = "<u>\(t)</u>" }
            if run.strikethrough { t = "<s>\(t)</s>" }
            var style: [String] = []
            if let c = run.color, !c.isNearlyBlack { style.append("color:#\(c.hex)") }
            if let h = run.highlight { style.append("background:#\(h.hex)") }
            if !style.isEmpty { t = "<span style=\"\(style.joined(separator: ";"))\">\(t)</span>" }
            if let link = run.link, let href = safeHref(link) { t = "<a href=\"\(escape(href))\">\(t)</a>" }
            return t
        }.joined()
    }
}
