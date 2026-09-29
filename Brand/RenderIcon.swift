import AppKit

// The approved artwork is authoritative. Preserve its composition and background.
let sourceURL = URL(fileURLWithPath: "Brand/Retriever-Logo-Approved.png")
guard let source = NSImage(contentsOf: sourceURL), source.size.width == source.size.height else {
    fatalError("Expected square approved artwork at \(sourceURL.path)")
}
func drawIcon(size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                from: .zero, operation: .copy, fraction: 1)
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
