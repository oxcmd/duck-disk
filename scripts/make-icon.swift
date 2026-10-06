// Renders the Duck Disk app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon on a 1024×1024 canvas (y grows upwards).
func drawIcon() {
    // Squircle background.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: color(0x2C2C33), ending: color(0x121215))!.draw(in: tile, angle: -90)
    color(0xFFFFFF, 0.06).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // Ring of cleanup colours, like the disk chart.
    let center = NSPoint(x: 512, y: 512)
    let colors: [UInt32] = [0xE8A33D, 0xE5584F, 0xD65A9C, 0x7C5CFF, 0x4C7DFF, 0x36B3C4]
    let gap: CGFloat = 7
    let span = (360 - gap * CGFloat(colors.count)) / CGFloat(colors.count)
    var start: CGFloat = 90
    for c in colors {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: 290, startAngle: start, endAngle: start - span, clockwise: true)
        arc.lineWidth = 62
        color(c).setStroke()
        arc.stroke()
        start -= span + gap
    }

    // Duck, facing right.
    let yellow = color(0xFFC93C)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 372, y: 455))
    tail.line(to: NSPoint(x: 318, y: 545))
    tail.line(to: NSPoint(x: 420, y: 500))
    tail.close()
    yellow.setFill()
    tail.fill()
    NSBezierPath(ovalIn: NSRect(x: 352, y: 352, width: 312, height: 196)).fill()
    NSBezierPath(ovalIn: NSRect(x: 520, y: 500, width: 168, height: 168)).fill()

    color(0xF2AE22).setFill()
    let wing = NSBezierPath(ovalIn: NSRect(x: 420, y: 410, width: 160, height: 92))
    wing.fill()

    color(0xF2862B).setFill()
    let beak = NSBezierPath()
    beak.move(to: NSPoint(x: 670, y: 598))
    beak.curve(to: NSPoint(x: 742, y: 572), controlPoint1: NSPoint(x: 712, y: 602), controlPoint2: NSPoint(x: 740, y: 590))
    beak.curve(to: NSPoint(x: 668, y: 548), controlPoint1: NSPoint(x: 738, y: 556), controlPoint2: NSPoint(x: 704, y: 546))
    beak.close()
    beak.fill()

    color(0x1A1A1E).setFill()
    NSBezierPath(ovalIn: NSRect(x: 612, y: 590, width: 30, height: 30)).fill()
    color(0xFFFFFF).setFill()
    NSBezierPath(ovalIn: NSRect(x: 626, y: 606, width: 9, height: 9)).fill()
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(output)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(output)/icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(output)")
