#!/usr/bin/env swift
//
// render_app_icon.swift
//
// Regenerates the MyTerm Remote app icon (1024x1024, opaque, no alpha).
//
// Usage:
//   swift apps/MyTermRemote/script/render_app_icon.swift <output.png>
//
// Design: a deep navy vertical gradient background with a large white
// monospaced ">_" prompt glyph, and a small iOS-system-blue accent dot
// near the underscore to hint at the "attention dot" feature.

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("Usage: swift render_app_icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = arguments[1]

let size = 1024
let width = size
let height = size

func monospaceFont(ofSize fontSize: CGFloat) -> NSFont {
    if let sfMono = NSFont(name: "SFMono-Bold", size: fontSize) {
        return sfMono
    }
    if let sfMonoAlt = NSFont(name: "SF Mono Bold", size: fontSize) {
        return sfMonoAlt
    }
    if let menlo = NSFont(name: "Menlo-Bold", size: fontSize) {
        return menlo
    }
    return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
}

/// Draws `attributedString` at `drawOrigin` into a transparent scratch
/// canvas and returns the tight pixel bounding box (alpha > threshold) of
/// the rendered ink, in the same top-left-origin, y-down coordinate space
/// used for `drawOrigin`. Returns nil if nothing was drawn.
func measureInkBounds(
    of attributedString: NSAttributedString,
    drawOrigin: CGPoint,
    canvasSize: Int
) -> CGRect? {
    guard let ctx = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: canvasSize * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    ctx.translateBy(x: 0, y: CGFloat(canvasSize))
    ctx.scaleBy(x: 1, y: -1)

    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    attributedString.draw(at: drawOrigin)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = ctx.data else { return nil }
    let pixels = data.bindMemory(to: UInt8.self, capacity: canvasSize * canvasSize * 4)

    var minX = canvasSize, maxX = -1, minY = canvasSize, maxY = -1
    let alphaThreshold: UInt8 = 10
    for y in 0..<canvasSize {
        let rowBase = y * canvasSize * 4
        for x in 0..<canvasSize {
            let alpha = pixels[rowBase + x * 4 + 3]
            if alpha > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }

    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
}

// --- Determine font size so the glyph's ink fills ~55% of the icon width ---
let promptText = ">_"
let targetWidthFraction: CGFloat = 0.55
let targetWidth = CGFloat(width) * targetWidthFraction

let measureCanvasSize = width * 3
let measureOrigin = CGPoint(x: CGFloat(width), y: CGFloat(width))

var fontSize: CGFloat = CGFloat(width) * 0.4
var currentFont = monospaceFont(ofSize: fontSize)
var attributes: [NSAttributedString.Key: Any] = [
    .font: currentFont,
    .foregroundColor: NSColor.white
]
var attributedString = NSAttributedString(string: promptText, attributes: attributes)

guard let firstPassBounds = measureInkBounds(of: attributedString, drawOrigin: measureOrigin, canvasSize: measureCanvasSize) else {
    fatalError("Could not measure prompt glyph ink bounds (first pass)")
}

let scale = targetWidth / firstPassBounds.width
fontSize *= scale
currentFont = monospaceFont(ofSize: fontSize)
attributes[.font] = currentFont
attributedString = NSAttributedString(string: promptText, attributes: attributes)

guard let finalBounds = measureInkBounds(of: attributedString, drawOrigin: measureOrigin, canvasSize: measureCanvasSize) else {
    fatalError("Could not measure prompt glyph ink bounds (final pass)")
}

// Bearing between the AppKit draw origin (top-left of the string's layout
// box) and the actual tight ink bounding box, so we can place the ink
// exactly where we want it rather than the layout box.
let bearing = CGPoint(x: finalBounds.origin.x - measureOrigin.x, y: finalBounds.origin.y - measureOrigin.y)

// Optical center of the icon, for the ink bounding box (not the layout box).
let desiredInkCenter = CGPoint(x: CGFloat(width) / 2.0, y: CGFloat(height) / 2.0)
let desiredInkOrigin = CGPoint(
    x: desiredInkCenter.x - finalBounds.width / 2.0,
    y: desiredInkCenter.y - finalBounds.height / 2.0
)
let finalDrawOrigin = CGPoint(x: desiredInkOrigin.x - bearing.x, y: desiredInkOrigin.y - bearing.y)
let finalInkBounds = CGRect(origin: desiredInkOrigin, size: finalBounds.size)

// --- Build the real icon context: NO alpha channel, so the PNG is opaque ---
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("Could not create color space")
}

let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Could not create CGContext")
}

// Flip so (0,0) is top-left, matching the coordinate space used above.
context.translateBy(x: 0, y: CGFloat(height))
context.scaleBy(x: 1, y: -1)

let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsContext

let bounds = CGRect(x: 0, y: 0, width: width, height: height)

// --- Background: deep near-black navy vertical gradient ---
let topColor = NSColor(calibratedRed: 0x0B / 255.0, green: 0x10 / 255.0, blue: 0x20 / 255.0, alpha: 1.0)
let bottomColor = NSColor(calibratedRed: 0x16 / 255.0, green: 0x1C / 255.0, blue: 0x33 / 255.0, alpha: 1.0)
guard let gradient = NSGradient(starting: topColor, ending: bottomColor) else {
    fatalError("Could not create gradient")
}
gradient.draw(in: bounds, angle: -90)

// --- Foreground: large white monospaced ">_" prompt glyph, ink-centered ---
attributedString.draw(at: finalDrawOrigin)

// --- Accent: iOS system blue dot near the underscore, bottom-right ---
let dotDiameter = CGFloat(width) * 0.06
let dotColor = NSColor(calibratedRed: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)

// The underscore is the trailing, lowest part of the glyph, so the ink
// bounding box's bottom-right corner sits right at its lower-right edge.
let dotCenter = CGPoint(
    x: finalInkBounds.maxX - dotDiameter * 0.25,
    y: finalInkBounds.maxY - dotDiameter * 0.25
)
let dotRect = CGRect(
    x: dotCenter.x - dotDiameter / 2.0,
    y: dotCenter.y - dotDiameter / 2.0,
    width: dotDiameter,
    height: dotDiameter
)
let dotPath = NSBezierPath(ovalIn: dotRect)
dotColor.setFill()
dotPath.fill()

NSGraphicsContext.restoreGraphicsState()

// --- Export to PNG (opaque, no alpha) ---
guard let cgImage = context.makeImage() else {
    fatalError("Could not create CGImage from context")
}

let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fatalError("Could not create PNG data")
}

let outputURL = URL(fileURLWithPath: outputPath)
do {
    try pngData.write(to: outputURL)
    print("Wrote \(width)x\(height) icon to \(outputPath)")
} catch {
    fatalError("Could not write PNG to \(outputPath): \(error)")
}
