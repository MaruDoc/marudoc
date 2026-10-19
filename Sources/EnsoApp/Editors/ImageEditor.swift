import AppKit
import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import EnsoShared
import EnsoCore
import EnsoDoc

// MARK: - Model

struct ImageMark: Identifiable, Equatable {
    enum Kind: Equatable { case pen([CGPoint]), rect(CGRect), arrow(CGPoint, CGPoint), text(String, CGPoint, Double) }
    let id = UUID()
    var kind: Kind
    var color: NSColor
    static func == (a: ImageMark, b: ImageMark) -> Bool { a.id == b.id }
}

enum AspectChoice: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x2, r16x9
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: return L("自由")
        case .original: return L("元の比率")
        case .square: return "1:1"
        case .r4x3: return "4:3"
        case .r3x2: return "3:2"
        case .r16x9: return "16:9"
        }
    }
    /// Width / height in landscape; nil for free. `size` is the image the crop is on.
    func ratio(for size: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return size.height > 0 ? size.width / size.height : nil
        case .square: return 1
        case .r4x3: return 4.0 / 3
        case .r3x2: return 3.0 / 2
        case .r16x9: return 16.0 / 9
        }
    }
    /// 縦横を入れ替え makes no difference to a free or square frame.
    var canSwap: Bool { self != .free && self != .square }
}

final class ImageEditorModel: ObservableObject {
    enum Mode { case crop, adjust, markup }
    enum MarkTool: String, CaseIterable { case pen, rect, arrow, text }

    /// The file this editor currently stands for: the opened file at first, then the new file a save wrote.
    @Published private(set) var url: URL
    /// The file that was opened, which "元のファイルに上書き" replaces.
    let originalURL: URL
    /// `url` is a file this editor wrote (not the original), so default saves update it in place.
    private(set) var ownsFile = false
    private(set) var original: CGImage
    private(set) var previewBase: CGImage
    private(set) var properties: [CFString: Any]
    private(set) var type: UTType
    /// The opened file is in a format that can be written back faithfully. Decided once: after a save the editor
    /// shows a PNG made from a GIF, but the GIF itself must still never be overwritten with PNG data.
    private(set) var originalWritable = false

    @Published var mode: Mode
    @Published var quarterTurns = 0
    @Published var flipH = false
    @Published var flipV = false
    /// Crop in normalised coordinates of the rotated image (origin top-left).
    @Published var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var aspect: AspectChoice = .free
    /// The ratio runs the other way round (3:4 instead of 4:3).
    @Published var portrait = false
    @Published var brightness = 0.0
    @Published var contrast = 1.0
    @Published var saturation = 1.0
    @Published var marks: [ImageMark] = []
    @Published var markTool: MarkTool = .pen
    @Published var color: NSColor = .systemRed
    @Published var preview: CGImage?
    /// The frame being dragged in crop mode, same coordinates as `crop`. Not published: dragging only redraws the overlay.
    var cropFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Where Cancel and Crop go back to.
    private(set) var returnMode: Mode = .adjust

    private var history: [Snapshot] = []
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    struct Snapshot { var q: Int; var h: Bool; var v: Bool; var crop: CGRect; var frame: CGRect; var portrait: Bool; var b: Double; var c: Double; var s: Double; var marks: [ImageMark] }

    private struct Loaded { var full: CGImage; var preview: CGImage; var properties: [CFString: Any]; var type: UTType }

    private static func load(_ url: URL) -> Loaded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), ImageCodec.isWithinLimits(src),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let full: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1)]
        let small: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: min(max(w, h, 1), 1600)]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, full as CFDictionary),
              let prev = CGImageSourceCreateThumbnailAtIndex(src, 0, small as CFDictionary) else { return nil }
        return Loaded(full: img, preview: prev, properties: props, type: (CGImageSourceGetType(src) as String?).flatMap { UTType($0) } ?? .png)
    }

    init?(url: URL, mode: Mode) {
        guard let l = Self.load(url) else { return nil }
        self.url = url
        self.originalURL = url
        self.original = l.full
        self.previewBase = l.preview
        self.properties = l.properties
        self.type = l.type
        self.mode = mode
        self.originalWritable = Self.writable(l.type)
        refresh()
        if mode == .crop { prepareCrop() }
    }

    /// Formats MaruDoc can write back faithfully; anything else (GIF, BMP, WebP, PSD...) is saved as a PNG.
    private static func writable(_ type: UTType) -> Bool { type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .tiff) || type.conforms(to: .png) }

    /// Everything that changed is a crop (and there is one): decides "(トリミング)" or "(編集済み)" in the new file's name.
    var onlyCropsChanged: Bool {
        crop != CGRect(x: 0, y: 0, width: 1, height: 1) && quarterTurns % 4 == 0 && !flipH && !flipV &&
        brightness == 0 && contrast == 1 && saturation == 1 && marks.isEmpty
    }

    /// After a save: the editor now shows the file just written, with nothing left to save. Edits start from that
    /// file, so undo history and the crop go back to a clean state. Returns false (and changes nothing) if the new
    /// file can't be read back.
    @discardableResult
    func rebase(to newURL: URL) -> Bool {
        guard let l = Self.load(newURL) else { return false }
        url = newURL
        ownsFile = newURL.standardizedFileURL != originalURL.standardizedFileURL
        original = l.full; previewBase = l.preview; properties = l.properties; type = l.type
        quarterTurns = 0; flipH = false; flipV = false
        crop = CGRect(x: 0, y: 0, width: 1, height: 1); cropFrame = crop
        aspect = .free; portrait = false
        brightness = 0; contrast = 1; saturation = 1
        marks = []
        history.removeAll()
        refresh()
        if mode == .crop { prepareCrop() }
        return true
    }

    var dirty: Bool {
        quarterTurns % 4 != 0 || flipH || flipV || crop != CGRect(x: 0, y: 0, width: 1, height: 1) ||
        brightness != 0 || contrast != 1 || saturation != 1 || !marks.isEmpty
    }

    func checkpoint() {
        history.append(Snapshot(q: quarterTurns, h: flipH, v: flipV, crop: crop, frame: cropFrame, portrait: portrait, b: brightness, c: contrast, s: saturation, marks: marks))
        if history.count > 50 { history.removeFirst() }
    }

    func undo() {
        guard let s = history.popLast() else { return }
        quarterTurns = s.q; flipH = s.h; flipV = s.v; crop = s.crop; cropFrame = s.frame; portrait = s.portrait
        brightness = s.b; contrast = s.c; saturation = s.s; marks = s.marks
        refresh()
    }
    var canUndo: Bool { !history.isEmpty }

    func rotate(_ dir: Int) {
        checkpoint()
        // The flip is applied after the rotation, so with exactly one flip active the stored turn runs the other way.
        let step = (flipH != flipV) ? -dir : dir
        quarterTurns = (quarterTurns + step + 4) % 4
        // Keep the crop on the same part of the picture.
        func turned(_ c: CGRect) -> CGRect {
            dir > 0 ? CGRect(x: 1 - c.maxY, y: c.minX, width: c.height, height: c.width)
                    : CGRect(x: c.minY, y: 1 - c.maxX, width: c.height, height: c.width)
        }
        crop = turned(crop)
        cropFrame = turned(cropFrame)
        // A fixed ratio turns with the frame; "元の比率" follows the rotated image by itself.
        if aspect.canSwap && aspect != .original { portrait.toggle() }
        refresh()
    }

    func flip(horizontal: Bool) {
        checkpoint()
        if horizontal {
            flipH.toggle(); crop.origin.x = 1 - crop.maxX; cropFrame.origin.x = 1 - cropFrame.maxX
        } else {
            flipV.toggle(); crop.origin.y = 1 - crop.maxY; cropFrame.origin.y = 1 - cropFrame.maxY
        }
        refresh()
    }

    // MARK: Crop session

    private static let fullImage = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Size in pixels of what a crop (normalised) leaves.
    func pixelSize(of c: CGRect) -> CGSize {
        CGSize(width: (rotatedSize.width * c.width).rounded(), height: (rotatedSize.height * c.height).rounded())
    }

    /// Width / height the frame is locked to, if any.
    var lockedRatio: CGFloat? {
        guard let r = aspect.ratio(for: rotatedSize) else { return nil }
        return aspect.canSwap && portrait ? 1 / r : r
    }

    /// Starts a crop: the earlier crop, or the whole picture.
    func prepareCrop() {
        aspect = .free
        portrait = false
        cropFrame = crop
        objectWillChange.send()
    }

    func resetCropFrame() {
        cropFrame = Self.fullImage
        aspect = .free
        portrait = false
        objectWillChange.send()
    }

    func setAspect(_ a: AspectChoice) {
        aspect = a
        // A portrait picture starts with the portrait version of a landscape ratio.
        portrait = a.canSwap && a != .original && rotatedSize.height > rotatedSize.width
        fitFrameToRatio()
    }

    func swapAspect() {
        guard aspect.canSwap else { return }
        portrait.toggle()
        // Turn the frame around its centre instead of shrinking it.
        let s = rotatedSize
        var w = cropFrame.height * s.height, h = cropFrame.width * s.width
        let k = min(1, s.width / max(w, 1), s.height / max(h, 1))
        w *= k; h *= k
        let nw = w / s.width, nh = h / s.height
        cropFrame = CGRect(x: min(max(cropFrame.midX - nw / 2, 0), 1 - nw), y: min(max(cropFrame.midY - nh / 2, 0), 1 - nh), width: nw, height: nh)
        objectWillChange.send()
    }

    /// The largest frame of the locked ratio that fits inside the current one, centred on it.
    private func fitFrameToRatio() {
        if let r = lockedRatio {
            let s = rotatedSize
            let cw = cropFrame.width * s.width, ch = cropFrame.height * s.height
            var w = cw, h = cw / r
            if h > ch { h = ch; w = ch * r }
            cropFrame = CGRect(x: cropFrame.midX - w / s.width / 2, y: cropFrame.midY - h / s.height / 2, width: w / s.width, height: h / s.height)
        }
        objectWillChange.send()
    }

    /// Applies the frame as the crop and goes back to the mode we came from.
    func commitCrop() {
        guard mode == .crop else { return }
        let s = rotatedSize
        var f = cropFrame.intersection(Self.fullImage)
        guard !f.isNull, f.width * s.width >= 2, f.height * s.height >= 2 else { return }
        // A frame within a pixel of every edge is no crop at all.
        if f.minX * s.width <= 1, f.minY * s.height <= 1, (1 - f.maxX) * s.width <= 1, (1 - f.maxY) * s.height <= 1 { f = Self.fullImage }
        if f != crop { checkpoint(); crop = f }
        mode = returnMode
    }

    func cancelCrop() {
        guard mode == .crop else { return }
        mode = returnMode
    }

    func modeChanged(from old: Mode, to new: Mode) {
        if new == .crop {
            if old != .crop { returnMode = old }
            prepareCrop()
        }
        refresh()
    }

    /// Size the saved picture will have; in crop mode, the size of the frame.
    var outputPixels: CGSize { pixelSize(of: mode == .crop ? cropFrame : crop) }

    // MARK: Rendering

    func refresh() {
        let showFull = mode == .crop
        preview = render(previewBase, cropping: !showFull)
    }

    /// Rotated size of the full-resolution image.
    var rotatedSize: CGSize {
        quarterTurns % 2 == 0 ? CGSize(width: original.width, height: original.height) : CGSize(width: original.height, height: original.width)
    }

    func render(_ base: CGImage, cropping: Bool) -> CGImage? {
        guard var img = oriented(base) else { return nil }
        if brightness != 0 || contrast != 1 || saturation != 1 {
            let f = CIFilter(name: "CIColorControls")!
            f.setValue(CIImage(cgImage: img), forKey: kCIInputImageKey)
            f.setValue(brightness, forKey: kCIInputBrightnessKey)
            f.setValue(contrast, forKey: kCIInputContrastKey)
            f.setValue(saturation, forKey: kCIInputSaturationKey)
            if let out = f.outputImage, let cg = ci.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Self.rgbSpace(img)) { img = cg }
        }
        if !marks.isEmpty { img = drawMarks(on: img) ?? img }
        if cropping, crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let r = CGRect(x: crop.minX * CGFloat(img.width), y: crop.minY * CGFloat(img.height),
                           width: crop.width * CGFloat(img.width), height: crop.height * CGFloat(img.height)).integral
            img = img.cropping(to: r) ?? img
        }
        return img
    }

    /// Grey and CMYK sources can't back an RGBA context; draw those into sRGB.
    static func rgbSpace(_ img: CGImage) -> CGColorSpace {
        if let cs = img.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private func oriented(_ img: CGImage) -> CGImage? {
        if quarterTurns % 4 == 0 && !flipH && !flipV { return img }
        let w = img.width, h = img.height
        let swap = quarterTurns % 2 == 1
        let W = swap ? h : w, H = swap ? w : h
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.rgbSpace(img), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
        if flipH { ctx.scaleBy(x: -1, y: 1) }
        if flipV { ctx.scaleBy(x: 1, y: -1) }
        ctx.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
        ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// Marks are stored normalised (origin top-left) relative to the rotated image.
    private func drawMarks(on img: CGImage) -> CGImage? {
        let W = CGFloat(img.width), H = CGFloat(img.height)
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.rgbSpace(img), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        let lw = max(2, min(W, H) / 220)
        func p(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * W, y: H - n.y * H) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for m in marks {
            ctx.setStrokeColor(m.color.cgColor); ctx.setFillColor(m.color.cgColor)
            ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            switch m.kind {
            case .pen(let pts):
                guard pts.count > 1 else { continue }
                ctx.beginPath(); ctx.move(to: p(pts[0])); for q in pts.dropFirst() { ctx.addLine(to: p(q)) }; ctx.strokePath()
            case .rect(let r):
                let a = p(CGPoint(x: r.minX, y: r.minY)), b = p(CGPoint(x: r.maxX, y: r.maxY))
                ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
            case .arrow(let s, let e):
                let a = p(s), b = p(e)
                ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                let ang = atan2(b.y - a.y, b.x - a.x), len = lw * 6
                ctx.beginPath()
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - len * cos(ang - .pi / 7), y: b.y - len * sin(ang - .pi / 7)))
                ctx.addLine(to: CGPoint(x: b.x - len * cos(ang + .pi / 7), y: b.y - len * sin(ang + .pi / 7)))
                ctx.closePath(); ctx.fillPath()
            case .text(let s, let at, let size):
                let font = NSFont(name: "HiraginoSans-W6", size: CGFloat(size) * H) ?? .boldSystemFont(ofSize: CGFloat(size) * H)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: m.color]
                let str = NSAttributedString(string: s, attributes: attrs)
                let origin = p(at)
                str.draw(at: CGPoint(x: origin.x, y: origin.y - str.size().height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    func write(to url: URL) throws {
        guard let img = render(original, cropping: true) else { throw EngineError.failed(L("画像を作れませんでした")) }
        let fmt: String = {
            if type.conforms(to: .jpeg) { return "jpeg" }
            if type.conforms(to: .heic) { return "heic" }
            if type.conforms(to: .tiff) { return "tiff" }
            return "png"
        }()
        let dest = CGImageDestinationCreateWithURL(url as CFURL, (fmt == "jpeg" ? UTType.jpeg : fmt == "heic" ? UTType.heic : fmt == "tiff" ? UTType.tiff : UTType.png).identifier as CFString, 1, nil)
        guard let dest else { throw DocIOError.writeFailed(url.lastPathComponent) }
        var props = properties
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = nil; props[kCGImagePropertyPixelHeight] = nil
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = 1; props[kCGImagePropertyTIFFDictionary] = tiff }
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DocIOError.writeFailed(url.lastPathComponent) }
    }
}

// MARK: - Panel

enum ImageEditor {
    static func makePanel(url: URL, mode: ImageEditorModel.Mode, coordinator: EditorCoordinator) -> EditorPanel {
        let panel = EditorPanel(size: EditorPanel.preferredSize(NSSize(width: 900, height: 720)), title: url.lastPathComponent)
        guard let model = ImageEditorModel(url: url, mode: mode) else {
            panel.contentView = FirstMouseHostingView(rootView: Text(L("画像を開けませんでした")).padding(40))
            return panel
        }
        let save: (EditorSaveDestination) -> Bool = { [weak panel, weak coordinator] destination in
            guard let panel else { return false }
            /// Writes the picture to `target` (through SafeWrite when that file exists) and re-points the editor at it.
            func write(to target: URL, createdNew: Bool) -> Bool {
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        SafeWrite.discard(try SafeWrite.replace(target) { tmp in try model.write(to: tmp) })
                    } else {
                        try model.write(to: target)
                    }
                    guard model.rebase(to: target) else { throw DocIOError.unreadable(target.lastPathComponent) }
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
            /// A new file next to the original; GIF, BMP, WebP... come out as PNG.
            func newFile() -> URL {
                let writable = model.originalWritable
                return OutputNamer.file(for: model.originalURL, ext: writable ? model.originalURL.pathExtension : "png", tag: EditorSaving.tag(onlyCrops: model.onlyCropsChanged))
            }
            switch destination {
            case .sameFolder:
                if model.ownsFile { return write(to: model.url, createdNew: false) }
                return write(to: newFile(), createdNew: true)
            case .choose:
                let proposed = model.ownsFile ? model.url : newFile()
                let type = UTType(filenameExtension: proposed.pathExtension) ?? .png
                EditorSaving.chooseDestination(on: panel, proposed: proposed, types: [type]) { url in
                    if url.standardizedFileURL == model.originalURL.standardizedFileURL, model.originalWritable {
                        _ = write(to: model.originalURL, createdNew: false)
                    } else {
                        // The save panel has already asked about replacing an existing file.
                        _ = write(to: url, createdNew: !FileManager.default.fileExists(atPath: url.path))
                    }
                }
                return false
            case .overwriteOriginal:
                // A format that can't be written back faithfully is never replaced; it becomes a PNG beside it.
                guard model.originalWritable else { return write(to: newFile(), createdNew: true) }
                return write(to: model.originalURL, createdNew: false)
            }
        }
        panel.minSize = NSSize(width: 640, height: 420)
        panel.representedURL = url
        panel.setContent(ImageEditorView(model: model, save: save, close: { [weak panel] in panel?.performClose(nil) }))
        panel.trackEdited(model) { model.dirty }
        panel.onSave = { if model.dirty { _ = save(.sameFolder) } }
        panel.onUndo = { model.undo() }
        panel.onCancel = {
            guard model.mode == .crop else { return false }
            model.cancelCrop(); return true
        }
        panel.isDirty = { model.dirty }
        panel.confirmClose = { [weak panel] done in
            guard model.dirty, let panel else { done(true); return }
            let alert = NSAlert()
            alert.messageText = String(format: L("「%@」への変更を保存しますか?"), model.url.lastPathComponent)
            alert.addButton(withTitle: L("保存")); alert.addButton(withTitle: L("キャンセル")); alert.addButton(withTitle: L("保存しない"))
            alert.beginSheetModal(for: panel) { r in
                if r == .alertFirstButtonReturn { done(save(.sameFolder)) } else { done(r == .alertThirdButtonReturn) }
            }
        }
        return panel
    }
}

// MARK: - Views

struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel
    var save: (EditorSaveDestination) -> Bool
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.mode != .crop {
                EditorToolRow {
                    HStack(spacing: 8) { controls }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                }
            }
            GeometryReader { geo in
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let img = model.preview {
                        let fit = fitSize(CGSize(width: img.width, height: img.height), in: geo.size.insetBy(ImageCropView.margin + 8))
                        Image(decorative: img, scale: 1).resizable().interpolation(.high).frame(width: fit.width, height: fit.height)
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                        if model.mode == .crop {
                            ImageCropRepresentable(model: model)
                                .frame(width: fit.width + ImageCropView.margin * 2, height: fit.height + ImageCropView.margin * 2)
                        }
                        if model.mode == .markup { MarkupLayer(model: model, size: fit).frame(width: fit.width, height: fit.height) }
                    }
                }
            }
            if model.mode == .crop { cropBar }
        }
        .background(.background)
        .navigationTitle(model.url.lastPathComponent)
        .navigationSubtitle(sizeText(model.outputPixels))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(L("モード"), selection: $model.mode) {
                    Text(L("トリミング")).tag(ImageEditorModel.Mode.crop)
                    Text(L("調整")).tag(ImageEditorModel.Mode.adjust)
                    Text(L("マークアップ")).tag(ImageEditorModel.Mode.markup)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            // Rotate and flip work in every mode, like Preview's rotate button.
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.rotate(-1) } label: { Image(systemName: "rotate.left") }
                    .help(L("左に回転"))
                Button { model.rotate(1) } label: { Image(systemName: "rotate.right") }
                    .help(L("右に回転"))
                Menu {
                    Button(L("左右反転")) { model.flip(horizontal: true) }
                    Button(L("上下反転")) { model.flip(horizontal: false) }
                } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .menuIndicator(.visible)
                .help(L("反転"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(L("取り消す"))
                    .disabled(!model.canUndo)
                EditorSaveMenu(dirty: model.dirty, enabled: model.dirty, canOverwrite: model.originalWritable, save: { _ = save($0) }) { EmptyView() }
            }
        }
        .onChange(of: model.mode) { old, new in model.modeChanged(from: old, to: new) }
    }

    private func sizeText(_ s: CGSize) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let n = { (v: CGFloat) in f.string(from: NSNumber(value: Int(v))) ?? "\(Int(v))" }
        return "\(n(s.width)) × \(n(s.height)) px"
    }

    /// Below the picture, never over it: ratio on the left, Cancel and Crop on the right.
    private var cropBar: some View {
        EditorBottomBar {
            Menu {
                Picker(L("比率"), selection: Binding(get: { model.aspect }, set: { model.setAspect($0) })) {
                    ForEach(AspectChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle(L("縦横を入れ替え"), isOn: Binding(get: { model.portrait }, set: { _ in model.swapAspect() }))
                    .disabled(!model.aspect.canSwap)
            } label: { Text(String(format: L("比率: %@"), model.aspect.label)) }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            Button(L("リセット")) { model.resetCropFrame() }
            Text(L("Shift で縦横比を固定・矢印キーで微調整"))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .layoutPriority(-1)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            Button(L("キャンセル")) { model.cancelCrop() }.keyboardShortcut(.cancelAction)
            Button(L("切り取る")) { model.commitCrop() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.mode {
        case .crop:
            EmptyView()
        case .adjust:
            slider(L("明るさ"), value: $model.brightness, range: -0.4...0.4)
            slider(L("コントラスト"), value: $model.contrast, range: 0.6...1.6)
            slider(L("彩度"), value: $model.saturation, range: 0...2)
        case .markup:
            ForEach(ImageEditorModel.MarkTool.allCases, id: \.self) { t in
                let sym = ["pen": "scribble", "rect": "rectangle", "arrow": "arrow.up.right", "text": "textformat"][t.rawValue]!
                let help = ["pen": L("手書き"), "rect": L("四角"), "arrow": L("矢印"), "text": L("文字を追加")][t.rawValue]!
                ToolButton(symbol: sym, help: help, selected: model.markTool == t) { model.markTool = t }
            }
            ToolSeparator()
            ForEach([NSColor.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black], id: \.self) { c in
                Circle().fill(Color(nsColor: c)).frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.primary.opacity(model.color == c ? 0.8 : 0.2), lineWidth: model.color == c ? 2 : 0.5))
                    .onTapGesture { model.color = c }
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Slider(value: value, in: range, onEditingChanged: { began in if began { model.checkpoint() } })
                .frame(width: 120)
                .onChange(of: value.wrappedValue) { _, _ in model.refresh() }
        }
    }

    private func fitSize(_ s: CGSize, in box: CGSize) -> CGSize {
        let k = min(box.width / max(s.width, 1), box.height / max(s.height, 1), 4)
        return CGSize(width: s.width * k, height: s.height * k)
    }
}

private extension CGSize {
    func insetBy(_ d: CGFloat) -> CGSize { CGSize(width: max(1, width - d * 2), height: max(1, height - d * 2)) }
}

// MARK: - Crop frame

struct ImageCropRepresentable: NSViewRepresentable {
    @ObservedObject var model: ImageEditorModel

    func makeNSView(context: Context) -> ImageCropView {
        let v = ImageCropView()
        v.model = model
        // Arrow keys and Return act on the frame right away.
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: ImageCropView, context: Context) {
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
    }
}

/// The crop frame over the fitted picture: dimming outside, eight handles and a pixel label. Drag a handle to resize,
/// inside to move, outside to draw a new frame. Shift (or a ratio from the menu) keeps the ratio; arrow keys nudge;
/// Return crops; Esc cancels. The view is a margin larger than the picture so the handles are never cut off.
/// Works in picture pixels with y up, like the PDF crop in display space.
final class ImageCropView: NSView {
    static let margin: CGFloat = 24

    weak var model: ImageEditorModel?
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var drag: CropDrag?
    private var dragStart = CGRect.zero         // frame at mouse down, pixels
    private var dragStartPoint = CGPoint.zero   // mouse at mouse down, pixels

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Coordinates

    private var imageRect: NSRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }
    private var pixels: CGSize { model?.rotatedSize ?? CGSize(width: 1, height: 1) }
    /// View points per picture pixel.
    private var scale: CGFloat { max(imageRect.width / max(pixels.width, 1), 0.0001) }

    private func toPixels(_ vp: CGPoint) -> CGPoint {
        CGPoint(x: (vp.x - imageRect.minX) / scale, y: (vp.y - imageRect.minY) / scale)
    }

    /// The frame in picture pixels (y up).
    private var cropRect: CGRect {
        get {
            let f = model?.cropFrame ?? .zero, s = pixels
            return CGRect(x: f.minX * s.width, y: (1 - f.maxY) * s.height, width: f.width * s.width, height: f.height * s.height)
        }
        set {
            let s = pixels
            model?.cropFrame = CGRect(x: newValue.minX / s.width, y: 1 - newValue.maxY / s.height, width: newValue.width / s.width, height: newValue.height / s.height)
            needsDisplay = true
        }
    }

    private func viewRect(_ r: CGRect) -> NSRect {
        NSRect(x: imageRect.minX + r.minX * scale, y: imageRect.minY + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = toPixels(convert(event.locationInWindow, from: nil))
        let f = cropRect
        dragStart = f
        dragStartPoint = p
        drag = CropGeometry.zone(at: p, frame: f, tolerance: 7 / scale)
        if case .move? = drag { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let drag else { return }
        let p = toPixels(convert(event.locationInWindow, from: nil))
        let bounds = pixels
        let locked = model.lockedRatio
        let shift = event.modifierFlags.contains(.shift)
        let r: CGRect
        switch drag {
        case .move:
            r = CropGeometry.move(dragStart, by: CGVector(dx: p.x - dragStartPoint.x, dy: p.y - dragStartPoint.y), bounds: bounds)
        case .resize(let h):
            let minSize = min(max(8, 12 / scale), min(bounds.width, bounds.height) / 2)
            r = CropGeometry.resize(dragStart, handle: h, to: p, bounds: bounds, minSize: minSize, keepAspect: shift || locked != nil)
        case .draw:
            let aspect = locked ?? (shift ? (dragStart.height > 1 ? dragStart.width / dragStart.height : bounds.width / bounds.height) : nil)
            r = CropGeometry.draw(from: dragStartPoint, to: p, bounds: bounds, aspect: aspect)
        }
        cropRect = r
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; model?.objectWillChange.send(); needsDisplay = true; window?.invalidateCursorRects(for: self) }
        guard case .draw? = drag else { return }
        let r = cropRect
        // A click outside the frame, not a drag: keep what was there.
        if r.width * scale < 8 || r.height * scale < 8 { cropRect = dragStart }
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { super.keyDown(with: event); return }
        // One screen point per press (ten with Shift), never less than a pixel.
        let step = max(1, (event.modifierFlags.contains(.shift) ? 10 : 1) / scale)
        switch event.keyCode {
        case 53: model.cancelCrop()
        case 36, 76: model.commitCrop()
        case 123: nudge(dx: -step, dy: 0)
        case 124: nudge(dx: step, dy: 0)
        case 125: nudge(dx: 0, dy: -step)
        case 126: nudge(dx: 0, dy: step)
        default: super.keyDown(with: event)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        cropRect = CropGeometry.move(cropRect, by: CGVector(dx: dx, dy: dy), bounds: pixels)
        model?.objectWillChange.send()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Cursors

    /// Crosshair outside the frame, resize cursors on its edges and corners, open hand inside. The areas don't overlap.
    override func resetCursorRects() {
        func add(_ r: NSRect, _ c: NSCursor) { if r.width > 0.5, r.height > 0.5 { addCursorRect(r, cursor: c) } }
        let f = viewRect(cropRect)
        let e: CGFloat = 6
        let o = f.insetBy(dx: -e, dy: -e)
        add(NSRect(x: bounds.minX, y: o.maxY, width: bounds.width, height: bounds.maxY - o.maxY), .crosshair)
        add(NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: o.minY - bounds.minY), .crosshair)
        add(NSRect(x: bounds.minX, y: o.minY, width: o.minX - bounds.minX, height: o.height), .crosshair)
        add(NSRect(x: o.maxX, y: o.minY, width: bounds.maxX - o.maxX, height: o.height), .crosshair)
        add(f.insetBy(dx: e, dy: e), .openHand)
        let d = e * 2
        add(NSRect(x: o.minX, y: o.maxY - d, width: d, height: d), ToolOverlay.cursor(for: .topLeft))
        add(NSRect(x: o.maxX - d, y: o.maxY - d, width: d, height: d), ToolOverlay.cursor(for: .topRight))
        add(NSRect(x: o.minX, y: o.minY, width: d, height: d), ToolOverlay.cursor(for: .bottomLeft))
        add(NSRect(x: o.maxX - d, y: o.minY, width: d, height: d), ToolOverlay.cursor(for: .bottomRight))
        add(NSRect(x: o.minX, y: o.minY + d, width: d, height: o.height - 2 * d), ToolOverlay.cursor(for: .left))
        add(NSRect(x: o.maxX - d, y: o.minY + d, width: d, height: o.height - 2 * d), ToolOverlay.cursor(for: .right))
        add(NSRect(x: o.minX + d, y: o.maxY - d, width: o.width - 2 * d, height: d), ToolOverlay.cursor(for: .top))
        add(NSRect(x: o.minX + d, y: o.minY, width: o.width - 2 * d, height: d), ToolOverlay.cursor(for: .bottom))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let img = imageRect
        let cr = viewRect(cropRect)

        let dim = NSBezierPath(rect: img)
        dim.append(NSBezierPath(rect: cr))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill(); dim.fill()

        // Rule of thirds
        let grid = NSBezierPath()
        for k in 1...2 {
            let x = cr.minX + cr.width * CGFloat(k) / 3, y = cr.minY + cr.height * CGFloat(k) / 3
            grid.move(to: NSPoint(x: x, y: cr.minY)); grid.line(to: NSPoint(x: x, y: cr.maxY))
            grid.move(to: NSPoint(x: cr.minX, y: y)); grid.line(to: NSPoint(x: cr.maxX, y: y))
        }
        grid.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.45).setStroke(); grid.stroke()

        let outer = NSBezierPath(rect: cr.insetBy(dx: -1, dy: -1)); outer.lineWidth = 1
        NSColor.black.withAlphaComponent(0.55).setStroke(); outer.stroke()
        let line = NSBezierPath(rect: cr); line.lineWidth = 1
        NSColor.white.setStroke(); line.stroke()

        for h in CropHandle.allCases {
            let c = h.point(on: cr)
            let p = NSBezierPath(rect: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)); p.lineWidth = 1
            NSColor.white.setFill(); p.fill()
            NSColor.black.withAlphaComponent(0.6).setStroke(); p.stroke()
        }

        // Size below the frame when there is room, else inside just above the bottom edge. Never on a handle.
        let size = model.pixelSize(of: model.cropFrame)
        let n = NumberFormatter(); n.numberStyle = .decimal
        let num = { (v: CGFloat) in n.string(from: NSNumber(value: Int(v))) ?? "\(Int(v))" }
        let text = "\(num(size.width)) × \(num(size.height)) px" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let ts = text.size(withAttributes: attrs)
        let lw = ceil(ts.width) + 16, lh = ceil(ts.height) + 8
        let pill = CropGeometry.labelRect(size: CGSize(width: lw, height: lh), frame: cr, bounds: bounds)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4), withAttributes: attrs)
    }
}

/// Drawing layer for pen / rectangle / arrow / text marks.
struct MarkupLayer: View {
    @ObservedObject var model: ImageEditorModel
    let size: CGSize
    @LocalState private var current: [CGPoint] = []
    @LocalState private var textAt: CGPoint?
    @LocalState private var text = ""

    /// Layer coordinates are relative to the cropped view; marks are stored relative to the whole rotated image.
    private func full(_ n: CGPoint) -> CGPoint {
        CGPoint(x: model.crop.minX + n.x * model.crop.width, y: model.crop.minY + n.y * model.crop.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                guard current.count > 1 else { return }
                var p = Path()
                switch model.markTool {
                case .pen: p.addLines(current.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                case .rect:
                    let a = current.first!, b = current.last!
                    p.addRect(CGRect(x: min(a.x, b.x) * size.width, y: min(a.y, b.y) * size.height,
                                     width: abs(a.x - b.x) * size.width, height: abs(a.y - b.y) * size.height))
                case .arrow:
                    p.move(to: CGPoint(x: current.first!.x * size.width, y: current.first!.y * size.height))
                    p.addLine(to: CGPoint(x: current.last!.x * size.width, y: current.last!.y * size.height))
                case .text: break
                }
                ctx.stroke(p, with: .color(Color(nsColor: model.color)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let n = CGPoint(x: g.location.x / size.width, y: g.location.y / size.height)
                if model.markTool == .text { return }
                current.append(n)
            }.onEnded { g in
                let n = CGPoint(x: g.location.x / size.width, y: g.location.y / size.height)
                if model.markTool == .text { textAt = n; text = ""; return }
                guard current.count > 1 else { current = []; return }
                model.checkpoint()
                switch model.markTool {
                case .pen: model.marks.append(ImageMark(kind: .pen(current.map(full)), color: model.color))
                case .rect:
                    let a = full(current.first!), b = full(current.last!)
                    model.marks.append(ImageMark(kind: .rect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))), color: model.color))
                case .arrow: model.marks.append(ImageMark(kind: .arrow(full(current.first!), full(current.last!)), color: model.color))
                case .text: break
                }
                current = []
                model.refresh()
            })
            if let at = textAt {
                TextField(L("文字を入力"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .offset(x: at.x * size.width, y: at.y * size.height - 12)
                    .onSubmit {
                        if !text.isEmpty {
                            model.checkpoint()
                            model.marks.append(ImageMark(kind: .text(text, full(at), 0.045 * model.crop.height), color: model.color))
                            model.refresh()
                        }
                        textAt = nil
                    }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
