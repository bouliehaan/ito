// Renders Resources/ito.icns: 糸電話, two cups and the thread between them,
// white on black. Run once; the .icns is committed.
import AppKit

let out = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ito.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: 824 px body, centred, square corners on purpose.
    NSColor.black.setFill()
    NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s).fill()
    NSColor(white: 1, alpha: 0.15).setStroke()
    let border = NSBezierPath(rect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s).insetBy(dx: 2 * s, dy: 2 * s))
    border.lineWidth = 4 * s
    border.stroke()
    NSColor.white.setFill()
    NSRect(x: 300 * s, y: 438 * s, width: 72 * s, height: 148 * s).fill()
    NSRect(x: 652 * s, y: 438 * s, width: 72 * s, height: 148 * s).fill()
    NSRect(x: 372 * s, y: 506 * s, width: 280 * s, height: 12 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
