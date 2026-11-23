// Offline review tool: swift Scripts/CreateVisualReview.swift <capture-directory>
import AppKit
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else { fatalError("Pass the GPU capture directory") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let scenes = ["clear-day", "partlyCloudy-day", "cloudy-day", "rain-day", "thunderstorm-night",
              "partlyCloudy-dusk", "clear-night", "snow-day", "cirrus-only-day"]
let tileWidth = 480, tileHeight = 326
let width = tileWidth * 3, height = tileHeight * 3
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot create review image") }
context.setFillColor(CGColor(gray: 0.07, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
for (index, scene) in scenes.enumerated() {
    let url = root.appendingPathComponent("\(scene).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
    let x = (index % 3) * tileWidth, y = (2 - index / 3) * tileHeight
    context.draw(image, in: CGRect(x: x, y: y + 26, width: tileWidth, height: 300))
    NSAttributedString(string: scene.replacingOccurrences(of: "-", with: " · "), attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white
    ]).draw(at: NSPoint(x: x + 10, y: y + 7))
}
NSGraphicsContext.restoreGraphicsState()
guard let image = context.makeImage() else { fatalError("Cannot finish review image") }
let url = root.appendingPathComponent("visual-review.png")
guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot write review image")
}
CGImageDestinationAddImage(output, image, nil)
guard CGImageDestinationFinalize(output) else { fatalError("Cannot save review image") }
print(url.path)
