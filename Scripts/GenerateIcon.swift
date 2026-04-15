#!/usr/bin/env swift
// GenerateIcon.swift — draws a retro CRT TV icon and exports icon.iconset/
// Run from the project root: swift Scripts/GenerateIcon.swift
// Then: iconutil -c icns icon.iconset -o icon.icns

import AppKit

// MARK: - Drawing

func drawTV(in size: CGSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext
    let w = size.width

    // Scale factors — all coordinates are expressed as fractions of 1024
    let s = w / 1024.0

    // ── Background: transparent ──────────────────────────────────────────────
    ctx.clear(CGRect(origin: .zero, size: size))

    // ── TV body ──────────────────────────────────────────────────────────────
    // Charcoal body with slight blue tint
    let bodyRect = CGRect(x: 80*s, y: 100*s, width: 864*s, height: 720*s)
    let bodyRadius = 60*s
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

    // Outer body fill
    ctx.setFillColor(NSColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1.0).cgColor)
    ctx.addPath(bodyPath)
    ctx.fillPath()

    // Subtle top highlight (lighter gradient band near top)
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let highlightGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 1.0, alpha: 0.12).cgColor,
            NSColor(white: 1.0, alpha: 0.0).cgColor
        ] as CFArray,
        locations: [0.0, 0.35]
    )!
    ctx.drawLinearGradient(
        highlightGrad,
        start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
        end: CGPoint(x: bodyRect.midX, y: bodyRect.midY),
        options: []
    )
    ctx.restoreGState()

    // Body border / bevel
    ctx.setStrokeColor(NSColor(white: 0.45, alpha: 0.6).cgColor)
    ctx.setLineWidth(4*s)
    ctx.addPath(bodyPath)
    ctx.strokePath()

    // ── Screen bezel (inset from body) ───────────────────────────────────────
    let bezelRect = CGRect(x: 130*s, y: 200*s, width: 764*s, height: 530*s)
    let bezelRadius = 40*s
    let bezelPath = CGPath(roundedRect: bezelRect, cornerWidth: bezelRadius, cornerHeight: bezelRadius, transform: nil)

    ctx.setFillColor(NSColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0).cgColor)
    ctx.addPath(bezelPath)
    ctx.fillPath()

    // ── Screen surface ────────────────────────────────────────────────────────
    let screenRect = CGRect(x: 155*s, y: 225*s, width: 714*s, height: 480*s)
    let screenRadius = 28*s
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil)

    // Screen base colour — deep teal-green (classic phosphor)
    ctx.setFillColor(NSColor(red: 0.04, green: 0.14, blue: 0.18, alpha: 1.0).cgColor)
    ctx.addPath(screenPath)
    ctx.fillPath()

    // Phosphor glow gradient (radial, centred slightly above-left)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    let glowGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(red: 0.10, green: 0.75, blue: 0.60, alpha: 0.28).cgColor,
            NSColor(red: 0.04, green: 0.14, blue: 0.18, alpha: 0.0).cgColor
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: CGPoint(x: screenRect.midX - 60*s, y: screenRect.midY + 60*s),
        startRadius: 0,
        endCenter:   CGPoint(x: screenRect.midX, y: screenRect.midY),
        endRadius:   380*s,
        options: [.drawsAfterEndLocation]
    )

    // Scanline effect: subtle horizontal banding
    var scanY = screenRect.minY
    while scanY < screenRect.maxY {
        ctx.setFillColor(NSColor(white: 0.0, alpha: 0.06).cgColor)
        ctx.fill(CGRect(x: screenRect.minX, y: scanY, width: screenRect.width, height: 2*s))
        scanY += 5*s
    }

    // Glass reflection (upper-left corner)
    let reflectionPath = CGMutablePath()
    reflectionPath.move(to: CGPoint(x: screenRect.minX + 30*s, y: screenRect.maxY - 30*s))
    reflectionPath.addLine(to: CGPoint(x: screenRect.minX + 220*s, y: screenRect.maxY - 30*s))
    reflectionPath.addLine(to: CGPoint(x: screenRect.minX + 120*s, y: screenRect.maxY - 160*s))
    reflectionPath.closeSubpath()

    let reflGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 1.0, alpha: 0.14).cgColor,
            NSColor(white: 1.0, alpha: 0.0).cgColor
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.addPath(reflectionPath)
    ctx.clip()
    ctx.drawLinearGradient(
        reflGrad,
        start: CGPoint(x: screenRect.minX + 30*s, y: screenRect.maxY - 30*s),
        end: CGPoint(x: screenRect.minX + 120*s, y: screenRect.maxY - 160*s),
        options: []
    )
    ctx.restoreGState()

    // Screen border
    ctx.setStrokeColor(NSColor(white: 0.25, alpha: 1.0).cgColor)
    ctx.setLineWidth(3*s)
    ctx.addPath(screenPath)
    ctx.strokePath()

    // ── Antennas ─────────────────────────────────────────────────────────────
    let antennaBase = CGPoint(x: 512*s, y: bodyRect.maxY)
    ctx.setStrokeColor(NSColor(red: 0.30, green: 0.32, blue: 0.36, alpha: 1.0).cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(12*s)

    // Left antenna
    ctx.move(to: antennaBase)
    ctx.addLine(to: CGPoint(x: 300*s, y: bodyRect.maxY + 220*s))
    ctx.strokePath()

    // Right antenna
    ctx.move(to: antennaBase)
    ctx.addLine(to: CGPoint(x: 724*s, y: bodyRect.maxY + 220*s))
    ctx.strokePath()

    // Antenna tips (small circles)
    ctx.setFillColor(NSColor(red: 0.30, green: 0.32, blue: 0.36, alpha: 1.0).cgColor)
    let tipRadius = 16*s
    ctx.fillEllipse(in: CGRect(x: 300*s - tipRadius, y: bodyRect.maxY + 220*s - tipRadius,
                               width: tipRadius*2, height: tipRadius*2))
    ctx.fillEllipse(in: CGRect(x: 724*s - tipRadius, y: bodyRect.maxY + 220*s - tipRadius,
                               width: tipRadius*2, height: tipRadius*2))

    // ── Bottom feet ───────────────────────────────────────────────────────────
    let footY   = bodyRect.minY - 30*s
    let footH   = 30*s
    let footW   = 80*s
    let footRadius = 10*s

    let leftFoot  = CGRect(x: 200*s, y: footY - footH, width: footW, height: footH + 10*s)
    let rightFoot = CGRect(x: 744*s, y: footY - footH, width: footW, height: footH + 10*s)

    ctx.setFillColor(NSColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1.0).cgColor)
    for footRect in [leftFoot, rightFoot] {
        ctx.addPath(CGPath(roundedRect: footRect, cornerWidth: footRadius, cornerHeight: footRadius, transform: nil))
        ctx.fillPath()
    }

    // ── Power LED (small green dot on bottom-right of body) ──────────────────
    let ledCenter = CGPoint(x: bodyRect.maxX - 60*s, y: bodyRect.minY + 60*s)
    let ledRadius = 14*s
    ctx.setFillColor(NSColor(red: 0.10, green: 0.90, blue: 0.45, alpha: 0.95).cgColor)
    ctx.fillEllipse(in: CGRect(x: ledCenter.x - ledRadius, y: ledCenter.y - ledRadius,
                               width: ledRadius*2, height: ledRadius*2))
    // LED glow
    let ledGlowGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(red: 0.10, green: 0.90, blue: 0.45, alpha: 0.5).cgColor,
            NSColor(red: 0.10, green: 0.90, blue: 0.45, alpha: 0.0).cgColor
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        ledGlowGrad,
        startCenter: ledCenter, startRadius: 0,
        endCenter: ledCenter, endRadius: ledRadius * 2.5,
        options: [.drawsAfterEndLocation]
    )

    image.unlockFocus()
    return image
}

// MARK: - Export

let iconsetURL = URL(fileURLWithPath: "icon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (px, filename) in sizes {
    let size = CGSize(width: px, height: px)
    let img  = drawTV(in: size)

    guard let tiffData  = img.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData   = bitmapRep.representation(using: .png, properties: [:])
    else {
        fputs("ERROR: could not render \(filename)\n", stderr)
        exit(1)
    }

    let dest = iconsetURL.appendingPathComponent(filename)
    try pngData.write(to: dest)
    print("  wrote \(filename) (\(px)×\(px))")
}

print("icon.iconset/ ready — run: iconutil -c icns icon.iconset -o icon.icns")
