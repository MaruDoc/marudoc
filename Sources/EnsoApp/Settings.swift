import Foundation
import ServiceManagement

/// User preferences (UserDefaults). Observable so SwiftUI settings can bind to it.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// The app was called Enso (com.yd.enso) before MaruDoc. On the first launch with no values of its own, MaruDoc
    /// takes the old ones, once.
    private static func migrateLegacyDefaults() {
        let flag = "legacyDefaultsMigrated"
        let d = UserDefaults.standard
        guard !d.bool(forKey: flag) else { return }
        defer { d.set(true, forKey: flag) }
        let current = Bundle.main.bundleIdentifier ?? "app.marudoc.MaruDoc"
        let old = "com.yd.enso" as CFString
        let user = kCFPreferencesCurrentUser, host = kCFPreferencesAnyHost
        let own = CFPreferencesCopyKeyList(current as CFString, user, host) as? [String] ?? []
        guard own.isEmpty, let keys = CFPreferencesCopyKeyList(old, user, host) as? [String] else { return }
        for key in keys {
            if let value = CFPreferencesCopyAppValue(key as CFString, old) { d.set(value, forKey: key) }
        }
    }

    private init() {
        Self.migrateLegacyDefaults()
        d.register(defaults: [
            "pressEnabled": true,
            "pressDelay": 0.5,
            "pressInWindows": true,
            "showMenuBarIcon": true,
            "imageDPI": 200.0,
            "placeNextToOriginal": true,
            "revealOutputs": false,
            "onboarded": false,
        ])
        // Read after registering the defaults (property initialisers would run first and see false / 0).
        pressEnabled = d.bool(forKey: "pressEnabled")
        pressDelay = d.double(forKey: "pressDelay")
        pressInWindows = d.bool(forKey: "pressInWindows")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        imageDPI = d.double(forKey: "imageDPI")
        placeNextToOriginal = d.bool(forKey: "placeNextToOriginal")
        revealOutputs = d.bool(forKey: "revealOutputs")
    }

    @Published var pressEnabled: Bool {
        didSet { d.set(pressEnabled, forKey: "pressEnabled"); NotificationCenter.default.post(name: .ensoSettingsChanged, object: nil) }
    }
    @Published var pressDelay: Double {
        didSet { d.set(pressDelay, forKey: "pressDelay"); NotificationCenter.default.post(name: .ensoSettingsChanged, object: nil) }
    }
    @Published var pressInWindows: Bool {
        didSet { d.set(pressInWindows, forKey: "pressInWindows") }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon"); NotificationCenter.default.post(name: .ensoSettingsChanged, object: nil) }
    }
    @Published var imageDPI: Double {
        didSet { d.set(imageDPI, forKey: "imageDPI") }
    }
    @Published var placeNextToOriginal: Bool {
        didSet { d.set(placeNextToOriginal, forKey: "placeNextToOriginal") }
    }
    @Published var revealOutputs: Bool {
        didSet { d.set(revealOutputs, forKey: "revealOutputs") }
    }
    var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { Log.error("login item: \(error.localizedDescription)") }
            objectWillChange.send()
        }
    }
}

extension Notification.Name {
    static let ensoSettingsChanged = Notification.Name("EnsoSettingsChanged")
}
