#if !APPSTORE
import AppKit
import EnsoShared

/// "Check for Updates… (Internet Required)" for the direct-download build.
///
/// This is the only place MaruDoc connects to the internet, and only when the user clicks the menu item. It reads
/// https://marudoc.app/version.json (a static file: the latest version, its date and notes) with a plain GET that
/// carries no file names, no settings and not even the running version, then compares on the Mac. Converting and
/// editing files never touch the network. The Mac App Store build has no such item: the store updates it, and its
/// sandbox has no network permission.
enum UpdateCheck {
    static let feed = URL(string: "https://marudoc.app/version.json")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var menuTitle: String { L("アップデートを確認… (ネット接続が必要)") }

    struct Latest: Decodable {
        let version: String
        let date: String?
        let page: String?
        let notes: [String]?
    }

    private static var running = false

    static func check() {
        guard !running else { return }
        running = true
        let config = URLSessionConfiguration.ephemeral   // no cookies, no cache on disk
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "MaruDoc"]
        var req = URLRequest(url: feed)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession(configuration: config).dataTask(with: req) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let latest = ok ? data.flatMap { try? JSONDecoder().decode(Latest.self, from: $0) } : nil
            DispatchQueue.main.async {
                running = false
                show(latest)
            }
        }.resume()
    }

    /// -1 when a is older than b.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
            if d != 0 { return d < 0 ? -1 : 1 }
        }
        return 0
    }

    private static func pageURL(_ latest: Latest?) -> URL? {
        var c = URLComponents(string: latest?.page ?? "https://marudoc.app/update/")
        c?.queryItems = [URLQueryItem(name: "v", value: version)]
        return c?.url
    }

    private static func show(_ latest: Latest?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard let latest else {
            alert.messageText = L("アップデートを確認できませんでした")
            alert.informativeText = L("インターネットに接続しているか確かめて、もう一度試してください。")
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: L("ブラウザで開く"))
            if alert.runModal() == .alertSecondButtonReturn, let u = pageURL(nil) { NSWorkspace.shared.open(u) }
            return
        }
        if compare(version, latest.version) >= 0 {
            alert.messageText = L("MaruDoc は最新です")
            alert.informativeText = String(format: L("お使いの版 %@ が最新です。"), version)
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.messageText = String(format: L("MaruDoc %@ があります"), latest.version)
        let notes = (latest.notes ?? []).prefix(5).map { "• " + $0 }.joined(separator: "\n")
        alert.informativeText = String(format: L("お使いの版は %@ です。"), version) + (notes.isEmpty ? "" : "\n\n" + notes)
        alert.addButton(withTitle: L("ダウンロード"))
        alert.addButton(withTitle: L("あとで"))
        if alert.runModal() == .alertFirstButtonReturn, let u = pageURL(latest) { NSWorkspace.shared.open(u) }
    }
}
#endif
