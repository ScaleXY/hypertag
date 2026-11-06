#!/usr/bin/env swift
// Draws the 1024px app icon. Usage: swift App/Scripts/generate-app-icon.swift <output.png>
import AppKit

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let gradient = CGGradient(colorsSpace: space, colors: [color(0.05, 0.42, 0.45), color(0.03, 0.18, 0.30)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])

// A luggage-style tag, rotated slightly, with three arcs for "present".
context.saveGState()
context.translateBy(x: 430, y: 512)
context.rotate(by: .pi / 4)
let tag = CGMutablePath()
tag.move(to: CGPoint(x: -300, y: -150))
tag.addLine(to: CGPoint(x: 130, y: -150))
tag.addLine(to: CGPoint(x: 290, y: 0))
tag.addLine(to: CGPoint(x: 130, y: 150))
tag.addLine(to: CGPoint(x: -300, y: 150))
tag.closeSubpath()
context.addPath(tag)
context.setFillColor(color(1, 1, 1))
context.fillPath()
context.setBlendMode(.normal)
context.setFillColor(color(0.04, 0.30, 0.37))
context.fillEllipse(in: CGRect(x: 100, y: -50, width: 100, height: 100))
context.restoreGState()

context.setStrokeColor(color(1, 1, 1, 0.9))
context.setLineCap(.round)
context.setLineWidth(46)
for (index, radius) in [120.0, 200.0, 280.0].enumerated() {
    context.setAlpha(1 - CGFloat(index) * 0.22)
    context.addArc(center: CGPoint(x: 560, y: 560), radius: radius, startAngle: -.pi / 12, endAngle: .pi / 2 + .pi / 12, clockwise: false)
    context.strokePath()
}

let image = NSBitmapImageRep(cgImage: context.makeImage()!)
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
