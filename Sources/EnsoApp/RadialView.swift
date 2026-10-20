import SwiftUI
import EnsoShared

final class RadialModel: ObservableObject {
    @Published var nodes: [MenuNode] = []
    @Published var hit: RadialGeometry.Hit = .hub
    @Published var openParent: Int?
    @Published var icon: NSImage?
    @Published var caption: String = ""
    @Published var appeared = false
    @Published var sticky = false
    /// The pointer is back on the hub, where a release or click closes the menu.
    @Published var showsCancel = false
    /// Offscreen snapshots can't render materials; use flat fills instead.
    var flatForSnapshot = false
    var snapshotDark = false

    var hoveredTitle: String? {
        switch hit {
        case .hub: return showsCancel ? L("キャンセル") : nil
        case .inner(let i): return nodes.indices.contains(i) ? nodes[i].title : nil
        case .outer(let p, let c):
            guard nodes.indices.contains(p), nodes[p].children.indices.contains(c) else { return nil }
            return nodes[p].children[c].title
        }
    }
}

/// An annular sector with a constant-width gap on both sides. Angles in degrees, 0 = 12 o'clock, clockwise.
struct AnnularSector: Shape {
    var startAngle: Double
    var endAngle: Double
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var gap: CGFloat = RadialGeometry.gap

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // Convert "0 = up, clockwise" to SwiftUI's "0 = right, clockwise (y down)".
        func rad(_ deg: Double) -> Double { (deg - 90) * .pi / 180 }
        let halfGapOut = Double(gap / 2 / outerRadius) * 180 / .pi
        let halfGapIn = Double(gap / 2 / max(innerRadius, 1)) * 180 / .pi
        var p = Path()
        p.addArc(center: c, radius: outerRadius, startAngle: .radians(rad(startAngle + halfGapOut)), endAngle: .radians(rad(endAngle - halfGapOut)), clockwise: false)
        p.addArc(center: c, radius: innerRadius, startAngle: .radians(rad(endAngle - halfGapIn)), endAngle: .radians(rad(startAngle + halfGapIn)), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct RadialMenuView: View {
    @ObservedObject var model: RadialModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private let size = RadialGeometry.panelSize

    var body: some View {
        ZStack {
            if let p = model.openParent, model.nodes.indices.contains(p), !model.nodes[p].children.isEmpty {
                outerFan(parent: p)
                    .transition(.scale(scale: 0.78).combined(with: .opacity))
            }
            innerRing
            hub
        }
        .frame(width: size, height: size)
        .scaleEffect(model.appeared || reduceMotion ? 1 : 0.88)
        .opacity(model.appeared ? 1 : 0)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: model.appeared)
        .animation(.easeOut(duration: 0.12), value: model.openParent)
        .animation(.easeOut(duration: 0.08), value: model.hit)
    }

    // MARK: Pieces

    private var innerRing: some View {
        let n = model.nodes.count
        let seg = RadialGeometry.segmentAngle(count: n)
        return ZStack {
            ForEach(Array(model.nodes.enumerated()), id: \.offset) { i, node in
                let center = RadialGeometry.innerCenter(index: i, count: n)
                let shape = AnnularSector(startAngle: center - seg / 2, endAngle: center + seg / 2,
                                          innerRadius: RadialGeometry.innerStart, outerRadius: RadialGeometry.innerEnd)
                let state = innerState(i)
                segmentBackground(shape, state: state)
                if !node.children.isEmpty { moreIndicator(angle: center, state: state) }
                label(node, angle: center, radius: (RadialGeometry.innerStart + RadialGeometry.innerEnd) / 2,
                      state: state, symbolSize: 17, hasMore: !node.children.isEmpty)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(node.title)
            }
        }
    }

    private func outerFan(parent: Int) -> some View {
        let node = model.nodes[parent]
        let n = model.nodes.count
        let pa = RadialGeometry.innerCenter(index: parent, count: n)
        let centers = RadialGeometry.childCenters(parentAngle: pa, count: node.children.count)
        let arc = RadialGeometry.childArcWidth(count: node.children.count)
        return ZStack {
            ForEach(Array(node.children.enumerated()), id: \.offset) { c, child in
                let shape = AnnularSector(startAngle: centers[c] - arc / 2, endAngle: centers[c] + arc / 2,
                                          innerRadius: RadialGeometry.outerStart, outerRadius: RadialGeometry.outerEnd)
                let state: SegmentState = (model.hit == .outer(parent: parent, child: c)) ? .hovered : .normal
                segmentBackground(shape, state: state)
                label(child, angle: centers[c], radius: (RadialGeometry.outerStart + RadialGeometry.outerEnd) / 2,
                      state: state, symbolSize: 15, hasMore: false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(child.title)
            }
        }
    }

    private var hub: some View {
        let r = RadialGeometry.hubRadius
        return ZStack {
            Color.clear.frame(width: r * 2, height: r * 2).modifier(Glass(shape: Circle(), flat: model.flatForSnapshot, dark: isDark))
            // Glass is clear enough that icon labels under the hub showed through; tint it a little.
            if !model.flatForSnapshot {
                Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.45)).frame(width: r * 2 - 2, height: r * 2 - 2)
            }
            VStack(spacing: 2) {
                if let title = model.hoveredTitle {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .frame(width: r * 1.7)
                        .foregroundStyle(primaryText)
                } else {
                    if let icon = model.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 34, height: 34)
                    }
                    Text(model.caption)
                        .font(.system(size: 9.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: r * 1.6)
                        .foregroundStyle(secondaryText)
                }
            }
        }
    }

    // MARK: Styling

    enum SegmentState { case normal, hovered, parent }

    private func innerState(_ i: Int) -> SegmentState {
        switch model.hit {
        case .inner(let h) where h == i: return .hovered
        case .outer(let p, _) where p == i: return .parent
        default: return model.openParent == i ? .parent : .normal
        }
    }

    private var isDark: Bool { model.flatForSnapshot ? model.snapshotDark : scheme == .dark }
    private var primaryText: Color { isDark ? .white : Color(white: 0.1) }
    private var secondaryText: Color { isDark ? Color(white: 0.78) : Color(white: 0.32) }

    @ViewBuilder
    private func segmentBackground(_ shape: AnnularSector, state: SegmentState) -> some View {
        switch state {
        case .hovered:
            shape.fill(Color.accentColor)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 1)
        case .parent:
            ZStack {
                Color.clear.modifier(Glass(shape: shape, flat: model.flatForSnapshot, dark: isDark))
                shape.fill(Color.accentColor.opacity(0.28))
            }
        case .normal:
            Color.clear.modifier(Glass(shape: shape, flat: model.flatForSnapshot, dark: isDark))
        }
    }

    private func label(_ node: MenuNode, angle: Double, radius: CGFloat, state: SegmentState, symbolSize: CGFloat, hasMore: Bool) -> some View {
        let rad = (angle - 90) * .pi / 180
        let x = CGFloat(cos(rad)) * radius, y = CGFloat(sin(rad)) * radius
        let fg: Color = state == .hovered ? .white : primaryText
        return VStack(spacing: 3) {
            Image(systemName: node.symbol)
                .font(.system(size: symbolSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(height: symbolSize + 2)
            Text(node.shortTitle)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 62)
        }
        .foregroundStyle(fg)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }

    /// A short arc along the segment's outer edge: "more options outward".
    private func moreIndicator(angle: Double, state: SegmentState) -> some View {
        let r = RadialGeometry.innerEnd - 5
        let half = 9.0
        return Path { p in
            p.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: r,
                     startAngle: .degrees(angle - 90 - half), endAngle: .degrees(angle - 90 + half), clockwise: false)
        }
        .stroke(state == .hovered ? Color.white.opacity(0.85) : primaryText.opacity(0.35), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

}

/// Liquid Glass on macOS 26+, translucent material before that, flat colour for offscreen snapshots.
struct Glass<S: Shape>: ViewModifier {
    var shape: S
    var flat: Bool
    var dark: Bool

    func body(content: Content) -> some View {
        if flat {
            content.background(shape.fill(dark ? Color(white: 0.2, opacity: 0.92) : Color(white: 0.97, opacity: 0.94))
                .overlay(shape.stroke(Color.black.opacity(dark ? 0.4 : 0.08), lineWidth: 0.5)))
        } else if #available(macOS 26.0, *) {
            content.background(Color.clear.glassEffect(.regular, in: shape))
        } else {
            content.background(shape.fill(.regularMaterial)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)))
        }
    }
}
