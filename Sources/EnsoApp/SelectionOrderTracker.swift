import AppKit
import EnsoCore

/// Remembers the order in which the user selected files in Finder.
///
/// Finder only exposes the current selection, never the order it was built in, and the Finder extension receives
/// the selection in whatever order Finder returns it. To merge files "in the order I clicked them" the app has to
/// watch the clicks itself. This reuses PressMonitor's event tap, so it works only while Accessibility is granted
/// and the long-press menu is switched on (that is what keeps the tap alive); otherwise `order(_:)` has nothing to
/// go on and returns the files as they came in.
///
/// How it works:
///  - PressMonitor calls `noteMouseUp` on the tap thread after each left mouse-up that is not part of the radial
///    menu. That call only stores the point and schedules work, so the tap thread is never held up.
///  - A short moment later (Finder needs a beat to update its selection; later clicks supersede earlier ones) the
///    work runs on a background queue: if Finder owns the window under the pointer, read Finder's selection through
///    Accessibility (`FinderAX.selection`, with a time budget). Other apps' windows and Finder views that can't be
///    read are ignored and leave the list as it was.
///  - The list is updated from the difference: items no longer selected are dropped, newly selected ones are
///    appended; a selection of one item or none resets the list to just that item. Several items that appear at once
///    (shift-click ranges, rubber-band selection) are appended in the order Finder reports them.
///
/// Limits: selections made with the keyboard (arrow keys, Cmd+A) aren't seen until the next click; a click that
/// changes the selection in under ~0.1 s before a merge is requested may not be read yet.
/// File names are never logged.
final class SelectionOrderTracker: @unchecked Sendable {
    static let shared = SelectionOrderTracker()

    private let lock = NSLock()
    private var state = SelectionOrder()        // standardized paths, selection order
    private var generation = 0
    private let queue = DispatchQueue(label: "app.marudoc.selection-order", qos: .utility)

    /// Wait after a mouse-up before reading, and the most time one read may take.
    private let settle: TimeInterval = 0.12
    private let budget: TimeInterval = 0.6

    // MARK: Tap thread

    /// Called from the event-tap thread. Cheap: records the click and schedules a read.
    func noteMouseUp(at point: CGPoint) {
        let gen = lock.withLock { generation += 1; return generation }
        queue.asyncAfter(deadline: .now() + settle) { [weak self] in self?.refresh(for: gen, at: point) }
    }

    // MARK: Background

    private func refresh(for gen: Int, at point: CGPoint) {
        // A newer click already scheduled its own read.
        guard lock.withLock({ generation == gen }) else { return }
        guard Permissions.accessibilityGranted, let pid = FinderAX.finderPID,
              FinderAX.finderOwnsPoint(point, finderPID: pid),
              let urls = FinderAX.selection(at: point, budget: budget) else { return }
        // The user may have clicked again while Finder was being queried.
        guard lock.withLock({ generation == gen }) else { return }
        update(with: urls.map { $0.standardizedFileURL.path })
    }

    private func update(with selection: [String]) {
        lock.withLock { state.update(with: selection) }
    }

    // MARK: Main thread

    /// `urls` in the order the user selected them, if the tracker saw exactly this selection; otherwise `urls`
    /// unchanged, i.e. the order the Finder extension or the radial menu delivered them in. There is deliberately
    /// no fallback to sorting by name (see `SelectionOrder.order`).
    func order(_ urls: [URL]) -> [URL] {
        lock.withLock { state }.order(urls)
    }
}
