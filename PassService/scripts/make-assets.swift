#!/usr/bin/env swift
// Regenerates the pass images in Sources/PassServiceCore/Resources.
// Run from PassService/: swift scripts/make-assets.swift

import AppKit

let brand = NSColor(srgbRed: 0.09, green: 0.33, blue: 0.86, alpha: 1)

func render(width: Int, height: Int, to path: String, draw: (CGFloat, CGFloat) -> Void) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(width), CGFloat(height))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: path))
}

/// A rounded tile holding a lightning bolt.
func drawMark(in rect: CGRect) {
    brand.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22).fill()
    let bolt = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [
        (0.58, 0.88), (0.26, 0.46), (0.47, 0.46), (0.40, 0.12), (0.74, 0.56), (0.53, 0.56),
    ]
    for (index, point) in points.enumerated() {
        let location = CGPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
        index == 0 ? bolt.move(to: location) : bolt.line(to: location)
    }
    bolt.close()
    NSColor.white.setFill()
    bolt.fill()
}

let directory = "Sources/PassServiceCore/Resources"
try render(width: 38, height: 38, to: "\(directory)/icon.png") { width, height in
    drawMark(in: CGRect(x: 0, y: 0, width: width, height: height))
}
try render(width: 76, height: 76, to: "\(directory)/icon@2x.png") { width, height in
    drawMark(in: CGRect(x: 0, y: 0, width: width, height: height))
}
try render(width: 160, height: 50, to: "\(directory)/logo.png") { _, height in
    drawMark(in: CGRect(x: 4, y: 7, width: height - 14, height: height - 14))
}
