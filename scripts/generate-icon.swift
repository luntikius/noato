import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels)/512, y: CGFloat(pixels)/512)
        NSColor(calibratedRed: 0.30, green: 0.29, blue: 0.78, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 456, height: 456), xRadius: 100, yRadius: 100).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 340, weight: .semibold), .foregroundColor: NSColor.white]
        ("n" as NSString).draw(at: NSPoint(x: 147, y: 67), withAttributes: attributes)
        NSColor(calibratedRed: 1, green: 0.53, blue: 0.38, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 352, y: 352, width: 46, height: 46)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
