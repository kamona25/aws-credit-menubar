import AppKit
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
let master = NSImage(size: NSSize(width: 1024, height: 1024))
master.lockFocus()
let outline = NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 210, yRadius: 210)
NSGradient(colors: [NSColor(srgbRed: 0.12, green: 0.25, blue: 0.47, alpha: 1), NSColor(srgbRed: 0.19, green: 0.50, blue: 0.76, alpha: 1)])!.draw(in: outline, angle: -55)
NSColor.white.withAlphaComponent(0.16).setStroke(); outline.lineWidth = 3; outline.stroke()
// Original geometric cloud artwork; the app icon does not embed a system symbol.
let cloud = NSBezierPath()
cloud.move(to: NSPoint(x: 338, y: 490))
cloud.line(to: NSPoint(x: 697, y: 490))
cloud.curve(to: NSPoint(x: 795, y: 590), controlPoint1: NSPoint(x: 758, y: 490), controlPoint2: NSPoint(x: 805, y: 527))
cloud.curve(to: NSPoint(x: 706, y: 694), controlPoint1: NSPoint(x: 795, y: 650), controlPoint2: NSPoint(x: 758, y: 693))
cloud.curve(to: NSPoint(x: 524, y: 813), controlPoint1: NSPoint(x: 689, y: 787), controlPoint2: NSPoint(x: 601, y: 835))
cloud.curve(to: NSPoint(x: 359, y: 706), controlPoint1: NSPoint(x: 446, y: 821), controlPoint2: NSPoint(x: 375, y: 785))
cloud.curve(to: NSPoint(x: 242, y: 617), controlPoint1: NSPoint(x: 292, y: 727), controlPoint2: NSPoint(x: 242, y: 675))
cloud.curve(to: NSPoint(x: 338, y: 490), controlPoint1: NSPoint(x: 211, y: 548), controlPoint2: NSPoint(x: 264, y: 490))
cloud.close()
NSColor.white.withAlphaComponent(0.95).setFill(); cloud.fill()
let text = "$" as NSString
let font = NSFont.systemFont(ofSize: 290, weight: .light)
let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.94)]
let size = text.size(withAttributes: attributes)
text.draw(at: NSPoint(x: (1024 - size.width) / 2, y: 160), withAttributes: attributes)
master.unlockFocus()
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)); NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
}
