import AppKit

/// Shared vector source for the application icon and navigation identity.
enum BrandArtwork {
    static let primaryRGB: UInt32 = 0x0B57D0
    static let accentRGB: UInt32 = 0x1967D2
    static let tintRGB: UInt32 = 0xE8F0FE

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func draw(in rect: NSRect, appIcon: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let canvas = NSAffineTransform()
        canvas.translateX(by: rect.minX, yBy: rect.minY)
        canvas.scaleX(by: rect.width / 1024, yBy: rect.height / 1024)
        canvas.concat()
        if appIcon {
            let tile = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 198, yRadius: 198)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
            shadow.shadowOffset = NSSize(width: 0, height: -7)
            shadow.shadowBlurRadius = 20
            shadow.set()
            NSColor.white.setFill(); tile.fill()
            NSGraphicsContext.restoreGraphicsState()
            color(0xE3EAF5).setStroke(); tile.lineWidth = 1.5; tile.stroke()
        }
        let mark = NSAffineTransform()
        let inset: CGFloat = appIcon ? 142 : 8
        mark.translateX(by: inset, yBy: inset)
        mark.scale(by: (1024 - 2 * inset) / 1000)
        mark.concat()

        color(tintRGB).setFill()
        NSBezierPath(ovalIn: NSRect(x: 238, y: 238, width: 524, height: 524)).fill()
        let renewal = NSBezierPath()
        renewal.appendArc(withCenter: NSPoint(x: 500, y: 500), radius: 340, startAngle: 60, endAngle: 360)
        renewal.line(to: NSPoint(x: 840, y: 588))
        stroke(renewal, width: 64, color: primaryRGB)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 773, y: 526))
        arrow.line(to: NSPoint(x: 840, y: 593))
        arrow.line(to: NSPoint(x: 907, y: 526))
        stroke(arrow, width: 64, color: primaryRGB)

        let letter = NSBezierPath()
        letter.move(to: NSPoint(x: 365, y: 340))
        letter.line(to: NSPoint(x: 500, y: 682))
        letter.line(to: NSPoint(x: 635, y: 340))
        stroke(letter, width: 58, color: accentRGB)
        let crossbar = NSBezierPath()
        crossbar.move(to: NSPoint(x: 414, y: 463))
        crossbar.line(to: NSPoint(x: 586, y: 463))
        stroke(crossbar, width: 52, color: accentRGB)
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat, color rgb: UInt32) {
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        color(rgb).setStroke(); path.stroke()
    }

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, appIcon: false)
            return true
        }
    }
}
