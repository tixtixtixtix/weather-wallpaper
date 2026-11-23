// Run from the repository root: swift Scripts/GenerateIcon.swift
// Original vector artwork, generated using AppKit; no downloaded or Apple-owned assets.
import AppKit

let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Sources/WeatherWallpaper/Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 188, yRadius: 188)
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0.02, 0.08, 0.24)
    shadow.shadowBlurRadius = 32
    shadow.shadowOffset = NSSize(width: 0, height: -15)
    shadow.set()
    color(0.1, 0.2, 0.35).setFill()
    tile.fill()
    NSShadow().set()
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [color(0.43, 0.69, 0.87), color(0.10, 0.31, 0.59), color(0.055, 0.13, 0.32)])!
        .draw(in: NSRect(x: 100, y: 100, width: 824, height: 824), angle: 65)

    NSGradient(starting: color(1, 0.81, 0.43, 0.35), ending: color(1, 0.8, 0.4, 0))!
        .draw(fromCenter: NSPoint(x: 655, y: 665), radius: 30,
              toCenter: NSPoint(x: 655, y: 665), radius: 340, options: [])
    let sun = NSBezierPath(ovalIn: NSRect(x: 548, y: 558, width: 214, height: 214))
    NSGradient(starting: color(1, 0.94, 0.73), ending: color(1, 0.74, 0.36))!
        .draw(in: sun, angle: 85)

    let cloud = NSBezierPath()
    cloud.appendOval(in: NSRect(x: 245, y: 342, width: 234, height: 227))
    cloud.appendOval(in: NSRect(x: 365, y: 364, width: 290, height: 280))
    cloud.appendOval(in: NSRect(x: 545, y: 339, width: 231, height: 222))
    cloud.appendRoundedRect(NSRect(x: 280, y: 334, width: 452, height: 165), xRadius: 80, yRadius: 80)
    let cloudShadow = NSShadow()
    cloudShadow.shadowColor = color(0.02, 0.09, 0.22, 0.3)
    cloudShadow.shadowBlurRadius = 35
    cloudShadow.shadowOffset = NSSize(width: 0, height: -19)
    cloudShadow.set()
    color(0.9, 0.95, 1).setFill()
    cloud.fill()
    NSShadow().set()
    NSGradient(starting: color(0.71, 0.83, 0.94), ending: .white)!.draw(in: cloud, angle: 90)

    let line = NSBezierPath(roundedRect: NSRect(x: 352, y: 256, width: 318, height: 8), xRadius: 4, yRadius: 4)
    color(0.77, 0.88, 1, 0.38).setFill()
    line.fill()
    NSGraphicsContext.restoreGraphicsState()
    tile.lineWidth = 2
    color(1, 1, 1, 0.15).setStroke()
    tile.stroke()
    NSGraphicsContext.restoreGraphicsState()

    try bitmap.representation(using: .png, properties: [:])!
        .write(to: destination.appendingPathComponent("icon-\(size).png"))
}
