import Foundation

/// Schemes a clickable link may use. Anything else (file:, smb:, custom app schemes) is kept in the file but not made clickable.
public enum LinkPolicy {
    public static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    public static func openableURL(_ raw: String) -> URL? {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), isOpenable(u) else { return nil }
        return u
    }

    /// Link targets that may be written to a file: http, https, mailto, a #fragment or a relative path. javascript:, data:, file: and the like are
    /// refused. Whitespace and control characters are removed first, as browsers ignore them inside a scheme.
    public static func safeHref(_ raw: String) -> String? {
        let s = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }))
        guard !s.isEmpty else { return nil }
        if let scheme = s.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) {
            return ["http:", "https:", "mailto:"].contains(s[scheme].lowercased()) ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isSafeHref(_ raw: String) -> Bool { safeHref(raw) != nil }

    public static func isOpenable(_ u: URL) -> Bool {
        guard let scheme = u.scheme?.lowercased() else { return false }
        return openableSchemes.contains(scheme)
    }
}
