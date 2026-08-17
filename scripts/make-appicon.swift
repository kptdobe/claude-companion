#!/usr/bin/env swift
//
// make-appicon.swift <out-dir>
//
// Renders an AppIcon.iconset into <out-dir>: a rounded "squircle" with a warm
// terracotta gradient and a white speech-bubble glyph — matching the menu bar
// bubble. The wrapper (make-appicon.sh) turns the iconset into AppIcon.icns.

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = (outDir as NSString).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(
    atPath: iconset, withIntermediateDirectories: true)

/// Render the icon at an exact pixel size into a PNG.
func renderPNG(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(px)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Squircle clip (Apple's ~0.2237 corner ratio).
    let clip = NSBezierPath(roundedRect: rect,
                            xRadius: size * 0.2237, yRadius: size * 0.2237)
    clip.addClip()

    // Warm terracotta gradient background.
    let top = NSColor(srgbRed: 0.90, green: 0.56, blue: 0.42, alpha: 1)
    let bottom = NSColor(srgbRed: 0.77, green: 0.35, blue: 0.23, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

    // White speech-bubble glyph, centered.
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "bubble.left.fill",
                           accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let gs = glyph.size
        let scale = (size * 0.52) / max(gs.width, gs.height)
        let w = gs.width * scale, h = gs.height * scale
        glyph.draw(in: CGRect(x: (size - w) / 2,
                              y: (size - h) / 2 + size * 0.03,
                              width: w, height: h))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// The sizes `iconutil` expects.
let variants: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
for v in variants {
    let name = v.scale == 1
        ? "icon_\(v.pt)x\(v.pt).png"
        : "icon_\(v.pt)x\(v.pt)@2x.png"
    let data = renderPNG(px: v.pt * v.scale)
    let path = (iconset as NSString).appendingPathComponent(name)
    try! data.write(to: URL(fileURLWithPath: path))
}
print("Wrote iconset to \(iconset)")
