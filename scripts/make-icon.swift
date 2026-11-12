import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels), inset = p * 0.08
        let rect = NSRect(x: inset, y: inset, width: p - 2 * inset, height: p - 2 * inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: p * 0.2, yRadius: p * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.30, alpha: 1),
                   ending: NSColor(calibratedRed: 0.035, green: 0.11, blue: 0.13, alpha: 1))!.draw(in: path, angle: -90)
        NSColor.white.withAlphaComponent(0.32).setStroke(); path.lineWidth = max(1, p * 0.012); path.stroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: p * 0.255, y: p * 0.255, width: p * 0.49, height: p * 0.49))
        NSColor.white.setStroke(); ring.lineWidth = p * 0.047; ring.stroke()
        let hands = NSBezierPath(); hands.move(to: NSPoint(x: p * 0.5, y: p * 0.68))
        hands.line(to: NSPoint(x: p * 0.5, y: p * 0.5)); hands.line(to: NSPoint(x: p * 0.62, y: p * 0.43))
        hands.lineWidth = p * 0.045; hands.lineCapStyle = .round; hands.lineJoinStyle = .round; hands.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
