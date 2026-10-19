import AppKit
import SwiftUI
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

/// Document editing in a popup.
/// - Word (.docx/.docm/.dotx): MaruDoc's own reader/writer; pages, margins, spacing and fonts as in the document;
///   saving rewrites only the body and keeps every other part of the file.
/// - RTF / .doc / .odt: macOS's text system, paginated with the document's paper size and margins.
/// - Text / Markdown: a calm continuous editor. HTML: continuous rich text.
final class TextEditorModel: ObservableObject {
    enum Layout { case paged, rich, plain }

    let url: URL
    let kind: FileKind
    let layout: Layout
    /// When the round trip may lose parts of the file, saving writes a copy instead of overwriting.
    private(set) var lossyReason: String?
    @Published var dirty = false
    @Published var preview = false
    @Published var previewText = ""
    @Published var zoom: CGFloat = 1
    /// Pages in the paged layout; follows the text while editing.
    @Published var pageCount = 1
    /// Set when the file couldn't be read: saving is disabled so an error message can never overwrite it.
    @Published var loadFailed = false
    @Published var loadError: String?

    private(set) var storage = NSTextStorage()
    private(set) var paged: PagedDocumentView?
    weak var plainTextView: NSTextView?
    private var docx: DocxDocument?
    private var cocoaAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]
    var pageSize = CGSize(width: 595.3, height: 841.9)
    var encoding: String.Encoding = .utf8
    var hadBOM = false
    lazy var changeObserver = ChangeObserver(model: self)

    /// The text view the format bar acts on (pages share one selection).
    var textView: NSTextView? { paged?.layoutManager.firstTextView ?? plainTextView }

    init(url: URL) {
        self.url = url
        self.kind = FileKind.of(url)
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "docx", "docm", "dotx", "doc", "odt", "rtf", "rtfd": layout = .paged
        case "html", "htm": layout = .rich
        default: layout = .plain
        }
        load()
        if let paged {
            pageCount = paged.textViews.count
            paged.onPageCountChange = { [weak self] n in
                DispatchQueue.main.async { if self?.pageCount != n { self?.pageCount = n } }
            }
        }
    }

    private func load() {
        let ext = url.pathExtension.lowercased()
        do {
            switch ext {
            case "docx", "docm", "dotx":
                let d = try DocxDocument(url: url)
                docx = d
                storage = NSTextStorage(attributedString: d.attributed)
                pageSize = d.page.size
                paged = PagedDocumentView(storage: storage, pageSize: d.page.size, margins: d.page.margins, usesFontLeading: false, headerFooter: d.headerFooter)
                if d.hasTrackedChanges { lossyReason = L("変更履歴") }
            case "doc", "odt", "rtf", "rtfd":
                var attrs: NSDictionary?
                let types: [String: NSAttributedString.DocumentType] = ["doc": .docFormat, "odt": .openDocument, "rtf": .rtf, "rtfd": .rtfd]
                let a = try NSAttributedString(url: url, options: [.documentType: types[ext]!], documentAttributes: &attrs)
                cocoaAttributes = attrs as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
                let paper = (cocoaAttributes[.paperSize] as? NSValue)?.sizeValue ?? CGSize(width: 595.3, height: 841.9)
                func m(_ k: NSAttributedString.DocumentAttributeKey) -> CGFloat { CGFloat((cocoaAttributes[k] as? NSNumber)?.doubleValue ?? 72) }
                let margins = NSEdgeInsets(top: m(.topMargin), left: m(.leftMargin), bottom: m(.bottomMargin), right: m(.rightMargin))
                storage = NSTextStorage(attributedString: a)
                pageSize = paper
                paged = PagedDocumentView(storage: storage, pageSize: paper, margins: margins)
                if ext == "doc" || ext == "odt" { lossyReason = L("この形式の細かい書式") }
                var hasImages = false
                a.enumerateAttribute(.attachment, in: NSRange(location: 0, length: a.length)) { v, _, stop in if v != nil { hasImages = true; stop.pointee = true } }
                if ext == "rtf" && hasImages { lossyReason = L("画像") }
            case "html", "htm":
                let model = try HTMLReader.model(from: Data(contentsOf: url), baseURL: url.deletingLastPathComponent())
                storage = NSTextStorage(attributedString: AttributedConverter.attributedString(from: model, style: .init(bodySize: 13, contentWidth: 640)))
                lossyReason = L("この形式の細かい書式")
            default:
                let data = try Data(contentsOf: url)
                let (s, enc, bom) = Self.decodeKeepingEncoding(data)
                encoding = enc; hadBOM = bom
                storage = NSTextStorage(string: s, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor])
            }
        } catch {
            loadFailed = true
            loadError = ErrorText.describe(error)
        }
    }

    static func decodeKeepingEncoding(_ data: Data) -> (String, String.Encoding, Bool) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8, true) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return (String(data: data, encoding: .utf16) ?? "", .utf16, true) }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8, false) }
        if let s = String(data: data, encoding: .shiftJIS) { return (s, .shiftJIS, false) }
        if let s = String(data: data, encoding: .japaneseEUC) { return (s, .japaneseEUC, false) }
        return (String(decoding: data, as: UTF8.self), .utf8, false)
    }

    func encodedText(_ s: String) -> Data {
        // Characters the original encoding can't hold force UTF-8 rather than losing text.
        if encoding == .utf16 { return s.data(using: .utf16) ?? Data(s.utf8) }
        guard var data = s.data(using: encoding) else { return Data(s.utf8) }
        if hadBOM && encoding == .utf8 { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return data
    }

    func save(asCopy: Bool) throws -> URL {
        let text = NSAttributedString(attributedString: storage)
        let target = asCopy ? OutputNamer.file(for: url, ext: url.pathExtension, tag: L("編集済み")) : url
        let write: (URL) throws -> Void = { [self] dest in
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "docx", "docm", "dotx":
                guard let docx else { throw DocIOError.writeFailed(url.lastPathComponent) }
                try docx.save(text, to: dest)
            case "doc", "odt", "rtf", "rtfd":
                let types: [String: NSAttributedString.DocumentType] = ["doc": .docFormat, "odt": .openDocument, "rtf": .rtf, "rtfd": .rtfd]
                var attrs = cocoaAttributes
                attrs[.documentType] = types[ext]!
                let range = NSRange(location: 0, length: text.length)
                if ext == "rtfd" {
                    guard let w = text.rtfdFileWrapper(from: range, documentAttributes: attrs) else { throw DocIOError.writeFailed(dest.lastPathComponent) }
                    try w.write(to: dest, options: .atomic, originalContentsURL: nil)
                } else {
                    try text.data(from: range, documentAttributes: attrs).write(to: dest, options: .atomic)
                }
            case "html", "htm":
                let model = AttributedConverter.model(from: text, title: url.deletingPathExtension().lastPathComponent)
                try HTMLWriter.string(from: model).write(to: dest, atomically: true, encoding: .utf8)
            default:
                try encodedText(text.string).write(to: dest, options: .atomic)
            }
        }
        if asCopy { try write(target) } else { SafeWrite.discard(try SafeWrite.replace(url, write: write)) }
        return target
    }

    final class ChangeObserver: NSObject, NSTextViewDelegate {
        weak var model: TextEditorModel?
        init(model: TextEditorModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            if model?.dirty == false { model?.dirty = true }
        }

        /// Only web and mail links are opened; every other scheme (file:, smb:, custom handlers) is refused.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            if let url, LinkPolicy.isOpenable(url) { NSWorkspace.shared.open(url) }
            return true
        }
    }
}

enum TextEditor {
    static func makePanel(url: URL, coordinator: EditorCoordinator) -> EditorPanel {
        let model = TextEditorModel(url: url)
        let width = model.layout == .paged ? max(760, model.pageSize.width + PagedDocumentView.side * 2 + 40) : 760
        let panel = EditorPanel(size: EditorPanel.preferredSize(NSSize(width: width, height: 900)), title: url.lastPathComponent)
        panel.minSize = NSSize(width: 720, height: 420)
        panel.representedURL = url
        // Fit the page width into the panel.
        if model.layout == .paged {
            let available = panel.frame.width - 24
            let needed = model.pageSize.width + PagedDocumentView.side * 2
            model.zoom = min(1, max(0.5, available / needed))
        }
        let save: (Bool) -> Bool = { [weak panel, weak coordinator] asCopy in
            guard let panel, !model.loadFailed else { return false }
            let copy = asCopy || model.lossyReason != nil
            do {
                let target = try model.save(asCopy: copy)
                model.dirty = false
                coordinator?.showDone(copy ? L("コピーとして保存しました") : L("保存しました"), detail: target.lastPathComponent, near: panel)
                if copy { DesktopPlacer.place([target], near: url) }
                return true
            } catch {
                coordinator?.showFailure(error, near: panel)
                return false
            }
        }
        panel.setContent(TextEditorView(model: model, save: { _ = save($0) }))
        panel.trackEdited(model) { model.dirty }
        panel.onSave = { if model.dirty { _ = save(false) } }
        panel.isDirty = { model.dirty }
        panel.confirmClose = { [weak panel] done in
            guard model.dirty, !model.loadFailed, let panel else { done(true); return }
            let alert = NSAlert()
            alert.messageText = String(format: L("「%@」への変更を保存しますか?"), url.lastPathComponent)
            alert.addButton(withTitle: L("保存")); alert.addButton(withTitle: L("キャンセル")); alert.addButton(withTitle: L("保存しない"))
            alert.beginSheetModal(for: panel) { r in
                if r == .alertFirstButtonReturn { done(save(false)) } else { done(r == .alertThirdButtonReturn) }
            }
        }
        return panel
    }
}

struct TextEditorView: View {
    @ObservedObject var model: TextEditorModel
    var save: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.layout != .plain && !model.loadFailed { EditorToolRow { FormatBar(model: model) } }
            if let reason = model.lossyReason {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(String(format: L("この書類には%@が含まれます。元のファイルを守るため、保存は「(編集済み)」の別ファイルになります。"), reason))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, EditorMetrics.barH).padding(.vertical, EditorMetrics.barV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }
            content
        }
        .navigationTitle(model.url.lastPathComponent)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.layout == .paged {
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { z in
                            Button("\(Int(z * 100))%") { model.zoom = CGFloat(z) }
                        }
                    } label: { Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit() }
                    .help(L("表示の大きさ"))
                }
                if model.kind == .markdown {
                    Toggle(isOn: Binding(get: { model.preview }, set: { on in
                        if on { model.previewText = model.storage.string }
                        model.preview = on
                    })) { Image(systemName: "eye") }
                    .toggleStyle(.button)
                    .help(L("プレビュー"))
                }
                Menu {
                    Button(L("コピーとして保存")) { save(true) }
                } label: { Text(L("保存")) } primaryAction: { save(false) }
                .disabled(!model.dirty || model.loadFailed)
            }
        }
    }

    /// "3 ページ" for paged documents, as in the PDF editor; "編集済み" once there are unsaved changes.
    private var subtitle: String {
        var parts: [String] = []
        if model.layout == .paged && !model.loadFailed { parts.append(String(format: L("%d ページ"), model.pageCount)) }
        if model.dirty { parts.append(L("編集済み")) }
        return parts.joined(separator: " ・ ")
    }

    @ViewBuilder private var content: some View {
        if let error = model.loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(L("開けませんでした")).font(.headline)
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let paged = model.paged {
            PagedEditorView(document: paged, zoom: $model.zoom, delegate: model.changeObserver)
        } else {
            // The editor stays alive under the preview so unsaved edits survive the toggle.
            ZStack {
                PlainTextView(model: model)
                if model.preview { MarkdownPreview(markdown: model.previewText) }
            }
        }
    }
}

/// Link clicks in a read-only preview: only LinkPolicy-approved URLs (http, https, mailto) are opened.
final class LinkGuardDelegate: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        if let url, LinkPolicy.isOpenable(url) { NSWorkspace.shared.open(url) }
        // Handled either way, so the default handler (which would open any scheme) never runs.
        return true
    }
}

struct MarkdownPreview: NSViewRepresentable {
    var markdown: String
    func makeCoordinator() -> LinkGuardDelegate { LinkGuardDelegate() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.textContainerInset = NSSize(width: 48, height: 32)
            tv.delegate = context.coordinator
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let model = MarkdownReader.model(from: markdown)
        tv.textStorage?.setAttributedString(AttributedConverter.attributedString(from: model, style: .init(bodySize: 13, contentWidth: 600)))
    }
}

/// Continuous editor for text, Markdown and HTML, with a readable line length.
struct PlainTextView: NSViewRepresentable {
    @ObservedObject var model: TextEditorModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.layoutManager?.replaceTextStorage(model.storage)
        tv.isRichText = model.layout == .rich
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.importsGraphics = model.layout == .rich
        tv.textContainerInset = NSSize(width: 56, height: 36)
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        if model.layout == .plain {
            tv.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor]
            let ps = NSMutableParagraphStyle(); ps.lineHeightMultiple = 1.25
            tv.defaultParagraphStyle = ps
            model.storage.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: model.storage.length))
        }
        tv.delegate = model.changeObserver
        model.plainTextView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// Paragraph style, bold / italic / underline, size, colour, lists and alignment.
struct FormatBar: View {
    @ObservedObject var model: TextEditorModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L("本文")) { setBlock(level: 0) }
                Button(L("見出し 1")) { setBlock(level: 1) }
                Button(L("見出し 2")) { setBlock(level: 2) }
                Button(L("見出し 3")) { setBlock(level: 3) }
            } label: { Text(L("段落")).frame(height: 32) }
            .menuStyle(.borderlessButton).fixedSize()
            ToolButton(symbol: "bold", help: L("太字")) { trait(.boldFontMask) }
            ToolButton(symbol: "italic", help: L("斜体")) { trait(.italicFontMask) }
            ToolButton(symbol: "underline", help: L("下線")) { model.textView?.underline(nil) }
            ToolButton(symbol: "strikethrough", help: L("取り消し線")) { strike() }
            ToolSeparator()
            ToolButton(symbol: "textformat.size.smaller", help: L("小さく")) { size(-1) }
            ToolButton(symbol: "textformat.size.larger", help: L("大きく")) { size(1) }
            Menu {
                ForEach([("黒", NSColor.black), ("赤", .systemRed), ("青", .systemBlue), ("緑", .systemGreen), ("オレンジ", .systemOrange), ("グレー", .gray)], id: \.0) { name, c in
                    Button(L(name)) { color(c) }
                }
            } label: { Image(systemName: "paintpalette").font(.system(size: 14)).frame(width: 32, height: 32) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("文字の色"))
            ToolSeparator()
            ToolButton(symbol: "list.bullet", help: L("箇条書き")) { list(ordered: false) }
            ToolButton(symbol: "list.number", help: L("番号付きリスト")) { list(ordered: true) }
            ToolSeparator()
            ToolButton(symbol: "text.alignleft", help: L("左揃え")) { model.textView?.alignLeft(nil) }
            ToolButton(symbol: "text.aligncenter", help: L("中央揃え")) { model.textView?.alignCenter(nil) }
            ToolButton(symbol: "text.alignright", help: L("右揃え")) { model.textView?.alignRight(nil) }
            Spacer()
        }
    }

    private var tv: NSTextView? { model.textView }

    private func edit(_ range: NSRange? = nil, _ body: (NSTextStorage, NSRange) -> Void) {
        guard let tv, let storage = tv.textStorage else { return }
        let r = range ?? tv.selectedRange()
        guard tv.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.beginEditing(); body(storage, r); storage.endEditing()
        tv.didChangeText()
    }

    private func trait(_ t: NSFontTraitMask) {
        guard let tv else { return }
        let r = tv.selectedRange()
        if r.length == 0 {
            var attrs = tv.typingAttributes
            if let f = attrs[.font] as? NSFont {
                let has = NSFontManager.shared.traits(of: f).contains(t)
                attrs[.font] = has ? NSFontManager.shared.convert(f, toNotHaveTrait: t) : NSFontManager.shared.convert(f, toHaveTrait: t)
                tv.typingAttributes = attrs
            }
            return
        }
        let first = (tv.textStorage?.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 13)
        let adding = !NSFontManager.shared.traits(of: first).contains(t)
        edit { s, r in
            s.enumerateAttribute(.font, in: r) { v, sub, _ in
                guard let f = v as? NSFont else { return }
                var nf = adding ? NSFontManager.shared.convert(f, toHaveTrait: t) : NSFontManager.shared.convert(f, toNotHaveTrait: t)
                if adding, t == .boldFontMask, !nf.fontDescriptor.symbolicTraits.contains(.bold), f.fontName.hasPrefix("HiraginoSans"),
                   let w6 = NSFont(name: "HiraginoSans-W6", size: f.pointSize) { nf = w6 }
                s.addAttribute(.font, value: nf, range: sub)
            }
        }
    }

    private func strike() {
        guard let tv, tv.selectedRange().length > 0 else { return }
        let r = tv.selectedRange()
        let on = (tv.textStorage?.attribute(.strikethroughStyle, at: r.location, effectiveRange: nil) as? Int ?? 0) != 0
        edit { s, r in on ? s.removeAttribute(.strikethroughStyle, range: r) : s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
    }

    private func size(_ delta: CGFloat) {
        guard let tv else { return }
        if tv.selectedRange().length == 0 {
            if let f = tv.typingAttributes[.font] as? NSFont {
                tv.typingAttributes[.font] = NSFontManager.shared.convert(f, toSize: max(6, f.pointSize + delta))
            }
            return
        }
        edit { s, r in
            s.enumerateAttribute(.font, in: r) { v, sub, _ in
                guard let f = v as? NSFont else { return }
                s.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: max(6, f.pointSize + delta)), range: sub)
            }
        }
    }

    private func color(_ c: NSColor) {
        guard let tv else { return }
        if tv.selectedRange().length == 0 { tv.typingAttributes[.foregroundColor] = c; return }
        edit { s, r in s.addAttribute(.foregroundColor, value: c, range: r) }
    }

    private func paragraphRange() -> NSRange? {
        guard let tv else { return nil }
        return (tv.string as NSString).paragraphRange(for: tv.selectedRange())
    }

    private func setBlock(level: Int) {
        guard let pr = paragraphRange(), let tv else { return }
        let base: CGFloat = 13
        let size: CGFloat = level == 0 ? base : [24, 19, 16][level - 1]
        if pr.length == 0 {
            // Empty last line: style what the user types next.
            let f = (tv.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: base)
            var nf = NSFontManager.shared.convert(f, toSize: size)
            nf = level == 0 ? NSFontManager.shared.convert(nf, toNotHaveTrait: .boldFontMask) : NSFontManager.shared.convert(nf, toHaveTrait: .boldFontMask)
            tv.typingAttributes[.font] = nf
            return
        }
        edit(pr) { s, r in
            s.enumerateAttribute(.font, in: r) { v, sub, _ in
                let f = (v as? NSFont) ?? .systemFont(ofSize: base)
                var nf = NSFontManager.shared.convert(f, toSize: size)
                nf = level == 0 ? NSFontManager.shared.convert(nf, toNotHaveTrait: .boldFontMask) : NSFontManager.shared.convert(nf, toHaveTrait: .boldFontMask)
                if level > 0, nf.fontName.hasPrefix("HiraginoSans"), let w6 = NSFont(name: "HiraginoSans-W6", size: size) { nf = w6 }
                if level == 0, nf.fontName.hasPrefix("HiraginoSans-W6"), let w3 = NSFont(name: "HiraginoSans-W3", size: size) { nf = w3 }
                s.addAttribute(.font, value: nf, range: sub)
            }
            let ps = ((s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            ps.headerLevel = level
            ps.paragraphSpacingBefore = level == 0 ? 0 : size * 0.6
            s.addAttribute(.paragraphStyle, value: ps, range: r)
        }
        _ = tv
    }

    /// Toggles a list on the selected paragraphs, with the "\t•\t" markers Cocoa uses.
    private func list(ordered: Bool) {
        guard let tv, let storage = tv.textStorage, let pr = paragraphRange() else { return }
        let ns = storage.string as NSString
        var paragraphs: [NSRange] = []
        var loc = pr.location
        while loc < NSMaxRange(pr) {
            let r = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            paragraphs.append(r); loc = NSMaxRange(r)
            if r.length == 0 { break }
        }
        if pr.length == 0 || pr.location >= storage.length {
            // Empty last line: start a list item here.
            let ps = NSMutableParagraphStyle()
            let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
            ps.textLists = [list]; ps.headIndent = 22; ps.firstLineHeadIndent = 0
            ps.tabStops = [NSTextTab(textAlignment: .left, location: 6), NSTextTab(textAlignment: .left, location: 22)]
            var attrs = tv.typingAttributes
            attrs[.paragraphStyle] = ps
            let marker = ordered ? "\t1.\t" : "\t\(list.marker(forItemNumber: 1))\t"
            tv.insertText(NSAttributedString(string: marker, attributes: attrs), replacementRange: tv.selectedRange())
            tv.typingAttributes = attrs
            return
        }
        let firstStyle = storage.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
        let removing = !(firstStyle?.textLists.isEmpty ?? true)
        guard tv.shouldChangeText(in: pr, replacementString: nil) else { return }
        storage.beginEditing()
        let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
        for (i, r) in paragraphs.enumerated().reversed() where r.length > 0 && r.location < storage.length {
            let ps = ((storage.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            let text = (storage.string as NSString).substring(with: r)
            if removing {
                if let m = text.range(of: #"^\t[^\t]{0,8}\t"#, options: .regularExpression) {
                    storage.deleteCharacters(in: NSRange(location: r.location, length: text.distance(from: text.startIndex, to: m.upperBound)))
                }
                ps.textLists = []; ps.headIndent = 0; ps.firstLineHeadIndent = 0
                storage.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: r.location, length: 0).union(ns.paragraphRange(for: NSRange(location: r.location, length: 0))))
            } else {
                let marker = ordered ? "\t\(i + 1).\t" : "\t\(list.marker(forItemNumber: 1))\t"
                let attrs = storage.attributes(at: r.location, effectiveRange: nil)
                storage.insert(NSAttributedString(string: marker, attributes: attrs), at: r.location)
                ps.textLists = [list]
                ps.headIndent = 22; ps.firstLineHeadIndent = 0
                ps.tabStops = [NSTextTab(textAlignment: .left, location: 6), NSTextTab(textAlignment: .left, location: 22)]
                let newRange = (storage.string as NSString).paragraphRange(for: NSRange(location: r.location, length: 0))
                storage.addAttribute(.paragraphStyle, value: ps, range: newRange)
            }
        }
        storage.endEditing()
        tv.didChangeText()
    }
}
