import AppKit
import EnsoShared
import EnsoCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    let runner = ActionRunner()
    let radial = RadialController()
    let monitor = PressMonitor()
    private var statusItem: NSStatusItem?
    private var trustTimer: Timer?
    private var tapFailed = false
    private var confirming = false
    /// Last seen value of the press-and-hold setting, to notice the user turning it on.
    private var lastPressEnabled = Settings.shared.pressEnabled

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        Bridge.prepareToken()
        Localization.register(AppStrings.en)
        Localization.register(AppStrings.enMore)
        Localization.register(AppStrings.enSaveMerge)
        Localization.register(AppStrings.enStatus)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched \(Bundle.main.bundlePath) \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")")
        SafeWrite.pruneOldBackups()
        SandboxAccess.restore()
        Warmup.run()
        wirePressMonitor()
        PermissionMonitor.shared.pressProbe = { [weak self] in self?.monitor.isActive ?? false }
        updateStatusItem()
        NotificationCenter.default.addObserver(forName: .ensoSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateStatusItem()
            self?.applyPressSettings()
        }
        applyPressSettings()
        // The welcome window opens on the first launch only (and when a sandboxed build has no folder access yet,
        // without which nothing works). It asks for nothing: each permission is requested when its feature is first
        // used, or when the user presses its button.
        if !Settings.shared.onboarded || (SandboxAccess.isSandboxed && !SandboxAccess.hasAccess) {
            SettingsWindowController.shared.show(tab: .welcome)
        }
    }

    /// Unsaved editors are offered before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = runner.editors.dirtyPanels
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(format: L("保存していない変更が %d 件あります"), dirty.count)
        alert.informativeText = L("終了すると、編集中の変更は失われます。")
        alert.addButton(withTitle: L("キャンセル"))
        alert.addButton(withTitle: L("保存せずに終了"))
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Opening the app again from Finder / Launchpad shows the settings window (the app has no Dock icon).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    // MARK: Long press

    private func wirePressMonitor() {
        monitor.onOpen = { [weak self] opened in self?.radial.open(opened) }
        monitor.onUpdate = { [weak self] hit, open, sticky, cancel in self?.radial.update(hit: hit, openParent: open, sticky: sticky, showsCancel: cancel) }
        monitor.onClose = { [weak self] in self?.radial.close() }
        monitor.onChoose = { [weak self] action, target in
            self?.runner.run(action, urls: target.urls, origin: .init(iconFrame: target.iconFrame, onDesktop: target.onDesktop, mouse: nil))
        }
        NotificationCenter.default.addObserver(forName: .ensoTapFailed, object: nil, queue: .main) { [weak self] _ in
            self?.tapFailed = true
            self?.updateStatusItem()
        }
    }

    private func applyPressSettings() {
        // Turning press-and-hold on is the moment to ask for Accessibility (never at launch, never while it stays on).
        let turnedOn = Settings.shared.pressEnabled && !lastPressEnabled
        lastPressEnabled = Settings.shared.pressEnabled
        if turnedOn && !Permissions.accessibilityGranted { Permissions.askAccessibility() }
        monitor.delay = Settings.shared.pressDelay
        monitor.allowWindows = Settings.shared.pressInWindows
        if Settings.shared.pressEnabled && Permissions.accessibilityGranted {
            monitor.start()
        } else if !Settings.shared.pressEnabled {
            monitor.cancelFromMain()
            monitor.stop()
        }
        // Accessibility may be granted later; start as soon as it is.
        if Settings.shared.pressEnabled && !Permissions.accessibilityGranted && trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard Permissions.accessibilityGranted else { return }
                t.invalidate()
                self?.trustTimer = nil
                self?.applyPressSettings()
            }
        }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard Settings.shared.showMenuBarIcon else {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil }
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "MaruDoc")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = !Settings.shared.pressEnabled

        let menu = NSMenu()
        let header = NSMenuItem(title: "MaruDoc", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let toggle = NSMenuItem(title: L("長押しメニュー"), action: #selector(togglePress), keyEquivalent: "")
        toggle.target = self
        toggle.state = Settings.shared.pressEnabled ? .on : .off
        menu.addItem(toggle)
        if tapFailed && Settings.shared.pressEnabled && Permissions.accessibilityGranted && !monitor.isActive {
            let warn = NSMenuItem(title: L("長押しを開始できませんでした。MaruDoc を開き直してください"), action: nil, keyEquivalent: "")
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
        }
        if Settings.shared.pressEnabled && !Permissions.accessibilityGranted {
            let warn = NSMenuItem(title: L("アクセシビリティの許可が必要です…"), action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L("設定…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: L("MaruDoc について"), action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("MaruDoc を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    @objc private func togglePress() { Settings.shared.pressEnabled.toggle() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openAbout() { SettingsWindowController.shared.show(tab: .about) }
    @objc private func openAccessibility() { Permissions.askAccessibility() }

    // MARK: URL bridge (Finder extension)

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        #if DEBUG
        if url.host == "debug" {
            // Diagnostics only when explicitly enabled (defaults write app.marudoc.MaruDoc verboseLog -bool true).
            let diagnostics = UserDefaults.standard.bool(forKey: "verboseLog")
            if diagnostics, url.path == "/desktop" { AXDebug.dumpDesktop(); return }
            if diagnostics, url.path == "/under" { AXDebug.dumpUnderMouse(); return }
            DebugTools.handle(url, app: self)
            return
        }
        #endif
        guard let request = Bridge.request(from: url) else { return }
        // Only ids the Finder menu can send are accepted, token or not. Checked before the token so that an
        // unknown id never rotates it.
        guard ActionCatalog.allActionIDs.contains(request.action) else { return }
        // TODO(next version, F8/F14/F19): this bearer token sits in the App Group defaults and proves nothing about who
        // sent the Apple Event. Replace it by checking the sender's audit token (keySenderAuditTokenAttr) against the
        // bundled Finder extension's signature, or by an XPC connection with a code-signing requirement.
        let authenticated = Bridge.authenticateAndRotate(request)
        var files = request.files
        switch ActionCatalog.admission(for: request.action, authenticated: authenticated) {
        case .refuse:
            return
        case .run:
            break
        case .askUser:
            // One dialog at a time; anything arriving while it is open is dropped, not queued.
            guard !confirming else { return }
            confirming = true
            defer { confirming = false }
            guard let approved = confirmUnauthenticated(request) else { return }
            files = approved
        }
        runner.run(request.action, urls: files, origin: .init(iconFrame: nil, onDesktop: false, mouse: request.mouse))
    }

    /// Most files a request without a token may name. A longer list is refused instead of being shown cut off.
    static let maxConfirmFiles = 20

    /// Shows every file the request would act on and returns exactly those files when the user approves, nil otherwise.
    /// Paths that do not exist are dropped first, so the list matches what will really be processed.
    private func confirmUnauthenticated(_ request: Bridge.Request) -> [URL]? {
        let opensSettings = request.action == Act.openSettings
        let files = opensSettings ? [] : request.files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !opensSettings && files.isEmpty { return nil }
        if files.count > Self.maxConfirmFiles {
            let alert = NSAlert()
            alert.messageText = L("要求を実行できません")
            alert.informativeText = String(format: L("Finder 以外から届いた要求で、対象のファイルが %d 件を超えています。"), Self.maxConfirmFiles)
            alert.addButton(withTitle: L("OK"))
            NSApp.activate()
            alert.runModal()
            return nil
        }
        let alert = NSAlert()
        alert.messageText = String(format: L("「%@」を実行しますか?"), ActionCatalog.title(for: request.action))
        alert.informativeText = L("Finder 以外から届いた要求です。心当たりがなければキャンセルしてください。")
            + (files.isEmpty ? "" : "\n\n" + files.map { Self.displayPath($0.path) }.joined(separator: "\n"))
        // Cancel is the default (Return); running needs an explicit click.
        alert.addButton(withTitle: L("キャンセル"))
        let run = alert.addButton(withTitle: L("実行"))
        run.keyEquivalent = ""
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn ? files : nil
    }

    /// Full path with the home folder as "~". Control characters (newlines included) become a visible mark,
    /// so a file name cannot fake extra lines in the dialog.
    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p == home { p = "~" } else if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        var out = ""
        for u in p.unicodeScalars {
            let v = u.value
            let control = v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029
                || (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0xFEFF
            out += control ? "\u{FFFD}" : String(u)
        }
        return out
    }
}
