import Cocoa
import Security
import FinderSync
import os
import EnsoShared

// Finder loads this class from the .appex (see NSExtensionPrincipalClass in its Info.plist).
// The binary is linked with `-e _NSExtensionMain`, so there is no Swift entry point here.

@objc(EnsoFinderSyncExtension)
final class EnsoFinderSyncExtension: FIFinderSync {

    override init() {
        super.init()
        updateWatchedVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func volumesChanged(_ note: Notification) { updateWatchedVolumes() }

    private func updateWatchedVolumes() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            urls.insert(v)
        }
        FIFinderSyncController.default().directoryURLs = urls
    }

    // MARK: Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return nil }
        let nodes = ActionCatalog.menu(for: urls)
        guard !nodes.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        let root = NSMenuItem(title: "MaruDoc", action: nil, keyEquivalent: "")
        root.image = Self.symbol("circle.circle")
        let sub = NSMenu(title: "MaruDoc")
        for node in nodes { sub.addItem(item(for: node)) }
        sub.addItem(.separator())
        let settings = NSMenuItem(title: L("MaruDoc の設定…"), action: #selector(runAction(_:)), keyEquivalent: "")
        settings.tag = ActionCatalog.tag(for: Act.openSettings)
        sub.addItem(settings)
        root.submenu = sub
        menu.addItem(root)
        return menu
    }

    private func item(for node: MenuNode) -> NSMenuItem {
        let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
        item.image = Self.symbol(node.symbol)
        if node.children.isEmpty {
            item.action = #selector(runAction(_:))
            item.tag = ActionCatalog.tag(for: node.action ?? "")
        } else {
            let sub = NSMenu(title: node.title)
            for child in node.children { sub.addItem(self.item(for: child)) }
            item.submenu = sub
        }
        return item
    }

    /// Finder copies menu items into its own process and draws template images dark on a dark menu,
    /// so symbols are tinted explicitly for the current appearance.
    private static func symbol(_ name: String) -> NSImage? {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let color = dark ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.22, alpha: 1)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let img = base.withSymbolConfiguration(config) else { return nil }
        img.isTemplate = false
        return img
    }

    @objc func runAction(_ sender: NSMenuItem) {
        guard let action = ActionCatalog.action(forTag: sender.tag) else { return }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        let request = Bridge.Request(action: action, files: urls, mouse: NSEvent.mouseLocation, token: Bridge.storedToken())
        guard let url = Bridge.url(for: request) else { return }
        // Hand the request to the app this extension is embedded in, never to another copy or whatever claims the scheme.
        guard let app = Self.containingApp() else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = Act.isEditor(action) || action == Act.openSettings
        config.addsToRecentItems = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config, completionHandler: nil)
    }

    /// MaruDoc.app/Contents/PlugIns/MaruDocFinder.appex -> MaruDoc.app, accepted only when it is MaruDoc with a valid
    /// signature whose team identifier equals this extension's. The team is compared through the signing information
    /// rather than a certificate requirement, because Mac App Store apps are re-signed by Apple and their leaf
    /// certificate no longer carries the developer's team in subject.OU. An extension without a team id (ad-hoc /
    /// self-signed dev build) cannot pin a team, so there only the bundle identifier and a valid signature are required.
    private static func containingApp() -> URL? {
        var app = Bundle.main.bundleURL
        for _ in 0..<3 { app.deleteLastPathComponent() }
        guard app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == Bridge.appBundleID else { return nil }

        let key = verificationKey(for: app)
        if let key, verified.withLock({ $0 }) == key { return app }

        let team = ownTeamID()
        var requirement: SecRequirement?
        if team != nil {
            guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess else { return nil }
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return nil }
        if let team {
            guard team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
                  teamID(of: code) == team else { return nil }
        }
        if let key { verified.withLock { $0 = key } }
        return app
    }

    /// App path plus the executable's modification date. A successful verification is remembered for this key only,
    /// so replacing the app (update, tampering) forces a new validation.
    private struct VerificationKey: Equatable { let path: String; let modified: Date }
    private static let verified = OSAllocatedUnfairLock<VerificationKey?>(initialState: nil)

    private static func verificationKey(for app: URL) -> VerificationKey? {
        guard let exe = Bundle(url: app)?.executableURL,
              let date = try? exe.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return VerificationKey(path: app.path, modified: date)
    }

    private static func teamID(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func ownTeamID() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
