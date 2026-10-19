import AppKit
import SwiftUI
import PDFKit
import EnsoShared

/// PDFView with MaruDoc's drawing tools. Annotations are created in page space; the overlay shows drags in view space.
final class EnsoPDFView: PDFView, NSTextFieldDelegate {
    weak var model: PDFEditorModel?
    let overlay = ToolOverlay()

    fileprivate var dragStart: CGPoint?
    fileprivate var dragCurrent: CGPoint?
    fileprivate var dragPage: PDFPage?
    fileprivate var inkPoints: [CGPoint] = []
    private(set) var selectedAnnotation: PDFAnnotation?
    private var moveOrigin: CGRect?
    private var editor: NSTextField?
    private var editCommit: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.pdfView = self
        addSubview(overlay)
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewVisiblePagesChanged] {
            NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in self?.refreshOverlay() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        if model?.mode == .crop { fitCropPage() }
        observeScrolling()
    }

    func refreshOverlay() {
        overlay.needsDisplay = true
        window?.invalidateCursorRects(for: overlay)
    }

    // The overlay follows the page when the document scrolls.
    private var clipObserver: NSObjectProtocol?
    private weak var observedClip: NSClipView?

    private func observeScrolling() {
        func scrollView(in v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView { return s }
            for sub in v.subviews where sub !== overlay { if let s = scrollView(in: sub) { return s } }
            return nil
        }
        guard let clip = scrollView(in: self)?.contentView, clip !== observedClip else { return }
        if let old = clipObserver { NotificationCenter.default.removeObserver(old) }
        clip.postsBoundsChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            self?.refreshOverlay()
        }
        observedClip = clip
    }

    /// Continuous scrolling at the page width for viewing and markup; one whole page fitted in the view for cropping.
    func configure(for mode: PDFEditorModel.Mode) {
        let page = document?.page(at: model?.selectedPage ?? 0)
        if mode == .crop {
            autoScales = false
            displayMode = .singlePage
            displaysPageBreaks = false
            minScaleFactor = 0.05
            maxScaleFactor = 8
            if let page { go(to: page) }
            fitCropPage()
        } else {
            displayMode = .singlePageContinuous
            displaysPageBreaks = true
            autoScales = true
            if let page { go(to: page) }
        }
        refreshOverlay()
    }

    /// Called when the crop page changes: show it and fit it.
    func cropPageChanged() {
        guard model?.mode == .crop, let page = cropPage else { return }
        if currentPage !== page { go(to: page) }
        fitCropPage()
        refreshOverlay()
    }

    private func fitCropPage() {
        guard let page = cropPage, bounds.width > 120, bounds.height > 120 else { return }
        let ds = CropGeometry.displaySize(of: page)
        guard ds.width > 1, ds.height > 1 else { return }
        let margin: CGFloat = 40   // room for the handles (10 pt, centred on the edge) and the size label
        let target = max(0.05, min((bounds.width - margin * 2) / ds.width, (bounds.height - margin * 2) / ds.height))
        if abs(scaleFactor - target) > 0.0005 { scaleFactor = target }
    }

    /// The first click in the popup should already draw / select, not just bring the panel forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    fileprivate var tool: PDFTool { model?.tool ?? .select }
    private var color: NSColor { model?.color ?? .systemYellow }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitEditing()
        let vp = convert(event.locationInWindow, from: nil)
        guard let model else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        if model.mode == .crop { cropMouseDown(vp); return }
        if model.mode != .annotate { super.mouseDown(with: event); return }
        guard let page = page(for: vp, nearest: true) else { super.mouseDown(with: event); return }
        let pp = convert(vp, to: page)

        switch tool {
        case .select:
            if let a = page.annotation(at: pp), a.isEnsoEditable {
                if event.clickCount == 2, a.type == "FreeText" { editFreeText(a, on: page); return }
                selectedAnnotation = a; moveOrigin = a.bounds; dragStart = vp; dragPage = page
                overlay.needsDisplay = true
                return
            }
            selectedAnnotation = nil
            overlay.needsDisplay = true
            super.mouseDown(with: event)
        case .highlight, .underline, .strike:
            dragStart = vp; dragCurrent = vp; dragPage = page
            super.mouseDown(with: event)
        case .text where page.rotation != 0, .fixText where page.rotation != 0:
            model.hint = L("回転したページには文字を書き込めません。ページを整理で回転を戻してから追加してください")
        case .text:
            beginEditing(at: vp, initial: "", fontSize: 14) { [weak self] text in
                guard let self, !text.isEmpty else { return }
                let a = Self.freeText(text, topLeft: pp, fontSize: 14, color: self.color == .systemYellow ? .black : self.color)
                model.add(a, to: page)
            }
        case .fixText:
            fixText(at: pp, on: page)
        case .note:
            beginEditing(at: vp, initial: "", fontSize: 13, width: 220) { [weak self] text in
                guard let self, !text.isEmpty else { return }
                let a = PDFAnnotation(bounds: CGRect(x: pp.x - 10, y: pp.y - 10, width: 20, height: 20), forType: .text, withProperties: nil)
                a.contents = text
                a.color = self.color
                a.iconType = .comment
                model.add(a, to: page)
            }
        case .signature:
            placeSignature(at: pp, on: page)
        case .pen:
            inkPoints = [pp]; dragPage = page
        case .rect, .oval, .arrow, .whiteout, .redact:
            dragStart = vp; dragCurrent = vp; dragPage = page
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        guard let model else { super.mouseDragged(with: event); return }
        if model.mode == .crop { cropMouseDragged(vp, shift: event.modifierFlags.contains(.shift)); return }
        if model.mode != .annotate { super.mouseDragged(with: event); return }
        switch tool {
        case .select:
            if let a = selectedAnnotation, let origin = moveOrigin, let start = dragStart, let page = dragPage {
                let p0 = convert(start, to: page), p1 = convert(vp, to: page)
                a.bounds = origin.offsetBy(dx: p1.x - p0.x, dy: p1.y - p0.y)
                overlay.needsDisplay = true
                setNeedsDisplay(bounds)
            } else { super.mouseDragged(with: event) }
        case .highlight, .underline, .strike:
            dragCurrent = vp
            super.mouseDragged(with: event)
        case .pen:
            if let page = dragPage { inkPoints.append(convert(vp, to: page)); overlay.needsDisplay = true }
        case .rect, .oval, .arrow, .whiteout, .redact:
            dragCurrent = vp; overlay.needsDisplay = true
        default:
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { super.mouseUp(with: event); return }
        defer { overlay.needsDisplay = true }
        if model.mode == .crop { cropMouseUp(); return }
        if model.mode != .annotate { super.mouseUp(with: event); return }

        switch tool {
        case .select:
            if let a = selectedAnnotation, let origin = moveOrigin, a.bounds != origin { model.moved(a, from: origin) }
            moveOrigin = nil; dragStart = nil
            if selectedAnnotation == nil { super.mouseUp(with: event) }
        case .highlight, .underline, .strike:
            super.mouseUp(with: event)
            let subtype: PDFAnnotationSubtype = tool == .highlight ? .highlight : tool == .underline ? .underline : .strikeOut
            if let sel = currentSelection, !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for line in sel.selectionsByLine() {
                    for page in line.pages {
                        let b = line.bounds(for: page)
                        guard b.width > 1, b.height > 1 else { continue }
                        model.add(Self.markup(subtype, bounds: b, color: color), to: page)
                    }
                }
                clearSelection()
            } else if tool == .highlight, let s = dragStart, let c = dragCurrent, let page = dragPage {
                // No text under the drag (e.g. a scan): highlight the area instead.
                let r = Self.rect(convert(s, to: page), convert(c, to: page))
                if r.width > 6, r.height > 4 {
                    let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
                    a.color = .clear
                    a.interiorColor = color.withAlphaComponent(0.38)
                    a.border = Self.border(0)
                    model.add(a, to: page)
                }
            }
            dragStart = nil; dragCurrent = nil
        case .pen:
            if let page = dragPage, inkPoints.count > 1 { model.add(Self.ink([inkPoints], color: color, width: 2), to: page) }
            inkPoints = []; dragPage = nil
        case .rect, .oval, .arrow, .whiteout, .redact:
            if let s = dragStart, let c = dragCurrent, let page = dragPage {
                let a0 = convert(s, to: page), a1 = convert(c, to: page)
                let r = Self.rect(a0, a1)
                if tool == .arrow, hypot(a1.x - a0.x, a1.y - a0.y) > 6 {
                    model.add(Self.arrow(from: a0, to: a1, color: color), to: page)
                } else if r.width > 4, r.height > 4 {
                    model.add(shape(r), to: page)
                }
            }
            dragStart = nil; dragCurrent = nil
        default:
            super.mouseUp(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if let model, model.mode == .crop {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 53: model.cancelCrop(); return
            case 36, 76: model.applyCrop(); return
            case 123: nudgeCrop(dx: -step, dy: 0); return
            case 124: nudgeCrop(dx: step, dy: 0); return
            case 125: nudgeCrop(dx: 0, dy: -step); return
            case 126: nudgeCrop(dx: 0, dy: step); return
            default: break
            }
        }
        if let a = selectedAnnotation, event.keyCode == 51 || event.keyCode == 117 {
            model?.remove(a)
            selectedAnnotation = nil
            overlay.needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let model, model.mode == .annotate else { return }
        if [.rect, .oval, .arrow, .whiteout, .redact, .pen].contains(tool) {
            addCursorRect(bounds, cursor: .crosshair)
        } else if tool == .text || tool == .fixText || tool == .note {
            addCursorRect(bounds, cursor: .iBeam)
        }
    }

    // MARK: Crop frame

    private var cropDrag: CropDrag?
    private var cropStart = CGRect.zero          // frame at mouse down, display space
    private var cropStartPoint = CGPoint.zero    // mouse at mouse down, display space

    private var cropPage: PDFPage? { document?.page(at: model?.selectedPage ?? 0) }

    private func toDisplay(_ vp: CGPoint, _ page: PDFPage) -> CGPoint {
        CropGeometry.pageToDisplay(convert(vp, to: page), box: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    private func displayFrame(_ page: PDFPage) -> CGRect? {
        model?.cropRect.map { CropGeometry.rectToDisplay($0, box: page.bounds(for: .cropBox), rotation: page.rotation) }
    }

    private func setDisplayFrame(_ r: CGRect, _ page: PDFPage) {
        model?.cropRect = CropGeometry.rectToPage(r, box: page.bounds(for: .cropBox), rotation: page.rotation)
        overlay.needsDisplay = true
    }

    private func cropMouseDown(_ vp: CGPoint) {
        guard let page = cropPage else { return }
        let p = toDisplay(vp, page)
        let frame = displayFrame(page)
        cropStart = frame ?? CGRect(origin: p, size: .zero)
        cropStartPoint = p
        cropDrag = frame.map { CropGeometry.zone(at: p, frame: $0, tolerance: 7 / max(scaleFactor, 0.01)) } ?? .draw
        if case .move = cropDrag { NSCursor.closedHand.set() }
    }

    private func cropMouseDragged(_ vp: CGPoint, shift: Bool) {
        guard let page = cropPage, let drag = cropDrag else { return }
        let p = toDisplay(vp, page)
        let ds = CropGeometry.displaySize(of: page)
        let r: CGRect
        switch drag {
        case .move:
            r = CropGeometry.move(cropStart, by: CGVector(dx: p.x - cropStartPoint.x, dy: p.y - cropStartPoint.y), bounds: ds)
        case .resize(let h):
            r = CropGeometry.resize(cropStart, handle: h, to: p, bounds: ds, minSize: max(8, 12 / max(scaleFactor, 0.01)), keepAspect: shift)
        case .draw:
            let aspect: CGFloat? = shift ? (cropStart.height > 1 ? cropStart.width / cropStart.height : ds.width / ds.height) : nil
            r = CropGeometry.draw(from: cropStartPoint, to: p, bounds: ds, aspect: aspect)
        }
        setDisplayFrame(r, page)
    }

    private func cropMouseUp() {
        defer { cropDrag = nil; model?.objectWillChange.send(); refreshOverlay() }
        guard case .draw? = cropDrag, let page = cropPage, let r = displayFrame(page), r.width < 8 || r.height < 8 else { return }
        // A click outside the frame, not a drag: keep what was there.
        if cropStart.width >= 8, cropStart.height >= 8 { setDisplayFrame(cropStart, page) } else { model?.resetCropFrame() }
    }

    private func nudgeCrop(dx: CGFloat, dy: CGFloat) {
        guard let page = cropPage, let f = displayFrame(page) else { return }
        setDisplayFrame(CropGeometry.move(f, by: CGVector(dx: dx, dy: dy), bounds: CropGeometry.displaySize(of: page)), page)
        model?.objectWillChange.send()
        refreshOverlay()
    }

    // MARK: Building annotations

    private func shape(_ r: CGRect) -> PDFAnnotation {
        switch tool {
        case .oval:
            let a = PDFAnnotation(bounds: r, forType: .circle, withProperties: nil)
            a.color = color; a.border = Self.border(2)
            return a
        case .whiteout:
            let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
            a.color = .white; a.interiorColor = .white; a.border = Self.border(0)
            return a
        case .redact:
            let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
            a.color = .black; a.interiorColor = .black; a.border = Self.border(0)
            a.setValue("1", forAnnotationKey: PDFAnnotation.redactKey)
            return a
        default:
            let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
            a.color = color; a.border = Self.border(2)
            return a
        }
    }

    static func border(_ w: CGFloat) -> PDFBorder {
        let b = PDFBorder(); b.lineWidth = w; return b
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func markup(_ type: PDFAnnotationSubtype, bounds b: CGRect, color: NSColor) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
        a.color = type == .highlight ? color.withAlphaComponent(0.45) : color
        let w = b.width, h = b.height
        a.quadrilateralPoints = [NSValue(point: NSPoint(x: 0, y: h)), NSValue(point: NSPoint(x: w, y: h)),
                                 NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: w, y: 0))]
        return a
    }

    /// Ink strokes given in page coordinates; paths are stored relative to the annotation's origin.
    static func ink(_ strokes: [[CGPoint]], color: NSColor, width: CGFloat) -> PDFAnnotation {
        let all = strokes.flatMap { $0 }
        let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 0
        let minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 0
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -width * 2, dy: -width * 2)
        let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        a.color = color
        a.border = border(width)
        for s in strokes where s.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: CGPoint(x: s[0].x - bounds.minX, y: s[0].y - bounds.minY))
            for p in s.dropFirst() { path.line(to: CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)) }
            a.add(path)
        }
        return a
    }

    static func arrow(from a0: CGPoint, to a1: CGPoint, color: NSColor) -> PDFAnnotation {
        let bounds = rect(a0, a1).insetBy(dx: -10, dy: -10)
        let a = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        a.startPoint = CGPoint(x: a0.x - bounds.minX, y: a0.y - bounds.minY)
        a.endPoint = CGPoint(x: a1.x - bounds.minX, y: a1.y - bounds.minY)
        a.endLineStyle = .closedArrow
        a.color = color
        a.interiorColor = color
        a.border = border(2)
        return a
    }

    static func freeText(_ text: String, topLeft: CGPoint, fontSize: CGFloat, color: NSColor) -> PDFAnnotation {
        let font = NSFont(name: "HiraginoSans-W3", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let size = (text as NSString).boundingRect(with: CGSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: font]).size
        let bounds = CGRect(x: topLeft.x - 2, y: topLeft.y - ceil(size.height) - 2, width: ceil(size.width) + 10, height: ceil(size.height) + 4)
        let a = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = font
        a.fontColor = color
        a.color = .clear
        a.border = border(0)
        a.alignment = .left
        return a
    }

    // MARK: Text editing overlay

    private func beginEditing(at viewPoint: CGPoint, initial: String, fontSize: CGFloat, width: CGFloat = 260, commit: @escaping (String) -> Void) {
        let scaled = fontSize * scaleFactor
        let field = NSTextField(frame: NSRect(x: viewPoint.x - 3, y: viewPoint.y - scaled * 1.5, width: max(width * scaleFactor, 120), height: scaled * 1.5 + 6))
        field.font = NSFont(name: "HiraginoSans-W3", size: scaled) ?? .systemFont(ofSize: scaled)
        field.stringValue = initial
        field.isBordered = true
        field.focusRingType = .exterior
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.95)
        field.placeholderString = L("文字を入力")
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)
        window?.makeFirstResponder(field)
        editor = field
        editCommit = commit
    }

    func commitEditing() {
        guard let field = editor else { return }
        let text = field.stringValue
        editor = nil
        field.removeFromSuperview()
        let c = editCommit
        editCommit = nil
        c?(text)
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commitEditing(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            editCommit = nil
            editor?.removeFromSuperview(); editor = nil
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if editor != nil { commitEditing() }
    }

    private func editFreeText(_ a: PDFAnnotation, on page: PDFPage) {
        let r = convert(a.bounds, from: page)
        let size = a.font?.pointSize ?? 14
        beginEditing(at: CGPoint(x: r.minX + 2, y: r.maxY), initial: a.contents ?? "", fontSize: size) { [weak self] text in
            guard let self, let model = self.model else { return }
            model.remove(a)
            if !text.isEmpty {
                model.add(Self.freeText(text, topLeft: CGPoint(x: a.bounds.minX + 2, y: a.bounds.maxY - 2), fontSize: size, color: a.fontColor ?? .black), to: page)
            }
        }
    }

    /// "Fix text": covers the clicked line with white and writes the corrected line on top in the same size.
    private func fixText(at pp: CGPoint, on page: PDFPage) {
        guard let model else { return }
        guard let sel = page.selectionForLine(at: pp), let raw = sel.string,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.hint = L("ここには文字がありません (スキャンした PDF は「文字を追加」と「白塗り」で直せます)")
            return
        }
        let original = raw.trimmingCharacters(in: .newlines)
        let b = sel.bounds(for: page)
        var fontSize = b.height * 0.82
        var fontColor = NSColor.black
        if let attr = sel.attributedString, attr.length > 0 {
            if let f = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { fontSize = f.pointSize }
            if let c = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor { fontColor = c }
        }
        let vr = convert(b, from: page)
        beginEditing(at: CGPoint(x: vr.minX, y: vr.maxY + 2), initial: original, fontSize: fontSize, width: max(b.width + 40, 160)) { text in
            guard text != original else { return }
            let cover = PDFAnnotation(bounds: b.insetBy(dx: -1, dy: -1), forType: .square, withProperties: nil)
            cover.color = .white; cover.interiorColor = .white; cover.border = Self.border(0)
            model.add(cover, to: page)
            if !text.isEmpty {
                model.add(Self.freeText(text, topLeft: CGPoint(x: b.minX, y: b.maxY + 1), fontSize: fontSize, color: fontColor), to: page)
            }
        }
    }

    // MARK: Signature

    private func placeSignature(at pp: CGPoint, on page: PDFPage) {
        guard let model else { return }
        if let strokes = SignatureStore.load(), !strokes.isEmpty {
            // Lay the signature out upright on screen, then map into page space (works on rotated pages too).
            let width: CGFloat = 150 * scaleFactor
            let v = convert(pp, from: page)
            let placed = strokes.map { s in s.map { n in
                convert(CGPoint(x: v.x + (n.x - 0.5) * width, y: v.y + (n.y - SignatureStore.aspect / 2) * width), to: page)
            } }
            model.add(Self.ink(placed, color: .black, width: 1.6), to: page)
        } else if let window {
            SignaturePad.present(on: window) { [weak self] in self?.placeSignature(at: pp, on: page) }
        }
    }
}

/// Draws in-progress drags, the crop frame and the selected annotation. Never takes mouse events.
final class ToolOverlay: NSView {
    weak var pdfView: EnsoPDFView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    /// The crop frame in this view's coordinates.
    private func cropFrame() -> (page: PDFPage, rect: NSRect)? {
        guard let v = pdfView, let model = v.model, model.mode == .crop, let r = model.cropRect,
              let page = v.document?.page(at: model.selectedPage) else { return nil }
        return (page, convert(v.convert(r, from: page), from: v))
    }

    static func cursor(for h: CropHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch h {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch h {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    /// Crosshair outside the frame, resize cursors on its edges and corners, open hand inside. The areas don't overlap.
    override func resetCursorRects() {
        guard let v = pdfView, v.model?.mode == .crop else { return }
        func add(_ r: NSRect, _ c: NSCursor) { if r.width > 0.5, r.height > 0.5 { addCursorRect(r, cursor: c) } }
        guard let f = cropFrame()?.rect else { add(bounds, .crosshair); return }
        let e: CGFloat = 6
        let o = f.insetBy(dx: -e, dy: -e)
        add(NSRect(x: bounds.minX, y: o.maxY, width: bounds.width, height: bounds.maxY - o.maxY), .crosshair)
        add(NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: o.minY - bounds.minY), .crosshair)
        add(NSRect(x: bounds.minX, y: o.minY, width: o.minX - bounds.minX, height: o.height), .crosshair)
        add(NSRect(x: o.maxX, y: o.minY, width: bounds.maxX - o.maxX, height: o.height), .crosshair)
        add(f.insetBy(dx: e, dy: e), .openHand)
        let d = e * 2
        add(NSRect(x: o.minX, y: o.maxY - d, width: d, height: d), Self.cursor(for: .topLeft))
        add(NSRect(x: o.maxX - d, y: o.maxY - d, width: d, height: d), Self.cursor(for: .topRight))
        add(NSRect(x: o.minX, y: o.minY, width: d, height: d), Self.cursor(for: .bottomLeft))
        add(NSRect(x: o.maxX - d, y: o.minY, width: d, height: d), Self.cursor(for: .bottomRight))
        add(NSRect(x: o.minX, y: o.minY + d, width: d, height: o.height - 2 * d), Self.cursor(for: .left))
        add(NSRect(x: o.maxX - d, y: o.minY + d, width: d, height: o.height - 2 * d), Self.cursor(for: .right))
        add(NSRect(x: o.minX + d, y: o.maxY - d, width: o.width - 2 * d, height: d), Self.cursor(for: .top))
        add(NSRect(x: o.minX + d, y: o.minY, width: o.width - 2 * d, height: d), Self.cursor(for: .bottom))
    }

    private func drawCrop(page: PDFPage, frame cr: NSRect, in v: EnsoPDFView) {
        let pageRect = convert(v.convert(page.bounds(for: .cropBox), from: page), from: v)
        let dim = NSBezierPath(rect: pageRect)
        dim.append(NSBezierPath(rect: cr))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill(); dim.fill()

        let outer = NSBezierPath(rect: cr.insetBy(dx: -1, dy: -1)); outer.lineWidth = 1
        NSColor.black.withAlphaComponent(0.55).setStroke(); outer.stroke()
        let line = NSBezierPath(rect: cr); line.lineWidth = 1
        NSColor.white.setStroke(); line.stroke()

        for h in CropHandle.allCases {
            let c = h.point(on: cr)
            let hr = NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
            let p = NSBezierPath(rect: hr); p.lineWidth = 1
            NSColor.white.setFill(); p.fill()
            NSColor.black.withAlphaComponent(0.6).setStroke(); p.stroke()
        }

        // Size below the frame when there is room, else inside just above the bottom edge. Never on a handle.
        let shown = CropGeometry.rectToDisplay(v.model?.cropRect ?? .zero, box: page.bounds(for: .cropBox), rotation: page.rotation)
        let text = CropGeometry.sizeLabel(widthPt: shown.width, heightPt: shown.height) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let ts = text.size(withAttributes: attrs)
        let lw = ceil(ts.width) + 16, lh = ceil(ts.height) + 8
        let pill = CropGeometry.labelRect(size: CGSize(width: lw, height: lh), frame: cr, bounds: bounds)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4), withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let v = pdfView, let model = v.model else { return }
        let accent = NSColor.controlAccentColor
        if let crop = cropFrame() { drawCrop(page: crop.page, frame: crop.rect, in: v) }
        let shapeTools: [PDFTool] = [.rect, .oval, .whiteout, .redact]
        if let s = v.dragStart, let c = v.dragCurrent, model.mode == .annotate && shapeTools.contains(v.tool) {
            let r = NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
            let p = v.tool == .oval ? NSBezierPath(ovalIn: convert(r, from: v)) : NSBezierPath(rect: convert(r, from: v))
            p.lineWidth = 1
            p.setLineDash([4, 3], count: 2, phase: 0)
            let fill: NSColor = v.tool == .redact ? .black.withAlphaComponent(0.6) : accent.withAlphaComponent(0.12)
            fill.setFill(); p.fill()
            accent.setStroke(); p.stroke()
        }
        if model.mode == .annotate, v.tool == .arrow, let s = v.dragStart, let c = v.dragCurrent {
            let p = NSBezierPath()
            p.move(to: convert(s, from: v)); p.line(to: convert(c, from: v))
            p.lineWidth = 2 * v.scaleFactor
            model.color.setStroke(); p.stroke()
        }
        if v.inkPoints.count > 1, let page = v.dragPage {
            let pts = v.inkPoints.map { convert(v.convert($0, from: page), from: v) }
            let path = NSBezierPath()
            path.move(to: pts[0])
            for pt in pts.dropFirst() { path.line(to: pt) }
            path.lineWidth = 2 * v.scaleFactor
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            model.color.setStroke(); path.stroke()
        }
        if let a = v.selectedAnnotation, let page = a.page {
            let r = convert(v.convert(a.bounds, from: page), from: v).insetBy(dx: -3, dy: -3)
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            p.lineWidth = 1.5
            p.setLineDash([5, 3], count: 2, phase: 0)
            accent.setStroke(); p.stroke()
        }
    }
}

