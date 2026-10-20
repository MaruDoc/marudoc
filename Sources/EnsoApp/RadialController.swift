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

    var isOpen: Bool { panel?.isVisible == true && model.appeared }

    func open(_ opened: PressMonitor.Opened) {
        let urls = opened.target.urls
        model.nodes = opened.session.nodes
        model.hit = .hub
        model.openParent = nil
        model.sticky = false
        model.icon = urls.count == 1 ? NSWorkspace.shared.icon(forFile: urls[0].path) : NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        model.caption = urls.count == 1 ? urls[0].lastPathComponent : String(format: L("%d 項目"), urls.count)
        lastHit = .hub
        show(at: opened.session.center)
    }

    func update(hit: RadialGeometry.Hit, openParent: Int?, sticky: Bool) {
        guard panel?.isVisible == true else { return }
        if hit != lastHit {
            lastHit = hit
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        model.hit = hit
        model.openParent = openParent
        model.sticky = sticky
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        let closing = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == closing else { return }
            panel.orderOut(nil)
            self.model.appeared = false
        })
    }

    /// `center` is in Quartz coordinates.
    private func show(at center: CGPoint) {
        let size = RadialGeometry.panelSize
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: center.x - size / 2, y: primaryHeight - center.y - size / 2, width: size, height: size)
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame, display: false)
        // Through the animator with no duration, so a fade-out still running is replaced rather than finishing at 0.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        model.appeared = false
        DispatchQueue.main.async { self.model.appeared = true }
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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: RadialMenuView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        p.contentView = host
        return p
    }
}
