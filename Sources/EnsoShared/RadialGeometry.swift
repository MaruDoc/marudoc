import Foundation
import CoreGraphics

/// Pure geometry for the radial menu: ring sizes and pointer -> item hit testing.
/// Angles are in degrees, 0 = 12 o'clock, increasing clockwise. Vectors use screen orientation (y grows downward).
public enum RadialGeometry {
    public static let hubRadius: CGFloat = 44
    public static let innerStart: CGFloat = 50
    public static let innerEnd: CGFloat = 120
    public static let outerStart: CGFloat = 127
    public static let outerEnd: CGFloat = 190
    /// Angular width of one item on the outer ring.
    public static let childArc: Double = 40
    /// Pointer distance beyond which the outer ring is used.
    public static let outerThreshold: CGFloat = 123
    /// Size of the square panel that holds the menu.
    public static let panelSize: CGFloat = 420
    /// Gap between segments, in points.
    public static let gap: CGFloat = 3

    public static func angle(dx: CGFloat, dy: CGFloat) -> Double {
        // atan2(x, -y): 0 at "up" (negative y), clockwise positive.
        var a = atan2(Double(dx), Double(-dy)) * 180 / .pi
        if a < 0 { a += 360 }
        return a
    }

    public static func normalize(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 360)
        if x < 0 { x += 360 }
        return x
    }

    /// Signed smallest difference a - b in (-180, 180].
    public static func delta(_ a: Double, _ b: Double) -> Double {
        var d = normalize(a - b)
        if d > 180 { d -= 360 }
        return d
    }

    public static func segmentAngle(count: Int) -> Double { 360 / Double(max(1, count)) }

    public static func innerCenter(index: Int, count: Int) -> Double { Double(index) * segmentAngle(count: count) }

    public static func innerIndex(angle: Double, count: Int) -> Int {
        guard count > 0 else { return -1 }
        let seg = segmentAngle(count: count)
        return Int(floor(normalize(angle + seg / 2) / seg)) % count
    }

    /// Centre angles of the children of the inner item at `parentAngle`, fanned out symmetrically.
    public static func childCenters(parentAngle: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let arc = min(childArc, 330 / Double(count))
        let start = parentAngle - arc * Double(count - 1) / 2
        return (0..<count).map { normalize(start + arc * Double($0)) }
    }

    public static func childArcWidth(count: Int) -> Double { min(childArc, 330 / Double(max(1, count))) }

    /// Nearest child to `angle`, or nil when the pointer has swung clearly away from the fan
    /// (more than half an item beyond either end).
    public static func childIndex(angle: Double, parentAngle: Double, count: Int) -> Int? {
        let centers = childCenters(parentAngle: parentAngle, count: count)
        guard !centers.isEmpty else { return nil }
        let arc = childArcWidth(count: count)
        var best = 0
        var bestD = Double.infinity
        for (i, c) in centers.enumerated() {
            let d = abs(delta(angle, c))
            if d < bestD { bestD = d; best = i }
        }
        return bestD <= arc / 2 + arc * 0.5 ? best : nil
    }

    public enum Hit: Equatable, Sendable {
        case hub
        case inner(Int)
        case outer(parent: Int, child: Int)
    }

    /// Resolves the pointer position. `childCounts[i]` is the number of children of inner item i.
    /// `openParent` is the inner item whose outer fan is currently shown, if any.
    public static func hit(dx: CGFloat, dy: CGFloat, childCounts: [Int], openParent: Int?) -> Hit {
        let d = hypot(dx, dy)
        if d < hubRadius { return .hub }
        let a = angle(dx: dx, dy: dy)
        let n = childCounts.count
        if n == 0 { return .hub }
        if d < outerThreshold { return .inner(innerIndex(angle: a, count: n)) }
        // Outer zone: stay in the open fan while the pointer is within it.
        if let p = openParent, childCounts[p] > 0,
           let c = childIndex(angle: a, parentAngle: innerCenter(index: p, count: n), count: childCounts[p]) {
            return .outer(parent: p, child: c)
        }
        let i = innerIndex(angle: a, count: n)
        if childCounts[i] > 0, let c = childIndex(angle: a, parentAngle: innerCenter(index: i, count: n), count: childCounts[i]) {
            return .outer(parent: i, child: c)
        }
        // No children in that direction: the pointer far out still means the inner item (flick).
        return .inner(i)
    }
}
