import AppKit
import SwiftUI
import Combine
import PDFKit
import UniformTypeIdentifiers
import EnsoShared
import EnsoCore

/// A floating window with the standard title bar and toolbar that opens beside the file it edits. Esc closes, ⌘S saves.
final class EditorPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onSave: (() -> Void)?
    /// Editor-level undo for ⌘Z when no text field is being edited (PDF and image editors).
    var onUndo: (() -> Void)?
    /// Asked before closing; call the completion with true to close. Used for "save changes?".
    var confirmClose: ((@escaping (Bool) -> Void) -> Void)?
    var isDirty: (() -> Bool)?
    /// Esc is offered here first; return true when it was used (e.g. to leave crop mode).
    var onCancel: (() -> Bool)?
    var fileURL: URL?
    /// Subscriptions that live as long as the window.
    var keepAlive: [AnyCancellable] = []
    private var closingConfirmed = false

    init(size: NSSize, title: String) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        self.title = title
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        minSize = NSSize(width: 360, height: 220)
        delegate = self
    }

    /// Hosts a SwiftUI view whose `.toolbar`, `.navigationTitle` and `.navigationSubtitle` become the window's own.
    func setContent<V: View>(_ root: V) {
        let size = contentRect(forFrameRect: frame).size
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.toolbars, .title]
        controller.sizingOptions = []
        contentViewController = controller
        setContentSize(size)
    }

    /// Mirrors "has unsaved changes" in the close button's dot.
    func trackEdited<M: ObservableObject>(_ model: M, dirty: @escaping () -> Bool) {
        keepAlive.append(model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.isDocumentEdited = dirty() }
        })
    }

    /// After a save wrote a new file, the window stands for that file: title, proxy icon and the "one editor per file" lookup.
    func retarget(to url: URL) {
        fileURL = url
        representedURL = url
        title = url.lastPathComponent
    }

    /// Fits the requested size into the screen with room to spare.
    static func preferredSize(_ wanted: NSSize) -> NSSize {
        let vf = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        // Room for the title bar and toolbar on top of the content.
        return NSSize(width: min(wanted.width, vf.width - 80), height: min(wanted.height, vf.height - 140))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if onCancel?() == true { return }
        performClose(nil)
    }

    /// Lets the first click on an inactive editor act right away instead of only bringing it forward.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow, canBecomeKey, attachedSheet == nil {
            if !NSApp.isActive { NSApp.activate() }
            makeKey()
        }
        super.sendEvent(event)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let confirm = confirmClose, !closingConfirmed else { return true }
        confirm { [weak self] ok in
            guard let self, ok else { return }
            self.closingConfirmed = true
            self.close()
        }
        return false
    }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "s" {
            onSave?(); return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "z",
           let undo = onUndo, !(firstResponder is NSTextView) {
            undo(); return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Places the panel beside `anchor` (Cocoa coordinates): to the right if it fits, else to the left, else centred.
    func place(beside anchor: NSRect) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 14
        var x: CGFloat
        if anchor.maxX + gap + size.width <= vf.maxX { x = anchor.maxX + gap }
        else if anchor.minX - gap - size.width >= vf.minX { x = anchor.minX - gap - size.width }
        else { x = vf.midX - size.width / 2 }
        var y = anchor.maxY - size.height + 10
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func present(beside anchor: NSRect) {
        place(beside: anchor)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}

/// Opens the right editor or prompt for an action and keeps it alive while it's on screen.
final class EditorCoordinator {
    private weak var runner: ActionRunner?
    private var open: [EditorPanel] = []

    init(runner: ActionRunner) {
        self.runner = runner
        installMainMenu()
    }

    /// Editors with unsaved changes (asked about when quitting).
    var dirtyPanels: [EditorPanel] { open.filter { $0.isDirty?() == true } }

    func open(_ action: String, urls: [URL], anchor: NSRect) {
        guard let url = urls.first else { return }
        let kind = FileKind.of(url)
        // One editor per file: bring the existing one forward instead of opening a second copy.
        if Act.isEditor(action), ![Act.editResize, Act.editPassword, Act.editWatermark].contains(action),
           let existing = open.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let panel: EditorPanel
        switch (action, kind) {
        case (Act.editOpen, .pdf):
            panel = PDFEditor.makePanel(url: url, mode: .view, coordinator: self)
        case (Act.editCrop, .pdf):
            panel = PDFEditor.makePanel(url: url, mode: .crop, coordinator: self)
        case (Act.editPages, .pdf):
            panel = PDFEditor.makePanel(url: url, mode: .pages, coordinator: self)
        case (Act.editOpen, .image):
            panel = ImageEditor.makePanel(url: url, mode: .adjust, coordinator: self)
        case (Act.editCrop, .image):
            panel = ImageEditor.makePanel(url: url, mode: .crop, coordinator: self)
        case (Act.editOpen, .word), (Act.editOpen, .rtf), (Act.editOpen, .markdown), (Act.editOpen, .text), (Act.editOpen, .html):
            panel = TextEditor.makePanel(url: url, coordinator: self)
        case (Act.editResize, _):
            panel = Prompts.resize(urls: urls, coordinator: self)
        case (Act.editPassword, _):
            panel = Prompts.password(url: url, coordinator: self)
        case (Act.editWatermark, _):
            panel = Prompts.watermark(urls: urls, coordinator: self)
        default:
            Log.error("no editor for \(action) \(kind)")
            return
        }
        if ![Act.editResize, Act.editPassword, Act.editWatermark].contains(action) { panel.fileURL = url }
        panel.onClose = { [weak self, weak panel] in
            self?.open.removeAll { $0 === panel }
            if self?.open.isEmpty == true, !(SettingsWindowController.shared.window?.isVisible ?? false) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        open.append(panel)
        panel.present(beside: anchor)
    }

    /// Runs an engine action from a prompt, with the HUD anchored where the prompt was.
    func perform(_ action: String, urls: [URL], options: EngineOptions, from panel: NSWindow) {
        let anchor = panel.frame.insetBy(dx: panel.frame.width / 2 - 1, dy: panel.frame.height / 2 - 1)
        panel.close()
        runner?.perform(action, urls: urls, anchor: anchor, options: options)
    }

    func showDone(_ message: String, detail: String?, near panel: NSWindow) {
        let anchor = NSRect(x: panel.frame.midX - 1, y: panel.frame.minY + 30, width: 2, height: 2)
        runner?.hud.showWorking(message, anchor: anchor)
        runner?.hud.showDone(message, detail: detail)
    }

    func showFailure(_ error: Error, near panel: NSWindow) {
        let anchor = NSRect(x: panel.frame.midX - 1, y: panel.frame.minY + 30, width: 2, height: 2)
        runner?.hud.showWorking("", anchor: anchor)
        runner?.hud.showFailed(L("保存できませんでした"), detail: ErrorText.describe(error))
    }

    /// A hidden main menu so ⌘Z / ⌘C / ⌘V / ⌘A work in the editors (menu-bar-only apps don't show it).
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: L("MaruDoc を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L("編集")); editItem.submenu = edit
        edit.addItem(NSMenuItem(title: L("取り消す"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L("やり直す"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("カット"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L("コピー"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L("ペースト"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L("すべてを選択"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let fmtItem = NSMenuItem(); main.addItem(fmtItem)
        let fmt = NSMenu(title: L("フォーマット")); fmtItem.submenu = fmt
        fmt.addItem(NSMenuItem(title: L("太字"), action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "b").with(tag: Int(NSFontTraitMask.boldFontMask.rawValue)))
        fmt.addItem(NSMenuItem(title: L("斜体"), action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "i").with(tag: Int(NSFontTraitMask.italicFontMask.rawValue)))
        fmt.addItem(NSMenuItem(title: L("下線"), action: #selector(NSText.underline(_:)), keyEquivalent: "u"))
        NSApp.mainMenu = main
    }
}

private extension NSMenuItem {
    func with(tag: Int) -> NSMenuItem {
        self.tag = tag
        if action == #selector(NSFontManager.addFontTrait(_:)) { target = NSFontManager.shared }
        return self
    }
}

/// Hosting view that reacts to the first click even when the panel isn't key yet.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Saving (PDF and image editors)

/// Where a save goes. The default never touches the original: it writes a new file next to it.
enum EditorSaveDestination {
    /// A new file in the original's folder (named "(トリミング)" / "(編集済み)"); once the editor has made that file,
    /// later saves update it in place.
    case sameFolder
    /// A save panel (a sheet on the editor) that starts in the original's folder.
    case choose
    /// The file that was opened, replaced in place.
    case overwriteOriginal
}

enum EditorSaving {
    /// Name of the new file for a crop-only edit or any other edit.
    static func tag(onlyCrops: Bool) -> String { onlyCrops ? L("トリミング") : L("編集済み") }

    /// Shows the save panel as a sheet on `window`, starting in `proposed`'s folder with its name filled in.
    /// The panel asks about replacing an existing file itself.
    static func chooseDestination(on window: NSWindow, proposed: URL, types: [UTType], completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.directoryURL = proposed.deletingLastPathComponent()
        panel.nameFieldStringValue = proposed.lastPathComponent
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }
}

/// The 保存 control of the PDF and image editors: pressing it saves next to the original; the menu has the other two ways.
struct EditorSaveMenu<Extra: View>: View {
    /// There is something to save.
    var dirty: Bool
    /// The control is available at all (the PDF editor also enables it for the crop reset item).
    var enabled: Bool
    var canOverwrite = true
    var save: (EditorSaveDestination) -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Menu {
            // The check mark shows which entry the button itself performs.
            Toggle(isOn: Binding(get: { true }, set: { _ in save(.sameFolder) })) { Text(L("元と同じフォルダに保存")) }
                .disabled(!dirty)
            Button(L("保存先を選ぶ…")) { save(.choose) }.disabled(!dirty)
            Divider()
            Button(L("元のファイルに上書き")) { save(.overwriteOriginal) }.disabled(!dirty || !canOverwrite)
            extra()
        } label: {
            Text(L("保存"))
        } primaryAction: {
            if dirty { save(.sameFolder) }
        }
        .disabled(!enabled)
    }
}

/// Bar metrics shared by every editor: 12 pt at the sides, 8 pt above and below, one control size per bar.
enum EditorMetrics {
    static let barH: CGFloat = 12
    static let barV: CGFloat = 8
}

/// A second row under the toolbar for tools (like Pages' format bar): hairline below.
struct EditorToolRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { content() }
                .controlSize(.regular)
                .padding(.horizontal, EditorMetrics.barH)
                .padding(.vertical, EditorMetrics.barV)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }
}

/// A bar under the content (crop options, hints): hairline above, never over the document.
struct EditorBottomBar<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) { content() }
                .controlSize(.regular)
                .padding(.horizontal, EditorMetrics.barH)
                .padding(.vertical, EditorMetrics.barV)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Thin vertical separator between tool groups.
struct ToolSeparator: View {
    var body: some View { Divider().frame(height: 16) }
}

struct ToolButton: View {
    var symbol: String
    var help: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
