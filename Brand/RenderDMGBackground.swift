import AppKit

// Finder window: 660 × 400. Icons: (169, 198) and (491, 198).
// AppKit artwork coordinates start at the bottom-left.
guard CommandLine.arguments.count == 2 else { fatalError("Pass an output PNG path") }
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 660, pixelsHigh: 400,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let ink = NSColor(srgbRed: 0.25, green: 0.20, blue: 0.13, alpha: 1)
let accent = NSColor(srgbRed: 0.72, green: 0.40, blue: 0.08, alpha: 1)
NSGradient(starting: NSColor(srgbRed: 1, green: 0.98, blue: 0.93, alpha: 1),
           ending: NSColor(srgbRed: 0.98, green: 0.88, blue: 0.66, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: 660, height: 400), angle: -90)
func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    value.draw(in: NSRect(x: 30, y: y, width: 600, height: size + 12), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph
    ])
}
text("Welcome to Retriever", y: 322, size: 30, weight: .bold, color: ink)
text("Drag Retriever to Applications to install.", y: 291, size: 16, weight: .regular, color: ink)
for x in [CGFloat(79), CGFloat(401)] {
    let panel = NSBezierPath(roundedRect: NSRect(x: x, y: 83, width: 180, height: 167), xRadius: 28, yRadius: 28)
    NSColor.white.withAlphaComponent(0.65).setFill()
    panel.fill()
}
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 291, y: 203))
arrow.line(to: NSPoint(x: 368, y: 203))
arrow.move(to: NSPoint(x: 349, y: 222))
arrow.line(to: NSPoint(x: 368, y: 203))
arrow.line(to: NSPoint(x: 349, y: 184))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
accent.setStroke()
arrow.stroke()
text("Then open Retriever from your Applications folder.", y: 50, size: 13, weight: .regular, color: ink)
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
