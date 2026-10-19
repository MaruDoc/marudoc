import AppKit
import EnsoShared

/// Puts newly created files next to the original icon on the desktop (Finder's `desktop position`, which is the
/// icon centre in top-left screen coordinates). Does nothing when the desktop is sorted, or when Finder
/// automation isn't allowed.
enum DesktopPlacer {

    static var desktopURL: URL {
        RealHome.url.appendingPathComponent("Desktop", isDirectory: true)
    }

    static func isOnDesktop(_ url: URL) -> Bool {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            == desktopURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func place(_ outputs: [URL], near original: URL) {
        let items = outputs.filter(isOnDesktop)
        guard !items.isEmpty, isOnDesktop(original), Settings.shared.placeNextToOriginal else { return }
        // Finder automation is asked for here, the first time a file really has to be placed (never at launch).
        // Denied: skip silently; the file is still next to the original and Finder places it.
        Permissions.ensureFinderAutomation { status in
            if status != .unknown { PermissionMonitor.shared.automation = status }
            if status == .denied { showAutomationHint(); return }
            // Call this only after the file has been written. Finder then needs a moment to notice it, which
            // `attempt` also waits for (it retries until the desktop lists the new icon).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                attempt(items, near: original, tries: 6)
            }
        }
    }

    private static var hintShown = false
    private static let hintHUD = HUDController()

    /// One gentle hint per launch at most.
    private static func showAutomationHint() {
        guard !hintShown else { return }
        hintShown = true
        let m = NSEvent.mouseLocation
        // A little below the "done" notice that is usually showing at the same time.
        hintHUD.showNotice(L("ファイルを隣に並べられません"),
                           detail: L("デスクトップで隣に並べるには、システム設定で Finder の操作を許可してください"),
                           anchor: NSRect(x: m.x - 1, y: m.y - 1 - 56, width: 2, height: 2))
    }

    private static func attempt(_ items: [URL], near original: URL, tries: Int) {
        guard let origin = FinderAX.desktopIconFrame(for: original) else {
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attempt(items, near: original, tries: tries - 1) } }
            return
        }
        let moving = Set(items.map { $0.standardizedFileURL.path })
        let icons = FinderAX.desktopIcons()
        // Finder lays out a new file on its own when it first notices it, which would undo a position set a moment
        // too early. So wait until the desktop actually lists every new icon (the last try goes ahead regardless,
        // in case the icons can't be matched by URL).
        let known = Set(icons.compactMap { $0.url?.standardizedFileURL.path })
        if tries > 0, !moving.isSubset(of: known) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attempt(items, near: original, tries: tries - 1) }
            return
        }
        var occupied = icons
            .filter { !moving.contains($0.url?.standardizedFileURL.path ?? "") }
            .map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        let step = gridStep(occupied: occupied, iconSize: origin.size)
        let c = CGPoint(x: origin.midX, y: origin.midY)
        var args: [String] = []
        for item in items {
            guard let spot = freeSpot(near: c, step: step, occupied: occupied) else { break }
            occupied.append(spot)
            args += [item.path, String(Int(spot.x)), String(Int(spot.y))]
        }
        guard !args.isEmpty else { return }
        // Fixed script text: paths and coordinates arrive only through argv (path, x, y per item).
        let source = """
        on run argv
            set n to count of argv
            tell application "Finder"
                repeat with i from 1 to n by 3
                    set p to item i of argv
                    set px to (item (i + 1) of argv) as integer
                    set py to (item (i + 2) of argv) as integer
                    set desktop position of item ((POSIX file p) as alias) to {px, py}
                end repeat
            end tell
        end run
        """
        AppleScriptRunner.run(source, arguments: args) { ok, _ in
            if ok { return }
            Log.info("place failed for \(args.count / 3) item(s)")
            // Finder may not list the new file yet.
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { attempt(items, near: original, tries: tries - 1) } }
        }
    }

    /// Distance between neighbouring icons, measured from the desktop itself (falls back to Finder's default grid).
    static func gridStep(occupied: [CGPoint], iconSize: CGSize) -> CGSize {
        var dx = CGFloat.infinity, dy = CGFloat.infinity
        for (i, a) in occupied.enumerated() {
            for b in occupied[(i + 1)...] {
                let x = abs(a.x - b.x), y = abs(a.y - b.y)
                if y < 8, x > 40 { dx = min(dx, x) }
                if x < 8, y > 40 { dy = min(dy, y) }
            }
        }
        let fx = max(iconSize.width + 40, 100), fy = max(iconSize.height + 48, 110)
        return CGSize(width: dx.isFinite ? dx : fx, height: dy.isFinite ? dy : fy)
    }

    static func freeSpot(near c: CGPoint, step: CGSize, occupied: [CGPoint]) -> CGPoint? {
        let primary = NSScreen.screens.first?.frame ?? .zero
        let bounds = CGRect(x: 0, y: 0, width: primary.width, height: primary.height).insetBy(dx: step.width / 2, dy: step.height / 2)
        // Left first (desktop icons usually hug the right edge), then below, right, above, then the next ring.
        let order: [(CGFloat, CGFloat)] = [(-1, 0), (0, 1), (1, 0), (0, -1), (-1, 1), (-1, -1), (1, 1), (1, -1),
                                           (-2, 0), (0, 2), (-2, 1), (-2, -1), (2, 0), (0, -2)]
        for (ox, oy) in order {
            let p = CGPoint(x: c.x + ox * step.width, y: c.y + oy * step.height)
            guard bounds.contains(p) else { continue }
            let taken = occupied.contains { abs($0.x - p.x) < step.width * 0.6 && abs($0.y - p.y) < step.height * 0.6 }
            if !taken { return p }
        }
        return nil
    }
}
