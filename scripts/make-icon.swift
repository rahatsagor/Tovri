// Native vector artwork: a cut ribbon and an insertion stem form Tovri's monochrome T.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Tovri-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

// Shared geometry for the native renders and editable SVGs; coordinates are top-to-bottom.
let ribbon: [CGPoint] = [CGPoint(x: 276, y: 302), CGPoint(x: 774, y: 302),
                         CGPoint(x: 698, y: 410), CGPoint(x: 200, y: 410)]
let stem: [CGPoint] = [CGPoint(x: 448, y: 434), CGPoint(x: 576, y: 434),
                       CGPoint(x: 576, y: 682), CGPoint(x: 448, y: 770)]

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

func svgPath(_ points: [CGPoint]) -> String {
    "M" + points.map { "\(Int($0.x)) \(Int($0.y))" }.joined(separator: "L") + "Z"
}

let mark = "<path d=\"\(svgPath(ribbon))\"/><path d=\"\(svgPath(stem))\"/>"
let logoSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="170 272 634 528" fill="currentColor" role="img" aria-label="Tovri">
  \(mark)
</svg>

"""
let iconSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Tovri app icon">
  <defs><linearGradient id="tile" x2="0" y2="1"><stop stop-color="#242424"/><stop offset="1" stop-color="#101010"/></linearGradient></defs>
  <rect x="100" y="100" width="824" height="824" rx="184" fill="url(#tile)" stroke="#383838" stroke-width="2"/>
  <g fill="#f5f5f5">\(mark)</g>
</svg>

"""

func render(_ pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 184, cornerHeight: 184, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.addPath(tile)
    ctx.setFillColor(NSColor(white: 0.063, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                              colors: [NSColor(white: 0.141, alpha: 1).cgColor,
                                       NSColor(white: 0.063, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()
    ctx.addPath(tile)
    ctx.setStrokeColor(NSColor(white: 0.22, alpha: 1).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.setFillColor(NSColor(white: 0.961, alpha: 1).cgColor)
    for points in [ribbon, stem] {
        ctx.addPath(polygon(points))
        ctx.fillPath()
    }
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return data
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try render(1024).write(to: output.deletingPathExtension().appendingPathExtension("png"))
try iconSVG.write(to: output.deletingPathExtension().appendingPathExtension("svg"), atomically: true, encoding: .utf8)
try logoSVG.write(to: output.deletingLastPathComponent().appendingPathComponent("Logo.svg"), atomically: true, encoding: .utf8)
print("Wrote monochrome icon, PNG and SVG artwork to \(output.deletingLastPathComponent().path)")
