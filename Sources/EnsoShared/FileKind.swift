import Foundation
import ImageIO
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
            // SVG and Illustrator files are "images" to the system, but nothing in MaruDoc can decode them,
            // so offering the image menu would only produce errors.
            if type.conforms(to: .image) { return isDecodableImage(type) ? .image : .other }
            if type.conforms(to: .html) { return .html }
            if type.conforms(to: .rtf) { return .rtf }
            if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { return .text }
        }
        return .other
    }

    /// Image types ImageIO can read.
    static let decodableImageTypes: [UTType] = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap { UTType($0) }

    static func isDecodableImage(_ type: UTType) -> Bool { decodableImageTypes.contains { type.conforms(to: $0) } }

    /// Image formats whose file can be rotated, flipped and cleaned of metadata in place without re-compressing or
    /// losing frames, pages or auxiliary images (see ImageOps.reorient / stripMetadata). WebP, RAW, JPEG 2000,
    /// Photoshop and others can only be converted.
    public static func supportsInPlaceEdit(_ url: URL) -> Bool {
        ["jpg", "jpeg", "jpe", "png", "heic", "heif", "hif", "avif", "tif", "tiff", "gif", "bmp", "tga", "ico"].contains(url.pathExtension.lowercased())
    }

    /// Kinds that can be laid out as pages (and therefore turned into PDF / images).
    public var isDocumentLike: Bool {
        switch self {
        case .word, .rtf, .markdown, .text, .html, .spreadsheet, .csv, .presentation: return true
        default: return false
        }
    }
}
