import Foundation
import EnsoShared

/// Decides where results go: next to the input, never overwriting an existing file.
public enum OutputNamer {

    /// "name.ext", or "name (tag).ext" when a tag is given; numbered "name 2.ext" if taken.
    public static func file(for input: URL, ext: String, tag: String? = nil, baseName: String? = nil) -> URL {
        let dir = input.deletingLastPathComponent()
        var base = baseName ?? input.deletingPathExtension().lastPathComponent
        if let tag { base += " (\(tag))" }
        return unique(dir.appendingPathComponent(base).appendingPathExtension(ext))
    }

    public static func folder(for input: URL, tag: String) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + " (\(tag))"
        return unique(dir.appendingPathComponent(base, isDirectory: true), isDirectory: true)
    }

    /// Finder-style numbering: "Report.pdf" -> "Report 2.pdf" -> "Report 3.pdf".
    /// Folders are numbered on the whole name (a dot in a folder name is not an extension).
    public static func unique(_ url: URL, isDirectory: Bool = false) -> URL {
        if !exists(url) { return url }
        let dir = url.deletingLastPathComponent()
        let ext = isDirectory ? "" : url.pathExtension
        let base = isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)", isDirectory: isDirectory)
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// True when something is at `url`, a dangling symlink included (lstat does not follow links).
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// True when `url` is a real directory and not a symlink to one.
    public static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// "name-01.png" style names inside an output folder.
    public static func numbered(_ base: String, index: Int, count: Int, ext: String) -> String {
        let width = max(2, String(count).count)
        return "\(base)-\(String(format: "%0\(width)d", index)).\(ext)"
    }
}

/// Writes that replace a file in place keep a copy of the original so the HUD can offer "Undo".
public enum SafeWrite {

    public struct Backup: Sendable {
        public let original: URL
        public let saved: URL
    }

    static var backupRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("app.marudoc.MaruDoc/Backups", isDirectory: true)
    }

    /// Calls `write` with a temporary URL in the same folder, then swaps it in for `url`.
    /// If anything throws, the original is untouched.
    @discardableResult
    public static func replace(_ url: URL, write: (URL) throws -> Void) throws -> Backup {
        let fm = FileManager.default
        let dir = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = dir.appendingPathComponent(url.lastPathComponent)
        try fm.copyItem(at: url, to: saved)

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".marudoc-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try write(tmp)
            // Keep the original's permissions (temporary files are created owner-only).
            if let perms = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
            }
            _ = try fm.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return Backup(original: url, saved: saved)
    }

    /// Removes a backup right away (editor saves: the user chose to replace the file, and a redacted original
    /// must not linger in the cache).
    public static func discard(_ backup: Backup) {
        try? FileManager.default.removeItem(at: backup.saved.deletingLastPathComponent())
    }

    public static func restore(_ backup: Backup) throws {
        let fm = FileManager.default
        let tmp = backup.original.deletingLastPathComponent().appendingPathComponent(".marudoc-restore-\(UUID().uuidString).\(backup.original.pathExtension)")
        try fm.copyItem(at: backup.saved, to: tmp)
        _ = try fm.replaceItemAt(backup.original, withItemAt: tmp)
    }

    /// Drops backups older than a day.
    public static func pruneOldBackups() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for item in items {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if created < cutoff { try? fm.removeItem(at: item) }
        }
    }
}
