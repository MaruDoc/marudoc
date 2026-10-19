import AppKit
import SwiftUI
import EnsoOffice

/// Word-processor page layout: white pages of the document's paper size on a grey desk, text flowing from page to
/// page inside the document's margins. One NSTextView per page, all sharing one layout manager, so editing,
/// selection and undo work across pages as in one text.
final class PagedDocumentView: NSView, NSLayoutManagerDelegate {
    let storage: NSTextStorage
    let layoutManager = BorderLayoutManager()
    private(set) var pageSize: CGSize
    private(set) var margins: NSEdgeInsets
    /// Read-only header and footer drawn on every page (.docx).
    var headerFooter: DocxHeaderFooter? { didSet { needsDisplay = true } }
    private(set) var textViews: [NSTextView] = []
    weak var textDelegate: NSTextViewDelegate?
    /// Called with the number of pages whenever it may have changed.
    var onPageCountChange: ((Int) -> Void)?

    private var ready = false
    private var addingPage = false

    static let gap: CGFloat = 28
    static let side: CGFloat = 36

    override var isFlipped: Bool { true }

    /// `usesFontLeading` false for .docx: the reader sets every line height itself, the way Word measures lines.
    init(storage: NSTextStorage, pageSize: CGSize, margins: NSEdgeInsets, usesFontLeading: Bool = true, headerFooter: DocxHeaderFooter? = nil) {
        self.storage = storage
        self.headerFooter = headerFooter
        self.pageSize = pageSize
        self.margins = margins
        super.init(frame: .zero)
        layoutManager.delegate = self
        layoutManager.allowsNonContiguousLayout = false
        layoutManager.usesFontLeading = usesFontLeading
        storage.addLayoutManager(layoutManager)
        addPage()
        // Lay out everything now: keep adding pages until the last one holds the end of the text.
        var guardCount = 0
        while guardCount < 2000, let last = layoutManager.textContainers.last {
            layoutManager.ensureLayout(for: last)
            let gr = layoutManager.glyphRange(for: last)
            if NSMaxRange(gr) >= layoutManager.numberOfGlyphs { break }
            addPage()
            guardCount += 1
        }
        ready = true
        updateFrame()
    }

    required init?(coder: NSCoder) { fatalError() }

    var contentSize: CGSize {
        CGSize(width: max(40, pageSize.width - margins.left - margins.right), height: max(40, pageSize.height - margins.top - margins.bottom))
    }

    func pageRect(_ i: Int) -> CGRect {
        CGRect(x: Self.side, y: Self.gap + CGFloat(i) * (pageSize.height + Self.gap), width: pageSize.width, height: pageSize.height)
    }

    private func addPage() {
        guard !addingPage else { return }
        addingPage = true
        defer { addingPage = false }
        let container = NSTextContainer(size: contentSize)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        let page = pageRect(textViews.count)
        // The view is created before its container joins the layout manager, so layout can't run (and ask for
        // more pages) while this page is half set up.
        let tv = PageTextView(frame: CGRect(x: page.minX + margins.left, y: page.minY + margins.top, width: contentSize.width, height: contentSize.height),
                              textContainer: container)
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.importsGraphics = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.insertionPointColor = .black
        tv.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.70, green: 0.84, blue: 1.0, alpha: 1)]
        // Paper stays paper in dark mode.
        tv.appearance = NSAppearance(named: .aqua)
        tv.delegate = textDelegate
        textViews.append(tv)
        addSubview(tv)
        layoutManager.addTextContainer(container)
    }

    private func removeLastPage() {
        guard textViews.count > 1, let tv = textViews.popLast() else { return }
        if let c = tv.textContainer, let i = layoutManager.textContainers.firstIndex(of: c) { layoutManager.removeTextContainer(at: i) }
        tv.removeFromSuperview()
    }

    private func updateFrame() {
        let h = Self.gap + CGFloat(textViews.count) * (pageSize.height + Self.gap)
        setFrameSize(NSSize(width: pageSize.width + Self.side * 2, height: h))
        needsDisplay = true
        onPageCountChange?(textViews.count)
    }

    func setDelegate(_ d: NSTextViewDelegate) {
        textDelegate = d
        textViews.forEach { $0.delegate = d }
    }

    // Add or drop pages as the text grows or shrinks while editing (never re-entrantly from inside layout).
    func layoutManager(_ lm: NSLayoutManager, didCompleteLayoutFor container: NSTextContainer?, atEnd: Bool) {
        guard ready else { return }
        let containers = lm.textContainers
        if container == nil || (container == containers.last && !atEnd) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let last = self.layoutManager.textContainers.last else { return }
                let gr = self.layoutManager.glyphRange(for: last)
                if NSMaxRange(gr) < self.layoutManager.numberOfGlyphs { self.addPage(); self.updateFrame() }
            }
        } else if atEnd, let c = container, let i = containers.firstIndex(of: c), i < containers.count - 1 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                while self.layoutManager.textContainers.count - 1 > i { self.removeLastPage() }
                self.updateFrame()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        for i in textViews.indices {
            let r = pageRect(i)
            guard r.intersects(dirtyRect.insetBy(dx: -20, dy: -20)) else { continue }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)
            shadow.set()
            NSColor.white.setFill()
            r.fill()
            NSGraphicsContext.restoreGraphicsState()
            if let hf = headerFooter { drawHeaderFooter(hf, page: i, in: r) }
        }
    }

    /// Header text starts `headerDistance` below the page top, footer text ends `footerDistance` above the bottom.
    private func drawHeaderFooter(_ hf: DocxHeaderFooter, page i: Int, in r: CGRect) {
        let width = contentSize.width, total = textViews.count
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        if let h = hf.header(page: i + 1, of: total) {
            h.draw(with: CGRect(x: r.minX + margins.left, y: r.minY + hf.headerDistance, width: width, height: r.height), options: opts, context: nil)
        }
        if let f = hf.footer(page: i + 1, of: total) {
            let height = ceil(f.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: opts, context: nil).height)
            f.draw(with: CGRect(x: r.minX + margins.left, y: r.maxY - hf.footerDistance - height, width: width, height: height), options: opts, context: nil)
        }
    }

    var firstTextView: NSTextView? { textViews.first }
}

/// Draws paragraph borders (`docxBorders`) behind the text: the top line above a paragraph's first line, the bottom
/// line below its last line, each only on the page that holds that line, spanning the paragraph's indents.
final class BorderLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, glyphsToShow.length > 0,
              let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil) else { return }
        let text = storage.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var loc = chars.location
        while loc < NSMaxRange(chars) {
            let pr = text.paragraphRange(for: NSRange(location: loc, length: 0))
            guard pr.length > 0 else { break }
            loc = NSMaxRange(pr)
            guard let b = storage.attribute(.docxBorders, at: pr.location, effectiveRange: nil) as? DocxParagraphBorders else { continue }
            let prev = pr.location > 0 ? storage.attribute(.docxBorders, at: pr.location - 1, effectiveRange: nil) as? DocxParagraphBorders : nil
            let next = loc < storage.length ? storage.attribute(.docxBorders, at: loc, effectiveRange: nil) as? DocxParagraphBorders : nil
            let style = storage.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
            let gr = glyphRange(forCharacterRange: pr, actualCharacterRange: nil)
            var g = gr.location
            while g < NSMaxRange(gr) {
                var eff = NSRange()
                let c = textContainer(forGlyphAt: g, effectiveRange: &eff)
                let part = NSIntersectionRange(eff, gr)
                guard part.length > 0 else { break }
                g = NSMaxRange(part)
                guard c === container else { continue }
                draw(b, prev: prev, next: next, style: style, part: part, startsParagraph: part.location == gr.location,
                     endsParagraph: NSMaxRange(part) == NSMaxRange(gr), container: container, origin: origin)
            }
        }
    }

    private func draw(_ b: DocxParagraphBorders, prev: DocxParagraphBorders?, next: DocxParagraphBorders?, style: NSParagraphStyle?, part: NSRange,
                      startsParagraph: Bool, endsParagraph: Bool, container: NSTextContainer, origin: NSPoint) {
        let first = lineFragmentUsedRect(forGlyphAt: part.location, effectiveRange: nil)
        let last = lineFragmentUsedRect(forGlyphAt: NSMaxRange(part) - 1, effectiveRange: nil)
        let left = origin.x + min(style?.headIndent ?? 0, style?.firstLineHeadIndent ?? 0)
        let tail = style?.tailIndent ?? 0
        let right = origin.x + (tail <= 0 ? container.size.width + tail : tail)
        let top = origin.y + first.minY, bottom = origin.y + last.maxY

        func line(_ e: DocxParagraphBorders.Edge, _ r: NSRect) {
            (e.color.flatMap(Self.color) ?? .black).setFill()
            r.fill()
        }
        let sameAsPrev = prev == b, sameAsNext = next == b
        if startsParagraph, !sameAsPrev, let e = b.top {
            line(e, NSRect(x: left, y: top - e.space - e.width, width: right - left, height: e.width))
        }
        if endsParagraph {
            if !sameAsNext, let e = b.bottom {
                line(e, NSRect(x: left, y: bottom + e.space, width: right - left, height: e.width))
            } else if sameAsNext, let e = b.between {
                line(e, NSRect(x: left, y: bottom + e.space, width: right - left, height: e.width))
            }
        }
        let y0 = top - ((startsParagraph && !sameAsPrev ? b.top?.space : 0) ?? 0)
        let y1 = bottom + ((endsParagraph && !sameAsNext ? b.bottom?.space : 0) ?? 0)
        if let e = b.left { line(e, NSRect(x: max(0, left - e.space - e.width), y: y0, width: e.width, height: y1 - y0)) }
        if let e = b.right { line(e, NSRect(x: right + e.space, y: y0, width: e.width, height: y1 - y0)) }
    }

    private static func color(_ hex: String) -> NSColor? {
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// A page's text view. Typing at the very end of a full page is handled by the shared layout manager.
final class PageTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Keeps the pages centred when the window is wider than a page.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        return r
    }
}

/// SwiftUI wrapper: scroll view + paged document, with zoom.
struct PagedEditorView: NSViewRepresentable {
    let document: PagedDocumentView
    @Binding var zoom: CGFloat
    var delegate: NSTextViewDelegate

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 3
        scroll.documentView = document
        document.setDelegate(delegate)
        DispatchQueue.main.async {
            scroll.magnification = zoom
            document.scroll(.zero)
            if let tv = document.firstTextView {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if abs(scroll.magnification - zoom) > 0.001 {
            scroll.setMagnification(zoom, centeredAt: NSPoint(x: document.bounds.midX, y: scroll.documentVisibleRect.midY))
        }
    }
}
