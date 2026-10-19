import Foundation

// Open Packaging Conventions: relationships, content types, core properties.

struct OPCRelationship {
    let id: String
    let type: String
    let target: String
    let external: Bool

    /// Relationship types differ between transitional and strict OOXML; compare the last path segment.
    func isType(_ suffix: String) -> Bool { type.hasSuffix("/" + suffix) }
}

enum RelType {
    static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let officeDocument = base + "officeDocument"
    static let extendedProps = base + "extended-properties"
    static let coreProps = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
    static let styles = base + "styles"
    static let numbering = base + "numbering"
    static let settings = base + "settings"
    static let fontTable = base + "fontTable"
    static let image = base + "image"
    static let hyperlink = base + "hyperlink"
    static let theme = base + "theme"
    static let worksheet = base + "worksheet"
    static let sharedStrings = base + "sharedStrings"
    static let slide = base + "slide"
    static let slideLayout = base + "slideLayout"
    static let slideMaster = base + "slideMaster"
    static let notesSlide = base + "notesSlide"
    static let notesMaster = base + "notesMaster"
    static let presProps = base + "presProps"
    static let viewProps = base + "viewProps"
    static let tableStyles = base + "tableStyles"
}

enum OPC {
    /// "word/document.xml" -> "word/_rels/document.xml.rels"; "" (package) -> "_rels/.rels".
    static func relsPath(for part: String) -> String {
        let p = ZipReader.normalize(part)
        if p.isEmpty { return "_rels/.rels" }
        let dir = (p as NSString).deletingLastPathComponent
        let file = (p as NSString).lastPathComponent
        return dir.isEmpty ? "_rels/\(file).rels" : "\(dir)/_rels/\(file).rels"
    }

    /// Relationships of a part; a missing .rels part simply means none.
    static func relationships(_ zip: ZipReader, for part: String) throws -> [OPCRelationship] {
        let path = relsPath(for: part)
        guard zip.contains(path) else { return [] }
        let root = try XNode.parse(try zip.data(path), part: path)
        return root.children.filter { $0.localName == "Relationship" }.compactMap { n in
            guard let id = n["Id"], let target = n["Target"] else { return nil }
            let external = n["TargetMode"]?.lowercased() == "external"
            return OPCRelationship(id: id, type: n["Type"] ?? "", target: external ? target : resolve(target, from: part), external: external)
        }
    }

    /// Resolves a relative part reference against the source part's folder.
    static func resolve(_ target: String, from part: String) -> String {
        var t = target.replacingOccurrences(of: "\\", with: "/")
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        var parts: [String]
        if t.hasPrefix("/") {
            parts = []
        } else {
            let dir = (ZipReader.normalize(part) as NSString).deletingLastPathComponent
            parts = dir.isEmpty ? [] : dir.split(separator: "/").map(String.init)
        }
        for seg in t.split(separator: "/") {
            switch seg {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(seg))
            }
        }
        return parts.joined(separator: "/")
    }

    /// The main document part (word/document.xml, xl/workbook.xml, ppt/presentation.xml).
    static func mainPart(_ zip: ZipReader, fallback: String) throws -> String {
        let rels = try relationships(zip, for: "")
        if let r = rels.first(where: { $0.isType("officeDocument") && !$0.external }), zip.contains(r.target) { return r.target }
        if zip.contains(fallback) { return fallback }
        throw OfficeError.missingPart(fallback)
    }

    /// dc:title from the core properties, if present and non-empty.
    static func coreTitle(_ zip: ZipReader) -> String? {
        let rels = (try? relationships(zip, for: "")) ?? []
        let path = rels.first(where: { $0.type.hasSuffix("/core-properties") })?.target ?? "docProps/core.xml"
        guard let data = try? zip.data(path), let root = try? XNode.parse(data, part: path) else { return nil }
        let t = root.child("dc:title")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    // MARK: Writing

    struct RelsBuilder {
        private(set) var items: [(id: String, type: String, target: String, external: Bool)] = []
        private var next = 1

        mutating func add(_ type: String, _ target: String, external: Bool = false) -> String {
            let id = "rId\(next)"
            next += 1
            items.append((id, type, target, external))
            return id
        }

        var xml: String {
            var s = xmlHeader + "<Relationships xmlns=\"\(NS.pr)\">"
            for r in items {
                s += "<Relationship Id=\"\(r.id)\" Type=\"\(r.type)\" Target=\"\(XMLEsc.attr(r.target))\""
                s += r.external ? " TargetMode=\"External\"/>" : "/>"
            }
            return s + "</Relationships>"
        }
    }

    static func contentTypes(defaults: [(String, String)], overrides: [(String, String)]) -> String {
        var s = xmlHeader + "<Types xmlns=\"\(NS.ct)\">"
        s += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        s += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        for (ext, type) in defaults { s += "<Default Extension=\"\(ext)\" ContentType=\"\(type)\"/>" }
        for (part, type) in overrides { s += "<Override PartName=\"/\(XMLEsc.attr(part))\" ContentType=\"\(type)\"/>" }
        return s + "</Types>"
    }

    static let coreContentType = "application/vnd.openxmlformats-package.core-properties+xml"
    static let appContentType = "application/vnd.openxmlformats-officedocument.extended-properties+xml"

    static func coreProperties(title: String?, date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: date)
        var s = xmlHeader + "<cp:coreProperties xmlns:cp=\"\(NS.cp)\" xmlns:dc=\"\(NS.dc)\" xmlns:dcterms=\"\(NS.dcterms)\" xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"\(NS.xsi)\">"
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { s += "<dc:title>\(XMLEsc.text(t))</dc:title>" }
        s += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>"
        s += "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:modified>"
        return s + "</cp:coreProperties>"
    }

    static func appProperties(extra: String = "") -> String {
        xmlHeader + "<Properties xmlns=\"\(NS.ep)\" xmlns:vt=\"\(NS.vt)\"><Application>MaruDoc</Application>\(extra)</Properties>"
    }

    /// Package-level relationships shared by all three formats.
    static func packageRels(main: String) -> String {
        var r = RelsBuilder()
        _ = r.add(RelType.officeDocument, main)
        _ = r.add(RelType.coreProps, "docProps/core.xml")
        _ = r.add(RelType.extendedProps, "docProps/app.xml")
        return r.xml
    }
}
