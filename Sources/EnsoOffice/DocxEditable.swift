import AppKit
import EnsoDoc

// Faithful .docx editing.
//
// Reading turns the document body into an NSAttributedString that looks like the document (styles, theme fonts,
// spacing, line grid, indents, numbering, tables, images, page breaks). Every paragraph and run remembers its
// original XML. Saving writes a new body from the edited text — reusing the original XML wherever the user didn't
// change formatting — and copies every other part of the package untouched (styles, numbering, headers, footers,
// footnotes, comments, media). Elements MaruDoc doesn't model (fields, bookmarks, equations, content controls,
// shapes) ride along as invisible or labelled placeholders and are written back verbatim.

public extension NSAttributedString.Key {
    /// Raw `<w:pPr>` of the paragraph ("" when it had none). On the whole paragraph.
    static let docxPPr = NSAttributedString.Key("EnsoDocxPPr")
    /// Look of the paragraph when it was loaded; a different value at save time means the user changed it.
    static let docxPSig = NSAttributedString.Key("EnsoDocxPSig")
    /// Raw `<w:rPr>` of the run ("" when it had none).
    static let docxRPr = NSAttributedString.Key("EnsoDocxRPr")
    static let docxRSig = NSAttributedString.Key("EnsoDocxRSig")
    /// Raw XML of an element MaruDoc doesn't edit; written back as is. On a zero-width space or an attachment.
    static let docxRaw = NSAttributedString.Key("EnsoDocxRaw")
    /// Characters MaruDoc inserted for display only (list numbers, page-break-before); never written.
    static let docxSynthetic = NSAttributedString.Key("EnsoDocxSynthetic")
    /// r:id of the w:hyperlink the run sits in.
    static let docxLinkID = NSAttributedString.Key("EnsoDocxLinkID")
    /// Height Word gives one line of this run (font ascent + descent + gap as Word measures it). Display only.
    static let docxLineHeight = NSAttributedString.Key("EnsoDocxLineHeight")
    /// `DocxParagraphBorders` of the paragraph (`w:pBdr`, style chain resolved). Display only; never written.
    static let docxBorders = NSAttributedString.Key("EnsoDocxBorders")
}

/// Border lines of a paragraph. Display only: saving writes the original `<w:pPr>`.
public struct DocxParagraphBorders: Hashable {
    public struct Edge: Hashable {
        /// Line width in points (`w:sz` is eighths of a point); 0 = no line.
        public var width: CGFloat
        /// Distance between line and text in points.
        public var space: CGFloat
        /// Hex RGB; nil = automatic (black).
        public var color: String?
    }
    public var top: Edge?, bottom: Edge?, left: Edge?, right: Edge?, between: Edge?
}

/// Header and footer of the last section, as text drawn on every page. PAGE and NUMPAGES fields are the
/// `pageToken` / `totalToken` characters, replaced when a page is drawn.
public struct DocxHeaderFooter {
    public var header: NSAttributedString?, footer: NSAttributedString?
    public var firstHeader: NSAttributedString?, firstFooter: NSAttributedString?
    /// `w:titlePg`: page 1 uses the first-page header and footer.
    public var differentFirstPage = false
    public var headerDistance: CGFloat, footerDistance: CGFloat

    static let pageToken = "\u{E010}", totalToken = "\u{E011}"

    public func header(page: Int, of total: Int) -> NSAttributedString? {
        Self.filled(differentFirstPage && page == 1 ? firstHeader : header, page: page, total: total)
    }

    public func footer(page: Int, of total: Int) -> NSAttributedString? {
        Self.filled(differentFirstPage && page == 1 ? firstFooter : footer, page: page, total: total)
    }

    /// Most PAGE / NUMPAGES fields replaced in one header or footer; further ones are dropped.
    static let maxFieldTokens = 1_000
    private static let tokenSet = CharacterSet(charactersIn: pageToken + totalToken)

    /// One pass over the text: the pieces between the tokens are copied once, each token is replaced by its number
    /// (cost proportional to the length, however many tokens there are).
    static func filled(_ s: NSAttributedString?, page: Int, total: Int) -> NSAttributedString? {
        guard let s, s.length > 0 else { return nil }
        let ns = s.string as NSString
        let out = NSMutableAttributedString()
        var pos = 0, count = 0
        while pos < ns.length {
            let r = ns.rangeOfCharacter(from: tokenSet, options: [], range: NSRange(location: pos, length: ns.length - pos))
            if r.location == NSNotFound { break }
            if r.location > pos { out.append(s.attributedSubstring(from: NSRange(location: pos, length: r.location - pos))) }
            count += 1
            if count <= maxFieldTokens {
                let value = ns.substring(with: r) == pageToken ? page : total
                out.append(NSAttributedString(string: String(value), attributes: s.attributes(at: r.location, effectiveRange: nil)))
            }
            pos = NSMaxRange(r)
        }
        if pos < ns.length { out.append(s.attributedSubstring(from: NSRange(location: pos, length: ns.length - pos))) }
        return out
    }
}

/// An image from the document. `runXML` is the whole original `<w:r>` (rPr + drawing), written back unchanged.
public final class DocxImageAttachment: NSTextAttachment {
    public var runXML: String?
}

/// Something MaruDoc shows but doesn't edit (equation, chart, text box, content control). Drawn as a small label.
public final class DocxOpaqueAttachment: NSTextAttachment {
    public var xml = ""

    public static func make(xml: String, label: String, size: CGFloat) -> DocxOpaqueAttachment {
        let a = DocxOpaqueAttachment()
        a.xml = xml
        let font = NSFont.systemFont(ofSize: max(9, size * 0.85), weight: .medium)
        let text = label as NSString
        let ts = text.size(withAttributes: [.font: font])
        let box = NSSize(width: ceil(ts.width) + 14, height: ceil(ts.height) + 4)
        a.image = NSImage(size: box, flipped: false) { r in
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
            text.draw(at: NSPoint(x: 7, y: 2), withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            return true
        }
        a.bounds = CGRect(x: 0, y: -3, width: box.width, height: box.height)
        return a
    }
}

public final class DocxTable: NSTextTable {
    public var tblPr: String?
    public var tblGrid: String?
    public var rowPr: [Int: String] = [:]
}

public final class DocxCellBlock: NSTextTableBlock {
    public var tcPr: String?
}

public struct DocxPageSetup: Sendable {
    public var size: CGSize
    public var margins: NSEdgeInsets
    public var headerDistance: CGFloat
    public var footerDistance: CGFloat
    /// Line pitch of the document grid (Japanese layouts), if one is active.
    public var linePitch: CGFloat?
}

public final class DocxDocument {
    public let url: URL
    public let page: DocxPageSetup
    public let attributed: NSAttributedString
    /// Tracked changes are flattened when MaruDoc writes the body, so such files are saved as a copy.
    public let hasTrackedChanges: Bool
    /// Header and footer of the document's last section (nil when it has none). Shown read-only on each page.
    public let headerFooter: DocxHeaderFooter?

    let zip: ZipReader
    let mainPart: String
    let documentXML: String
    let bodyContentRange: Range<String.Index>
    let sectPr: String?
    let w: String
    let rootNamespaces: String

    public init(url: URL) throws {
        self.url = url
        zip = try ZipReader(data: Data(contentsOf: url))
        mainPart = (try? OPC.mainPart(zip, fallback: "word/document.xml")) ?? "word/document.xml"
        let docData = try zip.data(mainPart)
        try OOXMLSAX.rejectDoctype(docData, part: mainPart)
        guard docData.count <= 256 << 20 else { throw OfficeError.tooLarge("\(mainPart) is too large to edit") }
        documentXML = String(decoding: docData, as: UTF8.self)
        let xmlBytes = Array(documentXML.utf8)
        guard let open = Self.findTag(xmlBytes, local: "body", closing: false, last: false, needsSpaceOrClose: false),
              let close = Self.findTag(xmlBytes, local: "body", closing: true, last: true, needsSpaceOrClose: false),
              open.upperBound <= close.lowerBound else {
            throw OfficeError.invalidDocument("no body")
        }
        let openRange = Self.stringRange(open, in: documentXML), closeRange = Self.stringRange(close, in: documentXML)
        bodyContentRange = openRange.upperBound..<closeRange.lowerBound
        let openTag = String(documentXML[openRange])
        w = openTag.hasPrefix("<") && openTag.contains(":") ? String(openTag.dropFirst().prefix { $0 != ":" }) : ""
        if let rootBytes = Self.findTag(xmlBytes, local: "document", closing: false, last: false, needsSpaceOrClose: true) {
            let tag = String(documentXML[Self.stringRange(rootBytes, in: documentXML)])
            let decls = tag.matches(of: #/xmlns(:[A-Za-z0-9_]+)?="[^"]*"/#).map { String($0.output.0) }
            rootNamespaces = decls.joined(separator: " ")
        } else {
            rootNamespaces = "xmlns:w=\"\(NS.w)\" xmlns:r=\"\(NS.r)\""
        }
        hasTrackedChanges = documentXML.contains(":ins ") || documentXML.contains(":del ") || documentXML.contains("rPrChange") || documentXML.contains("pPrChange")

        let reader = try DocxBodyReader(zip: zip, mainPart: mainPart, documentData: Self.protectWhitespace(docData))
        page = reader.page
        headerFooter = reader.headerFooter
        sectPr = reader.finalSectPr
        attributed = reader.result
    }

    /// XMLDocument drops text nodes that are only spaces (`<w:t xml:space="preserve"> </w:t>`), losing the space.
    /// They are swapped for private-use stand-ins before parsing and restored afterwards.
    static let spaceStandIn: Character = "\u{E000}", tabStandIn: Character = "\u{E001}"

    static func protectWhitespace(_ data: Data) -> Data {
        // Single linear pass for `<t>   </t>` (also instrText / delText, any prefix): the blank run is swapped for stand-ins.
        let src = [UInt8](data)
        let n = src.count
        @inline(__always) func isWord(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
        let space = [UInt8](String(spaceStandIn).utf8), tab = [UInt8](String(tabStandIn).utf8)
        var out = [UInt8]()
        out.reserveCapacity(n)
        var i = 0, copied = 0, nextGT = -1
        while i < n {
            guard src[i] == 0x3C else { i += 1; continue }
            var j = i + 1
            var k = j
            while k < n, isWord(src[k]) { k += 1 }
            var nameStart = j
            if k > j, k < n, src[k] == 0x3A { nameStart = k + 1 }
            var nameEnd = nameStart
            while nameEnd < n, isWord(src[nameEnd]) { nameEnd += 1 }
            let name = src[nameStart..<nameEnd]
            if name.elementsEqual("t".utf8) || name.elementsEqual("instrText".utf8) || name.elementsEqual("delText".utf8) {
                if nextGT < nameEnd {
                    var g = nameEnd
                    while g < n, src[g] != 0x3E { g += 1 }
                    nextGT = g < n ? g : n   // n: no '>' anywhere after this point
                }
                if nextGT >= n { break }
                j = nextGT + 1
                var e = j
                while e < n, src[e] == 0x20 || src[e] == 0x09 { e += 1 }
                if e > j, e + 1 < n, src[e] == 0x3C, src[e + 1] == 0x2F {
                    out.append(contentsOf: src[copied..<j])
                    for c in src[j..<e] { out.append(contentsOf: c == 0x09 ? tab : space) }
                    copied = e
                    i = e
                    continue
                }
            }
            i += 1
        }
        out.append(contentsOf: src[copied..<n])
        return Data(out)
    }

    /// Linear-time search for `<prefix:local ...>` (or `</prefix:local>`); returns its UTF-8 byte range.
    /// `needsSpaceOrClose` requires whitespace after the name (as the root element does); otherwise `>` may follow directly.
    static func findTag(_ b: [UInt8], local: String, closing: Bool, last: Bool, needsSpaceOrClose: Bool) -> Range<Int>? {
        @inline(__always) func isWord(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
        let name = Array(local.utf8)
        let n = b.count
        var found: Range<Int>?
        var nextGT = -1
        var i = 0
        while i < n {
            guard b[i] == 0x3C else { i += 1; continue }
            var j = i + 1
            if closing { guard j < n, b[j] == 0x2F else { i += 1; continue }; j += 1 } else if j < n, b[j] == 0x2F { i += 1; continue }
            var k = j
            while k < n, isWord(b[k]) { k += 1 }
            var nameStart = j
            if k > j, k < n, b[k] == 0x3A { nameStart = k + 1 }
            let nameEnd = nameStart + name.count
            if nameEnd <= n, b[nameStart..<nameEnd].elementsEqual(name) {
                if closing {
                    if nameEnd < n, b[nameEnd] == 0x3E { found = i..<(nameEnd + 1) }
                } else if nameEnd < n {
                    let c = b[nameEnd]
                    if c == 0x3E, !needsSpaceOrClose { found = i..<(nameEnd + 1) }
                    else if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                        if nextGT < nameEnd {
                            var g = nameEnd
                            while g < n, b[g] != 0x3E { g += 1 }
                            nextGT = g
                        }
                        if nextGT < n { found = i..<(nextGT + 1) }
                    }
                }
                if let f = found, !last { return f }
                if let f = found { i = f.upperBound; continue }
            }
            i += 1
        }
        return found
    }

    static func stringRange(_ r: Range<Int>, in s: String) -> Range<String.Index> {
        let u = s.utf8
        return u.index(u.startIndex, offsetBy: r.lowerBound)..<u.index(u.startIndex, offsetBy: r.upperBound)
    }

    static func restoreWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: String(spaceStandIn), with: " ").replacingOccurrences(of: String(tabStandIn), with: "\t")
    }

    /// Writes the edited body into a copy of the original package.
    public func save(_ text: NSAttributedString, to target: URL) throws {
        let writer = DocxBodyWriter(prefix: w, namespaces: rootNamespaces, zip: zip, mainPart: mainPart)
        var body = Self.restoreWhitespace(try writer.body(from: text))
        if let sectPr { body += sectPr }
        var xml = documentXML
        xml.replaceSubrange(bodyContentRange, with: body)

        let out = ZipWriter()
        var replaced: Set<String> = [mainPart]
        let relsPath = OPC.relsPath(for: mainPart)
        if !writer.newMedia.isEmpty {
            replaced.insert(relsPath)
            replaced.insert("[Content_Types].xml")
        }
        for name in zip.entryNames where !replaced.contains(name) && !name.hasSuffix("/") {
            try out.add(path: name, data: try zip.data(name))
        }
        try out.add(path: mainPart, data: Data(xml.utf8))
        if !writer.newMedia.isEmpty {
            var rels = (try? String(decoding: zip.data(relsPath), as: UTF8.self)) ?? "\(xmlHeader)<Relationships xmlns=\"\(NS.pr)\"></Relationships>"
            var ct = String(decoding: try zip.data("[Content_Types].xml"), as: UTF8.self)
            let dir = (mainPart as NSString).deletingLastPathComponent
            for m in writer.newMedia {
                try out.add(path: dir + "/" + m.target, data: m.data, compress: false)
                let rel = "<Relationship Id=\"\(m.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\(m.target)\"/>"
                if let end = rels.range(of: "</Relationships>", options: .backwards) { rels.replaceSubrange(end, with: rel + "</Relationships>") }
                if !ct.lowercased().contains("extension=\"png\""), let end = ct.range(of: "</Types>", options: .backwards) {
                    ct.replaceSubrange(end, with: "<Default Extension=\"png\" ContentType=\"image/png\"/></Types>")
                }
            }
            try out.add(path: relsPath, data: Data(rels.utf8))
            try out.add(path: "[Content_Types].xml", data: Data(ct.utf8))
        }
        try out.finalize(to: target)
    }

    // MARK: Signatures (shared by reader and writer)

    static func paragraphSignature(_ ps: NSParagraphStyle?) -> String {
        guard let p = ps else { return "-" }
        func r(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        return "\(p.alignment.rawValue)|\(r(p.headIndent))|\(r(p.firstLineHeadIndent))|\(r(p.tailIndent))|\(r(p.paragraphSpacingBefore))|\(r(p.paragraphSpacing))|\(r(p.lineHeightMultiple))|\(r(p.minimumLineHeight))|\(r(p.maximumLineHeight))"
    }

    static func runSignature(_ attrs: [NSAttributedString.Key: Any]) -> String {
        let f = attrs[.font] as? NSFont
        let color = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB).map { String(format: "%.2f,%.2f,%.2f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "-"
        let bg = (attrs[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB).map { String(format: "%.2f,%.2f,%.2f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "-"
        let u = attrs[.underlineStyle] as? Int ?? 0
        let s = attrs[.strikethroughStyle] as? Int ?? 0
        let b = attrs[.baselineOffset] as? CGFloat ?? 0
        return "\(f?.fontName ?? "-")|\(String(format: "%.1f", f?.pointSize ?? 0))|\(color)|\(bg)|\(u)|\(s)|\(b > 0 ? 1 : b < 0 ? -1 : 0)"
    }
}

// MARK: - Property model

struct RProps {
    var ascii: String?, eastAsia: String?, asciiTheme: String?, eastAsiaTheme: String?
    var size: Double?, bold: Bool?, italic: Bool?, underline: Bool?, strike: Bool?
    var color: String?, highlight: String?, shading: String?, vertAlign: String?, hidden: Bool?, hintEastAsia: Bool?

    mutating func apply(_ o: RProps) {
        if o.ascii != nil { ascii = o.ascii; asciiTheme = nil }
        if o.eastAsia != nil { eastAsia = o.eastAsia; eastAsiaTheme = nil }
        if o.asciiTheme != nil { asciiTheme = o.asciiTheme }
        if o.eastAsiaTheme != nil { eastAsiaTheme = o.eastAsiaTheme }
        size = o.size ?? size; bold = o.bold ?? bold; italic = o.italic ?? italic
        underline = o.underline ?? underline; strike = o.strike ?? strike
        color = o.color ?? color; highlight = o.highlight ?? highlight; shading = o.shading ?? shading
        vertAlign = o.vertAlign ?? vertAlign; hidden = o.hidden ?? hidden; hintEastAsia = o.hintEastAsia ?? hintEastAsia
    }
}

struct PProps {
    var jc: String?
    var before: Double?, after: Double?, beforeLines: Double?, afterLines: Double?, beforeAuto: Bool?, afterAuto: Bool?
    var line: Double?, lineRule: String?
    var left: Double?, right: Double?, firstLine: Double?, hanging: Double?
    var leftChars: Double?, firstLineChars: Double?, hangingChars: Double?
    var numId: String?, ilvl: Int?
    var pageBreakBefore: Bool?, contextual: Bool?, snapToGrid: Bool?
    var tabs: [(String, Double)]?
    var styleId: String?
    /// `w:pBdr` edges by name (top, bottom, left, right, between); width 0 = cleared.
    var borders: [String: DocxParagraphBorders.Edge]?

    mutating func apply(_ o: PProps) {
        if let b = o.borders { borders = (borders ?? [:]).merging(b) { _, new in new } }
        jc = o.jc ?? jc
        before = o.before ?? before; after = o.after ?? after
        if o.beforeLines != nil { beforeLines = o.beforeLines } ; if o.afterLines != nil { afterLines = o.afterLines }
        if o.before != nil && o.beforeLines == nil { beforeLines = nil }
        if o.after != nil && o.afterLines == nil { afterLines = nil }
        beforeAuto = o.beforeAuto ?? beforeAuto; afterAuto = o.afterAuto ?? afterAuto
        line = o.line ?? line; lineRule = o.lineRule ?? lineRule
        if o.left != nil { left = o.left; leftChars = o.leftChars }
        if o.leftChars != nil { leftChars = o.leftChars }
        right = o.right ?? right
        if o.firstLine != nil || o.hanging != nil || o.firstLineChars != nil || o.hangingChars != nil {
            firstLine = o.firstLine; hanging = o.hanging; firstLineChars = o.firstLineChars; hangingChars = o.hangingChars
        }
        numId = o.numId ?? numId; ilvl = o.ilvl ?? ilvl
        pageBreakBefore = o.pageBreakBefore ?? pageBreakBefore; contextual = o.contextual ?? contextual
        snapToGrid = o.snapToGrid ?? snapToGrid
        if let t = o.tabs { tabs = (tabs ?? []) + t }
        styleId = o.styleId ?? styleId
    }
}

// MARK: - XML helpers

extension XMLElement {
    func kids(_ local: String) -> [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == local } }
    func kid(_ local: String) -> XMLElement? { (children ?? []).first { ($0 as? XMLElement)?.localName == local } as? XMLElement }
    var elementKids: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
    func attr(_ local: String) -> String? { attributes?.first { $0.localName == local }?.stringValue }
    func descendants(_ local: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for k in elementKids { if k.localName == local { out.append(k) }; out += k.descendants(local) }
        return out
    }
}

func onOff(_ e: XMLElement?) -> Bool? {
    guard let e else { return nil }
    let v = e.attr("val")?.lowercased()
    return !(v == "0" || v == "false" || v == "off" || v == "none")
}

func twips(_ s: String?) -> Double? { OOXMLValue.double(s).map { $0 / 20 } }

// MARK: - Reader

final class DocxBodyReader {
    let zip: ZipReader
    let mainPart: String
    var page = DocxPageSetup(size: CGSize(width: 595.3, height: 841.9), margins: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72),
                             headerDistance: 36, footerDistance: 36, linePitch: nil)
    var finalSectPr: String?
    var headerFooter: DocxHeaderFooter?
    let result = NSMutableAttributedString()

    private var styles: [String: (type: String, basedOn: String?, p: PProps, r: RProps, name: String)] = [:]
    private var defaultParagraphStyle: String?
    private var defaultsR = RProps()
    private var defaultsP = PProps()
    private var themeMinorLatin: String?, themeMinorEA: String?, themeMajorLatin: String?, themeMajorEA: String?
    private var rels: [String: String] = [:]
    private var linkTargets: [String: String] = [:]
    private var abstractLevels: [String: [Int: (start: Int, fmt: String, text: String, p: PProps, r: RProps, suff: String)]] = [:]
    private var nums: [String: (abstract: String, starts: [Int: Int])] = [:]
    private var counters: [String: [Int]] = [:]
    private var defaultTab: CGFloat = 36
    private var prevStyleId: String?
    private var prevContextual = false
    private var prevRange: NSRange?

    init(zip: ZipReader, mainPart: String, documentData: Data) throws {
        self.zip = zip
        self.mainPart = mainPart
        loadRels()
        loadTheme()
        loadStyles()
        loadNumbering()
        loadSettings()
        try OOXMLSAX.rejectDoctype(documentData, part: mainPart)
        let doc = try XMLDocument(data: documentData, options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), let body = root.kid("body") else { throw OfficeError.invalidDocument("no body") }
        if let sect = body.kid("sectPr") {
            finalSectPr = sect.xmlString(options: .nodeCompactEmptyElement)
            readSection(sect)
            loadHeaderFooter(sect)
        }
        for child in body.elementKids { block(child, cell: nil) }
        finishParagraphSignatures()
    }

    // Parts

    private func part(_ path: String) -> XMLElement? {
        guard let d = try? zip.data(path), !OOXMLSAX.containsDoctype(d),
              let doc = try? XMLDocument(data: d, options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]) else { return nil }
        return doc.rootElement()
    }

    private func loadRels() {
        guard let rr = try? OPC.relationships(zip, for: mainPart) else { return }
        for r in rr {
            if r.external { linkTargets[r.id] = r.target } else { rels[r.id] = r.target }
        }
    }

    private func loadTheme() {
        guard let rr = try? OPC.relationships(zip, for: mainPart), let t = rr.first(where: { $0.isType("theme") }),
              let root = part(OPC.resolve(t.target, from: mainPart)) else { return }
        func pick(_ font: XMLElement?) -> (String?, String?) {
            guard let font else { return (nil, nil) }
            let latin = font.kid("latin")?.attr("typeface")
            var ea = font.kid("ea")?.attr("typeface")
            if ea?.isEmpty ?? true { ea = font.kids("font").first { $0.attr("script") == "Jpan" }?.attr("typeface") }
            return (latin, ea)
        }
        let scheme = root.descendants("fontScheme").first
        (themeMinorLatin, themeMinorEA) = pick(scheme?.kid("minorFont"))
        (themeMajorLatin, themeMajorEA) = pick(scheme?.kid("majorFont"))
    }

    private func loadStyles() {
        guard let root = part((mainPart as NSString).deletingLastPathComponent + "/styles.xml") else { return }
        if let dd = root.kid("docDefaults") {
            if let r = dd.kid("rPrDefault")?.kid("rPr") { defaultsR = rprops(r) }
            if let p = dd.kid("pPrDefault")?.kid("pPr") { defaultsP = pprops(p) }
        }
        for s in root.kids("style") {
            guard let id = s.attr("styleId") else { continue }
            let type = s.attr("type") ?? "paragraph"
            styles[id] = (type, s.kid("basedOn")?.attr("val"), s.kid("pPr").map(pprops) ?? PProps(), s.kid("rPr").map(rprops) ?? RProps(), s.kid("name")?.attr("val") ?? id)
            if type == "paragraph", s.attr("default") == "1" || s.attr("default") == "true" { defaultParagraphStyle = id }
        }
    }

    private func loadNumbering() {
        guard let root = part((mainPart as NSString).deletingLastPathComponent + "/numbering.xml") else { return }
        for a in root.kids("abstractNum") {
            guard let id = a.attr("abstractNumId") else { continue }
            var levels: [Int: (Int, String, String, PProps, RProps, String)] = [:]
            for l in a.kids("lvl") {
                let i = Int(l.attr("ilvl") ?? "0") ?? 0
                guard (0...8).contains(i) else { continue }
                levels[i] = (OOXMLValue.clamp(Int(l.kid("start")?.attr("val") ?? "1") ?? 1, 0, 32767), l.kid("numFmt")?.attr("val") ?? "decimal",
                             l.kid("lvlText")?.attr("val") ?? "", l.kid("pPr").map(pprops) ?? PProps(), l.kid("rPr").map(rprops) ?? RProps(),
                             l.kid("suff")?.attr("val") ?? "tab")
            }
            abstractLevels[id] = levels.mapValues { (start: $0.0, fmt: $0.1, text: $0.2, p: $0.3, r: $0.4, suff: $0.5) }
        }
        for n in root.kids("num") {
            guard let id = n.attr("numId"), let a = n.kid("abstractNumId")?.attr("val") else { continue }
            var starts: [Int: Int] = [:]
            for o in n.kids("lvlOverride") {
                if let i = Int(o.attr("ilvl") ?? ""), (0...8).contains(i), let s = o.kid("startOverride")?.attr("val").flatMap(Int.init) { starts[i] = OOXMLValue.clamp(s, 0, 32767) }
            }
            nums[id] = (a, starts)
        }
    }

    private func loadSettings() {
        guard let root = part((mainPart as NSString).deletingLastPathComponent + "/settings.xml") else { return }
        if let t = twips(root.kid("defaultTabStop")?.attr("val")), t > 0 { defaultTab = CGFloat(t) }
    }

    private func readSection(_ sect: XMLElement) {
        if let sz = sect.kid("pgSz"), let w = twips(sz.attr("w")), let h = twips(sz.attr("h")), w > 50, h > 50 {
            page.size = CGSize(width: w, height: h)
        }
        if let m = sect.kid("pgMar") {
            page.margins = NSEdgeInsets(top: CGFloat(abs(twips(m.attr("top")) ?? 72)), left: CGFloat(twips(m.attr("left") ?? m.attr("start")) ?? 72),
                                        bottom: CGFloat(abs(twips(m.attr("bottom")) ?? 72)), right: CGFloat(twips(m.attr("right") ?? m.attr("end")) ?? 72))
            page.headerDistance = CGFloat(twips(m.attr("header")) ?? 36)
            page.footerDistance = CGFloat(twips(m.attr("footer")) ?? 36)
        }
        if let g = sect.kid("docGrid"), let type = g.attr("type"), type == "lines" || type == "linesAndChars" || type == "snapToChars",
           let pitch = twips(g.attr("linePitch")), pitch > 4 {
            page.linePitch = CGFloat(pitch)
        }
    }

    // Header and footer

    private func loadHeaderFooter(_ sect: XMLElement) {
        func content(_ kind: String, _ type: String) -> NSAttributedString? {
            guard let ref = sect.kids(kind + "Reference").first(where: { ($0.attr("type") ?? "default") == type }),
                  let id = ref.attr("id"), let path = rels[id], let data = try? zip.data(path),
                  !OOXMLSAX.containsDoctype(data),
                  let doc = try? XMLDocument(data: DocxDocument.protectWhitespace(data), options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]),
                  let root = doc.rootElement() else { return nil }
            return headerFooterText(root)
        }
        var hf = DocxHeaderFooter(header: content("header", "default"), footer: content("footer", "default"),
                                  firstHeader: content("header", "first"), firstFooter: content("footer", "first"),
                                  differentFirstPage: onOff(sect.kid("titlePg")) ?? false,
                                  headerDistance: page.headerDistance, footerDistance: page.footerDistance)
        if !hf.differentFirstPage { hf.firstHeader = nil; hf.firstFooter = nil }
        if hf.header != nil || hf.footer != nil || hf.firstHeader != nil || hf.firstFooter != nil { headerFooter = hf }
    }

    private func headerFooterText(_ root: XMLElement) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func blocks(_ e: XMLElement) {
            for c in e.elementKids {
                switch c.localName {
                case "p": headerFooterParagraph(c, into: out)
                case "tbl": for p in c.descendants("p") { headerFooterParagraph(p, into: out) }
                case "sdt": if let content = c.kid("sdtContent") { blocks(content) }
                default: break
                }
            }
        }
        blocks(root)
        return out
    }

    /// One header/footer paragraph as plain text in light grey, keeping alignment, tab stops and run sizes.
    private func headerFooterParagraph(_ p: XMLElement, into out: NSMutableAttributedString) {
        let pPrEl = p.kid("pPr")
        let direct = pPrEl.map(pprops) ?? PProps()
        var (pp, pr) = resolvedP(direct.styleId)
        pp.apply(direct)
        var markR = pr
        if let r = pPrEl?.kid("rPr") { markR.apply(rprops(r)) }
        let grey = NSColor(white: 0.55, alpha: 1)
        let start = out.length

        var boxAlign: String?
        var instr = "", inField = false, inResult = false, fieldR = pr
        var buffered: [(String, RProps)] = []
        func add(_ text: String, _ r: RProps) {
            guard !text.isEmpty, !(inField && !inResult) else { return }
            if inField { buffered.append((text, r)); return }
            var a = attributes(r, eastAsian: text.unicodeScalars.contains { DocxDisplayFonts.isEastAsian($0) })
            a[.foregroundColor] = grey
            out.append(NSAttributedString(string: text, attributes: a))
        }
        func field(_ code: String, result: [(String, RProps)], _ r: RProps) {
            switch code.split(separator: " ").first?.uppercased() {
            case "PAGE": add(DocxHeaderFooter.pageToken, r)
            case "NUMPAGES", "SECTIONPAGES": add(DocxHeaderFooter.totalToken, r)
            default: for (t, rr) in result { add(t, rr) }
            }
        }
        func walk(_ e: XMLElement, _ base: RProps) {
            for c in e.elementKids {
                switch c.localName {
                case "r":
                    var r = base
                    if let rp = c.kid("rPr") { r.apply(rprops(rp)) }
                    for k in c.elementKids {
                        switch k.localName {
                        case "t", "delText": add(DocxDocument.restoreWhitespace(k.stringValue ?? ""), r)
                        case "tab": add("\t", r)
                        case "br", "cr": if k.attr("type") != "page" { add("\n", r) }
                        case "noBreakHyphen": add("-", r)
                        case "AlternateContent", "drawing", "pict":
                            // Text boxes (a page number is often one): their text joins the paragraph.
                            let box = k.localName == "AlternateContent" ? (k.kid("Choice") ?? k) : k
                            boxAlign = boxAlign ?? box.descendants("positionH").first?.kid("align")?.stringValue
                            for (n, bp) in box.descendants("txbxContent").flatMap({ $0.kids("p") }).enumerated() {
                                if n > 0 { add("\n", r) }
                                walk(bp, r)
                            }
                        case "instrText": instr += DocxDocument.restoreWhitespace(k.stringValue ?? "")
                        case "fldChar":
                            switch k.attr("fldCharType") {
                            case "begin": inField = true; inResult = false; instr = ""; buffered = []; fieldR = r
                            case "separate": inResult = true
                            case "end":
                                let code = instr, res = buffered
                                inField = false; inResult = false; instr = ""; buffered = []
                                field(code, result: res, fieldR)
                            default: break
                            }
                        default: break
                        }
                    }
                case "fldSimple":
                    var r = base
                    if let rp = c.kid("r")?.kid("rPr") { r.apply(rprops(rp)) }
                    let saved = (inField, inResult)
                    inField = true; inResult = true; buffered = []
                    walk(c, base)
                    let res = buffered
                    inField = saved.0; inResult = saved.1; buffered = []
                    field(c.attr("instr") ?? "", result: res, r)
                case "hyperlink", "smartTag", "ins", "customXml": walk(c, base)
                case "sdt": if let content = c.kid("sdtContent") { walk(content, base) }
                default: break
                }
            }
        }
        walk(p, pr)

        var markAttrs = attributes(markR, eastAsian: true)
        markAttrs[.foregroundColor] = grey
        out.append(NSAttributedString(string: "\n", attributes: markAttrs))

        let ps = NSMutableParagraphStyle()
        switch pp.jc {
        case "center": ps.alignment = .center
        case "right", "end": ps.alignment = .right
        default:
            // A framed page number (`w:framePr xAlign`) is placed by the frame, not by jc.
            switch pPrEl?.kid("framePr")?.attr("xAlign") ?? boxAlign {
            case "center": ps.alignment = .center
            case "right", "outside": ps.alignment = .right
            default: ps.alignment = .left
            }
        }
        ps.tabStops = (pp.tabs ?? []).compactMap { v, pos in
            switch v {
            case "center": return NSTextTab(textAlignment: .center, location: CGFloat(pos))
            case "right", "end": return NSTextTab(textAlignment: .right, location: CGFloat(pos))
            case "left", "start": return NSTextTab(textAlignment: .left, location: CGFloat(pos))
            default: return nil
            }
        }
        out.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: start, length: out.length - start))
    }

    // Properties

    private func rprops(_ e: XMLElement) -> RProps {
        var r = RProps()
        if let f = e.kid("rFonts") {
            r.ascii = f.attr("ascii") ?? f.attr("hAnsi"); r.eastAsia = f.attr("eastAsia")
            r.asciiTheme = f.attr("asciiTheme") ?? f.attr("hAnsiTheme"); r.eastAsiaTheme = f.attr("eastAsiaTheme")
            if f.attr("hint") == "eastAsia" { r.hintEastAsia = true }
        }
        if let s = e.kid("sz")?.attr("val").flatMap(OOXMLValue.double) { r.size = s / 2 }
        r.bold = onOff(e.kid("b")); r.italic = onOff(e.kid("i"))
        if let u = e.kid("u") { r.underline = (u.attr("val") ?? "single") != "none" }
        r.strike = onOff(e.kid("strike")) ?? onOff(e.kid("dstrike"))
        if let c = e.kid("color")?.attr("val"), c != "auto" { r.color = c }
        if let h = e.kid("highlight")?.attr("val"), h != "none" { r.highlight = h }
        if let s = e.kid("shd")?.attr("fill"), s != "auto" { r.shading = s }
        r.vertAlign = e.kid("vertAlign")?.attr("val")
        r.hidden = onOff(e.kid("vanish"))
        return r
    }

    private func pprops(_ e: XMLElement) -> PProps {
        var p = PProps()
        p.styleId = e.kid("pStyle")?.attr("val")
        p.jc = e.kid("jc")?.attr("val")
        if let s = e.kid("spacing") {
            p.before = twips(s.attr("before")); p.after = twips(s.attr("after"))
            p.beforeLines = s.attr("beforeLines").flatMap(OOXMLValue.double).map { $0 / 100 }
            p.afterLines = s.attr("afterLines").flatMap(OOXMLValue.double).map { $0 / 100 }
            p.beforeAuto = s.attr("beforeAutospacing").map { $0 != "0" && $0 != "false" }
            p.afterAuto = s.attr("afterAutospacing").map { $0 != "0" && $0 != "false" }
            p.line = s.attr("line").flatMap(OOXMLValue.double); p.lineRule = s.attr("lineRule")
        }
        if let i = e.kid("ind") {
            p.left = twips(i.attr("left") ?? i.attr("start")); p.right = twips(i.attr("right") ?? i.attr("end"))
            p.firstLine = twips(i.attr("firstLine")); p.hanging = twips(i.attr("hanging"))
            p.leftChars = (i.attr("leftChars") ?? i.attr("startChars")).flatMap(OOXMLValue.double).map { $0 / 100 }
            p.firstLineChars = i.attr("firstLineChars").flatMap(OOXMLValue.double).map { $0 / 100 }
            p.hangingChars = i.attr("hangingChars").flatMap(OOXMLValue.double).map { $0 / 100 }
        }
        if let n = e.kid("numPr") {
            p.numId = n.kid("numId")?.attr("val"); p.ilvl = n.kid("ilvl")?.attr("val").flatMap(Int.init)
        }
        if let b = e.kid("pBdr") {
            var edges: [String: DocxParagraphBorders.Edge] = [:]
            for k in b.elementKids {
                let name = ["start": "left", "end": "right"][k.localName ?? ""] ?? k.localName ?? ""
                guard ["top", "bottom", "left", "right", "between"].contains(name) else { continue }
                let v = k.attr("val") ?? "single"
                let none = v == "nil" || v == "none"
                let c = k.attr("color")
                edges[name] = .init(width: none ? 0 : CGFloat(max(2, k.attr("sz").flatMap(OOXMLValue.double) ?? 4)) / 8,
                                    space: CGFloat(k.attr("space").flatMap(OOXMLValue.double) ?? 0),
                                    color: c == nil || c == "auto" ? nil : c)
            }
            p.borders = edges
        }
        p.pageBreakBefore = onOff(e.kid("pageBreakBefore"))
        p.contextual = onOff(e.kid("contextualSpacing"))
        p.snapToGrid = onOff(e.kid("snapToGrid"))
        if let t = e.kid("tabs") {
            p.tabs = t.kids("tab").compactMap { tab in twips(tab.attr("pos")).map { (tab.attr("val") ?? "left", $0) } }
        }
        return p
    }

    private func styleChain(_ id: String?) -> [String] {
        var out: [String] = []
        var cur = id
        while let c = cur, let s = styles[c], !out.contains(c), out.count < 20 { out.insert(c, at: 0); cur = s.basedOn }
        return out
    }

    private func resolvedP(_ styleId: String?) -> (PProps, RProps) {
        var p = defaultsP, r = defaultsR
        for id in styleChain(styleId ?? defaultParagraphStyle) {
            p.apply(styles[id]!.p); r.apply(styles[id]!.r)
        }
        return (p, r)
    }

    private func fontName(_ r: RProps, eastAsian: Bool) -> String? {
        if eastAsian {
            if let n = r.eastAsia { return n }
            if let t = r.eastAsiaTheme { return t.hasPrefix("major") ? themeMajorEA : themeMinorEA }
            return themeMinorEA ?? r.ascii
        }
        if let n = r.ascii { return n }
        if let t = r.asciiTheme { return t.hasPrefix("major") ? themeMajorLatin : themeMinorLatin }
        return themeMinorLatin
    }

    private func color(_ hex: String?) -> NSColor? {
        guard let hex, hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private static let highlightColors: [String: String] = [
        "yellow": "FFFF00", "green": "00FF00", "cyan": "00FFFF", "magenta": "FF00FF", "blue": "0000FF", "red": "FF0000",
        "darkBlue": "000080", "darkCyan": "008080", "darkGreen": "008000", "darkMagenta": "800080", "darkRed": "800000",
        "darkYellow": "808000", "darkGray": "808080", "lightGray": "C0C0C0", "black": "000000", "white": "FFFFFF",
    ]

    /// Display attributes for text in the given script.
    private func attributes(_ r: RProps, eastAsian: Bool) -> [NSAttributedString.Key: Any] {
        var size = CGFloat(r.size ?? 10.5)
        var attrs: [NSAttributedString.Key: Any] = [:]
        if let v = r.vertAlign, v == "superscript" || v == "subscript" {
            attrs[.baselineOffset] = v == "superscript" ? size * 0.33 : -size * 0.15
            size *= 0.65
        }
        let requested = fontName(r, eastAsian: eastAsian)
        let font = DocxDisplayFonts.font(requested, size: size, bold: r.bold ?? false, italic: r.italic ?? false, eastAsian: eastAsian)
        attrs[.font] = font
        attrs[.docxLineHeight] = DocxDisplayFonts.wordLineHeight(requested: requested, font: font, eastAsian: eastAsian)
        attrs[.foregroundColor] = color(r.color) ?? NSColor.black
        if r.underline == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if r.strike == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let h = r.highlight.flatMap({ Self.highlightColors[$0] }) ?? r.shading, let c = color(h) { attrs[.backgroundColor] = c }
        return attrs
    }

    // Blocks

    private func block(_ e: XMLElement, cell: DocxCellBlock?) {
        switch e.localName {
        case "p": paragraph(e, cell: cell)
        case "tbl":
            if cell != nil { flattenTable(e, cell: cell) } else { table(e) }
        case "sdt":
            for c in e.kid("sdtContent")?.elementKids ?? [] { block(c, cell: cell) }
        case "sectPr", "bookmarkStart", "bookmarkEnd", "proofErr", "permStart", "permEnd", "commentRangeStart", "commentRangeEnd":
            break
        case "customXml":
            for c in e.elementKids { block(c, cell: cell) }
        default:
            // Unknown block (altChunk, etc.): keep it as a labelled placeholder paragraph.
            let ps = NSMutableParagraphStyle()
            if let cell { ps.textBlocks = [cell] }
            let att = DocxOpaqueAttachment.make(xml: e.xmlString(options: .nodeCompactEmptyElement), label: "…", size: 10)
            let s = NSMutableAttributedString(attachment: att)
            s.append(NSAttributedString(string: "\n"))
            s.addAttributes([.paragraphStyle: ps, .docxPPr: "", .docxRaw: e.xmlString(options: .nodeCompactEmptyElement)], range: NSRange(location: 0, length: s.length))
            result.append(s)
        }
    }

    private func paragraph(_ p: XMLElement, cell: DocxCellBlock?) {
        let pPrEl = p.kid("pPr")
        let direct = pPrEl.map(pprops) ?? PProps()
        var (pp, pr) = resolvedP(direct.styleId)
        // Numbering: level properties sit between the style and direct formatting.
        let numId = direct.numId ?? pp.numId
        let ilvl = OOXMLValue.clamp(direct.ilvl ?? pp.ilvl ?? 0, 0, 8)
        var level: (start: Int, fmt: String, text: String, p: PProps, r: RProps, suff: String)?
        if let numId, numId != "0", let n = nums[numId], let lv = abstractLevels[n.abstract]?[ilvl] {
            level = lv
            pp.apply(lv.p)
        }
        pp.apply(direct)
        var markR = pr
        if let r = pPrEl?.kid("rPr") { markR.apply(rprops(r)) }

        let start = result.length
        if pp.pageBreakBefore == true, cell == nil, start > 0 {
            result.append(NSAttributedString(string: "\u{0C}", attributes: [.docxSynthetic: true, .font: NSFont.systemFont(ofSize: 1)]))
        }

        // List marker.
        if let lv = level, let numId {
            var c = counters[numId] ?? Array(repeating: 0, count: 9)
            let starts = nums[numId]?.starts ?? [:]
            if c[ilvl] == 0 { c[ilvl] = (starts[ilvl] ?? lv.start) - 1 }
            c[ilvl] += 1
            for deeper in (ilvl + 1)..<9 { c[deeper] = 0 }
            counters[numId] = c
            var text = lv.text
            for k in 0...ilvl {
                let lvK = abstractLevels[nums[numId]!.abstract]?[k]
                let value = k == ilvl ? c[k] : max(c[k], lvK?.start ?? 1)
                text = text.replacingOccurrences(of: "%\(k + 1)", with: Self.format(value, lvK?.fmt ?? "decimal"))
            }
            if lv.fmt == "bullet" { text = Self.bullet(text) }
            var mr = pr; mr.apply(lv.r)
            let suffix = lv.suff == "space" ? " " : lv.suff == "nothing" ? "" : "\t"
            var attrs = attributes(mr, eastAsian: text.unicodeScalars.contains { DocxDisplayFonts.isEastAsian($0) })
            attrs[.docxSynthetic] = true
            result.append(NSAttributedString(string: text + suffix, attributes: attrs))
        }

        // Runs.
        for child in p.elementKids { inline(child, base: pr, linkID: nil, paraSize: CGFloat(pr.size ?? 10.5)) }

        // Paragraph mark.
        var markAttrs = attributes(markR, eastAsian: true)
        markAttrs[.docxRPr] = ""
        result.append(NSAttributedString(string: "\n", attributes: markAttrs))

        let range = NSRange(location: start, length: result.length - start)
        let ps = paragraphStyle(pp, runsIn: range, cell: cell)

        // Contextual spacing between paragraphs of the same style.
        let styleId = direct.styleId ?? defaultParagraphStyle
        if pp.contextual == true, prevContextual, styleId == prevStyleId, let prev = prevRange, cell == nil,
           let prevStyle = result.attribute(.paragraphStyle, at: prev.location, effectiveRange: nil) as? NSParagraphStyle,
           let m = prevStyle.mutableCopy() as? NSMutableParagraphStyle {
            m.paragraphSpacing = 0
            result.addAttribute(.paragraphStyle, value: m, range: prev)
            ps.paragraphSpacingBefore = 0
        }
        result.addAttributes([.paragraphStyle: ps, .docxPPr: pPrEl?.xmlString(options: .nodeCompactEmptyElement) ?? ""], range: range)
        if cell == nil, let b = pp.borders?.filter({ $0.value.width > 0 }), !b.isEmpty {
            result.addAttribute(.docxBorders, value: DocxParagraphBorders(top: b["top"], bottom: b["bottom"], left: b["left"], right: b["right"], between: b["between"]), range: range)
        }
        prevStyleId = styleId; prevContextual = pp.contextual == true; prevRange = cell == nil ? range : nil
    }

    private func paragraphStyle(_ pp: PProps, runsIn range: NSRange, cell: DocxCellBlock?) -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        switch pp.jc {
        case "center": ps.alignment = .center
        case "right", "end": ps.alignment = .right
        case "both", "distribute", "thaiDistribute", "lowKashida", "mediumKashida", "highKashida": ps.alignment = .justified
        default: ps.alignment = .left
        }
        // Largest font on the paragraph decides indents in character units; the tallest run decides line height.
        var largest: NSFont?
        var natural: CGFloat = 0
        result.enumerateAttributes(in: range) { a, _, _ in
            // Placeholders use a 1 pt font; ignore them.
            guard let f = a[.font] as? NSFont, f.pointSize > 2 else { return }
            if f.pointSize > (largest?.pointSize ?? 0) { largest = f }
            natural = max(natural, (a[.docxLineHeight] as? CGFloat) ?? DocxDisplayFonts.wordLineHeight(requested: nil, font: f, eastAsian: false))
        }
        let maxFont = largest ?? DocxDisplayFonts.font(nil, size: 10.5, bold: false, italic: false, eastAsian: true)
        if natural == 0 { natural = DocxDisplayFonts.wordLineHeight(requested: nil, font: maxFont, eastAsian: true) }
        let charWidth = maxFont.pointSize
        let left = CGFloat(pp.leftChars.map { $0 * Double(charWidth) } ?? pp.left ?? 0)
        var first = left
        if let h = pp.hangingChars.map({ $0 * Double(charWidth) }) ?? pp.hanging { first = left - CGFloat(h) }
        else if let f = pp.firstLineChars.map({ $0 * Double(charWidth) }) ?? pp.firstLine { first = left + CGFloat(f) }
        ps.headIndent = max(0, left)
        ps.firstLineHeadIndent = max(0, first)
        ps.tailIndent = -CGFloat(pp.right ?? 0)

        let pitch = page.linePitch
        let lineUnit = pitch ?? 12
        ps.paragraphSpacingBefore = CGFloat(pp.beforeLines.map { $0 * Double(lineUnit) } ?? pp.before ?? (pp.beforeAuto == true ? 14 : 0))
        ps.paragraphSpacing = CGFloat(pp.afterLines.map { $0 * Double(lineUnit) } ?? pp.after ?? (pp.afterAuto == true ? 14 : 0))

        // The editor lays out without font leading, so every line is exactly as tall as set here; a run larger
        // than that still grows its line (maximum stays open) instead of overlapping.
        switch pp.lineRule ?? "auto" {
        case "exact":
            if let l = pp.line { ps.minimumLineHeight = CGFloat(l / 20); ps.maximumLineHeight = CGFloat(l / 20) }
        case "atLeast":
            ps.minimumLineHeight = max(CGFloat((pp.line ?? 0) / 20), natural)
        default:
            let mult = CGFloat((pp.line ?? 240) / 240)
            if let pitch, pp.snapToGrid != false, cell == nil {
                // Word snaps each line to the document grid: as many grid lines as the text needs.
                let lines = max(1, ceil(natural / pitch - 0.02))
                ps.minimumLineHeight = (lines * pitch * mult).rounded()
            } else {
                ps.minimumLineHeight = (natural * mult).rounded()
            }
        }
        var tabs: [NSTextTab] = []
        for (kind, pos) in pp.tabs ?? [] where kind != "clear" {
            let align: NSTextAlignment = kind == "center" ? .center : (kind == "right" || kind == "end") ? .right : .left
            tabs.append(NSTextTab(textAlignment: align, location: CGFloat(pos)))
        }
        if pp.numId != nil, ps.headIndent > 0 { tabs.append(NSTextTab(textAlignment: .left, location: ps.headIndent)) }
        ps.tabStops = tabs.sorted { $0.location < $1.location }
        ps.defaultTabInterval = defaultTab
        if let cell { ps.textBlocks = [cell] }
        return ps
    }

    private func inline(_ e: XMLElement, base: RProps, linkID: String?, paraSize: CGFloat) {
        switch e.localName {
        case "r": run(e, base: base, linkID: linkID)
        case "hyperlink":
            let id = e.attr("id")
            for c in e.elementKids { inline(c, base: base, linkID: id, paraSize: paraSize) }
        case "ins", "smartTag", "customXml":
            for c in e.elementKids { inline(c, base: base, linkID: linkID, paraSize: paraSize) }
        case "pPr", "del", "moveFrom":
            break
        case "oMath", "oMathPara":
            appendOpaque(e.xmlString(options: .nodeCompactEmptyElement), label: "数式", size: paraSize)
        case "sdt", "fldSimple":
            // Inline content controls and simple fields: show their text, keep the element intact.
            let text = DocxDocument.restoreWhitespace(e.descendants("t").compactMap(\.stringValue).joined())
            if text.isEmpty { appendInvisible(e.xmlString(options: .nodeCompactEmptyElement)) } else { appendOpaque(e.xmlString(options: .nodeCompactEmptyElement), label: text, size: paraSize) }
        default:
            appendInvisible(e.xmlString(options: .nodeCompactEmptyElement))
        }
    }

    private func appendInvisible(_ xml: String) {
        result.append(NSAttributedString(string: "\u{200B}", attributes: [.docxRaw: xml, .font: NSFont.systemFont(ofSize: 1)]))
    }

    private func appendImage(_ att: DocxImageAttachment, runXML: String) {
        att.runXML = runXML
        let s = NSMutableAttributedString(attachment: att)
        s.addAttribute(.docxRaw, value: runXML, range: NSRange(location: 0, length: s.length))
        result.append(s)
    }

    private func appendOpaque(_ xml: String, label: String, size: CGFloat) {
        let att = DocxOpaqueAttachment.make(xml: xml, label: label, size: size)
        let s = NSMutableAttributedString(attachment: att)
        s.addAttribute(.docxRaw, value: xml, range: NSRange(location: 0, length: s.length))
        result.append(s)
    }

    private static let plainRunChildren: Set<String> = ["rPr", "t", "tab", "br", "cr", "noBreakHyphen", "softHyphen", "lastRenderedPageBreak", "sym", "drawing"]

    private func run(_ r: XMLElement, base: RProps, linkID: String?) {
        let rPrEl = r.kid("rPr")
        let direct = rPrEl.map(rprops) ?? RProps()
        var props = base
        if let rs = rPrEl?.kid("rStyle")?.attr("val") { for id in styleChain(rs) { props.apply(styles[id]!.r) } }
        props.apply(direct)
        let kids = r.elementKids
        // Runs carrying fields, notes, objects... are kept whole.
        if kids.contains(where: { !Self.plainRunChildren.contains($0.localName ?? "") }) || props.hidden == true {
            if props.hidden != true, let draw = r.descendants("drawing").first, let att = image(draw) {
                appendImage(att, runXML: r.xmlString(options: .nodeCompactEmptyElement))
                return
            }
            let t = DocxDocument.restoreWhitespace(r.descendants("t").compactMap(\.stringValue).joined())
            if t.isEmpty || props.hidden == true { appendInvisible(r.xmlString(options: .nodeCompactEmptyElement)) } else { appendOpaque(r.xmlString(options: .nodeCompactEmptyElement), label: t, size: CGFloat(props.size ?? 10.5)) }
            return
        }
        let rPrXML = rPrEl?.xmlString(options: .nodeCompactEmptyElement) ?? ""
        for k in kids {
            switch k.localName {
            case "t": appendText(DocxDocument.restoreWhitespace(k.stringValue ?? ""), props: props, rPr: rPrXML, linkID: linkID)
            case "tab": appendText("\t", props: props, rPr: rPrXML, linkID: linkID)
            case "br", "cr":
                if k.attr("type") == "page" { appendText("\u{0C}", props: props, rPr: rPrXML, linkID: linkID) }
                else if k.attr("type") == "column" { appendText("\u{2028}", props: props, rPr: rPrXML, linkID: linkID) }
                else { appendText("\u{2028}", props: props, rPr: rPrXML, linkID: linkID) }
            case "noBreakHyphen": appendText("\u{2011}", props: props, rPr: rPrXML, linkID: linkID)
            case "softHyphen": appendText("\u{00AD}", props: props, rPr: rPrXML, linkID: linkID)
            case "sym":
                if let c = k.attr("char"), let v = UInt32(c, radix: 16) {
                    let scalar = v >= 0xF000 ? (v - 0xF000) : v
                    let mapped = Self.symbolMap[scalar] ?? Unicode.Scalar(scalar).map { String(Character($0)) } ?? "•"
                    appendText(mapped, props: props, rPr: rPrXML, linkID: linkID, raw: r.xmlString(options: .nodeCompactEmptyElement))
                    return
                }
            case "drawing":
                if let att = image(k) {
                    appendImage(att, runXML: r.xmlString(options: .nodeCompactEmptyElement))
                    return
                } else {
                    appendOpaque(r.xmlString(options: .nodeCompactEmptyElement), label: "図形", size: CGFloat(props.size ?? 10.5))
                    return
                }
            default: break
            }
        }
    }

    private static let symbolMap: [UInt32: String] = [0xB7: "•", 0xA7: "▪", 0x6C: "●", 0x6E: "■", 0xD8: "➢", 0x76: "❖", 0xFC: "✓", 0xA8: "◆", 0x71: "❑"]

    private func appendText(_ text: String, props: RProps, rPr: String, linkID: String?, raw: String? = nil) {
        guard !text.isEmpty else { return }
        // Split into Latin / East Asian pieces: Word draws them with different fonts.
        var pieces: [(String, Bool)] = []
        for ch in text.unicodeScalars {
            var ea = DocxDisplayFonts.isEastAsian(ch)
            if !ea, props.hintEastAsia == true, DocxDisplayFonts.isAmbiguous(ch) { ea = true }
            if let last = pieces.last, last.1 == ea { pieces[pieces.count - 1].0.unicodeScalars.append(ch) } else { pieces.append((String(ch), ea)) }
        }
        for (s, ea) in pieces {
            var attrs = attributes(props, eastAsian: ea)
            attrs[.docxRPr] = rPr
            if let linkID {
                attrs[.docxLinkID] = linkID
                if let t = linkTargets[linkID], let u = LinkPolicy.openableURL(t) { attrs[.link] = u }
            }
            if let raw { attrs[.docxRaw] = raw }
            attrs[.docxRSig] = DocxDocument.runSignature(attrs)
            result.append(NSAttributedString(string: s, attributes: attrs))
        }
    }

    private func image(_ drawing: XMLElement) -> DocxImageAttachment? {
        guard let blip = drawing.descendants("blip").first, let rid = blip.attr("embed"), let path = rels[rid],
              let data = try? zip.data(path), OfficeImage.withinLimits(data), let img = NSImage(data: data) else { return nil }
        let ext = drawing.descendants("extent").first
        // A drawing is never larger than a few thousand points; absurd extents are clamped so saving can't overflow.
        let w = min(max(ext?.attr("cx").flatMap(OOXMLValue.double).map { $0 / 12700 } ?? Double(img.size.width), 0), 100_000)
        let h = min(max(ext?.attr("cy").flatMap(OOXMLValue.double).map { $0 / 12700 } ?? Double(img.size.height), 0), 100_000)
        let att = DocxImageAttachment()
        att.image = img
        att.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        return att
    }

    // Tables

    private func table(_ t: XMLElement) {
        let grid = t.kid("tblGrid")?.kids("gridCol").map { CGFloat(twips($0.attr("w")) ?? 50) } ?? []
        let table = DocxTable()
        table.tblPr = t.kid("tblPr")?.xmlString(options: .nodeCompactEmptyElement)
        table.tblGrid = t.kid("tblGrid")?.xmlString(options: .nodeCompactEmptyElement)
        table.numberOfColumns = max(1, grid.count)
        table.collapsesBorders = true
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        if grid.reduce(0, +) > 0 { table.setContentWidth(grid.reduce(0, +), type: .absoluteValueType) }
        let styleId = t.kid("tblPr")?.kid("tblStyle")?.attr("val")
        let styleName = styleId.flatMap { styles[$0]?.name.lowercased() } ?? ""
        let borders = (t.kid("tblPr")?.kid("tblBorders")?.elementKids.contains { ($0.attr("val") ?? "nil") != "nil" && $0.attr("val") != "none" } ?? false)
            || styleName.contains("grid") || styleName.contains("格子")
        for (r, tr) in t.kids("tr").enumerated() {
            if let trPr = tr.kid("trPr") { table.rowPr[r] = trPr.xmlString(options: .nodeCompactEmptyElement) }
            var col = 0
            for tc in tr.kids("tc") {
                let span = OOXMLValue.clamp(Int(tc.kid("tcPr")?.kid("gridSpan")?.attr("val") ?? "1") ?? 1, 1, 63)
                let cellBlock = DocxCellBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: min(col, table.numberOfColumns - 1), columnSpan: max(1, span))
                cellBlock.tcPr = tc.kid("tcPr")?.xmlString(options: .nodeCompactEmptyElement)
                let width = grid.isEmpty ? 0 : grid[min(col, grid.count - 1)..<min(col + span, grid.count)].reduce(0, +)
                if width > 0 { cellBlock.setValue(width, type: .absoluteValueType, for: .width) }
                cellBlock.setWidth(5.4, type: .absoluteValueType, for: .padding, edge: .minX)
                cellBlock.setWidth(5.4, type: .absoluteValueType, for: .padding, edge: .maxX)
                cellBlock.setWidth(1, type: .absoluteValueType, for: .padding, edge: .minY)
                cellBlock.setWidth(1, type: .absoluteValueType, for: .padding, edge: .maxY)
                if borders {
                    cellBlock.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cellBlock.setBorderColor(.black)
                }
                if let fill = tc.kid("tcPr")?.kid("shd")?.attr("fill"), let c = color(fill) { cellBlock.backgroundColor = c }
                let before = result.length
                for c in tc.elementKids where c.localName != "tcPr" { self.block(c, cell: cellBlock) }
                if result.length == before { // a cell must hold a paragraph
                    let ps = NSMutableParagraphStyle(); ps.textBlocks = [cellBlock]
                    result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: ps, .docxPPr: ""]))
                }
                col += span
            }
        }
    }

    /// Tables nested in a cell are shown as plain paragraphs of their text (written back as such).
    private func flattenTable(_ t: XMLElement, cell: DocxCellBlock?) {
        for p in t.descendants("p") { paragraph(p, cell: cell) }
    }

    private func finishParagraphSignatures() {
        let ns = result.string as NSString
        var loc = 0
        while loc < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let ps = result.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
            result.addAttribute(.docxPSig, value: DocxDocument.paragraphSignature(ps), range: r)
            loc = NSMaxRange(r)
            if r.length == 0 { break }
        }
    }

    // Number formats

    static func format(_ n: Int, _ fmt: String) -> String {
        switch fmt {
        case "decimalZero": return String(format: "%02d", n)
        case "upperRoman": return roman(n)
        case "lowerRoman": return roman(n).lowercased()
        case "upperLetter": return letters(n)
        case "lowerLetter": return letters(n).lowercased()
        case "decimalFullWidth", "decimalFullWidth2":
            return String(String(n).unicodeScalars.map { Character(Unicode.Scalar($0.value + 0xFEE0)!) })
        case "decimalEnclosedCircle", "decimalEnclosedCircleChinese":
            if (1...20).contains(n) { return String(Character(Unicode.Scalar(0x2460 + UInt32(n) - 1)!)) }
            return String(n)
        case "aiueoFullWidth", "aiueo":
            let k = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン")
            return n >= 1 && n <= k.count ? String(k[n - 1]) : String(n)
        case "iroha", "irohaFullWidth":
            let k = Array("イロハニホヘトチリヌルヲワカヨタレソツネナラムウヰノオクヤマケフコエテアサキユメミシヱヒモセス")
            return n >= 1 && n <= k.count ? String(k[n - 1]) : String(n)
        case "ideographDigital", "japaneseCounting", "japaneseDigitalTenThousand", "chineseCounting", "chineseCountingThousand":
            return kanji(n)
        case "none": return ""
        default: return String(n)
        }
    }

    static func roman(_ n: Int) -> String {
        guard n > 0, n < 4000 else { return String(n) }
        let v = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var x = n, s = ""
        for (k, r) in v { while x >= k { s += r; x -= k } }
        return s
    }

    static func letters(_ n: Int) -> String {
        guard n > 0 else { return "" }
        let c = Character(Unicode.Scalar(65 + (n - 1) % 26)!)
        return String(repeating: c, count: (n - 1) / 26 + 1)
    }

    static func kanji(_ n: Int) -> String {
        let d = Array("〇一二三四五六七八九")
        if n < 10 { return String(d[max(0, n)]) }
        if n < 100 { return (n / 10 == 1 ? "" : String(d[n / 10])) + "十" + (n % 10 == 0 ? "" : String(d[n % 10])) }
        return String(n)
    }

    static func bullet(_ text: String) -> String {
        var out = ""
        for s in text.unicodeScalars {
            if (0xF000...0xF0FF).contains(s.value) { out += symbolMap[s.value - 0xF000] ?? "•" }
            else if s == "o" { out += "◦" }
            else { out.unicodeScalars.append(s) }
        }
        return out.isEmpty ? "•" : out
    }
}
