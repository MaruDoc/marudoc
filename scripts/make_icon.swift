// Draws the MaruDoc app icon and writes an .iconset (then run iconutil).
// usage: swift scripts/make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ ctx: CGContext, _ S: CGFloat) {
    let k = S / 1024
    ctx.scaleBy(x: k, y: k)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Tile with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x000000, 0.28))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0xF4F5F8)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xFFFFFF), rgb(0xE9ECF1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0x000000, 0.06)); ctx.setLineWidth(2); ctx.strokePath()

    // Ring of six segments; one is "selected".
    let c = CGPoint(x: 512, y: 512)
    let rOut: CGFloat = 300, rIn: CGFloat = 196, gapWidth: CGFloat = 18
    let n = 6
    for i in 0..<n {
        // 12 o'clock = 90°, clockwise.
        let mid = CGFloat.pi / 2 - CGFloat(i) * 2 * .pi / CGFloat(n)
        // Constant-width gaps: the angular half-width shrinks less at the outer radius than at the inner one.
        let halfOut = CGFloat.pi / CGFloat(n) - (gapWidth / 2) / rOut
        let halfIn = CGFloat.pi / CGFloat(n) - (gapWidth / 2) / rIn
        let p = CGMutablePath()
        p.addArc(center: c, radius: rOut, startAngle: mid + halfOut, endAngle: mid - halfOut, clockwise: true)
        p.addArc(center: c, radius: rIn, startAngle: mid - halfIn, endAngle: mid + halfIn, clockwise: false)
        p.closeSubpath()
        ctx.saveGState()
        if i == 1 {
            ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: rgb(0x0A60D0, 0.35))
            ctx.addPath(p); ctx.clip()
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x3A9BFF), rgb(0x0A6CF0)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 812), end: CGPoint(x: 812, y: 512), options: [])
        } else {
            ctx.addPath(p); ctx.setFillColor(rgb(0xD5DBE5)); ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // Document in the hub.
    let page = CGRect(x: 512 - 74, y: 512 - 96, width: 148, height: 192)
    let fold: CGFloat = 46
    let doc = CGMutablePath()
    doc.move(to: CGPoint(x: page.minX + 16, y: page.minY))
    doc.addLine(to: CGPoint(x: page.maxX - 16, y: page.minY))
    doc.addQuadCurve(to: CGPoint(x: page.maxX, y: page.minY + 16), control: CGPoint(x: page.maxX, y: page.minY))
    doc.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    doc.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    doc.addLine(to: CGPoint(x: page.minX + 16, y: page.maxY))
    doc.addQuadCurve(to: CGPoint(x: page.minX, y: page.maxY - 16), control: CGPoint(x: page.minX, y: page.maxY))
    doc.addLine(to: CGPoint(x: page.minX, y: page.minY + 16))
    doc.addQuadCurve(to: CGPoint(x: page.minX + 16, y: page.minY), control: CGPoint(x: page.minX, y: page.minY))
    doc.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: rgb(0x000000, 0.18))
    ctx.addPath(doc); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 10))
    corner.addQuadCurve(to: CGPoint(x: page.maxX - fold + 10, y: page.maxY - fold), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    corner.closeSubpath()
    ctx.addPath(corner); ctx.setFillColor(rgb(0xDCE1E9)); ctx.fillPath()
    ctx.setFillColor(rgb(0xBFC7D3))
    let lines: [(CGFloat, CGFloat)] = [(0.62, 0.66), (0.46, 0.66), (0.30, 0.42)]
    for (y, w) in lines {
        let r = CGRect(x: page.minX + 26, y: page.minY + page.height * y, width: (page.width - 52) * w / 0.66, height: 12)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
    }
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
}
print("wrote", out.path)
