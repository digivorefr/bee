// Draws the Bee application icon and writes Resources/Bee.icns.
// Usage: swift Scripts/make-icon.swift (from the repository root)
import AppKit

let canvas: CGFloat = 1024
let honeyTop = NSColor(srgbRed: 0.97, green: 0.79, blue: 0.17, alpha: 1)
let honeyBottom = NSColor(srgbRed: 0.93, green: 0.66, blue: 0.04, alpha: 1)
let ink = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)

func drawIcon(in context: CGContext) {
    // The tile.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    context.addPath(tilePath)
    context.setFillColor(honeyBottom.cgColor)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [honeyTop.cgColor, honeyBottom.cgColor] as CFArray, locations: [0, 1]
    )
    if let gradient {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    }
    context.restoreGState()

    // One cell of the comb.
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let radius: CGFloat = 262
    let hexagon = CGMutablePath()
    for corner in 0..<6 {
        let angle = CGFloat(corner) * .pi / 3 + .pi / 6
        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        if corner == 0 { hexagon.move(to: point) } else { hexagon.addLine(to: point) }
    }
    hexagon.closeSubpath()
    context.addPath(hexagon)
    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(46)
    context.setLineJoin(.round)
    context.strokePath()

    // Three lines: a request on the wire, and the stripes of a bee.
    context.setLineCap(.round)
    context.setLineWidth(42)
    let left = center.x - 118
    let lines: [(y: CGFloat, width: CGFloat)] = [(84, 236), (0, 168), (-84, 204)]
    for line in lines {
        context.move(to: CGPoint(x: left, y: center.y + line.y))
        context.addLine(to: CGPoint(x: left + line.width, y: center.y + line.y))
        context.strokePath()
    }
}

func png(size: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: context)
    return bitmap.representation(using: .png, properties: [:])
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Bee.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    guard let data = png(size: variant.size) else { fatalError("Could not draw \(variant.name)") }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/Bee.icns"]
try process.run()
process.waitUntilExit()
if let preview = png(size: 512) { try preview.write(to: URL(fileURLWithPath: "Resources/Bee-icon-preview.png")) }
print(process.terminationStatus == 0 ? "Wrote Resources/Bee.icns" : "iconutil failed")
