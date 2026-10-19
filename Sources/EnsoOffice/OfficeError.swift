import Foundation

/// Errors thrown by the ZIP container and the Office readers / writers.
/// Messages are English; the app layer is expected to wrap them for display.
public enum OfficeError: Error, LocalizedError, Equatable {
    /// The file is not a ZIP archive at all.
    case notAZip(String)
    /// The file is an OLE compound document: a password-protected OOXML file or a legacy .doc/.xls/.ppt.
    case encryptedOrLegacyOffice
    /// The ZIP structure is damaged.
    case corruptZip(String)
    case unsupportedZipFeature(String)
    /// A required package part is missing.
    case missingPart(String)
    case malformedXML(part: String, detail: String)
    /// Structurally valid package whose content does not make sense.
    case invalidDocument(String)
    /// Exceeds a format limit (ZIP without ZIP64 support, Excel row/column limits, ...).
    case tooLarge(String)
    case invalidArgument(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip(let s): return "Not a valid Office file (no ZIP container): \(s)"
        case .encryptedOrLegacyOffice:
            return "This file is password-protected or uses the old binary Office format (.doc/.xls/.ppt), which is not supported."
        case .corruptZip(let s): return "The file is damaged (ZIP): \(s)"
        case .unsupportedZipFeature(let s): return "Unsupported ZIP feature: \(s)"
        case .missingPart(let s): return "The document is incomplete: missing \(s)"
        case .malformedXML(let part, let detail): return "The document is damaged: \(part) is not valid XML (\(detail))"
        case .invalidDocument(let s): return "The document is damaged: \(s)"
        case .tooLarge(let s): return "Too large: \(s)"
        case .invalidArgument(let s): return "Invalid input: \(s)"
        case .io(let s): return "File error: \(s)"
        }
    }
}

extension Data {
    /// Writes atomically and maps Foundation errors to `OfficeError.io`.
    func writeOffice(to url: URL) throws {
        do { try write(to: url, options: .atomic) } catch { throw OfficeError.io("\(url.lastPathComponent): \(error.localizedDescription)") }
    }

    static func readOffice(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw OfficeError.io("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
