import AppKit
import PDFKit
import EnsoDoc

/// The eight crop handles. "Top" is the top of the page as shown (display space, y up).
enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// Where the handle sits on a rect.
    func point(on r: CGRect) -> CGPoint {
        CGPoint(x: movesLeft ? r.minX : movesRight ? r.maxX : r.midX,
                y: movesBottom ? r.minY : movesTop ? r.maxY : r.midY)
    }
}

/// What a press on the crop frame does.
enum CropDrag { case move, resize(CropHandle), draw }

/// Maths behind the PDF crop frame. Page space is the PDF's own (unrotated) coordinates; display space is the page
/// as shown: rotation applied, origin at the bottom-left of the crop box, y up. The frame is edited in display space.
enum CropGeometry {
    static func displaySize(of page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    static func pageToDisplay(_ p: CGPoint, box: CGRect, rotation: Int) -> CGPoint {
        let u = p.x - box.minX, v = p.y - box.minY
        switch ((rotation % 360) + 360) % 360 {
        case 90: return CGPoint(x: v, y: box.width - u)
        case 180: return CGPoint(x: box.width - u, y: box.height - v)
        case 270: return CGPoint(x: box.height - v, y: u)
        default: return CGPoint(x: u, y: v)
        }
    }

    static func displayToPage(_ d: CGPoint, box: CGRect, rotation: Int) -> CGPoint {
        let u: CGFloat, v: CGFloat
        switch ((rotation % 360) + 360) % 360 {
        case 90: u = box.width - d.y; v = d.x
        case 180: u = box.width - d.x; v = box.height - d.y
        case 270: u = d.y; v = box.height - d.x
        default: u = d.x; v = d.y
        }
        return CGPoint(x: box.minX + u, y: box.minY + v)
    }

    static func rectToDisplay(_ r: CGRect, box: CGRect, rotation: Int) -> CGRect {
        standardRect(pageToDisplay(CGPoint(x: r.minX, y: r.minY), box: box, rotation: rotation),
                     pageToDisplay(CGPoint(x: r.maxX, y: r.maxY), box: box, rotation: rotation))
    }

    static func rectToPage(_ r: CGRect, box: CGRect, rotation: Int) -> CGRect {
        standardRect(displayToPage(CGPoint(x: r.minX, y: r.minY), box: box, rotation: rotation),
                     displayToPage(CGPoint(x: r.maxX, y: r.maxY), box: box, rotation: rotation))
    }

    static func standardRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Editing the frame (display space)

    static func clamp(_ p: CGPoint, to bounds: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    /// Slides the frame without resizing it, keeping it inside the page.
    static func move(_ r: CGRect, by d: CGVector, bounds: CGSize) -> CGRect {
        CGRect(x: min(max(r.minX + d.dx, 0), max(0, bounds.width - r.width)),
               y: min(max(r.minY + d.dy, 0), max(0, bounds.height - r.height)),
               width: r.width, height: r.height)
    }

    /// Drags `handle` of `r0` to `p`. With `keepAspect` the start ratio is kept.
    static func resize(_ r0: CGRect, handle: CropHandle, to point: CGPoint, bounds: CGSize, minSize: CGFloat, keepAspect: Bool) -> CGRect {
        let p = clamp(point, to: bounds)
        guard keepAspect, r0.width > 0, r0.height > 0 else {
            var l = r0.minX, r = r0.maxX, b = r0.minY, t = r0.maxY
            if handle.movesLeft { l = min(p.x, r - minSize) }
            if handle.movesRight { r = max(p.x, l + minSize) }
            if handle.movesBottom { b = min(p.y, t - minSize) }
            if handle.movesTop { t = max(p.y, b + minSize) }
            return CGRect(x: l, y: b, width: r - l, height: t - b)
        }
        let a = r0.width / r0.height
        if handle.isCorner {
            let ax = handle.movesLeft ? r0.maxX : r0.minX, ay = handle.movesBottom ? r0.maxY : r0.minY
            let sx: CGFloat = handle.movesRight ? 1 : -1, sy: CGFloat = handle.movesTop ? 1 : -1
            let w = max((p.x - ax) * sx, 0), h = max((p.y - ay) * sy, 0)
            let maxW = min(sx > 0 ? bounds.width - ax : ax, (sy > 0 ? bounds.height - ay : ay) * a)
            let nw = min(max(max(w, h * a), minSize), max(maxW, minSize))
            let nh = nw / a
            return CGRect(x: sx > 0 ? ax : ax - nw, y: sy > 0 ? ay : ay - nh, width: nw, height: nh)
        }
        if handle == .left || handle == .right {
            let room = handle == .right ? bounds.width - r0.minX : r0.maxX
            var nw = min(max(handle == .right ? p.x - r0.minX : r0.maxX - p.x, minSize), room)
            var nh = nw / a
            if nh > bounds.height { nh = bounds.height; nw = nh * a }
            let y = min(max(r0.midY - nh / 2, 0), bounds.height - nh)
            return CGRect(x: handle == .right ? r0.minX : r0.maxX - nw, y: y, width: nw, height: nh)
        }
        let room = handle == .top ? bounds.height - r0.minY : r0.maxY
        var nh = min(max(handle == .top ? p.y - r0.minY : r0.maxY - p.y, minSize), room)
        var nw = nh * a
        if nw > bounds.width { nw = bounds.width; nh = nw / a }
        let x = min(max(r0.midX - nw / 2, 0), bounds.width - nw)
        return CGRect(x: x, y: handle == .top ? r0.minY : r0.maxY - nh, width: nw, height: nh)
    }

    /// What a press at `p` does: handles first, then the edges, then inside, else a new frame. `t` is the grab distance.
    static func zone(at p: CGPoint, frame f: CGRect, tolerance t: CGFloat) -> CropDrag {
        func near(_ a: CGPoint) -> Bool { abs(a.x - p.x) <= t && abs(a.y - p.y) <= t }
        for h in CropHandle.allCases where h.isCorner && near(h.point(on: f)) { return .resize(h) }
        for h in CropHandle.allCases where !h.isCorner && near(h.point(on: f)) { return .resize(h) }
        let inX = p.x >= f.minX - t && p.x <= f.maxX + t, inY = p.y >= f.minY - t && p.y <= f.maxY + t
        let e = t * 0.6
        if inY, abs(p.x - f.minX) <= e { return .resize(.left) }
        if inY, abs(p.x - f.maxX) <= e { return .resize(.right) }
        if inX, abs(p.y - f.minY) <= e { return .resize(.bottom) }
        if inX, abs(p.y - f.maxY) <= e { return .resize(.top) }
        return f.contains(p) ? .move : .draw
    }

    /// A new frame dragged from `a` to `b`; `aspect` (width / height) locks the ratio.
    static func draw(from a: CGPoint, to b: CGPoint, bounds: CGSize, aspect: CGFloat?) -> CGRect {
        let a0 = clamp(a, to: bounds), b0 = clamp(b, to: bounds)
        var dx = b0.x - a0.x, dy = b0.y - a0.y
        if let asp = aspect, asp > 0 {
            let sx: CGFloat = dx < 0 ? -1 : 1, sy: CGFloat = dy < 0 ? -1 : 1
            let maxW = min(sx > 0 ? bounds.width - a0.x : a0.x, (sy > 0 ? bounds.height - a0.y : a0.y) * asp)
            let w = min(max(abs(dx), abs(dy) * asp), maxW)
            dx = sx * w; dy = sy * w / asp
        }
        return CGRect(x: min(a0.x, a0.x + dx), y: min(a0.y, a0.y + dy), width: abs(dx), height: abs(dy))
    }

    // MARK: Content detection

    /// Bounding box (page space) of everything that isn't white, plus about 2 % of padding. Nil for a blank page.
    static func contentBounds(of page: PDFPage, maxSide: CGFloat = 480, padding: CGFloat = 0.02) -> CGRect? {
        let box = page.bounds(for: .cropBox)
        let ds = displaySize(of: page)
        guard ds.width > 1, ds.height > 1 else { return nil }
        let k = maxSide / max(ds.width, ds.height)
        let w = max(1, Int((ds.width * k).rounded())), h = max(1, Int((ds.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / ds.width, y: CGFloat(h) / ds.height)
        // draw(with:to:) already applies the page's rotation and crop-box origin.
        ctx.clip(to: CGRect(origin: .zero, size: ds))
        page.draw(with: .cropBox, to: ctx)

        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        var minCol = w, maxCol = -1, minRow = h, maxRow = -1
        for row in 0..<h {
            let base = row * ctx.bytesPerRow
            for col in 0..<w {
                let i = base + col * 4
                if px[i] < 240 || px[i + 1] < 240 || px[i + 2] < 240 {
                    if col < minCol { minCol = col }
                    if col > maxCol { maxCol = col }
                    if row < minRow { minRow = row }
                    if row > maxRow { maxRow = row }
                }
            }
        }
        guard maxCol >= 0 else { return nil }
        // Memory row 0 is the top of the image.
        var r = CGRect(x: CGFloat(minCol) / CGFloat(w) * ds.width,
                       y: CGFloat(h - 1 - maxRow) / CGFloat(h) * ds.height,
                       width: CGFloat(maxCol - minCol + 1) / CGFloat(w) * ds.width,
                       height: CGFloat(maxRow - minRow + 1) / CGFloat(h) * ds.height)
        r = r.insetBy(dx: -ds.width * padding, dy: -ds.height * padding).intersection(CGRect(origin: .zero, size: ds))
        guard r.width > 1, r.height > 1 else { return nil }
        return rectToPage(r, box: box, rotation: page.rotation)
    }

    /// The page inset by 5 % on every side.
    static func fallbackFrame(for page: PDFPage) -> CGRect {
        let ds = displaySize(of: page)
        let r = CGRect(origin: .zero, size: ds).insetBy(dx: ds.width * 0.05, dy: ds.height * 0.05)
        return rectToPage(r, box: page.bounds(for: .cropBox), rotation: page.rotation)
    }

    /// The frame a page starts with: the whole displayed page (its crop box). "余白を自動検出" snaps to the content on request.
    static func initialFrame(for page: PDFPage) -> CGRect {
        page.bounds(for: .cropBox)
    }

    /// True when `frame` (page space) shows the whole page, within half a point.
    static func isFullFrame(_ frame: CGRect, for page: PDFPage) -> Bool {
        let full = initialFrame(for: page)
        return abs(frame.minX - full.minX) <= 0.5 && abs(frame.minY - full.minY) <= 0.5
            && abs(frame.width - full.width) <= 0.5 && abs(frame.height - full.height) <= 0.5
    }

    /// A frame from another page, fitted to a page of `size` (display space): cut off at the page edges. Nil when too
    /// little of it is left on this page, which then shows the whole page instead.
    static func clamp(_ frame: CGRect, toDisplaySize size: CGSize) -> CGRect? {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite else { return nil }
        let r = frame.intersection(CGRect(origin: .zero, size: size))
        return r.isNull || r.width <= 10 || r.height <= 10 ? nil : r
    }

    /// Where the size label goes (view coordinates, y up): below the frame when there is room, else inside just above
    /// the bottom edge, else above the top edge. Always clear of the handles, which reach 5 pt past the edge.
    static func labelRect(size: CGSize, frame cr: CGRect, bounds: CGRect) -> CGRect {
        let gap: CGFloat = 12
        let x = min(max(cr.midX - size.width / 2, bounds.minX + 4), max(bounds.minX + 4, bounds.maxX - size.width - 4))
        var y = cr.minY - gap - size.height
        if y < bounds.minY + 4 {
            y = cr.minY + gap
            if y + size.height > cr.maxY - gap {
                y = cr.maxY + gap
                if y + size.height > bounds.maxY - 4 { y = cr.midY - size.height / 2 }
            }
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Size label

    private static let papers: [(String, Double, Double)] = [("A4", 210, 297), ("A5", 148, 210), ("B5", 182, 257), ("Letter", 215.9, 279.4)]

    /// "182 × 257 mm", with the paper name added when it's within 1 mm of a known size.
    static func sizeLabel(widthPt: CGFloat, heightPt: CGFloat) -> String {
        let w = Double(widthPt) * 25.4 / 72, h = Double(heightPt) * 25.4 / 72
        var text = "\(SafeInt.round(w)) × \(SafeInt.round(h)) mm"
        for (name, pw, ph) in papers {
            if (abs(w - pw) <= 1 && abs(h - ph) <= 1) || (abs(w - ph) <= 1 && abs(h - pw) <= 1) { text += " · " + name; break }
        }
        return text
    }
}
