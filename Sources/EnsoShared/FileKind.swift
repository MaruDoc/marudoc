import Foundation
import UniformTypeIdentifiers

/// What kind of document a file is, as far as MaruDoc's menus are concerned.
public enum FileKind: String, CaseIterable, Sendable {
    case pdf
    case image
    case word        // .docx .doc .odt
    case rtf         // .rtf .rtfd
    case markdown    // .md .markdown
    case text        // .txt and other plain text
    case html
    case spreadsheet // .xlsx
    case csv         // .csv .tsv
    case presentation // .pptx
    case other

    public static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif", "jp2", "psd", "tga":
            return .image
        case "docx", "doc", "odt", "docm", "dotx": return .word
        case "rtf", "rtfd": return .rtf
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "txt", "text", "log": return .text
        case "html", "htm", "xhtml": return .html
        case "xlsx", "xlsm": return .spreadsheet
        case "csv", "tsv": return .csv
        case "pptx": return .presentation
        default: break
        }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .html) { return .html }
            if type.conforms(to: .rtf) { return .rtf }
            if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { return .text }
        }
        return .other
    }

    /// Kinds that can be laid out as pages (and therefore turned into PDF / images).
    public var isDocumentLike: Bool {
        switch self {
        case .word, .rtf, .markdown, .text, .html, .spreadsheet, .csv, .presentation: return true
        default: return false
        }
    }
}
