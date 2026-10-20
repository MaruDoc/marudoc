import Foundation
import CoreGraphics

/// The interaction state of one open radial menu, independent of any UI.
/// The event-tap thread owns it; the panel on the main thread only mirrors `hit` and `openParent`.
public struct RadialSession: Sendable {
    public let nodes: [MenuNode]
    /// Centre in Quartz coordinates (top-left origin).
    public let center: CGPoint
    /// Where the pointer was when the menu opened. Differs from `center` when the ring was moved to fit on screen;
    /// the pointer is then left where it is instead of jumping to the centre.
    public let origin: CGPoint
    /// False while a moved ring waits for the pointer to leave `origin`. Until then nothing is hovered, so the
    /// release that ends the long press never picks whatever item happens to lie under the pointer.
    public private(set) var armed: Bool
    public private(set) var hit: RadialGeometry.Hit = .hub
    public private(set) var openParent: Int?
    public private(set) var movedOut = false
    /// The pointer is inside the hub (not merely `hit == .hub`, which also covers the area beyond a moved ring).
    public private(set) var inHub: Bool
    public private(set) var sticky = false
    private let childCounts: [Int]

    public enum Decision: Equatable, Sendable {
        case choose(String)
        case keepOpen
        case cancel
    }

    /// Pointer travel from `origin` that arms a moved ring.
    static let armDistance: CGFloat = 8

    public init(nodes: [MenuNode], center: CGPoint, origin: CGPoint? = nil) {
        self.nodes = nodes
        self.center = center
        self.origin = origin ?? center
        self.armed = hypot(self.origin.x - center.x, self.origin.y - center.y) <= 1
        self.inHub = self.armed
        self.childCounts = nodes.map { $0.children.count }
    }

    /// True when the ring was moved away from the pointer to fit on screen.
    public var isShifted: Bool { hypot(origin.x - center.x, origin.y - center.y) > 1 }

    /// Releasing or clicking now closes the menu without choosing anything: the pointer has come back to the hub.
    /// Right after the press the pointer is in the hub too, but a release there keeps the menu open, so it doesn't count.
    public var showsCancel: Bool { inHub && movedOut }

    /// Beyond the ring of a moved menu. Distance from its centre says nothing about direction there, so it is no flick.
    private func isOutside(_ p: CGPoint) -> Bool {
        isShifted && hypot(p.x - center.x, p.y - center.y) > RadialGeometry.outerEnd + 6
    }

    /// Updates the hover state. Returns true when what the menu should show changed.
    @discardableResult
    public mutating func move(to p: CGPoint) -> Bool {
        if !armed {
            guard hypot(p.x - origin.x, p.y - origin.y) > Self.armDistance else { return false }
            armed = true
        }
        let dx = p.x - center.x, dy = p.y - center.y
        let oldHit = hit, oldOpen = openParent, oldCancel = showsCancel
        inHub = hypot(dx, dy) < RadialGeometry.hubRadius
        if hypot(dx, dy) > RadialGeometry.hubRadius { movedOut = true }
        let newHit = isOutside(p) ? .hub : RadialGeometry.hit(dx: dx, dy: dy, childCounts: childCounts, openParent: openParent)
        hit = newHit
        switch newHit {
        case .hub:
            if !sticky { openParent = nil }
        case .inner(let i):
            if openParent != i { openParent = nil }
        case .outer(let parent, _):
            openParent = parent
        }
        return oldHit != hit || oldOpen != openParent || oldCancel != showsCancel
    }

    /// Called after the pointer has rested on an inner item for a moment: reveal its children.
    @discardableResult
    public mutating func dwell(on index: Int) -> Bool {
        guard hit == .inner(index), nodes.indices.contains(index), !nodes[index].children.isEmpty, openParent != index else { return false }
        openParent = index
        return true
    }

    /// The pointer was released (or clicked, in sticky mode) at `p`.
    public mutating func release(at p: CGPoint) -> Decision {
        move(to: p)
        // A moved ring released before reaching it (or off it) stays open for a click, like a release in the centre.
        if isShifted, !sticky, !armed || isOutside(p) {
            sticky = true
            return .keepOpen
        }
        switch hit {
        case .outer(let parent, let child):
            if let a = nodes[parent].children[child].action { return .choose(a) }
            return .cancel
        case .inner(let i):
            if let a = nodes[i].action { return .choose(a) }
            openParent = i
            sticky = true
            return .keepOpen
        case .hub:
            if !movedOut && !sticky {
                sticky = true
                return .keepOpen
            }
            return .cancel
        }
    }

    /// Whether a click at `p` lands on the menu (sticky mode).
    public func contains(_ p: CGPoint) -> Bool {
        let dx = p.x - center.x, dy = p.y - center.y
        let d = hypot(dx, dy)
        if d <= RadialGeometry.innerEnd + 4 { return true }
        guard d <= RadialGeometry.outerEnd + 6 else { return false }
        if case .outer = RadialGeometry.hit(dx: dx, dy: dy, childCounts: childCounts, openParent: openParent) { return openParent != nil }
        return false
    }

    /// Keeps the whole ring on the display that contains `p`. Quartz coordinates; thread-safe (CoreGraphics only).
    public static func clampedCenter(for p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetActiveDisplayList(count, &ids, &count)
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }.first { $0.contains(p) } ?? CGRect(x: p.x - 500, y: p.y - 500, width: 1000, height: 1000)
        let margin = RadialGeometry.outerEnd + 10
        let x = min(max(p.x, bounds.minX + margin), bounds.maxX - margin)
        let y = min(max(p.y, bounds.minY + margin + 24), bounds.maxY - margin)
        return CGPoint(x: x, y: y)
    }
}
