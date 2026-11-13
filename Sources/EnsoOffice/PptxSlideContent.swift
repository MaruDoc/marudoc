import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// Text bodies, pictures and graphic frames (tables, SmartArt, charts, OLE previews) of the slide renderer.
extension SlideRenderer {

    // MARK: Text in shapes

    struct BodyProps {
        var lIns = 7.2, tIns = 3.6, rIns = 7.2, bIns = 3.6
        var anchor = "t"
        var anchorCtr = false
        var wrap = true
        var vert = "horz"
        var rot = 0.0
        var autofit: XNode?
    }

    /// bodyPr attributes, the most specific setting winning.
    func bodyProps(_ chain: [XNode]) -> BodyProps {
        var b = BodyProps()
        func attr(_ k: String) -> String? { for n in chain { if let v = n[k] { return v } }; return nil }
        func emu(_ k: String) -> Double? { OOXMLValue.double(attr(k)).map { $0 / 12700 } }
        b.lIns = emu("lIns") ?? 7.2; b.tIns = emu("tIns") ?? 3.6; b.rIns = emu("rIns") ?? 7.2; b.bIns = emu("bIns") ?? 3.6
        b.anchor = attr("anchor") ?? "t"
        b.anchorCtr = OOXMLValue.onOff(attr("anchorCtr") ?? "0")
        b.wrap = attr("wrap") != "none"
        b.vert = attr("vert") ?? "horz"
        b.rot = (OOXMLValue.double(attr("rot")) ?? 0) / 60000
        for n in chain {
            if let a = n.children.first(where: { ["a:noAutofit", "a:normAutofit", "a:spAutoFit"].contains($0.tag) }) { b.autofit = a; break }
        }
        return b
    }

    func textInheritance(_ r: Resolved, layer: Layer) -> TextInheritance {
        var inh = TextInheritance(colors: layer.colors, theme: scope.theme)
        inh.rels = pkg.rels(layer.part)
        inh.slideNumber = scope.number
        inh.defaultLang = pkg.defaultTextStyle?.child("a:defPPr")?.child("a:defRPr")?["lang"]
            ?? pkg.defaultTextStyle?.child("a:lvl1pPr")?.child("a:defRPr")?["lang"] ?? "ja-JP"
        if layer.kind == .slide, r.isPlaceholder {
            inh.lists = [r.layoutPh, r.masterPh].compactMap { $0.flatMap { SlideRenderer.kid($0, "txBody")?.child("a:lstStyle") } }
        }
        if let style = scope.masterTextStyle(placeholderType: r.phType, isPlaceholder: r.isPlaceholder && layer.kind == .slide) { inh.lists.append(style) }
        if let d = pkg.defaultTextStyle { inh.lists.append(d) }
        inh.fontRef = r.style?.child("a:fontRef")
        return inh
    }

    func drawText(_ body: XNode, resolved r: Resolved, layer: Layer, box: CGRect, geoText: CGRect, txXfrm: Xfrm?, shapeXfrm: Xfrm, map: CGAffineTransform, mirrored: Bool) {
        var bpChain = [body.child("a:bodyPr")].compactMap { $0 }
        if layer.kind == .slide, r.isPlaceholder {
            bpChain += [r.layoutPh, r.masterPh].compactMap { $0.flatMap { SlideRenderer.kid($0, "txBody")?.child("a:bodyPr") } }
        }
        let bp = bodyProps(bpChain)
        var area = geoText
        if let t = txXfrm {
            // SmartArt keeps a separate text rectangle in the frame's space.
            let s = shapeXfrm.rect
            area = CGRect(x: t.rect.minX - s.minX, y: t.rect.minY - s.minY, width: t.rect.width, height: t.rect.height)
        }
        area = CGRect(x: area.minX + bp.lIns, y: area.minY + bp.tIns, width: area.width - bp.lIns - bp.rIns, height: area.height - bp.tIns - bp.bIns)
        drawTextBody(body, inheritance: textInheritance(r, layer: layer), props: bp, area: area, mirrored: mirrored)
    }

    /// Lays out and draws a text body inside `area` (already inset), honouring anchoring, autofit, rotation and
    /// vertical text.
    /// `fitToBox`: a body set in substitute fonts that runs out of its box is shrunk to fit (table cells pass false:
    /// their rows grow instead).
    func drawTextBody(_ body: XNode, inheritance: TextInheritance, props bp: BodyProps, area areaIn: CGRect, mirrored: Bool, fitToBox: Bool = true) {
        var styler = TextStyler(body: body, inheritance: inheritance)
        if let af = bp.autofit, af.tag == "a:normAutofit" {
            styler.fontScale = (OOXMLValue.double(af["fontScale"]) ?? 100_000) / 100_000
            styler.spacingReduction = (OOXMLValue.double(af["lnSpcReduction"]) ?? 0) / 100_000
        }
        var paras = styler.paragraphs(body)
        guard paras.contains(where: { $0.runs.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } }) else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        var area = areaIn
        if mirrored {
            // Text is never mirrored: a flipped shape shows its text the right way round (rotated for vertical flips).
            ctx.translateBy(x: area.midX, y: 0); ctx.scaleBy(x: -1, y: 1); ctx.translateBy(x: -area.midX, y: 0)
        }
        var rotation = bp.rot
        let vertical = ["vert", "vert270", "eaVert", "wordArtVert", "mongolianVert", "wordArtVertRtl"].contains(bp.vert)
        if bp.vert == "vert" || bp.vert == "eaVert" || bp.vert == "wordArtVert" || bp.vert == "mongolianVert" { rotation += 90 }
        if bp.vert == "vert270" || bp.vert == "wordArtVertRtl" { rotation -= 90 }
        if bp.vert == "eaVert" || bp.vert == "mongolianVert" || bp.vert == "wordArtVert" {
            drawVerticalEA(paras, area: area, props: bp, styler: styler)
            return
        }
        if rotation != 0 {
            ctx.translateBy(x: area.midX, y: area.midY)
            ctx.rotate(by: rotation * .pi / 180)
            if vertical { area = CGRect(x: -area.height / 2, y: -area.width / 2, width: area.height, height: area.width) } else {
                area = CGRect(x: -area.width / 2, y: -area.height / 2, width: area.width, height: area.height)
            }
        }
        var block = text.layout(paras, width: Double(area.width), wrap: bp.wrap)
        // The stored scale was measured by PowerPoint with the original fonts. When the substitutes still overflow
        // clearly, shrink further until the text fits, as PowerPoint would on its next edit.
        func overflows(_ b: SlideTextLayout.Block) -> Bool { b.contentHeight > Double(area.height) * 1.04 + 2 }
        if bp.autofit?.tag == "a:normAutofit", overflows(block) {
            var scale = styler.fontScale
            for _ in 0..<14 where overflows(block) && scale > 0.25 {
                scale *= 0.95
                var s2 = styler
                s2.fontScale = scale
                s2.spacingReduction = min(styler.spacingReduction + 0.02, 0.2)
                paras = s2.paragraphs(body)
                block = text.layout(paras, width: Double(area.width), wrap: bp.wrap)
            }
        } else if fitToBox, bp.autofit?.tag != "a:normAutofit", block.usesSubstitute {
            block = fitSubstitutes(body, styler: styler, props: bp, area: area, block: block)
        }
        var y = Double(area.minY)
        switch bp.anchor {
        case "ctr": y = Double(area.midY) - block.height / 2
        case "b": y = Double(area.maxY) - block.height
        default: break
        }
        var x = Double(area.minX)
        if bp.anchorCtr { x += (Double(area.width) - block.width) / 2 }
        text.draw(block, at: CGPoint(x: x, y: y), in: ctx, pdf: isPDF)
    }

    /// The box was sized for the fonts the deck names. Drawn in a Mac substitute that is wider (MS PGothic and
    /// MS Mincho are narrower than Hiragino), the text can run out of its box and under whatever lies below; it is
    /// shrunk the way PowerPoint's normAutofit does instead. Wrapping text: line spacing reduced up to 20 %, then
    /// the font in 5 % steps, down to 60 %. Unwrapped text (labels): the font scaled to the box width, down to 70 %.
    /// A body that still does not fit at the floor is drawn at full size, as the file has it, and reported.
    func fitSubstitutes(_ body: XNode, styler: TextStyler, props bp: BodyProps, area: CGRect, block: SlideTextLayout.Block) -> SlideTextLayout.Block {
        func layout(_ scale: Double, _ reduction: Double) -> SlideTextLayout.Block {
            var s2 = styler
            s2.fontScale = scale
            s2.spacingReduction = reduction
            return text.layout(s2.paragraphs(body), width: Double(area.width), wrap: bp.wrap)
        }
        var out = block
        var scale = 1.0
        var fits = true
        if bp.wrap {
            let limit = Double(area.height) * 1.02
            guard block.contentHeight > limit else { return block }
            let steps: [(Double, Double)] = [(1, 0.1), (1, 0.2)] + stride(from: 0.95, through: 0.6, by: -0.05).map { ($0, 0.2) }
            fits = false
            for (sc, red) in steps {
                out = layout(sc, red)
                scale = sc
                if out.contentHeight <= limit { fits = true; break }
            }
        } else {
            let limit = Double(area.width) * 1.02
            guard block.maxLineWidth > limit else { return block }
            // Width scales with the font size; a second pass absorbs rounding in the line widths.
            for _ in 0..<3 {
                scale = max(0.7, (scale * Double(area.width) / out.maxLineWidth * 0.995 * 200).rounded(.down) / 200)
                out = layout(scale, 0)
                if out.maxLineWidth <= limit || scale <= 0.7 { break }
            }
            fits = out.maxLineWidth <= limit
        }
        fitted.append(PptxSlideRenderer.Fit(slide: currentSlide, scale: scale, wraps: bp.wrap, fits: fits))
        // Text that does not fit even at the floor ran out of its box in the author's own fonts too: it is drawn as
        // the file has it, and reported.
        if !fits { gap("text overflows its box"); return block }
        return out
    }

    /// Vertical East Asian text (vert="eaVert"): columns from right to left, CJK upright, Latin turned.
    func drawVerticalEA(_ paras: [StyledParagraph], area: CGRect, props bp: BodyProps, styler: TextStyler) {
        let s = NSMutableAttributedString()
        for (i, p) in paras.enumerated() {
            var align = CTTextAlignment.left
            if p.align == "ctr" { align = .center } else if p.align == "r" { align = .right }
            var lineMult = CGFloat(p.lineSpacingPct ?? 1)
            let style: CTParagraphStyle = withUnsafeBytes(of: &align) { ap in
                withUnsafeBytes(of: &lineMult) { lp in
                    let set = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ap.baseAddress!),
                               CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: lp.baseAddress!)]
                    return CTParagraphStyleCreate(set, set.count)
                }
            }
            for r in p.runs where !r.text.isEmpty {
                for ch in r.text.unicodeScalars {
                    let ea = SlideTextLayout.usesEastAsianFont(ch, eaLang: r.eaLang)
                    let face = fonts.face(ea ? r.ea : r.latin, size: r.size, bold: r.bold, italic: r.italic, eastAsian: ea)
                    let attrs: [CFString: Any] = [kCTFontAttributeName: face.font, kCTForegroundColorAttributeName: (r.color ?? .black).cgColor,
                                                  kCTVerticalFormsAttributeName: true, kCTParagraphStyleAttributeName: style]
                    s.append(NSAttributedString(string: ch == "\u{2028}" ? "\u{2028}" : String(ch), attributes: attrs as [NSAttributedString.Key: Any]))
                }
            }
            if i < paras.count - 1 { s.append(NSAttributedString(string: "\n")) }
        }
        guard s.length > 0 else { return }
        let fs = CTFramesetterCreateWithAttributedString(s as CFAttributedString)
        let w = Double(area.width), h = Double(area.height)
        let tall = bp.wrap ? h : 100_000
        let path = CGPath(rect: CGRect(x: 0, y: h - tall, width: w, height: tall), transform: nil)
        let attrs = [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, attrs)
        // Columns used: from the rightmost line origin to the leftmost line's far side.
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var shift = 0.0
        if let minX = origins.map(\.x).min(), !lines.isEmpty {
            var desc: CGFloat = 0
            _ = CTLineGetTypographicBounds(lines[lines.count - 1], nil, &desc, nil)
            let used = w - Double(minX) + Double(desc)
            if bp.anchor == "ctr" { shift = -(w - used) / 2 } else if bp.anchor == "b" { shift = -(w - used) }
        }
        ctx.saveGState()
        ctx.translateBy(x: area.minX + shift, y: area.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    // MARK: Pictures

    func drawPicture(_ n: XNode, layer: Layer, map: CGAffineTransform, mirrored: Bool) {
        if isHidden(n) { return }
        let r = resolve(n, layer: layer)
        guard let x = r.xfrm, let blipFill = SlideRenderer.kid(n, "blipFill") ?? n.child("p:blipFill") else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let box = enterShape(x, map: map)
        let geoSpPr = r.spPrs.first { $0.child("a:prstGeom") != nil || $0.child("a:custGeom") != nil }
        var unknown = Set<String>()
        let geo = DrawingGeometry.geometry(geoSpPr, w: Double(box.width), h: Double(box.height), unknown: &unknown)
        ctx.saveGState()
        for gp in geo.paths where gp.fill != .none { ctx.addPath(gp.path) }
        if !ctx.isPathEmpty { ctx.clip() }
        drawBlip(blipFill, part: layer.part, frame: box, colors: layer.colors)
        ctx.restoreGState()
        if let line = resolvedLine(r, colors: layer.colors) {
            for gp in geo.paths where gp.stroke { stroke(gp.path, line, isLine: geo.isLine, draw: true) }
        }
    }

    /// Draws the picture of a blipFill into `frame` (local coordinates; the caller has clipped to the shape).
    func drawBlip(_ blipFill: XNode, part: String, frame: CGRect, colors: ColorResolver) {
        guard let blip = blipFill.child("a:blip") else { return }
        guard let id = blip["r:embed"], let rel = pkg.rels(part)[id], !rel.external else {
            if blip["r:link"] != nil { gap("linked pictures (not embedded)") }
            return
        }
        let target = rel.target
        let alpha = min(max((OOXMLValue.double(blip.child("a:alphaModFix")?["amt"]) ?? 100_000) / 100_000, 0), 1)
        if blip.child("a:clrChange") != nil || blip.child("a:duotone") != nil || blip.child("a:grayscl") != nil || blip.child("a:biLevel") != nil {
            gap("picture colour effects (drawn without them)")
        }
        var crop = (l: 0.0, t: 0.0, r: 0.0, b: 0.0)
        if let s = blipFill.child("a:srcRect") {
            func f(_ k: String) -> Double { (OOXMLValue.double(s[k]) ?? 0) / 100_000 }
            crop = (f("l"), f("t"), f("r"), f("b"))
        }
        var dest = frame
        if let fr = blipFill.child("a:stretch")?.child("a:fillRect") {
            func f(_ k: String) -> Double { (OOXMLValue.double(fr[k]) ?? 0) / 100_000 }
            let l = f("l"), t = f("t"), rr = f("r"), b = f("b")
            dest = CGRect(x: frame.minX + frame.width * l, y: frame.minY + frame.height * t,
                          width: frame.width * (1 - l - rr), height: frame.height * (1 - t - b))
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if alpha < 1 { ctx.setAlpha(alpha) }

        guard let img = pkg.image(target) else {
            let ext = (target as NSString).pathExtension.lowercased()
            if ["emf", "wmf", "emz", "wmz"].contains(ext), let data = pkg.data(target), EMFPlayer.draw(data, in: dest, crop: crop, ctx: ctx) {
                return
            }
            gap(["emf", "wmf", "emz", "wmz"].contains(ext) ? "EMF/WMF pictures" : "pictures in .\(ext) format")
            return
        }
        let orientation = (target.lowercased().hasSuffix(".jpg") || target.lowercased().hasSuffix(".jpeg")) ? pkg.orientation(target) : 1

        if let tile = blipFill.child("a:tile") {
            drawTiled(img, tile: tile, frame: frame)
            return
        }
        let cw = 1 - crop.l - crop.r, ch = 1 - crop.t - crop.b
        guard cw > 0.0001, ch > 0.0001 else { return }
        let full = CGRect(x: dest.minX - dest.width * crop.l / cw, y: dest.minY - dest.height * crop.t / ch,
                          width: dest.width / cw, height: dest.height / ch)
        drawImage(img, in: full, orientation: orientation)
    }

    /// Draws a CGImage upright into `rect` of the y-down context, applying an EXIF orientation.
    func drawImage(_ img: CGImage, in rect: CGRect, orientation: Int = 1) {
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        // Now y is up and the image fills (0, 0, w, h); the orientation maps stored pixels to the displayed picture.
        let w = rect.width, h = rect.height
        switch orientation {
        case 2: ctx.translateBy(x: w, y: 0); ctx.scaleBy(x: -1, y: 1)
        case 3: ctx.translateBy(x: w, y: h); ctx.rotate(by: .pi)
        case 4: ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
        case 5: ctx.translateBy(x: 0, y: h); ctx.rotate(by: -.pi / 2); ctx.scaleBy(x: -1, y: 1); ctx.translateBy(x: -h, y: 0)
        case 6: ctx.translateBy(x: 0, y: h); ctx.rotate(by: -.pi / 2)
        case 7: ctx.translateBy(x: w, y: 0); ctx.rotate(by: .pi / 2); ctx.scaleBy(x: -1, y: 1); ctx.translateBy(x: -h, y: 0)
        case 8: ctx.translateBy(x: w, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        let drawSize = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        ctx.draw(img, in: CGRect(origin: .zero, size: drawSize))
        ctx.restoreGState()
    }

    func drawTiled(_ img: CGImage, tile: XNode, frame: CGRect) {
        let sx = (OOXMLValue.double(tile["sx"]) ?? 100_000) / 100_000, sy = (OOXMLValue.double(tile["sy"]) ?? 100_000) / 100_000
        let tx = (OOXMLValue.double(tile["tx"]) ?? 0) / 12700, ty = (OOXMLValue.double(tile["ty"]) ?? 0) / 12700
        // Tiles are drawn at the picture's own size (96 dpi when it declares none).
        let tw = max(Double(img.width) * 0.75 * abs(sx), 1), th = max(Double(img.height) * 0.75 * abs(sy), 1)
        let count = (Double(frame.width) / tw + 2) * (Double(frame.height) / th + 2)
        guard count < 20_000 else { drawImage(img, in: frame); return }
        var y = Double(frame.minY) + ty.truncatingRemainder(dividingBy: th) - th
        while y < Double(frame.maxY) {
            var x = Double(frame.minX) + tx.truncatingRemainder(dividingBy: tw) - tw
            while x < Double(frame.maxX) {
                drawImage(img, in: CGRect(x: x, y: y, width: tw, height: th))
                x += tw
            }
            y += th
        }
    }

    // MARK: Graphic frames

    func drawGraphicFrame(_ n: XNode, layer: Layer, map: CGAffineTransform, mirrored: Bool) {
        if isHidden(n) { return }
        let r = resolve(n, layer: layer)
        guard let x = r.xfrm ?? SlideRenderer.xfrm(n.child("p:xfrm")), let data = n.child("a:graphic")?.child("a:graphicData") else { return }
        let uri = data["uri"] ?? ""
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let box = enterShape(x, map: map)
        if uri.hasSuffix("/table"), let tbl = data.child("a:tbl") {
            drawTable(tbl, frame: box, layer: layer)
        } else if uri.hasSuffix("/diagram") {
            drawDiagram(data, frame: box, layer: layer)
        } else if uri.hasSuffix("/chart") {
            drawChart(data, frame: box, layer: layer)
        } else if uri.hasSuffix("/ole") || data.contains("p:oleObj") {
            // OLE objects carry a preview picture (often EMF).
            if let pic = data.firstDescendant("p:pic"), let bf = pic.child("p:blipFill") {
                drawBlip(bf, part: layer.part, frame: box, colors: layer.colors)
            } else { gap("embedded objects without a preview") }
        } else {
            gap("unsupported graphic frames")
        }
    }

    // MARK: SmartArt

    /// SmartArt is drawn from the drawing part PowerPoint saves next to the data model (ppt/diagrams/drawingN.xml).
    func drawDiagram(_ data: XNode, frame: CGRect, layer: Layer) {
        let rels = pkg.rels(layer.part)
        guard let ids = data.children.first(where: { $0.localName == "relIds" }), let dm = ids["r:dm"], let dmRel = rels[dm],
              let dmXML = pkg.xml(dmRel.target) else { gap("SmartArt without a saved drawing"); return }
        var drawingPart: String?
        if let ext = dmXML.descendants("http://schemas.microsoft.com/office/drawing/2008/diagram:dataModelExt").first, let rid = ext["relId"], let rel = rels[rid] {
            drawingPart = rel.target
        }
        if drawingPart == nil {
            // Older files: the only diagramDrawing relationship of the slide.
            let drawings = rels.values.filter { $0.type.hasSuffix("/diagramDrawing") }
            if drawings.count == 1 { drawingPart = drawings[0].target }
        }
        guard let part = drawingPart, let drawing = pkg.xml(part), let tree = drawing.children.first(where: { $0.localName == "spTree" }) else {
            gap("SmartArt without a saved drawing"); return
        }
        ctx.saveGState()
        ctx.translateBy(x: frame.minX, y: frame.minY)
        var l = layer
        l.kind = .diagram
        l.part = part
        drawTree(tree, layer: l, map: .identity, mirrored: false)
        ctx.restoreGState()
    }
}
