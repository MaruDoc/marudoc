import AppKit

let app = NSApplication.shared

// `MaruDoc --snapshots <dir>`: render the radial menu and HUD offscreen and exit (used for review and the website).
if let i = CommandLine.arguments.firstIndex(of: "--snapshots") {
    let dir = CommandLine.arguments.count > i + 1 ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : DebugTools.snapshotDir
    MainActor.assumeIsolated { DebugTools.snapshots(to: dir) }
    exit(0)
}

// `MaruDoc --render-docx <in.docx> <out.png>`: draw the editor's first page (for fidelity checks).
if let i = CommandLine.arguments.firstIndex(of: "--render-docx"), CommandLine.arguments.count > i + 2 {
    MainActor.assumeIsolated { DebugTools.renderDocx(URL(fileURLWithPath: CommandLine.arguments[i + 1]), to: URL(fileURLWithPath: CommandLine.arguments[i + 2])) }
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
