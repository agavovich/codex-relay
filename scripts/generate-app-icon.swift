#!/usr/bin/swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data(
        "usage: generate-app-icon.swift <AppIcon.iconset>\n".utf8
    ))
    exit(EXIT_FAILURE)
}

let projectDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let sourceURL = projectDirectory
    .appendingPathComponent("Resources", isDirectory: true)
    .appendingPathComponent("AppIconPreview.png")

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data(
        "could not load icon source at \(sourceURL.path)\n".utf8
    ))
    exit(EXIT_FAILURE)
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

func renderIcon(size: Int, to outputURL: URL) throws {
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
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .copy,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: outputURL, options: .atomic)
}

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
    try renderIcon(
        size: size,
        to: outputDirectory.appendingPathComponent(name)
    )
}

print(outputDirectory.path)
