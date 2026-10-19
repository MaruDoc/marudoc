import AppKit
import EnsoShared

/// The user's real home folder (inside the App Store sandbox, NSHomeDirectory() points at the container).
enum RealHome {
    static let url: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
}

/// App Store build only: files the Finder extension hands over are outside the sandbox, so the user grants a folder
/// (normally the home folder) once and MaruDoc keeps a security-scoped bookmark to it.
enum SandboxAccess {
    static var isSandboxed: Bool {
        #if APPSTORE
        return true
        #else
        return false
        #endif
    }
    private static let key = "grantedFolders"
    private static var active: [URL] = []

    static var hasAccess: Bool { !isSandboxed || !active.isEmpty }

    static func restore() {
        guard isSandboxed else { return }
        let stored = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        var fresh: [Data] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            active.append(url)
            if stale, let renewed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                fresh.append(renewed)
            } else { fresh.append(data) }
        }
        UserDefaults.standard.set(fresh, forKey: key)
    }

    static func requestFolder(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = RealHome.url
        panel.prompt = L("許可")
        panel.message = L("MaruDoc が変換・編集するファイルのあるフォルダを選んでください。ふつうはホームフォルダを選びます。")
        NSApp.activate()
        panel.begin { r in
            guard r == .OK, let url = panel.url,
                  let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                completion(false); return
            }
            var stored = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
            stored.append(data)
            UserDefaults.standard.set(stored, forKey: key)
            if url.startAccessingSecurityScopedResource() { active.append(url) }
            completion(true)
        }
    }
}
