import AppKit
import SwiftUI
import EnsoShared

/// Shows the radial menu panel. All decisions (what is hovered, what runs) are made by RadialSession on the
/// event-tap thread; this class only mirrors them on screen.
///
/// Every open builds a new panel, and a panel that the window server does not show is replaced by another new one.
/// A panel is never ordered front again once it has been ordered out (OverlayPanel explains why).
final class RadialController {
    let model = RadialModel()
    private var panel: NSPanel?
    private var lastHit: RadialGeometry.Hit = .hub
    /// Bumped on every open, so a fade-out that was still running cannot touch the menu that opened after it.
    private var generation = 0
    /// True from open until close, whatever the window server currently reports for the panel.
    private var showing = false
    /// Panels built during the current open to replace one that was not on screen.
    private var rebuilds = 0
    /// A locked screen or a sleeping display never shows any panel; this keeps that from rebuilding on every update.
    private static let maxRebuilds = 3
    /// The window server reports occlusion some time after an order-front; before that it is not trusted.
    private static let settleTime: TimeInterval = 0.25
    /// System uptime when the current panel was ordered front.
    private var orderedFrontAt: TimeInterval = 0

    var isOpen: Bool { showing }

    func open(_ opened: PressMonitor.Opened) {
        let urls = opened.target.urls
        model.nodes = opened.session.nodes
        model.hit = .hub
        model.openParent = nil
        model.sticky = false
        model.showsCancel = false
        model.icon = urls.count == 1 ? NSWorkspace.shared.icon(forFile: urls[0].path) : NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        model.caption = urls.count == 1 ? urls[0].lastPathComponent : String(format: L("%d 項目"), urls.count)
        lastHit = .hub
        show(at: opened.session.center)
    }

    func update(hit: RadialGeometry.Hit, openParent: Int?, sticky: Bool, showsCancel: Bool) {
        guard showing, let panel else { return }
        // The press monitor still has a menu open, so the panel must be on screen too.
        let settled = ProcessInfo.processInfo.systemUptime - orderedFrontAt >= Self.settleTime
        if let why = OverlayPanel.whyNotOnScreen(panel, includeOcclusion: settled) { replacePanel(reason: "update: \(why)") }
        if hit != lastHit {
            lastHit = hit
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        model.hit = hit
        model.openParent = openParent
        model.sticky = sticky
        model.showsCancel = showsCancel
    }

    func close() {
        guard showing, panel != nil else { return }
        showing = false
        let closing = generation
        // The fade runs in the SwiftUI content; the window stays at alpha 1 and is closed once the fade is over.
        withAnimation(.easeOut(duration: 0.12)) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, self.generation == closing else { return }
            self.discardPanel()
            self.model.appeared = false
        }
    }

    /// `center` is in Quartz coordinates.
    private func show(at center: CGPoint) {
        let size = RadialGeometry.panelSize
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: center.x - size / 2, y: primaryHeight - center.y - size / 2, width: size, height: size)
        generation += 1
        showing = true
        rebuilds = 0
        let shown = generation
        // The previous menu's panel may still be fading out. It goes now; its pending close sees the new generation.
        discardPanel()
        // Fully opaque at once, also when a fade-out of the previous menu was still running.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.visible = true
            model.appeared = false
        }
        let panel = putUp(frame: frame)
        // A panel the window server attached to another Space already reports that here.
        if let why = OverlayPanel.whyNotOnScreen(panel, includeOcclusion: false) { replacePanel(reason: "open: \(why)") }
        // The new hosting view has drawn the small state, so this plays the pop-in.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == shown else { return }
            self.model.appeared = true
        }
    }

    /// Builds a new panel at `frame`, orders it front, and checks it again once the window server has settled.
    @discardableResult
    private func putUp(frame: NSRect) -> NSPanel {
        let started = ProcessInfo.processInfo.systemUptime
        let host = NSHostingView(rootView: RadialMenuView(model: model))
        let panel = OverlayPanel.make(level: .popUpMenu, frame: frame, ignoresMouseEvents: true, content: host)
        self.panel = panel
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        orderedFrontAt = ProcessInfo.processInfo.systemUptime
        let ms = (orderedFrontAt - started) * 1000
        if ms > 30 { Log.info(String(format: "radial panel took %.0f ms to build and draw", ms)) }
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime) { [weak self, weak panel] in
            guard let self, let panel, self.showing, self.generation == shown, self.panel === panel else { return }
            if let why = OverlayPanel.whyNotOnScreen(panel) { self.replacePanel(reason: "check: \(why)") }
        }
        return panel
    }

    /// Replaces the current panel with a new one at the same place. The menu is shown as it is now, without the
    /// pop-in, because the pointer may already be moving.
    private func replacePanel(reason: String) {
        guard let old = panel else { return }
        guard rebuilds < Self.maxRebuilds else {
            if rebuilds == Self.maxRebuilds {
                rebuilds += 1
                Log.info("radial panel not on screen (\(reason)): \(OverlayPanel.describe(old)); already replaced \(Self.maxRebuilds) times, leaving it for this menu")
            }
            return
        }
        rebuilds += 1
        Log.info("radial panel not on screen (\(reason)): \(OverlayPanel.describe(old)); new panel \(rebuilds)/\(Self.maxRebuilds)")
        let frame = old.frame
        discardPanel()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.visible = true
            model.appeared = true
        }
        putUp(frame: frame)
    }

    private func discardPanel() {
        guard let panel else { return }
        self.panel = nil
        OverlayPanel.discard(panel)
    }
}
