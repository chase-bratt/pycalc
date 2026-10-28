// Renders the PyCalc app icon (1024×1024 PNG) with CoreGraphics.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Apple icon grid: 824pt body centred in 1024 with a continuous-corner squircle.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(shape); ctx.setFillColor(color(0x1C1C20)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(0x2A1650), color(0x472F5B), color(0x1E1A26)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
let glow = CGGradient(colorsSpace: space, colors: [color(0xC4AEF4, 0.28), color(0xC4AEF4, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 380, y: 700), startRadius: 0,
                       endCenter: CGPoint(x: 380, y: 700), endRadius: 520, options: [])

// Grid
ctx.setStrokeColor(color(0xFFFFFF, 0.06)); ctx.setLineWidth(3)
for i in stride(from: 100.0, through: 924.0, by: 103.0) {
    ctx.move(to: CGPoint(x: i, y: 100)); ctx.addLine(to: CGPoint(x: i, y: 924))
    ctx.move(to: CGPoint(x: 100, y: i)); ctx.addLine(to: CGPoint(x: 924, y: i))
}
ctx.strokePath()
ctx.setStrokeColor(color(0xFFFFFF, 0.22)); ctx.setLineWidth(5)
ctx.move(to: CGPoint(x: 100, y: 512)); ctx.addLine(to: CGPoint(x: 924, y: 512))
ctx.move(to: CGPoint(x: 512, y: 100)); ctx.addLine(to: CGPoint(x: 512, y: 924))
ctx.strokePath()

// Damped wave in lavender, parabola in rose
func curve(_ f: (CGFloat) -> CGFloat) -> CGPath {
    let path = CGMutablePath()
    for step in 0...400 {
        let x = 100 + CGFloat(step) / 400 * 824
        let point = CGPoint(x: x, y: 512 + f((x - 512) / 103) * 103)
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    return path
}
let parabola = curve { $0 * $0 / 4.5 - 1.6 }
let wave = curve { 2.6 * sin($0 * 1.1) * exp(-abs($0) / 5) }
for (path, hex, width) in [(parabola, UInt32(0xCCA4B4), CGFloat(18)), (wave, UInt32(0xC4AEF4), CGFloat(24))] {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(hex, 0.9))
    ctx.setStrokeColor(color(hex)); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.addPath(path); ctx.strokePath()
    ctx.restoreGState()
}

// Citrine point on the wave's peak
let peakX: CGFloat = 512 + 103 * 1.3
let peakY = 512 + 2.6 * sin(1.3 * 1.1) * exp(-1.3 / 5) * 103
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: color(0xDCCE40, 1))
ctx.setFillColor(color(0xDCCE40))
ctx.fillEllipse(in: CGRect(x: peakX - 36, y: peakY - 36, width: 72, height: 72))
ctx.restoreGState()
ctx.setStrokeColor(color(0x1C1C20)); ctx.setLineWidth(9)
ctx.strokeEllipse(in: CGRect(x: peakX - 36, y: peakY - 36, width: 72, height: 72))

// Inner highlight
ctx.setStrokeColor(color(0xFFFFFF, 0.12)); ctx.setLineWidth(4)
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
