import AppKit

/// The Duck Disk duck: one drawing shared by the app icon (scripts/make-icon.swift compiles this file in)
/// and the logo inside the app. Uses AppKit only, so the icon script can build it without the app.
enum DuckArtwork {
    /// Draws on a 1024×1024 canvas (y grows upwards). The tile is the dark rounded square of the app icon.
    static func draw(tile: Bool) {
        if tile {
            let shape = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                                     xRadius: 185, yRadius: 185)
            NSGradient(starting: color(0x2C2C33), ending: color(0x121215))!.draw(in: shape, angle: -90)
            color(0xFFFFFF, 0.06).setStroke()
            shape.lineWidth = 3
            shape.stroke()
        }

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
        color(0xFFC93C).setFill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 372, y: 455))
        tail.line(to: NSPoint(x: 318, y: 545))
        tail.line(to: NSPoint(x: 420, y: 500))
        tail.close()
        tail.fill()
        NSBezierPath(ovalIn: NSRect(x: 352, y: 352, width: 312, height: 196)).fill()
        NSBezierPath(ovalIn: NSRect(x: 520, y: 500, width: 168, height: 168)).fill()

        color(0xF2AE22).setFill()
        NSBezierPath(ovalIn: NSRect(x: 420, y: 410, width: 160, height: 92)).fill()

        color(0xF2862B).setFill()
        let beak = NSBezierPath()
        beak.move(to: NSPoint(x: 670, y: 598))
        beak.curve(to: NSPoint(x: 742, y: 572), controlPoint1: NSPoint(x: 712, y: 602),
                   controlPoint2: NSPoint(x: 740, y: 590))
        beak.curve(to: NSPoint(x: 668, y: 548), controlPoint1: NSPoint(x: 738, y: 556),
                   controlPoint2: NSPoint(x: 704, y: 546))
        beak.close()
        beak.fill()

        color(0x1A1A1E).setFill()
        NSBezierPath(ovalIn: NSRect(x: 612, y: 590, width: 30, height: 30)).fill()
        color(0xFFFFFF).setFill()
        NSBezierPath(ovalIn: NSRect(x: 626, y: 606, width: 9, height: 9)).fill()
    }

    /// The ring and duck without the tile, cropped to the ring, for use inside the app.
    static let mark: NSImage = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        // The ring's outer edge spans 512 ± 321 on the 1024 canvas.
        let scale = rect.width / 642
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.translateX(by: -191, yBy: -191)
        transform.concat()
        draw(tile: false)
        return true
    }

    /// PNG of the full app icon at a pixel size.
    static func iconPNG(pixels: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        ctx.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        draw(tile: true)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
