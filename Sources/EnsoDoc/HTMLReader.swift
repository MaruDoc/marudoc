import Foundation

/// HTML -> DocModel without WebKit, so nothing referenced by the page (remote images, CSS, scripts) is ever fetched.
/// Only `data:` images and local files next to the document are embedded.
public enum HTMLReader {

    public static func model(from data: Data, baseURL: URL? = nil) throws -> DocModel {
        let doc: XMLDocument
        do {
            // Decode ourselves: tidy would otherwise read UTF-8 pages as Latin-1.
            doc = try XMLDocument(xmlString: stripXMLDeclaration(decode(data)), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        } catch {
            // Fall back to text if even tidy can't make sense of it.
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            return PlainTextReader.model(from: text)
        }
        var b = Builder(baseURL: baseURL)
        let title = (try? doc.nodes(forXPath: "//title").first?.stringValue)?.flatMap { $0 }?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let body = (try? doc.nodes(forXPath: "//body"))?.first {
            b.block(body)
        } else if let root = doc.rootElement() {
            b.block(root)
        }
        b.flush()
        var model = DocModel(title: (title?.isEmpty == false) ? title : nil, blocks: b.blocks, bodyFontSize: 11)
        if model.title == nil, case .heading(_, let p)? = model.blocks.first { model.title = p.plainText }
        return model
    }

    /// An XHTML file may start with `<?xml ... ?>`; tidy mode would choke on it or mis-decode the text.
    static func stripXMLDeclaration(_ s: String) -> String {
        var t = Substring(s)
        while let f = t.first, f == "\u{FEFF}" || f.isWhitespace { t = t.dropFirst() }
        guard t.hasPrefix("<?xml"), let end = t.range(of: "?>") else { return s }
        return String(t[end.upperBound...])
    }

    /// Honours a declared charset (Shift_JIS / EUC-JP pages exist), otherwise BOM / UTF-8 detection.
    static func decode(_ data: Data) -> String {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if let r = head.range(of: #"charset\s*=\s*["']?([a-z0-9_\-]+)"#, options: .regularExpression) {
            let name = head[r].replacingOccurrences(of: #"charset\s*=\s*["']?"#, with: "", options: .regularExpression)
            let enc = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(name as CFString))
            if enc != UInt(kCFStringEncodingInvalidId), let s = String(data: data, encoding: String.Encoding(rawValue: enc)) { return s }
        }
        return PlainTextReader.decode(data)
    }

    struct Style {
        var bold = false, italic = false, underline = false, strike = false, code = false
        var link: String?
    }

    struct Builder {
        let baseURL: URL?
        var blocks: [DocBlock] = []
        var runs: [DocRun] = []
        var listStack: [(ordered: Bool, counter: Int)] = []

        init(baseURL: URL?) { self.baseURL = baseURL }

        static let blockTags: Set<String> = ["p", "div", "section", "article", "main", "header", "footer", "nav", "aside",
                                             "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "pre",
                                             "blockquote", "hr", "figure", "figcaption", "body", "html", "dl", "dt", "dd", "address"]
        static let skipTags: Set<String> = ["script", "style", "head", "noscript", "template", "iframe", "object", "embed", "svg", "button", "form", "input", "select", "textarea"]

        mutating func flush() {
            let p = DocParagraph(runs).normalized()
            runs = []
            guard !p.isEmpty else { return }
            if !listStack.isEmpty {
                let level = listStack.count - 1
                listStack[level].counter += 1
                let top = listStack[level]
                blocks.append(.listItem(DocListItem(ordered: top.ordered, level: level, number: top.ordered ? top.counter : nil,
                                                    paragraph: trimmed(p))))
            } else {
                blocks.append(.paragraph(trimmed(p)))
            }
        }

        func trimmed(_ p: DocParagraph) -> DocParagraph {
            var q = p
            if !q.runs.isEmpty {
                q.runs[0].text = String(q.runs[0].text.drop(while: { $0 == " " }))
                let last = q.runs.count - 1
                while q.runs[last].text.hasSuffix(" ") { q.runs[last].text.removeLast() }
            }
            return q.normalized()
        }

        mutating func block(_ node: XMLNode) {
            for child in node.children ?? [] { visit(child, style: Style()) }
        }

        mutating func visit(_ node: XMLNode, style: Style) {
            if node.kind == .text {
                let collapsed = (node.stringValue ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if collapsed.isEmpty { return }
                if collapsed == " ", runs.isEmpty || runs.last?.text.hasSuffix(" ") == true { return }
                runs.append(DocRun(collapsed, bold: style.bold, italic: style.italic, underline: style.underline,
                                   strikethrough: style.strike, code: style.code, link: style.link))
                return
            }
            guard let el = node as? XMLElement, let name = el.name?.lowercased() else { return }
            if Self.skipTags.contains(name) { return }
            var s = style
            switch name {
            case "strong", "b": s.bold = true
            case "em", "i", "cite": s.italic = true
            case "u", "ins": s.underline = true
            case "s", "strike", "del": s.strike = true
            case "code", "kbd", "tt", "samp": s.code = true
            case "a":
                if let href = el.attribute(forName: "href")?.stringValue, href.hasPrefix("http") || href.hasPrefix("mailto:") { s.link = href }
            case "br":
                runs.append(DocRun("\n")); return
            case "img":
                if let img = image(el) { flush(); blocks.append(.image(img)) }
                return
            default: break
            }

            if !Self.blockTags.contains(name) {
                for c in el.children ?? [] { visit(c, style: s) }
                return
            }

            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                let level = Int(String(name.last!)) ?? 1
                let saved = runs; runs = []
                for c in el.children ?? [] { visit(c, style: s) }
                let p = trimmed(DocParagraph(runs).normalized()); runs = saved
                if !p.isEmpty { blocks.append(.heading(level: level, p)) }
            case "ul", "ol":
                flush()
                listStack.append((name == "ol", min(1_000_000, max(-1_000_000, Int(el.attribute(forName: "start")?.stringValue ?? "") ?? 1)) - 1))
                for c in el.children ?? [] { visit(c, style: s) }
                flush()
                listStack.removeLast()
            case "li":
                flush()
                for c in el.children ?? [] { visit(c, style: s) }
                flush()
            case "pre":
                flush()
                blocks.append(.code((el.stringValue ?? "").trimmingCharacters(in: .newlines), language: nil))
            case "blockquote":
                flush()
                let start = blocks.count
                for c in el.children ?? [] { visit(c, style: s) }
                flush()
                for i in start..<blocks.count { if case .paragraph(let p) = blocks[i] { blocks[i] = .quote(p) } }
            case "hr":
                flush(); blocks.append(.horizontalRule)
            case "table":
                flush()
                if let t = table(el) { blocks.append(.table(t)) }
            default:
                flush()
                for c in el.children ?? [] { visit(c, style: s) }
                flush()
            }
        }

        func table(_ el: XMLElement) -> DocTable? {
            var rows: [[DocTableCell]] = []
            var header = 0
            func collect(_ node: XMLNode, inHead: Bool) {
                for c in node.children ?? [] {
                    guard let e = c as? XMLElement, let n = e.name?.lowercased() else { continue }
                    switch n {
                    case "thead": collect(e, inHead: true)
                    case "tbody", "tfoot": collect(e, inHead: false)
                    case "tr":
                        var cells: [DocTableCell] = []
                        var allTH = true
                        for cc in e.children ?? [] {
                            guard let ce = cc as? XMLElement, let cn = ce.name?.lowercased(), cn == "td" || cn == "th" else { continue }
                            if cn == "td" { allTH = false }
                            var sub = Builder(baseURL: baseURL)
                            sub.block(ce); sub.flush()
                            let paras = sub.blocks.compactMap { b -> DocParagraph? in
                                switch b { case .paragraph(let p), .heading(_, let p), .quote(let p): return p
                                case .listItem(let li): return li.paragraph
                                default: return nil }
                            }
                            let span = Int(ce.attribute(forName: "colspan")?.stringValue ?? "1") ?? 1
                            cells.append(DocTableCell(paras.isEmpty ? [DocParagraph(text: "")] : paras, colSpan: max(1, min(span, 60))))
                        }
                        if !cells.isEmpty {
                            if (inHead || allTH) && rows.count == header { header += 1 }
                            rows.append(cells)
                        }
                    default: collect(e, inHead: inHead)
                    }
                }
            }
            collect(el, inHead: false)
            return rows.isEmpty ? nil : DocTable(rows: rows, headerRows: header)
        }

        func image(_ el: XMLElement) -> DocImage? {
            guard let src = el.attribute(forName: "src")?.stringValue else { return nil }
            var data: Data?
            if src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") {
                let meta = src[..<comma]
                let payload = String(src[src.index(after: comma)...])
                data = meta.contains(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
            } else if let base = baseURL {
                data = HTMLReader.readLocalImage(src, base: base)
            }
            guard let d = data, let cg = ImageCodec.decode(d), var img = ImageCodec.docImage(from: cg) else { return nil }
            if let w = el.attribute(forName: "width")?.stringValue.flatMap(Double.init), w > 0, w < 100_000 {
                img.displayHeight = img.displayHeight * w / max(img.displayWidth, 1)
                img.displayWidth = w * 0.75
                img.displayHeight *= 0.75
            }
            img.altText = el.attribute(forName: "alt")?.stringValue
            return img
        }
    }

    /// Reads a local image: the path is judged by `localImageURL`, then the file is opened once and the opened
    /// descriptor itself is checked (regular file, size, real location inside `base`) and read. Nothing is checked by
    /// path and then opened again, so a folder swapped for a symlink in between cannot redirect the read.
    static func readLocalImage(_ src: String, base: URL) -> Data? {
        guard let file = localImageURL(src, base: base) else { return nil }
        return readOpenedFile(file, inside: base)
    }

    public static func readOpenedFile(_ file: URL, inside folder: URL, limit: Int = 100_000_000) -> Data? {
        guard let root = realPath(folder.path) else { return nil }
        // O_NOFOLLOW refuses a symlink as the last component; O_NONBLOCK keeps a FIFO from blocking the open.
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0, Int(st.st_size) <= limit else { return nil }
        // Where the descriptor really points (symlinked folders on the way are already resolved).
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        let opened = String(cString: buffer)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard opened.hasPrefix(prefix) else { return nil }
        var data = Data(count: Int(st.st_size))
        var done = 0
        while done < data.count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + done, $0.count - done) }
            if n <= 0 { break }
            done += n
        }
        data.removeSubrange(done...)
        return data
    }

    private static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// A local `<img src>` is read only when, with symlinks resolved, it is a regular file inside the document's folder.
    static func localImageURL(_ src: String, base: URL) -> URL? {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: String
        if let scheme = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) {
            // Only file: is a local path; http:, ftp:, smb: and the like are never fetched.
            guard trimmed[scheme].lowercased() == "file:", let u = URL(string: trimmed), u.isFileURL else { return nil }
            path = u.path
        } else {
            path = trimmed
            if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
            path = path.removingPercentEncoding ?? path
        }
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path
        let file = URL(fileURLWithPath: path, relativeTo: base).resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.path.hasPrefix(prefix) else { return nil }
        guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
              (v.fileSize ?? 0) <= 100_000_000 else { return nil }
        return file
    }
}
