import AppKit

enum MenuBarIcon {
    static let pointSize = NSSize(width: 18, height: 18)

    static func make() -> NSImage {
        let image = NSImage(size: pointSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.shouldAntialias = true

            let scale = min(rect.width, rect.height) / 18
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let ink = NSColor.black

            let orbit = NSBezierPath()
            orbit.appendArc(
                withCenter: center,
                radius: 7.05 * scale,
                startAngle: 40,
                endAngle: 325,
                clockwise: false
            )
            orbit.lineWidth = 1.35 * scale
            orbit.lineCapStyle = .round
            ink.setStroke()
            orbit.stroke()

            let glyph = NSBezierPath()
            glyph.move(to: NSPoint(
                x: center.x - 3.75 * scale,
                y: center.y + 2.65 * scale
            ))
            glyph.line(to: NSPoint(
                x: center.x - 0.85 * scale,
                y: center.y
            ))
            glyph.line(to: NSPoint(
                x: center.x - 3.75 * scale,
                y: center.y - 2.65 * scale
            ))
            glyph.move(to: NSPoint(
                x: center.x + 0.9 * scale,
                y: center.y - 2.65 * scale
            ))
            glyph.line(to: NSPoint(
                x: center.x + 4.05 * scale,
                y: center.y - 2.65 * scale
            ))
            glyph.lineWidth = 1.55 * scale
            glyph.lineCapStyle = .round
            glyph.lineJoinStyle = .round
            glyph.stroke()

            let nodeAngle = 40 * CGFloat.pi / 180
            let nodeCenter = NSPoint(
                x: center.x + cos(nodeAngle) * 7.05 * scale,
                y: center.y + sin(nodeAngle) * 7.05 * scale
            )
            let nodeRadius = 1.15 * scale
            let node = NSBezierPath(ovalIn: NSRect(
                x: nodeCenter.x - nodeRadius,
                y: nodeCenter.y - nodeRadius,
                width: nodeRadius * 2,
                height: nodeRadius * 2
            ))
            ink.setFill()
            node.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Relay"
        return image
    }
}

enum MenuBarIconSelfTest {
    static func run() -> [String] {
        let image = MenuBarIcon.make()
        var failures: [String] = []
        if image.size != MenuBarIcon.pointSize {
            failures.append("menu bar icon has the wrong point size")
        }
        if !image.isTemplate {
            failures.append("menu bar icon is not configured as a template image")
        }
        if image.tiffRepresentation == nil {
            failures.append("menu bar icon did not render")
        }
        return failures
    }
}
