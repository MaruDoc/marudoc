import AppKit

/// Builds the borderless, non-activating panels that float on every Space (the radial menu and the HUD), and checks
/// whether one is really on screen.
///
/// Why these panels are never kept across a hidden period: a window whose collectionBehavior contains
/// `.canJoinAllSpaces` loses its all-Spaces membership when a full-screen Space is destroyed (any app leaves full
/// screen) while the window is ordered out. The window server leaves it attached to the one Space that was active at
/// that moment. AppKit does not notice: `collectionBehavior` still contains `.canJoinAllSpaces`, and after
/// `orderFrontRegardless()` on any other Space the window reports `isVisible == true` and `alphaValue == 1`, while
/// `isOnActiveSpace` is false (already right after the call) and `occlusionState` lacks `.visible`. Nothing is drawn.
/// Seen on macOS 27.0.
///
/// Re-assigning `collectionBehavior` (the same value, or `[]` and then the value) does not repair such a window, and
/// neither does `orderOut` followed by `orderFrontRegardless()`. A newly created window joins all Spaces on its first
/// order-front, and building one with a hosting view takes a few milliseconds. So the owners build a new panel each
/// time they show one, `discard` it when it hides, and replace it whenever `whyNotOnScreen` reports a problem.
///
/// `.canJoinAllSpaces` is used in this file only; scripts/check_overlay_windows.sh enforces that.
enum OverlayPanel {
    /// A new panel at `frame` (Cocoa screen coordinates) showing `content`. Put it on screen with
    /// `orderFrontRegardless()`; MaruDoc never activates for these panels.
    static func make(level: NSWindow.Level, frame: NSRect, ignoresMouseEvents: Bool, content: NSView) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: frame.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = level
        p.ignoresMouseEvents = ignoresMouseEvents
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        // The owner's property is the only strong reference. With true, `close()` would release the panel once more.
        p.isReleasedWhenClosed = false
        // The content fades itself in SwiftUI; an AppKit fade on top would compete with it.
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        content.frame = NSRect(origin: .zero, size: frame.size)
        p.contentView = content
        p.setFrame(frame, display: false)
        return p
    }

    /// Why `panel` is not on screen, or nil when it is. `occlusionState` is only updated after the window server has
    /// handled an order-front, so right after `orderFrontRegardless()` pass `includeOcclusion: false`.
    static func whyNotOnScreen(_ panel: NSWindow, includeOcclusion: Bool = true) -> String? {
        if !panel.isVisible { return "not visible" }
        if !panel.isOnActiveSpace { return "not on active Space" }
        if includeOcclusion, !panel.occlusionState.contains(.visible) { return "occluded" }
        return nil
    }

    /// The window state behind `whyNotOnScreen`, for the log.
    static func describe(_ panel: NSWindow) -> String {
        let f = panel.frame
        return "visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) occlusion=\(panel.occlusionState.rawValue)"
            + " frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) screens=\(NSScreen.screens.count)"
    }

    /// Takes a panel off screen for good. It must not be ordered front again; the owner drops its reference.
    static func discard(_ panel: NSWindow) {
        panel.orderOut(nil)
        panel.close()
    }
}
