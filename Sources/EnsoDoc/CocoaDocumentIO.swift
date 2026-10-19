import AppKit

public enum DocIOError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case writeFailed(String)
    case encrypted

    public var errorDescription: String? {
        switch self {
        case .unreadable(let n): return isJa ? "「\(n)」を読み込めませんでした" : "Couldn't read “\(n)”"
        case .unsupported(let what): return isJa ? "この形式には対応していません (\(what))" : "This format isn't supported (\(what))"
        case .writeFailed(let n): return isJa ? "「\(n)」を書き出せませんでした" : "Couldn't write “\(n)”"
        case .encrypted: return isJa ? "パスワードで保護されています" : "The file is password protected"
        }
    }
    private var isJa: Bool { Locale.preferredLanguages.first?.hasPrefix("ja") == true }
}

/// Reading and writing through Cocoa's text system (RTF, RTFD, .doc, .odt, HTML, web archives, plain text).
/// HTML import uses WebKit internally, so these run on the main thread.
public enum CocoaDocumentIO {

    @MainActor
    public static func readAttributed(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch ext {
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "docx", "docm", "dotx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
        case "html", "htm", "xhtml":
            // Never through WebKit (it would fetch remote resources): parse ourselves.
            let model = try HTMLReader.model(from: Data(contentsOf: url), baseURL: url.deletingLastPathComponent())
            return AttributedConverter.attributedString(from: model, style: .init(bodySize: 13, contentWidth: 560))
        default: break
        }
        do {
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch {
            throw DocIOError.unreadable(url.lastPathComponent)
        }
    }

    @MainActor
    public static func readModel(_ url: URL) throws -> DocModel {
        let attr = try readAttributed(url)
        return AttributedConverter.model(from: attr, title: url.deletingPathExtension().lastPathComponent)
    }

    /// Writes .rtf, or .rtfd when the document contains images. Returns the URL actually written.
    @discardableResult
    public static func writeRTF(_ model: DocModel, to url: URL) throws -> URL {
        let attr = AttributedConverter.attributedString(from: model, style: .init(bodySize: CGFloat(model.bodyFontSize)))
        let range = NSRange(location: 0, length: attr.length)
        let hasImages = model.blocks.contains { if case .image = $0 { return true }; return false }
        if hasImages {
            var target = url.deletingPathExtension().appendingPathExtension("rtfd")
            if FileManager.default.fileExists(atPath: target.path) {
                // Same numbering as everywhere else: never replace an existing document.
                let base = target.deletingPathExtension().lastPathComponent
                var n = 2
                repeat {
                    target = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)").appendingPathExtension("rtfd")
                    n += 1
                } while FileManager.default.fileExists(atPath: target.path)
            }
            guard let wrapper = attr.rtfdFileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else {
                throw DocIOError.writeFailed(target.lastPathComponent)
            }
            try wrapper.write(to: target, options: .atomic, originalContentsURL: nil)
            return target
        }
        guard let data = attr.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
            throw DocIOError.writeFailed(url.lastPathComponent)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Writes an attributed string in the format implied by the extension (used by the rich-text editor).
    public static func write(_ attr: NSAttributedString, to url: URL) throws {
        let range = NSRange(location: 0, length: attr.length)
        let ext = url.pathExtension.lowercased()
        let type: NSAttributedString.DocumentType
        switch ext {
        case "rtf": type = .rtf
        case "rtfd":
            guard let w = attr.rtfdFileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else {
                throw DocIOError.writeFailed(url.lastPathComponent)
            }
            try w.write(to: url, options: .atomic, originalContentsURL: nil)
            return
        case "doc": type = .docFormat
        case "docx", "docm": type = .officeOpenXML
        case "odt": type = .openDocument
        case "html", "htm": type = .html
        case "txt", "text", "md", "markdown", "csv", "log":
            try attr.string.write(to: url, atomically: true, encoding: .utf8)
            return
        default: throw DocIOError.unsupported(ext)
        }
        let data = try attr.data(from: range, documentAttributes: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue])
        try data.write(to: url, options: .atomic)
    }
}
