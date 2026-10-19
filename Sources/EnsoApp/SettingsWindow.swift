import AppKit
import SwiftUI
import EnsoShared

/// The only regular window MaruDoc has: welcome / general / about, in the standard toolbar-tab (Settings) style.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    enum Tab: Int { case welcome, general, about }

    private static let width: CGFloat = 580
    private let tabs = NSTabViewController()
    private var timer: Timer?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        add(WelcomeView(), title: L("はじめに"), symbol: "hand.wave")
        add(GeneralView(), title: L("一般"), symbol: "gearshape")
        add(AboutView(), title: L("情報"), symbol: "info.circle")
        window.contentViewController = tabs
        window.toolbarStyle = .preference
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Tallest a tab may be: about 80 % of the screen, less the title bar and toolbar. Taller content scrolls.
    private static var maxContentHeight: CGFloat {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        return max(320, screen * 0.8 - 80)
    }

    /// Each tab is as tall as its content (the hosting controller reports it as the preferred size, and the tab
    /// controller resizes the window to that when the tab changes); the width stays fixed.
    private func add<V: View>(_ view: V, title: String, symbol: String) {
        let vc = NSHostingController(rootView: view.frame(width: Self.width).frame(maxHeight: Self.maxContentHeight))
        vc.sizingOptions = .preferredContentSize
        vc.title = title
        let item = NSTabViewItem(viewController: vc)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    func show(tab: Tab? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startRefreshing()
    }

    func windowDidBecomeKey(_ notification: Notification) { startRefreshing() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        // Back to a menu-bar-only app when the window goes away.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Re-reads the permission states now and every 1.5 s while the window is visible.
    private func startRefreshing() {
        PermissionMonitor.shared.refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            PermissionMonitor.shared.refresh()
        }
    }
}

// MARK: - Permission state

final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published var accessibility = Permissions.accessibilityGranted
    @Published var finderExtension = Permissions.finderExtensionEnabled
    @Published var automation = Permissions.AutomationStatus.unknown
    @Published var folder = SandboxAccess.hasAccess
    @Published var pressActive = false
    @Published var pressFailed = false
    @Published var extensionRunning = false
    /// Set by AppDelegate: whether the event tap is really on.
    var pressProbe: (() -> Bool)?
    private var checkingAutomation = false

    private init() {
        NotificationCenter.default.addObserver(forName: .ensoTapFailed, object: nil, queue: .main) { [weak self] _ in
            self?.pressFailed = true
        }
    }

    func refresh() {
        let active = pressProbe?() ?? false
        if active != pressActive { pressActive = active }
        if active && pressFailed { pressFailed = false }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "app.marudoc.MaruDoc.FinderSync").isEmpty
        if running != extensionRunning { extensionRunning = running }
        let a = Permissions.accessibilityGranted
        if a != accessibility { accessibility = a; NotificationCenter.default.post(name: .ensoSettingsChanged, object: nil) }
        let f = Permissions.finderExtensionEnabled
        if f != finderExtension { finderExtension = f }
        let o = SandboxAccess.hasAccess
        if o != folder { folder = o }
        refreshAutomation()
    }

    private func refreshAutomation() {
        guard !checkingAutomation else { return }
        checkingAutomation = true
        DispatchQueue.global(qos: .utility).async {
            let status = Permissions.finderAutomationStatus()
            DispatchQueue.main.async {
                self.checkingAutomation = false
                if status != self.automation { self.automation = status }
            }
        }
    }

    func requestAutomation() {
        Permissions.requestFinderAutomation { [weak self] status in
            self?.automation = status
            self?.refresh()
        }
    }
}

// MARK: - Welcome

private struct WelcomeView: View {
    @ObservedObject private var state = PermissionMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                Text(L("MaruDoc へようこそ")).font(.title2.weight(.semibold))
                Text(L("ファイルを右クリックするか、デスクトップで長押しするだけで、変換と編集ができます。処理はすべてこの Mac の中で行い、ファイルを外に送ることはありません。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 40)
            }
            .padding(.top, 20)

            Form {
                Section(L("準備")) {
                    PermissionRow(symbol: "contextualmenu.and.cursorarrow", tint: .blue,
                                  title: L("右クリックメニューを有効にする"),
                                  detail: L("Finder 拡張機能で MaruDoc をオンにします。"),
                                  done: state.finderExtension, button: L("設定を開く…")) { Permissions.openExtensionSettings() }
                    PermissionRow(symbol: "accessibility", tint: .blue,
                                  title: L("長押しメニューを許可する"),
                                  detail: L("アクセシビリティで MaruDoc をオンにします。"),
                                  done: state.accessibility, button: L("許可する…")) {
                        Permissions.askAccessibility()
                    }
                    PermissionRow(symbol: "gearshape.2", tint: .purple,
                                  title: L("デスクトップでの並べ方を許可する"),
                                  detail: L("変換したファイルを元の隣に置くため、Finder の操作を許可します。"),
                                  done: state.automation == .granted,
                                  button: state.automation == .denied ? L("設定を開く…") : L("許可する…")) {
                        if state.automation == .denied { Permissions.openAutomationSettings() } else { state.requestAutomation() }
                    }
                    if SandboxAccess.isSandboxed {
                        PermissionRow(symbol: "folder", tint: .orange,
                                      title: L("ファイルへのアクセスを許可する"),
                                      detail: L("選んだフォルダの中のファイルだけを扱えます。"),
                                      done: state.folder, button: L("フォルダを選ぶ…")) {
                            SandboxAccess.requestFolder { ok in state.folder = ok }
                        }
                    }
                }
                Section {
                    Text(L("ファイルを押したまま少し待つ → 円が出たら行きたい方向へ滑らせて離す。中心で離すとメニューが残るので、クリックでも選べます。"))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(L("はじめる")) {
                    Settings.shared.onboarded = true
                    SettingsWindowController.shared.window?.close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .onAppear { state.refresh() }
    }
}

private struct PermissionRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var done: Bool
    var button: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if done {
                Label {
                    Text(L("許可済み")).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Button(button, action: action).buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - General

private struct GeneralView: View {
    @ObservedObject private var s = Settings.shared
    @LocalState private var launchAtLogin = Settings.shared.launchAtLogin

    var body: some View {
        Form {
            StatusSection()
            Section {
                Toggle(L("ログイン時に開く"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in Settings.shared.launchAtLogin = v }
                Toggle(L("メニューバーに表示"), isOn: $s.showMenuBarIcon)
            }
            Section(L("長押しメニュー")) {
                Toggle(L("デスクトップで長押しメニューを使う"), isOn: $s.pressEnabled)
                Toggle(L("Finder のウインドウでも使う"), isOn: $s.pressInWindows).disabled(!s.pressEnabled)
                LabeledContent(L("押し続ける時間")) {
                    HStack {
                        Slider(value: $s.pressDelay, in: 0.3...0.8, step: 0.05).frame(width: 180)
                        Text(String(format: L("%.2f 秒"), s.pressDelay)).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                    }
                }
                .disabled(!s.pressEnabled)
            }
            Section(L("書き出し")) {
                Toggle(L("デスクトップでは元のファイルの隣に並べる"), isOn: $s.placeNextToOriginal)
                Toggle(L("変換したファイルを Finder で選択する"), isOn: $s.revealOutputs)
                Picker(L("PDF を画像にするときの解像度"), selection: $s.imageDPI) {
                    Text("72 dpi").tag(72.0)
                    Text("150 dpi").tag(150.0)
                    Text(L("200 dpi (標準)")).tag(200.0)
                    Text("300 dpi").tag(300.0)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Status

/// "Is it working?": measured state (extension switched on, event tap live, automation answered), not only permission flags.
private struct StatusSection: View {
    @ObservedObject private var state = PermissionMonitor.shared
    @ObservedObject private var s = Settings.shared

    var body: some View {
        Section(L("いまの状態")) {
            StatusRow(color: state.finderExtension ? .green : .orange,
                      title: L("Finder の右クリックメニュー"),
                      text: state.finderExtension ? (state.extensionRunning ? L("動作中") : L("有効")) : L("無効です"),
                      button: state.finderExtension ? nil : L("設定を開く…")) { Permissions.openExtensionSettings() }
            pressRow
            automationRow
        }
    }

    @ViewBuilder private var pressRow: some View {
        let title = L("長押しメニュー")
        if !s.pressEnabled {
            StatusRow(color: .gray, title: title, text: L("オフ (設定で無効)"))
        } else if !state.accessibility {
            StatusRow(color: .orange, title: title, text: L("許可が必要"), button: L("許可する…")) { Permissions.askAccessibility() }
        } else if state.pressActive {
            StatusRow(color: .green, title: title, text: L("動作中"))
        } else if state.pressFailed {
            StatusRow(color: .orange, title: title, text: L("開始できませんでした。開き直してください"))
        } else {
            StatusRow(color: .gray, title: title, text: L("起動しています…"))
        }
    }

    @ViewBuilder private var automationRow: some View {
        let title = L("デスクトップの並べ方")
        switch state.automation {
        case .granted:
            StatusRow(color: .green, title: title, text: L("許可済み"))
        case .denied:
            StatusRow(color: .orange, title: title, text: L("許可されていません"), button: L("設定を開く…")) { Permissions.openAutomationSettings() }
        case .notDetermined, .unknown:
            StatusRow(color: .gray, title: title, text: L("未確認 (初めて使う時に確認します)"))
        }
    }
}

private struct StatusRow: View {
    var color: Color
    var title: String
    var text: String
    var button: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            Spacer(minLength: 12)
            Text(text).foregroundStyle(.secondary)
            if let button {
                Button(button, action: action).controlSize(.small)
            }
        }
    }
}

// MARK: - About

private struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
                    Text("MaruDoc").font(.title.weight(.semibold))
                    Text(String(format: L("バージョン %@"), Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                Text(L("MaruDoc はネットワークに接続しません。変換・編集・文字認識はすべてこの Mac の中で行われ、ファイルやその内容が外部に送られることはありません。"))
                    .foregroundStyle(.secondary)
                Text("© 2026 Yitao Ding").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}
