import AppKit
import SwiftUI
import PDFKit
import EnsoShared
import EnsoCore
import EnsoDoc

// MARK: - Model

enum PDFTool: String, CaseIterable, Identifiable {
    case select, fixText, text, highlight, underline, strike, pen, rect, oval, arrow, whiteout, redact, note, signature
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .fixText: return "character.cursor.ibeam"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strike: return "strikethrough"
        case .pen: return "scribble"
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .arrow: return "arrow.up.right"
        case .whiteout: return "eraser"
        case .redact: return "rectangle.fill"
        case .note: return "note.text"
        case .signature: return "signature"
        }
    }

    var label: String {
        switch self {
        case .select: return L("選択")
        case .fixText: return L("文字を修正")
        case .text: return L("文字を追加")
        case .highlight: return L("ハイライト")
        case .underline: return L("下線")
        case .strike: return L("取り消し線")
        case .pen: return L("手書き")
        case .rect: return L("四角")
        case .oval: return L("丸")
        case .arrow: return L("矢印")
        case .whiteout: return L("白塗り")
        case .redact: return L("墨消し (保存時に画像化して元の文字を消す)")
        case .note: return L("付箋")
        case .signature: return L("署名")
        }
    }

    var usesColor: Bool { [.text, .highlight, .underline, .strike, .pen, .rect, .oval, .arrow, .note].contains(self) }
}

final class PDFEditorModel: ObservableObject {
    enum Mode: Hashable { case view, annotate, crop, pages }

    /// The file this editor currently stands for. It starts as the opened file; after a save that wrote a new file
    /// it is that file, so later saves update it instead of piling up "(編集済み) (編集済み)".
    @Published var url: URL
    /// The file that was opened, which "元のファイルに上書き" replaces.
    let originalURL: URL
    /// `url` is a file this editor wrote (not the original).
    var ownsFile = false
    /// Something other than a crop changed since the last save (decides "(トリミング)" or "(編集済み)" in the name).
    private(set) var nonCropEdits = false
    @Published var document: PDFDocument
    @Published var mode: Mode
    @Published var tool: PDFTool = .select
    @Published var color: NSColor = .systemYellow
    @Published var dirty = false
    @Published var pageVersion = 0
    @Published var selectedPage = 0
    @Published var hint: String?
    @Published var sidebarVisible: Bool
    @Published var applyToAll = false {
        didSet {
            guard oldValue != applyToAll, mode == .crop, let r = cropRect, let page = document.page(at: selectedPage) else { return }
            if applyToAll {
                // OFF -> ON: the frame on screen becomes the shared one.
                sharedDisplayFrame = CropGeometry.rectToDisplay(r, box: page.bounds(for: .cropBox), rotation: page.rotation)
            } else {
                // ON -> OFF: the shared frame stays as this page's own pending frame only.
                pendingFrames[selectedPage] = r
            }
        }
    }
    /// Crop frame in page coordinates, current page. Not published: dragging only redraws the overlay.
    /// Every change made while cropping is remembered: per page, or as the shared frame when "all pages" is on.
    var cropRect: CGRect? {
        didSet {
            guard mode == .crop, !restoringFrame, let r = cropRect, let page = document.page(at: selectedPage) else { return }
            if applyToAll {
                sharedDisplayFrame = CropGeometry.rectToDisplay(r, box: page.bounds(for: .cropBox), rotation: page.rotation)
            } else {
                pendingFrames[selectedPage] = r
            }
        }
    }
    /// Frames set during this crop session, by page index, in page coordinates ("all pages" off).
    private(set) var pendingFrames: [Int: CGRect] = [:]
    /// The frame shared by all pages, in display space of the page it was set on ("all pages" on).
    private var sharedDisplayFrame: CGRect?
    /// True while a frame is being shown (not edited), so it is not stored back.
    private var restoringFrame = false

    enum Op {
        case add(PDFAnnotation, PDFPage)
        case remove(PDFAnnotation, PDFPage)
        case move(PDFAnnotation, CGRect)
        case snapshot(Data, Int)
    }
    private var undoStack: [Op] = []
    /// Undo depth at the last save; dirty means "different from what's on disk".
    private var savedDepth = 0
    weak var pdfView: EnsoPDFView?

    init(url: URL, document: PDFDocument, mode: Mode) {
        self.url = url
        self.originalURL = url
        self.document = document
        self.mode = mode
        self.sidebarVisible = document.pageCount > 1
        // Opened straight into crop mode: modeChanged never runs, so set the default here.
        if mode == .crop { applyToAll = pagesShareSize }
    }

    func markSaved() {
        savedDepth = undoStack.count
        dirty = false
        nonCropEdits = false
    }

    /// Only crops changed (and at least one page is cropped).
    var onlyCropsChanged: Bool { !nonCropEdits && hasCrops }

    private func refreshDirty() { dirty = undoStack.count != savedDepth }

    /// After redactions replace pages, older undo entries point at pages that no longer exist.
    func clearHistory() { undoStack.removeAll(); savedDepth = 0 }

    var hasRedactions: Bool {
        for i in 0..<document.pageCount {
            if document.page(at: i)?.annotations.contains(where: { $0.isEnsoRedaction }) == true { return true }
        }
        return false
    }

    // Annotation edits

    func add(_ a: PDFAnnotation, to page: PDFPage) {
        nonCropEdits = true
        page.addAnnotation(a)
        undoStack.append(.add(a, page))
        refreshDirty()
    }

    func remove(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        nonCropEdits = true
        page.removeAnnotation(a)
        undoStack.append(.remove(a, page))
        refreshDirty()
    }

    func moved(_ a: PDFAnnotation, from old: CGRect) {
        nonCropEdits = true
        undoStack.append(.move(a, old))
        refreshDirty()
    }

    /// Page-level changes snapshot the whole document for undo. Very large files skip it (no undo for that step)
    /// and only the most recent snapshots are kept.
    func snapshot(isCrop: Bool = false) {
        if !isCrop { nonCropEdits = true }
        guard let data = document.dataRepresentation() else { return }
        if data.count > 80_000_000 { savedDepth = -1; return }
        undoStack.append(.snapshot(data, selectedPage))
        let snapshots = undoStack.indices.filter { if case .snapshot = undoStack[$0] { return true }; return false }
        if snapshots.count > 10, let oldest = snapshots.first {
            undoStack.removeSubrange(0...oldest)
            savedDepth = -1
        }
    }

    func pagesChanged() {
        refreshDirty()
        if savedDepth == -1 { dirty = true }
        pageVersion += 1
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo() {
        guard let op = undoStack.popLast() else { return }
        switch op {
        case .add(let a, let page): page.removeAnnotation(a)
        case .remove(let a, let page): page.addAnnotation(a)
        case .move(let a, let old): a.bounds = old
        case .snapshot(let data, let index):
            if let doc = PDFDocument(data: data) {
                document = doc
                pdfView?.document = doc
                selectedPage = max(0, min(index, doc.pageCount - 1))
                pageVersion += 1
                // The restored pages can be larger than the cropped ones; keep the scale from cutting them off.
                if mode != .crop { pdfView?.fitPageWidth() }
                // Older entries point at objects of the replaced document; they can't be undone any more.
                undoStack.removeAll()
                savedDepth = -1
            }
        }
        refreshDirty()
        pdfView?.needsDisplay = true
        pdfView?.overlay.needsDisplay = true
        if mode == .crop { prepareCrop() }
        objectWillChange.send()
    }

    // Page operations

    func rotate(_ index: Int, by degrees: Int) {
        guard let p = document.page(at: index) else { return }
        snapshot()
        p.rotation = ((p.rotation + degrees) % 360 + 360) % 360
        pagesChanged()
    }

    func delete(_ index: Int) {
        guard document.pageCount > 1 else { return }
        snapshot()
        document.removePage(at: index)
        selectedPage = min(selectedPage, document.pageCount - 1)
        pagesChanged()
    }

    func move(from source: IndexSet, to destination: Int) {
        snapshot()
        let pages = source.compactMap { document.page(at: $0) }
        for i in source.sorted(by: >) { document.removePage(at: i) }
        let target = destination - source.filter { $0 < destination }.count
        for (k, p) in pages.enumerated() { document.insert(p, at: min(target + k, document.pageCount)) }
        pagesChanged()
    }

    func insertBlank(at index: Int) {
        snapshot()
        let size = document.page(at: max(0, index - 1)).map { $0.bounds(for: .mediaBox).size } ?? DocModelSizes.a4
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        document.insert(page, at: min(index, document.pageCount))
        pagesChanged()
    }

    func duplicate(_ index: Int) {
        guard let p = document.page(at: index)?.copy() as? PDFPage else { return }
        snapshot()
        document.insert(p, at: index + 1)
        pagesChanged()
    }

    func insertFiles(_ urls: [URL], at index: Int) {
        snapshot()
        var at = index
        for u in urls {
            if FileKind.of(u) == .pdf, let d = PDFDocument(url: u), !d.isLocked {
                for i in 0..<d.pageCount { if let p = d.page(at: i) { document.insert(p, at: at); at += 1 } }
            } else if FileKind.of(u) == .image, let p = PDFPageFactory.page(forImage: u) {
                document.insert(p, at: at); at += 1
            }
        }
        pagesChanged()
    }

    // Cropping

    /// All pages show the same size and rotation, so one frame fits every page.
    var pagesShareSize: Bool {
        guard document.pageCount > 1, let first = document.page(at: 0) else { return false }
        let s0 = CropGeometry.displaySize(of: first)
        return (1..<document.pageCount).allSatisfy { i in
            guard let p = document.page(at: i) else { return false }
            let s = CropGeometry.displaySize(of: p)
            return abs(s.width - s0.width) <= 1 && abs(s.height - s0.height) <= 1
        }
    }

    /// Some page shows less than its full media box.
    var hasCrops: Bool {
        (0..<document.pageCount).contains { i in
            guard let p = document.page(at: i) else { return false }
            let c = p.bounds(for: .cropBox), m = p.bounds(for: .mediaBox)
            return abs(c.minX - m.minX) > 0.5 || abs(c.minY - m.minY) > 0.5 || abs(c.width - m.width) > 0.5 || abs(c.height - m.height) > 0.5
        }
    }

    func modeChanged(to m: Mode) {
        // Entering or leaving crop mode always starts and ends with no pending frames.
        clearCropSession()
        cropRect = nil
        hint = nil
        if m == .crop { applyToAll = pagesShareSize }
        pdfView?.configure(for: m)
        if m == .crop {
            prepareCrop()
            // Arrow keys and Return act on the page right away.
            if let v = pdfView { v.window?.makeFirstResponder(v) }
        }
        pdfView?.overlay.needsDisplay = true
        objectWillChange.send()
    }

    func clearCropSession() {
        pendingFrames = [:]
        sharedDisplayFrame = nil
    }

    /// Shows the frame for the current page: the shared one ("all pages" on, clamped to this page), this page's own
    /// pending frame (off), or the whole page.
    func prepareCrop() {
        guard mode == .crop, let page = document.page(at: selectedPage) else { cropRect = nil; return }
        restoringFrame = true
        defer { restoringFrame = false }
        let full = CropGeometry.initialFrame(for: page)
        if applyToAll {
            if let shared = sharedDisplayFrame,
               let d = CropGeometry.clamp(shared, toDisplaySize: CropGeometry.displaySize(of: page)) {
                cropRect = CropGeometry.rectToPage(d, box: page.bounds(for: .cropBox), rotation: page.rotation)
            } else {
                cropRect = full
            }
        } else {
            cropRect = pendingFrames[selectedPage] ?? full
        }
        pdfView?.cropPageChanged()
        objectWillChange.send()
    }

    /// Puts the frame back on the whole current page (and remembers that).
    func resetCropFrame() {
        guard mode == .crop, let page = document.page(at: selectedPage) else { return }
        cropRect = CropGeometry.initialFrame(for: page)
    }

    /// Pages that "切り取る" will crop with "all pages" off: their pending frame is not the whole page.
    var pagesWithPendingCrop: [Int] {
        pendingFrames.keys.sorted().filter { i in
            guard let page = document.page(at: i), let r = pendingFrames[i] else { return false }
            return !CropGeometry.isFullFrame(r, for: page)
        }
    }

    /// Marker on the thumbnail of page `i`.
    func hasPendingCrop(_ i: Int) -> Bool {
        guard mode == .crop, let page = document.page(at: i) else { return false }
        if applyToAll {
            guard let r = cropRect, let current = document.page(at: selectedPage) else { return false }
            return !CropGeometry.isFullFrame(r, for: current)
        }
        guard let r = pendingFrames[i] else { return false }
        return !CropGeometry.isFullFrame(r, for: page)
    }

    /// "余白を自動検出": with all pages selected, the frame covers the content of every page.
    func autoDetectCrop() {
        guard mode == .crop, let page = document.page(at: selectedPage) else { return }
        var frame = CropGeometry.contentBounds(of: page)
        if applyToAll, pagesShareSize {
            let origin = page.bounds(for: .cropBox).origin
            let step = max(1, document.pageCount / 30)
            for i in stride(from: 0, to: document.pageCount, by: step) where i != selectedPage {
                guard let p = document.page(at: i), let b = CropGeometry.contentBounds(of: p) else { continue }
                let o = p.bounds(for: .cropBox).origin
                let shifted = b.offsetBy(dx: origin.x - o.x, dy: origin.y - o.y)
                frame = frame.map { $0.union(shifted) } ?? shifted
            }
        }
        cropRect = frame ?? CropGeometry.fallbackFrame(for: page)   // recorded for this page, or as the shared frame
        pdfView?.overlay.needsDisplay = true
        pdfView?.window?.invalidateCursorRects(for: pdfView!.overlay)
        objectWillChange.send()
    }

    func cancelCrop() {
        guard mode == .crop else { return }
        clearCropSession()
        mode = .view
    }

    func applyCrop() {
        guard mode == .crop, let rect = cropRect, rect.width > 10, rect.height > 10,
              let current = document.page(at: selectedPage) else { return }
        // (page, new crop box in page space) for every page that changes.
        var changes: [(PDFPage, CGRect)] = []
        if applyToAll {
            let shown = CropGeometry.rectToDisplay(rect, box: current.bounds(for: .cropBox), rotation: current.rotation)
            for i in 0..<document.pageCount {
                guard let p = document.page(at: i) else { continue }
                let d = shown.intersection(CGRect(origin: .zero, size: CropGeometry.displaySize(of: p)))
                let r = CropGeometry.rectToPage(d, box: p.bounds(for: .cropBox), rotation: p.rotation).intersection(p.bounds(for: .mediaBox))
                if r.width > 10, r.height > 10 { changes.append((p, r)) }
            }
        } else {
            for i in pagesWithPendingCrop {
                guard let p = document.page(at: i), let pending = pendingFrames[i] else { continue }
                let r = pending.intersection(p.bounds(for: .mediaBox))
                if r.width > 10, r.height > 10 { changes.append((p, r)) }
            }
        }
        clearCropSession()
        guard !changes.isEmpty else { cropRect = nil; mode = .view; return }
        snapshot(isCrop: true)   // one undo step for all pages
        for (p, r) in changes { p.setBounds(r, for: .cropBox) }
        cropRect = nil
        mode = .view
        pagesChanged()
        pdfView?.fitPageWidth()
        pdfView?.needsDisplay = true
    }

    /// Shows every page in full again.
    func resetCrop() {
        guard hasCrops else { return }
        clearCropSession()
        snapshot(isCrop: true)
        for i in 0..<document.pageCount {
            guard let p = document.page(at: i) else { continue }
            p.setBounds(p.bounds(for: .mediaBox), for: .cropBox)
        }
        pagesChanged()
        if mode == .crop { pdfView?.layoutDocumentView() } else { pdfView?.fitPageWidth() }
        pdfView?.needsDisplay = true
        if mode == .crop { prepareCrop() }
    }
}

enum DocModelSizes { static let a4 = CGSize(width: 595.28, height: 841.89) }

extension PDFAnnotation {
    static let redactKey = PDFAnnotationKey(rawValue: "/EnsoRedact")
    var isEnsoRedaction: Bool { value(forAnnotationKey: Self.redactKey) != nil }
    var isEnsoEditable: Bool {
        let t = type ?? ""
        return !["Link", "Widget", "Popup"].contains(t)
    }
}

// MARK: - Panel

enum PDFEditor {
    static func makePanel(url: URL, mode: PDFEditorModel.Mode, coordinator: EditorCoordinator) -> EditorPanel {
        let doc = PDFDocument(url: url) ?? PDFDocument()
        let model = PDFEditorModel(url: url, document: doc, mode: mode)
        let panel = EditorPanel(size: EditorPanel.preferredSize(NSSize(width: 960, height: 760)), title: url.lastPathComponent)
        panel.minSize = NSSize(width: 800, height: 480)
        panel.representedURL = url
        let actions = PDFEditorActions(model: model, coordinator: coordinator)
        actions.panel = panel
        panel.setContent(PDFEditorView(model: model, actions: actions))
        panel.trackEdited(model) { model.dirty }
        panel.onSave = { if model.dirty { actions.save(.sameFolder) } }
        panel.onUndo = { model.undo() }
        panel.onCancel = {
            guard model.mode == .crop else { return false }
            model.cancelCrop(); return true
        }
        panel.isDirty = { model.dirty }
        panel.confirmClose = { done in actions.confirmClose(done) }
        if doc.isLocked {
            DispatchQueue.main.async { actions.unlock() }
        }
        return panel
    }
}

final class PDFEditorActions {
    let model: PDFEditorModel
    weak var coordinator: EditorCoordinator?
    weak var panel: EditorPanel?

    init(model: PDFEditorModel, coordinator: EditorCoordinator) {
        self.model = model
        self.coordinator = coordinator
    }

    func unlock() {
        guard let panel else { return }
        let alert = NSAlert()
        alert.messageText = L("パスワードで保護された PDF です")
        alert.informativeText = L("編集するにはパスワードを入力してください。")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("開く"))
        alert.addButton(withTitle: L("キャンセル"))
        alert.beginSheetModal(for: panel) { [weak self] r in
            guard let self else { return }
            if r == .alertFirstButtonReturn, self.model.document.unlock(withPassword: field.stringValue) {
                self.model.pageVersion += 1
                self.model.pdfView?.document = self.model.document
                if self.model.mode == .crop {
                    self.model.applyToAll = self.model.pagesShareSize
                    self.model.prepareCrop()
                }
            } else {
                panel.close()
            }
        }
    }

    /// Returns true when a file was written. `.choose` answers false right away (the save panel is asynchronous).
    /// Redactions rasterise pages: every destination except the original writes a redacted copy and leaves the open
    /// document (and the original file) alone; overwriting the original asks first.
    @discardableResult
    func save(_ destination: EditorSaveDestination, confirmedRedaction: Bool = false) -> Bool {
        guard let panel else { return false }
        switch destination {
        case .sameFolder:
            if model.ownsFile {
                // Update the file this editor made earlier.
                return write(to: model.url, createdNew: false, redactInPlace: false)
            }
            let tag = EditorSaving.tag(onlyCrops: model.onlyCropsChanged)
            return write(to: OutputNamer.file(for: model.originalURL, ext: "pdf", tag: tag), createdNew: true, redactInPlace: false)
        case .choose:
            let tag = EditorSaving.tag(onlyCrops: model.onlyCropsChanged)
            let proposed = model.ownsFile ? model.url : OutputNamer.file(for: model.originalURL, ext: "pdf", tag: tag)
            EditorSaving.chooseDestination(on: panel, proposed: proposed, types: [.pdf]) { [weak self] url in
                guard let self else { return }
                if url.standardizedFileURL == self.model.originalURL.standardizedFileURL {
                    self.save(.overwriteOriginal)
                } else {
                    // The save panel has already asked about replacing an existing file.
                    self.write(to: url, createdNew: !FileManager.default.fileExists(atPath: url.path), redactInPlace: false)
                }
            }
            return false
        case .overwriteOriginal:
            if model.hasRedactions && !confirmedRedaction {
                let alert = NSAlert()
                alert.messageText = L("墨消しを反映して保存します")
                alert.informativeText = L("墨消しのあるページは画像になり、隠した文字は元に戻せません。元のファイルは残して、コピーとして保存することをおすすめします。")
                alert.addButton(withTitle: L("コピーとして保存"))
                alert.addButton(withTitle: L("上書き保存"))
                alert.addButton(withTitle: L("キャンセル"))
                alert.beginSheetModal(for: panel) { [weak self] r in
                    if r == .alertFirstButtonReturn { self?.save(.sameFolder) }
                    else if r == .alertSecondButtonReturn { self?.save(.overwriteOriginal, confirmedRedaction: true) }
                }
                return false
            }
            return write(to: model.originalURL, createdNew: false, redactInPlace: model.hasRedactions)
        }
    }

    /// Writes the document to `target` (replacing it through SafeWrite when it exists) and makes the editor stand for it.
    /// `createdNew` is true for a file that did not exist before: it is placed next to the original on the desktop.
    @discardableResult
    private func write(to target: URL, createdNew: Bool, redactInPlace: Bool) -> Bool {
        guard let panel else { return false }
        var doc = model.document
        do {
            if model.hasRedactions {
                if redactInPlace {
                    try Redaction.apply(to: doc); model.clearHistory()
                } else {
                    // Redact a copy so the open document keeps its text and its redaction boxes.
                    guard let data = doc.dataRepresentation(), let copy = PDFDocument(data: data),
                          Redaction.count(in: copy) == Redaction.count(in: doc) else {
                        throw EngineError.failed(L("墨消しを反映できませんでした"))
                    }
                    try Redaction.apply(to: copy)
                    doc = copy
                }
            }
            if FileManager.default.fileExists(atPath: target.path) {
                let backup = try SafeWrite.replace(target) { tmp in
                    guard doc.write(to: tmp) else { throw DocIOError.writeFailed(tmp.lastPathComponent) }
                }
                SafeWrite.discard(backup)
            } else {
                guard doc.write(to: target) else { throw DocIOError.writeFailed(target.lastPathComponent) }
            }
            model.url = target
            model.ownsFile = target.standardizedFileURL != model.originalURL.standardizedFileURL
            model.markSaved()
            model.pageVersion += 1
            panel.retarget(to: target)
            coordinator?.showDone(model.ownsFile ? L("新しいファイルとして保存しました") : L("保存しました"), detail: target.lastPathComponent, near: panel)
            // The file exists now, so Finder can be asked to put its icon beside the original (retried inside).
            if createdNew { DesktopPlacer.place([target], near: model.originalURL) }
            return true
        } catch {
            coordinator?.showFailure(error, near: panel)
            return false
        }
    }

    func confirmClose(_ done: @escaping (Bool) -> Void) {
        guard model.dirty, let panel else { done(true); return }
        let alert = NSAlert()
        alert.messageText = String(format: L("「%@」への変更を保存しますか?"), model.url.lastPathComponent)
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("キャンセル"))
        alert.addButton(withTitle: L("保存しない"))
        alert.beginSheetModal(for: panel) { [weak self] r in
            switch r {
            case .alertFirstButtonReturn: done(self?.save(.sameFolder) ?? false)
            case .alertThirdButtonReturn: done(true)
            default: done(false)
            }
        }
    }

    func insertFromFile() {
        guard let panel else { return }
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.allowedContentTypes = [.pdf, .image]
        open.beginSheetModal(for: panel) { [weak self] r in
            guard let self, r == .OK else { return }
            self.model.insertFiles(open.urls, at: self.model.selectedPage + 1)
        }
    }
}

/// Burns redaction boxes in: affected pages are replaced by a 300 dpi image, so the covered text is really gone.
enum Redaction {
    static func count(in doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.annotations.filter { $0.isEnsoRedaction }.count ?? 0) }
    }

    static func apply(to doc: PDFDocument) throws {
        // Check every affected page first, so an oversized one fails before any page has been replaced.
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), page.annotations.contains(where: { $0.isEnsoRedaction }) else { continue }
            let b = page.bounds(for: .cropBox)
            let size = page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
            guard bitmapSize(size, scale: 300.0 / 72) != nil else { throw EngineError.failed(L("墨消しを反映できませんでした")) }
        }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), page.annotations.contains(where: { $0.isEnsoRedaction }) else { continue }
            // Draw the redaction boxes opaque black.
            for a in page.annotations where a.isEnsoRedaction {
                a.interiorColor = .black; a.color = .black
            }
            guard let image = renderWithAnnotations(page, dpi: 300) else { throw EngineError.failed(L("墨消しを反映できませんでした")) }
            let size = CGSize(width: page.bounds(for: .cropBox).width, height: page.bounds(for: .cropBox).height)
            let displaySize = page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
            let ns = NSImage(cgImage: image, size: displaySize)
            guard let newPage = PDFPage(image: ns, options: [.mediaBox: CGRect(origin: .zero, size: displaySize), .compressionQuality: 0.92]) else {
                throw EngineError.failed(L("墨消しを反映できませんでした"))
            }
            doc.removePage(at: i)
            doc.insert(newPage, at: i)
        }
    }

    /// Pixel size for a page of `size` points at `scale`, or nil when it is degenerate or beyond 200 megapixels.
    static func bitmapSize(_ size: CGSize, scale: Double) -> (Int, Int)? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0 else { return nil }
        let w = SafeInt.round(Double(size.width) * scale, 0, 1_000_000), h = SafeInt.round(Double(size.height) * scale, 0, 1_000_000)
        guard SafeInt.isReasonablePixelSize(w, h, limit: 200_000_000) else { return nil }
        return (w, h)
    }

    static func renderWithAnnotations(_ page: PDFPage, dpi: Double) -> CGImage? {
        let b = page.bounds(for: .cropBox)
        let size = page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
        let k = dpi / 72
        // The page size comes from the file: check it before allocating (fail closed, the caller throws on nil).
        guard let (w, h) = bitmapSize(size, scale: k),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: k, y: k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        // draw(with:to:) already applies the page's rotation and crop-box origin, and includes annotations.
        page.draw(with: .cropBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

// MARK: - SwiftUI

struct PDFEditorView: View {
    @ObservedObject var model: PDFEditorModel
    let actions: PDFEditorActions

    private let palette: [NSColor] = [.systemYellow, .systemGreen, .systemBlue, .systemPink, .systemRed, .black]

    private var showSidebar: Bool { model.mode == .pages || model.sidebarVisible }

    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .annotate { toolBar }
            HStack(spacing: 0) {
                if showSidebar {
                    PageSidebar(model: model, actions: actions, wide: model.mode == .pages)
                        .frame(width: model.mode == .pages ? 320 : 144)
                    Divider()
                }
                VStack(spacing: 0) {
                    PDFViewRepresentable(model: model)
                    if model.mode == .crop {
                        cropBar
                    } else if model.mode == .annotate, let hint = model.hint {
                        EditorBottomBar {
                            Text(hint).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .background(.background)
        .navigationTitle(model.url.lastPathComponent)
        .navigationSubtitle(String(format: L("%d ページ"), model.document.pageCount) + (model.dirty ? " ・ " + L("編集済み") : ""))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(L("サイドバーを表示/隠す"))
                    .disabled(model.mode == .pages)
            }
            ToolbarItem(placement: .principal) {
                Picker(L("モード"), selection: $model.mode) {
                    Text(L("表示")).tag(PDFEditorModel.Mode.view)
                    Text(L("マークアップ")).tag(PDFEditorModel.Mode.annotate)
                    Text(L("トリミング")).tag(PDFEditorModel.Mode.crop)
                    Text(L("ページ")).tag(PDFEditorModel.Mode.pages)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(L("取り消す"))
                    .disabled(!model.canUndo)
                EditorSaveMenu(dirty: model.dirty, enabled: model.dirty || model.hasCrops, save: { actions.save($0) }) {
                    Divider()
                    Button(L("トリミングを元に戻す")) { model.resetCrop() }.disabled(!model.hasCrops)
                }
            }
        }
        .onChange(of: model.mode) { _, m in model.modeChanged(to: m) }
        .onChange(of: model.selectedPage) { _, _ in if model.mode == .crop { model.prepareCrop() } }
        .onChange(of: model.tool) { _, t in
            switch t {
            case .fixText: model.hint = L("直したい行をクリックしてください")
            case .redact: model.hint = L("消したい範囲をドラッグ。保存するとそのページは画像になり、元の文字は残りません")
            case .signature: model.hint = L("署名を置く場所をクリックしてください")
            default: model.hint = nil
            }
        }
    }

    private var toolBar: some View {
        EditorToolRow {
            ForEach(PDFTool.allCases) { t in
                ToolButton(symbol: t.symbol, help: t.label, selected: model.tool == t) { model.tool = t }
                if t == .select || t == .text || t == .strike || t == .arrow || t == .redact { ToolSeparator() }
            }
            Spacer(minLength: 8)
            if model.tool.usesColor {
                HStack(spacing: 8) {
                    ForEach(palette, id: \.self) { c in
                        Circle().fill(Color(nsColor: c)).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(model.color == c ? 0.85 : 0.15), lineWidth: model.color == c ? 2 : 0.5))
                            .contentShape(Circle())
                            .onTapGesture { model.color = c }
                            .accessibilityLabel(c.accessibilityName)
                    }
                }
            }
        }
    }

    /// Below the page, never over it.
    private var cropBar: some View {
        EditorBottomBar {
            Button(L("余白を自動検出")) { model.autoDetectCrop() }
            Toggle(L("すべてのページに適用"), isOn: $model.applyToAll)
                .toggleStyle(.checkbox)
                .disabled(model.document.pageCount < 2)
            Text(!model.applyToAll && !model.pagesWithPendingCrop.isEmpty
                 ? String(format: L("%d ページを切り取ります"), model.pagesWithPendingCrop.count)
                 : L("Shift で縦横比を固定・矢印キーで微調整"))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .layoutPriority(-1)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            Button(L("キャンセル")) { model.cancelCrop() }.keyboardShortcut(.cancelAction)
            Button(L("切り取る")) { model.applyCrop() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.cropRect == nil)
        }
    }
}

/// Thumbnails: a narrow strip while editing, a wide list in page mode with reorder, rotate, delete, insert.
struct PageSidebar: View {
    @ObservedObject var model: PDFEditorModel
    let actions: PDFEditorActions
    var wide: Bool

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(0..<model.document.pageCount, id: \.self) { i in
                    PageThumb(model: model, index: i, wide: wide)
                        .listRowSeparator(.hidden)
                        .contextMenu { pageMenu(i) }
                        .onTapGesture { model.selectedPage = i; model.pdfView?.go(to: model.document.page(at: i)!) }
                }
                .onMove { from, to in model.move(from: from, to: to) }
            }
            .listStyle(.sidebar)
            .id(model.pageVersion)
            if wide {
                Divider()
                HStack(spacing: 8) {
                    ToolButton(symbol: "rotate.left", help: L("左に回転")) { model.rotate(model.selectedPage, by: -90) }
                    ToolButton(symbol: "rotate.right", help: L("右に回転")) { model.rotate(model.selectedPage, by: 90) }
                    ToolButton(symbol: "plus.square.on.square", help: L("複製")) { model.duplicate(model.selectedPage) }
                    ToolButton(symbol: "doc.badge.plus", help: L("空白ページを挿入")) { model.insertBlank(at: model.selectedPage + 1) }
                    ToolButton(symbol: "square.and.arrow.down.on.square", help: L("ファイルから挿入…")) { actions.insertFromFile() }
                    Spacer()
                    ToolButton(symbol: "trash", help: L("削除")) { model.delete(model.selectedPage) }
                        .disabled(model.document.pageCount <= 1)
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder private func pageMenu(_ i: Int) -> some View {
        Button(L("右に回転")) { model.rotate(i, by: 90) }
        Button(L("左に回転")) { model.rotate(i, by: -90) }
        Button(L("複製")) { model.duplicate(i) }
        Button(L("後ろに空白ページを挿入")) { model.insertBlank(at: i + 1) }
        Divider()
        Button(L("削除"), role: .destructive) { model.delete(i) }.disabled(model.document.pageCount <= 1)
    }
}

struct PageThumb: View {
    @ObservedObject var model: PDFEditorModel
    let index: Int
    var wide: Bool

    var body: some View {
        let selected = model.selectedPage == index
        HStack(spacing: 10) {
            VStack(spacing: 3) {
                if let page = model.document.page(at: index) {
                    Image(nsImage: page.thumbnail(of: NSSize(width: wide ? 120 : 84, height: wide ? 150 : 110), for: .cropBox))
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: wide ? 120 : 84, height: wide ? 150 : 110)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                        .overlay(alignment: .topTrailing) {
                            if model.hasPendingCrop(index) {
                                Image(systemName: "crop").font(.system(size: 9, weight: .semibold))
                                    .padding(3).foregroundStyle(.white)
                                    .background(Circle().fill(Color.accentColor))
                                    .padding(2)
                            }
                        }
                }
                Text("\(index + 1)").font(.system(size: 10)).foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            if wide {
                VStack(alignment: .leading, spacing: 2) {
                    let size = model.document.page(at: index).map { Rasterizer_displaySize($0) } ?? .zero
                    Text(String(format: L("ページ %d"), index + 1)).font(.callout)
                    Text("\(SafeInt.round(size.width * 25.4 / 72)) × \(SafeInt.round(size.height * 25.4 / 72)) mm").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

func Rasterizer_displaySize(_ page: PDFPage) -> CGSize {
    let b = page.bounds(for: .cropBox)
    return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
}

/// Link annotations with a URL action: PDFKit calls this instead of opening the URL itself. Only LinkPolicy-approved
/// URLs (http, https, mailto) are opened; file:, smb: and custom schemes are ignored. In-document destinations
/// (GoTo) never reach this method and keep working.
final class PDFLinkGuard: NSObject, PDFViewDelegate {
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        if LinkPolicy.isOpenable(url) { NSWorkspace.shared.open(url) }
    }

    // Links to other files (GoToR) are never followed.
    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}
}

struct PDFViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: PDFEditorModel

    func makeCoordinator() -> PDFLinkGuard { PDFLinkGuard() }

    func makeNSView(context: Context) -> EnsoPDFView {
        let v = EnsoPDFView()
        v.delegate = context.coordinator
        v.model = model
        v.document = model.document
        v.backgroundColor = NSColor.windowBackgroundColor
        model.pdfView = v
        v.configure(for: model.mode)
        if model.mode == .crop { model.prepareCrop() }
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak v] _ in
            guard let v, let page = v.currentPage, let doc = v.document else { return }
            let i = doc.index(for: page)
            if model.selectedPage != i { model.selectedPage = i }
        }
        return v
    }

    func updateNSView(_ v: EnsoPDFView, context: Context) {
        if v.document !== model.document { v.document = model.document }
        v.overlay.needsDisplay = true
    }
}
