import AppKit
import SwiftUI
import EnsoShared
import EnsoOffice

/// Developer hooks reachable through `marudoc://debug/...` (used by the verification runs).
enum DebugTools {
    static var snapshotDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.marudoc.MaruDoc/snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    #if DEBUG
    static func handle(_ url: URL, app: AppDelegate) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.path {
        case "/snapshot":
            #if DEBUG
            MainActor.assumeIsolated { snapshots() }
            #endif
            break
        case "/state":
            Log.info("state ax=\(Permissions.accessibilityGranted) ext=\(Permissions.finderExtensionEnabled) tap=\(app.monitor.isRunning) active=\(app.monitor.canModifyEvents) phase=\(app.monitor.currentPhase)")
        default:
            #if DEBUG
            for i in 0..<20 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.5) { AXDebug.dumpUnderMouse() } }
            #endif
            break
        }
    }
    #endif

    /// Renders the radial menu and HUD offscreen (flat fills instead of glass) for visual review.
    @MainActor
    static func snapshots(to dir: URL? = nil) {
        let target = dir ?? snapshotDir
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let samples: [(String, [URL])] = [
            ("pdf", [URL(fileURLWithPath: "/tmp/報告書.pdf")]),
            ("image", [URL(fileURLWithPath: "/tmp/photo.jpg")]),
            ("word", [URL(fileURLWithPath: "/tmp/memo.docx")]),
            ("multi", [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf"), URL(fileURLWithPath: "/tmp/c.png")]),
        ]
        for dark in [false, true] {
            for (name, urls) in samples {
                let nodes = ActionCatalog.menu(for: urls)
                var states: [(String, RadialGeometry.Hit, Int?)] = [("hub", .hub, nil), ("inner1", .inner(1), nil)]
                if let withKids = nodes.firstIndex(where: { !$0.children.isEmpty }) {
                    states.append(("outer", .outer(parent: withKids, child: min(1, nodes[withKids].children.count - 1)), withKids))
                }
                for (stateName, hit, open) in states {
                    let m = RadialModel()
                    m.nodes = nodes; m.hit = hit; m.openParent = open; m.appeared = true
                    m.flatForSnapshot = true; m.snapshotDark = dark
                    m.icon = NSWorkspace.shared.icon(for: .pdf)
                    m.caption = urls.count == 1 ? urls[0].lastPathComponent : String(format: L("%d 項目"), urls.count)
                    let view = RadialMenuView(model: m)
                        .background(dark ? Color(white: 0.12) : Color(white: 0.78))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    write(view, name: "radial-\(name)-\(stateName)-\(dark ? "dark" : "light")", to: target)
                }
            }
            // Transparent versions for the website.
            let m = RadialModel()
            let nodes = ActionCatalog.menu(for: [URL(fileURLWithPath: "/tmp/報告書.pdf")])
            m.nodes = nodes; m.hit = .outer(parent: 0, child: 1); m.openParent = 0; m.appeared = true
            m.flatForSnapshot = true; m.snapshotDark = dark
            m.icon = NSWorkspace.shared.icon(for: .pdf); m.caption = "報告書.pdf"
            // On a plain "desktop" colour so the light segments read against a white page.
            let backdrop = dark ? Color(red: 0.16, green: 0.18, blue: 0.22) : Color(red: 0.47, green: 0.53, blue: 0.62)
            write(RadialMenuView(model: m).padding(.top, 6).padding(.bottom, -40)
                    .background(backdrop, in: RoundedRectangle(cornerRadius: 22))
                    .environment(\.colorScheme, dark ? .dark : .light),
                  name: "site-radial-\(dark ? "dark" : "light")", to: target)
            let hud = HUDModel()
            hud.state = .done; hud.title = L("Word に変換しました"); hud.detail = "報告書.docx"; hud.visible = true; hud.canUndo = false
            write(HUDView(model: hud).background(dark ? Color(white: 0.12) : Color(white: 0.85)).environment(\.colorScheme, dark ? .dark : .light),
                  name: "hud-\(dark ? "dark" : "light")", to: target)
        }
        Log.info("snapshots written to \(target.path)")
    }

    /// Renders the paged editor's first two pages to a PNG at 2x.
    @MainActor
    static func renderDocx(_ url: URL, to out: URL) {
        guard let doc = try? DocxDocument(url: url) else { print("cannot open"); return }
        let storage = NSTextStorage(attributedString: doc.attributed)
        let view = PagedDocumentView(storage: storage, pageSize: doc.page.size, margins: doc.page.margins, usesFontLeading: false, headerFooter: doc.headerFooter)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let pages = min(2, view.textViews.count)
        let rect = NSRect(x: 0, y: 0, width: view.bounds.width, height: PagedDocumentView.gap + CGFloat(pages) * (doc.page.size.height + PagedDocumentView.gap))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
        print("pages \(view.textViews.count) -> \(out.path)")
        for (i, tv) in view.textViews.enumerated() {
            let gr = view.layoutManager.glyphRange(for: tv.textContainer!)
            let cr = view.layoutManager.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            let used = view.layoutManager.usedRect(for: tv.textContainer!)
            print("  page \(i): frame \(tv.frame) chars \(cr) used \(used)")
        }
    }

    @MainActor
    private static func write<V: View>(_ view: V, name: String, to dir: URL) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }
}
