import AppKit
import ApplicationServices
import FinderSync

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// The on-demand Accessibility flow: only called from something the user pressed (a 「許可する…」 button, the
    /// menu-bar item, or turning press-and-hold on). Never from launch.
    static func askAccessibility() {
        guard !accessibilityGranted else { return }
        requestAccessibility()
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static var finderExtensionEnabled: Bool { FIFinderSyncController.isExtensionEnabled }

    static func openExtensionSettings() { FIFinderSyncController.showExtensionManagementInterface() }

    enum AutomationStatus { case granted, notDetermined, denied, unknown }

    /// Automation permission for Finder. Can block (Finder not responding), so call it off the main thread.
    static func finderAutomationStatus(askUser: Bool = false) -> AutomationStatus {
        var addr = AEAddressDesc()
        let bundleID = Array("com.apple.finder".utf8)
        let created = bundleID.withUnsafeBytes { raw in
            AECreateDesc(DescType(typeApplicationBundleID), raw.baseAddress, bundleID.count, &addr)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&addr) }
        let status = AEDeterminePermissionToAutomateTarget(&addr, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }

    private static let automationGate = DispatchQueue(label: "marudoc.automation-gate")

    /// For the first time a feature needs Finder automation: reports the status, asking the user when it is still
    /// undetermined. Runs off the main thread (the prompt blocks until answered) and one at a time, so two files
    /// finishing together cannot raise two prompts. `completion` runs on the main queue.
    static func ensureFinderAutomation(completion: @escaping (AutomationStatus) -> Void) {
        automationGate.async {
            var status = finderAutomationStatus(askUser: false)
            if status == .notDetermined { status = finderAutomationStatus(askUser: true) }
            DispatchQueue.main.async { completion(status) }
        }
    }

    /// Shows the system prompt (when it has not been answered yet), then reports the resulting status on the main queue.
    static func requestFinderAutomation(completion: @escaping (AutomationStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let status = finderAutomationStatus(askUser: true)
            Log.info("automation: \(status)")
            DispatchQueue.main.async { completion(status) }
        }
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
