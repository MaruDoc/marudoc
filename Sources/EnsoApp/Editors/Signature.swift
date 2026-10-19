import AppKit
import SwiftUI
import EnsoShared

/// One saved signature: strokes normalised to a 1 × aspect box (origin bottom-left), stored locally.
enum SignatureStore {
    static let aspect: CGFloat = 0.4

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("MaruDoc", isDirectory: true)
        // The folder used to be called Enso; copy it over once, leaving the old one alone.
        let old = support.appendingPathComponent("Enso", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signature.json")
    }

    static func load() -> [[CGPoint]]? {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder().decode([[[Double]]].self, from: data) else { return nil }
        return raw.map { $0.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
    }

    static func save(_ strokes: [[CGPoint]]) {
        let raw = strokes.map { $0.map { [Double($0.x), Double($0.y)] } }
        if let data = try? JSONEncoder().encode(raw) { try? data.write(to: fileURL, options: .atomic) }
    }

    static func clear() { try? FileManager.default.removeItem(at: fileURL) }
}

/// A sheet with a drawing area for the signature.
enum SignaturePad {
    static func present(on window: NSWindow, done: @escaping () -> Void) {
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        let view = SignaturePadView { strokes in
            if let strokes { SignatureStore.save(strokes) }
            window.endSheet(sheet)
            if strokes != nil { done() }
        }
        sheet.contentView = NSHostingView(rootView: view)
        window.beginSheet(sheet)
    }
}

struct SignaturePadView: View {
    var finish: ([[CGPoint]]?) -> Void
    @LocalState private var strokes: [[CGPoint]] = []
    @LocalState private var current: [CGPoint] = []
    private let size = CGSize(width: 420, height: 168)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("署名を書いてください")).font(.headline)
            Canvas { ctx, _ in
                for s in strokes + [current] where s.count > 1 {
                    var p = Path()
                    p.addLines(s)
                    ctx.stroke(p, with: .color(.primary), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 1).padding(.horizontal, 24).padding(.bottom, 36) }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { current.append($0.location) }
                .onEnded { _ in if current.count > 1 { strokes.append(current) }; current = [] })
            HStack {
                Button(L("消す")) { strokes = [] }
                Spacer()
                Button(L("キャンセル")) { finish(nil) }.keyboardShortcut(.cancelAction)
                Button(L("この署名を使う")) { finish(normalized()) }.keyboardShortcut(.defaultAction).disabled(strokes.isEmpty)
            }
        }
        .padding(20)
    }

    /// Fit into a 1 × aspect box, flip to bottom-left origin.
    private func normalized() -> [[CGPoint]] {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return [] }
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let k = min(1 / w, SignatureStore.aspect / h)
        let ox = (1 - w * k) / 2, oy = (SignatureStore.aspect - h * k) / 2
        return strokes.map { s in s.map { CGPoint(x: ox + ($0.x - minX) * k, y: SignatureStore.aspect - (oy + ($0.y - minY) * k)) } }
    }
}
