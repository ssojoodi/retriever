import AppKit

// Editable vector source. All coordinates use a 1024 × 1024 bottom-left origin.
func drawIcon(size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let tile = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 204, yRadius: 204)
    NSGradient(starting: NSColor(srgbRed: 1, green: 0.79, blue: 0.32, alpha: 1),
               ending: NSColor(srgbRed: 0.93, green: 0.49, blue: 0.12, alpha: 1))!.draw(in: tile, angle: -90)
    // Folder tab and body.
    let folder = NSBezierPath()
    folder.move(to: NSPoint(x: 205, y: 310))
    folder.line(to: NSPoint(x: 205, y: 691))
    folder.curve(to: NSPoint(x: 245, y: 731), controlPoint1: NSPoint(x: 205, y: 717), controlPoint2: NSPoint(x: 220, y: 731))
    folder.line(to: NSPoint(x: 412, y: 731))
    folder.line(to: NSPoint(x: 474, y: 664))
    folder.line(to: NSPoint(x: 779, y: 664))
    folder.curve(to: NSPoint(x: 819, y: 624), controlPoint1: NSPoint(x: 805, y: 664), controlPoint2: NSPoint(x: 819, y: 650))
    folder.line(to: NSPoint(x: 819, y: 310))
    folder.close()
    NSColor(srgbRed: 0.59, green: 0.28, blue: 0.05, alpha: 0.45).setFill()
    folder.fill()
    let front = NSBezierPath(roundedRect: NSRect(x: 205, y: 264, width: 614, height: 374), xRadius: 44, yRadius: 44)
    NSColor(srgbRed: 1, green: 0.92, blue: 0.69, alpha: 1).setFill()
    front.fill()
    // A single arrow means retrieve, with broad geometry retained at Dock sizes.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 473, y: 591))
    arrow.line(to: NSPoint(x: 551, y: 591))
    arrow.line(to: NSPoint(x: 551, y: 446))
    arrow.line(to: NSPoint(x: 626, y: 446))
    arrow.line(to: NSPoint(x: 512, y: 332))
    arrow.line(to: NSPoint(x: 398, y: 446))
    arrow.line(to: NSPoint(x: 473, y: 446))
    arrow.close()
    NSColor(srgbRed: 0.24, green: 0.26, blue: 0.24, alpha: 1).setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let output = URL(fileURLWithPath: "Sources/RetrieverApp/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)@\(scale)x.png"
        let png = drawIcon(size: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent(filename), options: .atomic)
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
let metadata: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
try (json + Data([10])).write(to: output.appendingPathComponent("Contents.json"), options: .atomic)
print("Generated all ten Retriever icon slots (16–1024 pixels).")
