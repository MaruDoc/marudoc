import Foundation

// MARK: - Writing

enum XMLEsc {
    /// True for scalars allowed in XML 1.0 documents.
    @inline(__always) static func isValid(_ v: UInt32) -> Bool {
        if v >= 0x20 { return v != 0xFFFE && v != 0xFFFF }
        return v == 0x09 || v == 0x0A || v == 0x0D
    }

    /// Removes characters that XML 1.0 cannot carry at all (control characters, U+FFFE/FFFF).
    static func sanitized(_ s: String) -> String {
        if !s.unicodeScalars.contains(where: { !isValid($0.value) }) { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where isValid(u.value) { out.append(u) }
        return String(out)
    }

    /// Escapes element text.
    static func text(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: if isValid(u.value) { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    /// Escapes an attribute value (double-quoted). Tabs/newlines become character references
    /// so attribute-value normalisation does not turn them into spaces.
    static func attr(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t": out += "&#9;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            default: if isValid(u.value) { out.unicodeScalars.append(u) }
            }
        }
        return out
    }
}

let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

// MARK: - Namespaces

/// Maps namespace URIs (transitional and strict OOXML) to short, prefix-independent keys,
/// so readers work no matter which prefixes the producing application chose.
enum NS {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let pr = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let ct = "http://schemas.openxmlformats.org/package/2006/content-types"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    static let pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let x = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let cp = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let dcterms = "http://purl.org/dc/terms/"
    static let xsi = "http://www.w3.org/2001/XMLSchema-instance"
    static let ep = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
    static let vt = "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"

    static let keys: [String: String] = [
        w: "w", "http://purl.oclc.org/ooxml/wordprocessingml/main": "w",
        r: "r", "http://purl.oclc.org/ooxml/officeDocument/relationships": "r",
        pr: "pr", ct: "ct",
        a: "a", "http://purl.oclc.org/ooxml/drawingml/main": "a",
        wp: "wp", "http://purl.oclc.org/ooxml/drawingml/wordprocessingDrawing": "wp",
        pic: "pic", "http://purl.oclc.org/ooxml/drawingml/picture": "pic",
        p: "p", "http://purl.oclc.org/ooxml/presentationml/main": "p",
        x: "x", "http://purl.oclc.org/ooxml/spreadsheetml/main": "x",
        cp: "cp", dc: "dc", dcterms: "dcterms",
        "http://schemas.openxmlformats.org/markup-compatibility/2006": "mc",
        "urn:schemas-microsoft-com:vml": "v",
        "urn:schemas-microsoft-com:office:office": "o",
        "http://schemas.microsoft.com/office/word/2010/wordprocessingShape": "wps",
        "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup": "wpg",
        "http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas": "wpc",
        "http://schemas.openxmlformats.org/officeDocument/2006/math": "m",
        "http://purl.oclc.org/ooxml/officeDocument/math": "m",
        "http://schemas.openxmlformats.org/drawingml/2006/chart": "c",
        "http://purl.oclc.org/ooxml/drawingml/chart": "c",
        "http://schemas.openxmlformats.org/drawingml/2006/diagram": "dgm",
        "http://www.w3.org/XML/1998/namespace": "xml",
    ]

    @inline(__always) static func key(_ uri: String?) -> String {
        guard let uri, !uri.isEmpty else { return "" }
        return keys[uri] ?? uri
    }
}

// MARK: - Reading

/// SAX front-end over Foundation's XMLParser that reports namespace-normalised names:
/// elements as "w:p", attributes as "w:val" / "r:id" / plain "val".
final class OOXMLSAX: NSObject, XMLParserDelegate {
    var onStart: ((_ tag: String, _ attrs: [String: String]) -> Void)?
    var onEnd: ((_ tag: String) -> Void)?
    var onText: ((_ text: String) -> Void)?

    private var prefixes: [String: [String]] = [:]
    private var tagStack: [String] = []

    /// OOXML parts never carry a DOCTYPE. Refusing it up front keeps entity tricks out of every parser.
    static func rejectDoctype(_ data: Data, part: String) throws {
        if containsDoctype(data) { throw OfficeError.malformedXML(part: part, detail: "DOCTYPE is not allowed") }
    }

    static func containsDoctype(_ data: Data) -> Bool {
        let needle = Array("<!doctype".utf8)
        // UTF-16 parts have a NUL next to every ASCII byte; drop them so the same scan finds the marker.
        let utf16 = data.count >= 2 && (data[data.startIndex] == 0 || data[data.startIndex + 1] == 0
                                        || (data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xFE)
                                        || (data[data.startIndex] == 0xFE && data[data.startIndex + 1] == 0xFF))
        let bytes: [UInt8] = utf16 ? data.filter { $0 != 0 } : Array(data)
        guard bytes.count >= needle.count else { return false }
        var i = 0
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == 0x3C {   // '<'
                var j = 1
                while j < needle.count {
                    var c = bytes[i + j]
                    if c >= 0x41 && c <= 0x5A { c += 0x20 }
                    if c != needle[j] { break }
                    j += 1
                }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    static func run(_ data: Data, part: String, configure: (OOXMLSAX) -> Void) throws {
        try rejectDoctype(data, part: part)
        let handler = OOXMLSAX()
        configure(handler)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = handler
        if !parser.parse() {
            let err = parser.parserError as NSError?
            let detail = err.map { "line \(parser.lineNumber): \($0.localizedDescription)" } ?? "line \(parser.lineNumber)"
            throw OfficeError.malformedXML(part: part, detail: detail)
        }
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixes[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        if prefixes[prefix]?.isEmpty == false { prefixes[prefix]?.removeLast() }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let tag = NS.key(namespaceURI) + ":" + elementName
        tagStack.append(tag)
        guard let onStart else { return }
        var attrs: [String: String] = [:]
        attrs.reserveCapacity(attributeDict.count)
        for (k, v) in attributeDict {
            if let colon = k.firstIndex(of: ":") {
                let prefix = String(k[..<colon])
                let local = k[k.index(after: colon)...]
                if prefix == "xmlns" { continue }
                if prefix == "xml" { attrs["xml:" + local] = v; continue }
                let uri = prefixes[prefix]?.last
                attrs[(uri.map { NS.key($0) } ?? prefix) + ":" + local] = v
            } else {
                attrs[k] = v
            }
        }
        onStart(tag, attrs)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = tagStack.popLast() ?? (NS.key(namespaceURI) + ":" + elementName)
        onEnd?(tag)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { onText?(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { onText?(s) }
    }
}

/// A small read-only DOM node. `tag` is namespace-normalised ("w:p", "a:t", "x:c").
final class XNode {
    let tag: String
    let attrs: [String: String]
    var children: [XNode] = []
    /// Character data directly inside this element (concatenated).
    var text: String = ""

    init(tag: String, attrs: [String: String]) { self.tag = tag; self.attrs = attrs }

    /// The local name without namespace key.
    var localName: Substring {
        if let i = tag.lastIndex(of: ":") { return tag[tag.index(after: i)...] }
        return Substring(tag)
    }

    subscript(_ attr: String) -> String? { attrs[attr] }

    func child(_ tag: String) -> XNode? { children.first { $0.tag == tag } }
    func children(_ tag: String) -> [XNode] { children.filter { $0.tag == tag } }

    /// All descendants with the tag, depth-first in document order.
    func descendants(_ tag: String) -> [XNode] {
        var out: [XNode] = []
        func walk(_ n: XNode) { for c in n.children { if c.tag == tag { out.append(c) }; walk(c) } }
        walk(self)
        return out
    }

    func firstDescendant(_ tag: String) -> XNode? {
        for c in children {
            if c.tag == tag { return c }
            if let d = c.firstDescendant(tag) { return d }
        }
        return nil
    }

    func contains(_ tag: String) -> Bool { firstDescendant(tag) != nil }

    /// Concatenated text of all descendant elements with the given tag (e.g. all "a:t").
    func allText(_ textTag: String) -> String {
        var s = ""
        func walk(_ n: XNode) { for c in n.children { if c.tag == textTag { s += c.text } else { walk(c) } } }
        walk(self)
        return s
    }

    static func parse(_ data: Data, part: String) throws -> XNode {
        let root = XNode(tag: "#document", attrs: [:])
        var stack: [XNode] = [root]
        try OOXMLSAX.run(data, part: part) { sax in
            sax.onStart = { tag, attrs in
                let n = XNode(tag: tag, attrs: attrs)
                stack.last?.children.append(n)
                stack.append(n)
            }
            sax.onEnd = { _ in if stack.count > 1 { stack.removeLast() } }
            sax.onText = { s in stack.last?.text += s }
        }
        guard let top = root.children.first else { throw OfficeError.malformedXML(part: part, detail: "empty document") }
        return top
    }
}

// MARK: - Attribute value parsing

enum OOXMLValue {
    /// ST_OnOff: absent value means "on".
    static func onOff(_ s: String?) -> Bool {
        guard let s else { return true }
        switch s.lowercased() { case "0", "false", "off", "none": return false; default: return true }
    }

    @inline(__always) static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, v)) }

    static func int(_ s: String?) -> Int? {
        guard let s else { return nil }
        // Values this large never occur in real files; refusing them keeps later arithmetic from overflowing.
        if let i = Int(s) { return abs(i) <= 1_000_000_000 ? i : nil }
        if let d = Double(s), d.isFinite, abs(d) <= 1e9 { return Int(d) }
        return nil
    }

    static func double(_ s: String?) -> Double? {
        guard let s, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
        return d
    }

    /// Twips (1/20 pt) from either a plain number or a universal measure like "2.5cm" / "12pt" / "1in".
    static func twips(_ s: String?) -> Double? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let units: [(String, Double)] = [("mm", 56.6929), ("cm", 566.929), ("in", 1440), ("pt", 20), ("pc", 240), ("pi", 240)]
        for (u, f) in units where s.hasSuffix(u) {
            s.removeLast(u.count)
            return double(s).map { $0 * f }
        }
        return double(s)
    }
}
