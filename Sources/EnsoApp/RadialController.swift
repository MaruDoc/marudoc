import AppKit
import SwiftUI
import EnsoShared

/// Shows the radial menu panel. All decisions (what is hovered, what runs) are made by RadialSession on the
/// event-tap thread; this class only mirrors them on screen.
final class RadialController {
    let model = RadialModel()
    private var panel: NSPanel?
    private var lastHit: RadialGeometry.Hit = .hub
    /// Bumped on every open, so a fade-out that was still running cannot hide the menu that opened after it.
    private var generation = 0
    /// True from open until close, whatever the window server currently reports for the panel.
    private var showing = false

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
        if !panel.isVisible { reveal(panel, reason: "update") }
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
        guard showing, let panel else { return }
        showing = false
        let closing = generation
        // The fade runs in the SwiftUI content. The window itself always stays at alpha 1: a window ordered in
        // while its alpha is still 0 (or fading) can be treated as not visible and never drawn.
        withAnimation(.easeOut(duration: 0.12)) { model.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, self.generation == closing else { return }
            panel.orderOut(nil)
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
        let shown = generation
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Fully opaque at once, also when a fade-out of the previous menu was still running.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.visible = true
            model.appeared = false
        }
        panel.alphaValue = 1
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        DispatchQueue.main.async { self.model.appeared = true }
        // The window server decides visibility asynchronously; check once the menu should be on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let panel = self.panel, self.showing, self.generation == shown else { return }
            if !panel.isVisible || !panel.occlusionState.contains(.visible) { self.reveal(panel, reason: "check") }
        }
    }

    /// Puts the panel back on screen when the system reports it hidden although a menu is open.
    private func reveal(_ panel: NSPanel, reason: String) {
        Log.info("radial panel not on screen (\(reason)): visible=\(panel.isVisible) alpha=\(panel.alphaValue) occlusion=\(panel.occlusionState.rawValue); showing again")
        panel.alphaValue = 1
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        panel.display()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.visible = true
            model.appeared = true
        }
    }

    private func makePanel() -> NSPanel {
        let size = RadialGeometry.panelSize
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // Without this AppKit may fade the panel in and out on its own, which competes with the open/close above.
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: RadialMenuView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        p.contentView = host
        return p
    }
}
