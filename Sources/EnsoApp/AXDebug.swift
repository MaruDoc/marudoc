import AppKit
import ApplicationServices

/// Developer aid: logs the accessibility element under the mouse (`marudoc://debug/ax`).
enum AXDebug {
    static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, a as CFString, &v)
        return v
    }

    static func describe(_ e: AXUIElement) -> String {
        var names: CFArray?
        AXUIElementCopyAttributeNames(e, &names)
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
        let title = attr(e, kAXTitleAttribute) as? String ?? ""
        let desc = attr(e, kAXDescriptionAttribute) as? String ?? ""
        let url = (attr(e, kAXURLAttribute) as? URL)?.path ?? ""
        let fn = attr(e, kAXFilenameAttribute) as? String ?? ""
        let id = attr(e, kAXIdentifierAttribute) as? String ?? ""
        return "\(role)/\(sub) title=\(title) desc=\(desc) id=\(id) url=\(url) fn=\(fn) attrs=\((names as? [String])?.joined(separator: ",") ?? "")"
    }

    static func dumpUnderMouse() {
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        let system = AXUIElementCreateSystemWide()
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(system, Float(p.x), Float(h - p.y), &el)
        guard err == .success, var e = el else { Log.info("ax: none at \(p) err=\(err.rawValue)"); return }
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        var line = "ax @\(Int(p.x)),\(Int(h - p.y)) pid=\(pid) \(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")\n"
        for depth in 0..<8 {
            line += String(repeating: "  ", count: depth) + describe(e) + "\n"
            guard let parent = attr(e, kAXParentAttribute) else { break }
            e = parent as! AXUIElement
        }
        Log.info(line)
    }
}

extension AXDebug {
    /// Dumps Finder's desktop icons (`marudoc://debug/desktop`).
    static func dumpDesktop() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        var out = "desktop dump\n"
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 5 else { return }
            var pos = CGPoint.zero, size = CGSize.zero
            if let p = attr(e, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if let s = attr(e, kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            out += String(repeating: "  ", count: depth) + describe(e) + " frame=\(Int(pos.x)),\(Int(pos.y)),\(Int(size.width))x\(Int(size.height))\n"
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
                for k in kids.prefix(12) { walk(k, depth + 1) }
            }
        }
        if let kids = attr(app, kAXChildrenAttribute) as? [AXUIElement] {
            for k in kids where (attr(k, kAXRoleAttribute) as? String) == "AXScrollArea" { walk(k, 0) }
        }
        Log.info(out)
    }
}
