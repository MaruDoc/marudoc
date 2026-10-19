import AppKit
import SwiftUI
import EnsoShared

final class HUDModel: ObservableObject {
    enum State: Equatable { case working, done, failed, info }
    @Published var state: State = .working
    @Published var title = ""
    @Published var detail: String?
    @Published var progress: Double?
    @Published var canUndo = false
    @Published var canCancel = false
    @Published var visible = false
    var onUndo: (() -> Void)?
    var onCancel: (() -> Void)?
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if let d = model.detail {
                    Text(d)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 260, alignment: .leading)
            if model.canUndo {
                Button(L("取り消す")) { model.onUndo?() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
            } else if model.canCancel {
                Button {
                    model.onCancel?()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("キャンセル"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(Glass(shape: Capsule(), flat: false, dark: false))
        .fixedSize()
        .opacity(model.visible ? 1 : 0)
        .scaleEffect(model.visible ? 1 : 0.94)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: model.visible)
        .padding(12)
    }

    @ViewBuilder private var leading: some View {
        switch model.state {
        case .working:
            if let p = model.progress {
                ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 19)).foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 17)).foregroundStyle(.orange)
        case .info:
            Image(systemName: "info.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }
}

/// A small floating notice near the file being processed.
final class HUDController {
    let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var anchor: NSRect = .zero
    var onHidden: (() -> Void)?

    /// `anchor` is in Cocoa screen coordinates (icon frame or a point-sized rect at the mouse).
    func showWorking(_ title: String, detail: String? = nil, anchor: NSRect, onCancel: (() -> Void)? = nil) {
        hideWork?.cancel()
        self.anchor = anchor
        model.state = .working
        model.title = title
        model.detail = detail
        model.progress = nil
        model.canUndo = false
        model.canCancel = onCancel != nil
        model.onCancel = onCancel
        present()
    }

    func update(progress: Double) {
        model.progress = max(0, min(1, progress))
    }

    func showDone(_ title: String, detail: String? = nil, undo: (() -> Void)? = nil) {
        model.state = .done
        model.title = title
        model.detail = detail
        model.canCancel = false
        model.canUndo = undo != nil
        model.onUndo = { [weak self] in
            undo?()
            self?.hide()
        }
        present()
        scheduleHide(after: undo == nil ? 2.4 : 6)
    }

    /// A quiet one-line hint (no error): grey info icon, a little longer on screen.
    func showNotice(_ title: String, detail: String?, anchor: NSRect) {
        hideWork?.cancel()
        self.anchor = anchor
        model.state = .info
        model.title = title
        model.detail = detail
        model.canCancel = false
        model.canUndo = false
        present()
        scheduleHide(after: 7)
    }

    func showFailed(_ title: String, detail: String?) {
        model.state = .failed
        model.title = title
        model.detail = detail
        model.canCancel = false
        model.canUndo = false
        present()
        scheduleHide(after: 5)
    }

    func hide() {
        hideWork?.cancel()
        model.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.model.visible else { return }
            self.panel?.orderOut(nil)
            self.onHidden?()
        }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let host = panel.contentView else { return }
        let size = host.fittingSize
        // Below the icon, centred; above it if there's no room.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height + 4)
        if origin.y < vf.minY { origin.y = anchor.maxY - 4 }
        origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - size.height - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if !model.visible { DispatchQueue.main.async { self.model.visible = true } }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 70),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: HUDView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        return p
    }
}
