// AppIcon.swift
//
// Draws the Screenshot Hub app icon: a viewfinder with two screenshots in it,
// the back one dashed (still in memory), the front one saved.
// build.sh runs this script and turns the result into an .icns with iconutil.
//
// Usage: swift AppIcon.swift <folder.iconset>

import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Runs `body` in a coordinate system rotated around `center`.
func rotated(_ degrees: CGFloat, around center: NSPoint, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: degrees)
    transform.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws the icon in a 1024 × 1024 point canvas.
func drawIcon() {
    // Tile on the standard macOS grid: 824 points wide with a 100 point margin.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let dropShadow = NSShadow()
    dropShadow.shadowColor = color(0x000000, 0.28)
    dropShadow.shadowBlurRadius = 24
    dropShadow.shadowOffset = NSSize(width: 0, height: -10)
    dropShadow.set()
    color(0x4B3FD9).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Indigo top left to pink bottom right.
    NSGradient(colors: [color(0x4F5BFA), color(0x8B45F0), color(0xE2508F)],
               atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!
        .draw(in: tile, angle: -55)
    // Soft light from the top.
    NSGradient(colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)])!
        .draw(in: tile, angle: -90)

    // Viewfinder corners.
    let frame = NSRect(x: 222, y: 222, width: 580, height: 580)
    let arm: CGFloat = 118
    let corners = NSBezierPath()
    corners.lineWidth = 42
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                           (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
        corners.move(to: NSPoint(x: x, y: y + dy * arm))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x + dx * arm, y: y))
    }
    color(0xFFFFFF, 0.95).setStroke()
    corners.stroke()

    let center = NSPoint(x: 512, y: 500)
    let card = NSRect(x: -190, y: -136, width: 380, height: 272)

    // Back screenshot: still in memory, so dashed.
    rotated(-11, around: NSPoint(x: center.x - 18, y: center.y + 34)) {
        let back = NSBezierPath(roundedRect: card, xRadius: 34, yRadius: 34)
        color(0xFFFFFF, 0.22).setFill()
        back.fill()
        back.lineWidth = 12
        back.setLineDash([30, 22], count: 2, phase: 0)
        color(0xFFFFFF, 0.9).setStroke()
        back.stroke()
    }

    // Front screenshot: saved.
    rotated(5, around: NSPoint(x: center.x + 20, y: center.y - 22)) {
        let front = NSBezierPath(roundedRect: card, xRadius: 34, yRadius: 34)
        NSGraphicsContext.saveGraphicsState()
        let cardShadow = NSShadow()
        cardShadow.shadowColor = color(0x2A1270, 0.35)
        cardShadow.shadowBlurRadius = 30
        cardShadow.shadowOffset = NSSize(width: 0, height: -14)
        cardShadow.set()
        color(0xFFFFFF).setFill()
        front.fill()
        NSGraphicsContext.restoreGraphicsState()

        // A small landscape as the "picture".
        let picture = card.insetBy(dx: 26, dy: 26)
        let picturePath = NSBezierPath(roundedRect: picture, xRadius: 18, yRadius: 18)
        NSGraphicsContext.saveGraphicsState()
        picturePath.addClip()
        NSGradient(colors: [color(0xDCE3FF), color(0xF3E6FF)])!.draw(in: picture, angle: 90)

        color(0xFFA62B).setFill()
        NSBezierPath(ovalIn: NSRect(x: picture.maxX - 108, y: picture.maxY - 98, width: 62, height: 62)).fill()

        let farHill = NSBezierPath()
        farHill.move(to: NSPoint(x: picture.minX - 10, y: picture.minY))
        farHill.line(to: NSPoint(x: picture.minX + 70, y: picture.minY + 92))
        farHill.line(to: NSPoint(x: picture.minX + 150, y: picture.minY + 40))
        farHill.line(to: NSPoint(x: picture.minX + 230, y: picture.minY + 128))
        farHill.line(to: NSPoint(x: picture.maxX + 10, y: picture.minY + 10))
        farHill.line(to: NSPoint(x: picture.maxX + 10, y: picture.minY))
        farHill.close()
        color(0x8B45F0, 0.55).setFill()
        farHill.fill()

        let nearHill = NSBezierPath()
        nearHill.move(to: NSPoint(x: picture.minX - 10, y: picture.minY))
        nearHill.line(to: NSPoint(x: picture.minX + 110, y: picture.minY + 70))
        nearHill.line(to: NSPoint(x: picture.minX + 200, y: picture.minY + 22))
        nearHill.line(to: NSPoint(x: picture.maxX + 10, y: picture.minY + 84))
        nearHill.line(to: NSPoint(x: picture.maxX + 10, y: picture.minY))
        nearHill.close()
        color(0x4F5BFA).setFill()
        nearHill.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

func render(pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// The file names iconutil expects.
for size in [16, 32, 128, 256, 512] {
    try render(pixels: size, to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2, to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
