import AppKit
import PDFKit
import EnsoShared
import EnsoCore

/// Executes a chosen action: popup editors for hands-on work, the engine for everything else.
final class ActionRunner {
    /// HUD used by editors and prompts; each engine run gets its own so parallel runs don't overwrite each other.
    let hud = HUDController()
    private var activeHUDs: [HUDController] = []
    lazy var editors = EditorCoordinator(runner: self)

    final class CancelFlag: @unchecked Sendable { var value = false }

    struct Origin {
        var iconFrame: CGRect?   // Quartz coordinates
        var onDesktop: Bool
        var mouse: CGPoint?      // Cocoa coordinates
    }

    /// Anchor rectangle in Cocoa coordinates for HUD / popups.
    func anchor(for urls: [URL], origin: Origin) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var frame = origin.iconFrame
        if frame == nil, let first = urls.first, DesktopPlacer.isOnDesktop(first) {
            frame = FinderAX.desktopIconFrame(for: first)
        }
        if let f = frame {
            return NSRect(x: f.minX, y: primaryHeight - f.maxY - 18, width: f.width, height: f.height + 18)
        }
        let m = origin.mouse ?? NSEvent.mouseLocation
        return NSRect(x: m.x - 1, y: m.y - 1, width: 2, height: 2)
    }

    func run(_ action: String, urls: [URL], origin: Origin) {
        Log.info("run \(action) on \(urls.count) file(s)")
        if action == Act.openSettings { SettingsWindowController.shared.show(); return }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        if action == Act.editSplitRanges || action == Act.editSplitEvery {
            split(action, url: existing[0], anchor: anchor(for: existing, origin: origin))
            return
        }
        if Act.isMerge(action) {
            // Page order = the order the user selected the files in, when the selection tracker saw it; otherwise the
            // order they arrived in (never sorted by name).
            let ordered = SelectionOrderTracker.shared.order(existing)
            perform(action, urls: ordered, anchor: anchor(for: ordered, origin: origin), options: EngineOptions())
            return
        }
        if Act.isEditor(action) {
            editors.open(action, urls: existing, anchor: anchor(for: existing, origin: origin))
            return
        }
        perform(action, urls: existing, anchor: anchor(for: existing, origin: origin), options: EngineOptions())
    }

    /// Asks for the ranges / page count, then splits. A PDF that can't be opened goes straight to the plain split,
    /// which reports why in the HUD.
    private func split(_ action: String, url: URL, anchor: NSRect) {
        guard let doc = PDFDocument(url: url), !doc.isLocked else {
            perform(Act.pdfSplit, urls: [url], anchor: anchor, options: EngineOptions())
            return
        }
        var options = EngineOptions()
        if action == Act.editSplitRanges {
            guard let text = SplitPrompt.ranges(pageCount: doc.pageCount) else { return }
            options.splitRanges = text
            perform(Act.pdfSplitRanges, urls: [url], anchor: anchor, options: options)
        } else {
            guard let n = SplitPrompt.every(pageCount: doc.pageCount) else { return }
            options.splitEvery = n
            perform(Act.pdfSplitEvery, urls: [url], anchor: anchor, options: options)
        }
    }

    /// Runs the engine with explicit options (also used by the small prompts: password, watermark, resize).
    func perform(_ action: String, urls: [URL], anchor: NSRect, options: EngineOptions) {
        let engine = Engine()
        var opts = options
        opts.imageDPI = Settings.shared.imageDPI
        engine.options = opts
        let flag = CancelFlag()
        let hud = HUDController()
        activeHUDs.append(hud)
        // Stack a little lower when another job is still showing.
        let offset = CGFloat(activeHUDs.count - 1) * 52
        hud.onHidden = { [weak self, weak hud] in self?.activeHUDs.removeAll { $0 === hud } }
        hud.showWorking(ActionCatalog.title(for: action), detail: urls.count == 1 ? urls[0].lastPathComponent : String(format: L("%d 項目"), urls.count),
                        anchor: anchor.offsetBy(dx: 0, dy: -offset), onCancel: { flag.value = true })
        // Progress arrives on the engine's thread and is only ever applied on the main queue.
        nonisolated(unsafe) let progressHUD = hud
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await engine.run(action, files: urls, progress: { p in
                        DispatchQueue.main.async { progressHUD.update(progress: p) }
                    }, cancelled: { flag.value })
                }.value
                if let text = result.clipboardText {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                let undo: (() -> Void)? = result.backups.isEmpty ? nil : {
                    for b in result.backups {
                        do { try SafeWrite.restore(b) } catch { Log.error("undo failed: \(error.localizedDescription)") }
                    }
                }
                hud.showDone(result.message, detail: result.detail, undo: undo)
                if let original = urls.first { DesktopPlacer.place(result.outputs, near: original) }
                if Settings.shared.revealOutputs, !result.outputs.isEmpty, !(urls.first.map(DesktopPlacer.isOnDesktop) ?? false) {
                    NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
                }
                Log.info("done \(action): \(result.outputs.count) output(s)")
            } catch EngineError.cancelled {
                hud.hide()
            } catch {
                let message = ErrorText.describe(error)
                hud.showFailed(L("できませんでした"), detail: message)
                Log.error("\(action) failed")
            }
        }
    }
}
