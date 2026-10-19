import AppKit
import ApplicationServices

/// Finds the Finder item (desktop icon or window row/icon) under a point using the Accessibility API.
/// Finder exposes desktop icons as AXImage elements with AXURL and AXFilename (checked on macOS 27).
enum FinderAX {

    struct Target {
        /// The pressed item first, then the rest of the selection when the pressed item is part of it.
        var urls: [URL]
        /// Frame of the pressed icon in Quartz coordinates (top-left origin), if known.
        var iconFrame: CGRect?
        var onDesktop: Bool
        /// Elements that were selected before the press, so the selection can be restored.
        var selectedElements: [AXUIElement]
    }

    static var finderPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }

    /// True when the frontmost window under `point` (layer 0 up to, not including, 20: ordinary windows and
    /// floating panels, MaruDoc's own included) is Finder's, or when no such window covers it (the desktop).
    /// Menu bar, Dock and transparent windows are skipped. Uses only window bounds, owner and layer, which need
    /// no extra permission.
    static func finderOwnsPoint(_ point: CGPoint, finderPID: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < 20,
                  let owner = w[kCGWindowOwnerPID as String] as? pid_t,
                  let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.contains(point) else { continue }
            // Finder's own desktop windows sit below layer 0 and never reach here; any Finder window found
            // here is a real window, so ownership is decided by the owner alone.
            return owner == finderPID
        }
        return true
    }

    static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    static func axValue(_ v: AnyObject?) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    static func element(_ v: AnyObject?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func frame(of e: AXUIElement) -> CGRect? {
        guard let p = axValue(attr(e, kAXPositionAttribute)), let s = axValue(attr(e, kAXSizeAttribute)) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos)
        AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func fileURL(of e: AXUIElement) -> URL? {
        if let u = attr(e, kAXURLAttribute) as? URL, u.isFileURL { return u }
        if let s = attr(e, kAXURLAttribute) as? String, let u = URL(string: s), u.isFileURL { return u }
        return nil
    }

    /// `point` is in Quartz global coordinates.
    static func target(at point: CGPoint, allowWindows: Bool) -> Target? {
        guard let pid = finderPID else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        var hitPID: pid_t = 0
        if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let h = hit {
            AXUIElementGetPid(h, &hitPID)
        }
        if hitPID != pid {
            // Transparent overlays from other apps (screen recorders, window tools) can win the system-wide hit test.
            // If Finder really is the frontmost normal window there (or it's the bare desktop), ask Finder directly.
            guard finderOwnsPoint(point, finderPID: pid) else { return nil }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            hit = nil
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return nil }
        }
        guard var e = hit else { return nil }

        // Walk up to the element that carries the file URL. Stop at containers so a Finder window's own
        // folder URL is never mistaken for the pressed item.
        var itemElement: AXUIElement?
        var url: URL?
        for _ in 0..<5 {
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if ["AXScrollArea", "AXWindow", "AXApplication", "AXBrowser", "AXSplitGroup"].contains(role) { break }
            if let u = fileURL(of: e), ["AXImage", "AXRow", "AXCell", "AXGroup", "AXTextField", "AXStaticText"].contains(role) {
                url = u; itemElement = e; break
            }
            guard let parent = element(attr(e, kAXParentAttribute)) else { break }
            e = parent
        }
        guard let url, let item = itemElement else { return nil }

        // Desktop or window? The desktop's icons live in a group/scroll area with no AXWindow ancestor that is a real window.
        var onDesktop = false
        var container: AXUIElement? = element(attr(item, kAXParentAttribute))
        var cursor = container
        for _ in 0..<6 {
            guard let c = cursor else { break }
            let role = attr(c, kAXRoleAttribute) as? String ?? ""
            if role == "AXWindow" { onDesktop = false; break }
            if role == "AXApplication" { onDesktop = true; break }
            cursor = element(attr(c, kAXParentAttribute))
        }
        if !onDesktop && !allowWindows { return nil }

        // Multi-selection: if the pressed item is selected, act on the whole selection.
        var urls = [url]
        var selected: [AXUIElement] = []
        let isSelected = (attr(item, kAXSelectedAttribute) as? Bool) ?? false
        if isSelected {
            // Find the nearest ancestor that reports its selection.
            var c = container
            for _ in 0..<4 {
                guard let cc = c else { break }
                if let sel = attr(cc, kAXSelectedChildrenAttribute) as? [AXUIElement], !sel.isEmpty {
                    selected = sel
                    break
                }
                if let rows = attr(cc, kAXSelectedRowsAttribute) as? [AXUIElement], !rows.isEmpty {
                    selected = rows
                    break
                }
                c = element(attr(cc, kAXParentAttribute))
            }
            for s in selected {
                if let u = fileURL(of: s) ?? firstChildURL(s), !urls.contains(u) { urls.append(u) }
            }
        }
        container = nil
        return Target(urls: urls, iconFrame: frame(of: item), onDesktop: onDesktop, selectedElements: selected)
    }

    /// Finder's current selection in the list under `point` (Quartz coordinates): the nearest container above the
    /// hit element that reports AXSelectedChildren / AXSelectedRows, each child resolved to its AXURL. Returns nil
    /// when nothing readable is there (another app, a sidebar without file URLs, a view Finder doesn't describe),
    /// and an empty array when the list reports no selection. Gives up after `budget` seconds.
    /// Only the order Finder reports comes back, which is not the order the user clicked in.
    static func selection(at point: CGPoint, budget: TimeInterval) -> [URL]? {
        guard let pid = finderPID else { return nil }
        let deadline = Date().addingTimeInterval(budget)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var e = hit else { return nil }
        for _ in 0..<8 {
            if Date() > deadline { return nil }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if role == "AXApplication" { return nil }
            var selected: [AXUIElement]?
            if let sel = attr(e, kAXSelectedChildrenAttribute) as? [AXUIElement] { selected = sel }
            else if let rows = attr(e, kAXSelectedRowsAttribute) as? [AXUIElement] { selected = rows }
            if let selected {
                var urls: [URL] = []
                for s in selected {
                    if Date() > deadline { return nil }
                    guard let u = fileURL(of: s) ?? firstChildURL(s) else { continue }
                    let std = u.standardizedFileURL
                    if !urls.contains(std) { urls.append(std) }
                }
                // Rows that carry no URL at all mean this is not a file list (a sidebar, a tag list...).
                if urls.isEmpty && !selected.isEmpty { return nil }
                return urls
            }
            guard let parent = element(attr(e, kAXParentAttribute)) else { return nil }
            e = parent
        }
        return nil
    }

    private static func firstChildURL(_ e: AXUIElement) -> URL? {
        guard let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for k in kids { if let u = fileURL(of: k) { return u } }
        return nil
    }

    /// Puts the selection back after the synthetic click collapsed it.
    static func restoreSelection(_ elements: [AXUIElement]) {
        guard elements.count > 1 else { return }
        for e in elements { AXUIElementSetAttributeValue(e, kAXSelectedAttribute as CFString, kCFBooleanTrue) }
    }

    /// Frame (Quartz coordinates) of a desktop icon for a file, used to place popups next to it.
    static func desktopIconFrame(for url: URL) -> CGRect? {
        guard let pid = finderPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let areas = attr(app, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for area in areas where (attr(area, kAXRoleAttribute) as? String) == "AXScrollArea" {
            for group in (attr(area, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for icon in (attr(group, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    if fileURL(of: icon)?.standardizedFileURL.path == url.standardizedFileURL.path { return frame(of: icon) }
                }
            }
        }
        return nil
    }

    /// All desktop icons with their frames (Quartz coordinates), for finding a free spot.
    static func desktopIcons() -> [(url: URL?, frame: CGRect)] {
        guard let pid = finderPID else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var out: [(URL?, CGRect)] = []
        for area in (attr(app, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where (attr(area, kAXRoleAttribute) as? String) == "AXScrollArea" {
            for group in (attr(area, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for icon in (attr(group, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    if let f = frame(of: icon) { out.append((fileURL(of: icon), f)) }
                }
            }
        }
        return out
    }
}
