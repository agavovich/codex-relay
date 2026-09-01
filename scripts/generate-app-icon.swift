#!/usr/bin/swift

import AppKit
import Foundation

private let designSize: CGFloat = 1024

private func color(
    _ white: CGFloat,
    alpha: CGFloat = 1
) -> NSColor {
    NSColor(calibratedWhite: white, alpha: alpha)
}

private func drawRelayIcon() {
    let squircle = NSBezierPath(
        roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900),
        xRadius: 218,
        yRadius: 218
    )

    NSGraphicsContext.saveGraphicsState()
    let outerShadow = NSShadow()
    outerShadow.shadowColor = color(0, alpha: 0.48)
    outerShadow.shadowBlurRadius = 34
    outerShadow.shadowOffset = NSSize(width: 0, height: -18)
    outerShadow.set()
    color(0.07).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0.24), color(0.07)])!
        .draw(in: squircle, angle: -90)

    color(1, alpha: 0.28).setStroke()
    squircle.lineWidth = 7
    squircle.stroke()

    let topReflection = NSBezierPath(
        roundedRect: NSRect(x: 112, y: 634, width: 800, height: 252),
        xRadius: 145,
        yRadius: 145
    )
    NSGradient(colors: [color(1, alpha: 0), color(1, alpha: 0.22)])!
        .draw(in: topReflection, angle: 90)

    let ringCenter = NSPoint(x: 512, y: 493)
    let ring = NSBezierPath()
    ring.appendArc(
        withCenter: ringCenter,
        radius: 312,
        startAngle: 43,
        endAngle: 317,
        clockwise: false
    )
    ring.lineCapStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let ringShadow = NSShadow()
    ringShadow.shadowColor = color(0, alpha: 0.42)
    ringShadow.shadowBlurRadius = 16
    ringShadow.shadowOffset = NSSize(width: 0, height: -7)
    ringShadow.set()
    color(0.03, alpha: 0.72).setStroke()
    ring.lineWidth = 38
    ring.stroke()
    NSGraphicsContext.restoreGraphicsState()

    color(0.80, alpha: 0.48).setStroke()
    ring.lineWidth = 24
    ring.stroke()
    color(1, alpha: 0.42).setStroke()
    ring.lineWidth = 5
    ring.stroke()

    let glyph = NSBezierPath()
    glyph.move(to: NSPoint(x: 365, y: 600))
    glyph.line(to: NSPoint(x: 470, y: 500))
    glyph.line(to: NSPoint(x: 365, y: 400))
    glyph.move(to: NSPoint(x: 535, y: 400))
    glyph.line(to: NSPoint(x: 660, y: 400))
    glyph.lineCapStyle = .round
    glyph.lineJoinStyle = .round
    glyph.lineWidth = 58

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = color(0, alpha: 0.34)
    glyphShadow.shadowBlurRadius = 16
    glyphShadow.shadowOffset = NSSize(width: 0, height: -7)
    glyphShadow.set()
    color(1).setStroke()
    glyph.stroke()
    NSGraphicsContext.restoreGraphicsState()

    func drawNode(
        angleDegrees: CGFloat,
        accent: NSColor
    ) {
        let radians = angleDegrees * .pi / 180
        let center = NSPoint(
            x: ringCenter.x + cos(radians) * 312,
            y: ringCenter.y + sin(radians) * 312
        )
        let outer = NSBezierPath(ovalIn: NSRect(
            x: center.x - 43,
            y: center.y - 43,
            width: 86,
            height: 86
        ))

        NSGraphicsContext.saveGraphicsState()
        let nodeShadow = NSShadow()
        nodeShadow.shadowColor = accent.withAlphaComponent(0.45)
        nodeShadow.shadowBlurRadius = 22
        nodeShadow.set()
        accent.setFill()
        outer.fill()
        NSGraphicsContext.restoreGraphicsState()

        color(1, alpha: 0.70).setStroke()
        outer.lineWidth = 6
        outer.stroke()

        let inner = NSBezierPath(ovalIn: NSRect(
            x: center.x - 27,
            y: center.y - 27,
            width: 54,
            height: 54
        ))
        color(0.055, alpha: 0.96).setFill()
        inner.fill()
        color(1, alpha: 0.22).setStroke()
        inner.lineWidth = 4
        inner.stroke()
    }

    drawNode(angleDegrees: 43, accent: color(0.82, alpha: 0.92))
    drawNode(
        angleDegrees: 317,
        accent: NSColor(calibratedRed: 0.32, green: 0.94, blue: 0.77, alpha: 0.96)
    )
}

private func renderIcon(size: Int, to outputURL: URL) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.imageInterpolation = .high
    graphicsContext.shouldAntialias = true
    graphicsContext.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let scale = CGFloat(size) / designSize
    graphicsContext.cgContext.scaleBy(x: scale, y: scale)
    drawRelayIcon()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: outputURL, options: .atomic)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon.swift <AppIcon.iconset>\n".utf8))
    exit(EXIT_FAILURE)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in outputs {
    try renderIcon(size: size, to: outputDirectory.appendingPathComponent(name))
}

print(outputDirectory.path)
