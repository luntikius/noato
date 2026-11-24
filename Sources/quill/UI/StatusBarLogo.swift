import AppKit

/// The app's n + dot mark, without the app-icon tile for menu-bar legibility.
/// Idle uses a template for both appearances; recording has actual red pixels.
@MainActor
enum StatusBarLogo {
    static func image(recording: Bool) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 36, height: 36))
        let ink = recording ? NSColor.systemRed : NSColor.black
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 35, weight: .semibold), .foregroundColor: ink,
        ]
        ("n" as NSString).draw(at: NSPoint(x: 5, y: -2), withAttributes: attributes)
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: 27, y: 27, width: 5, height: 5)).fill()
        let image = NSImage(size: NSSize(width: 18, height: 18))
        bitmap.size = image.size
        image.addRepresentation(bitmap)
        image.isTemplate = !recording
        return image
    }
}
