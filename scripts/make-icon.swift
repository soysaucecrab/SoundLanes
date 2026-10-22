// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let output = URL(fileURLWithPath: "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = size * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: size * 185 / 1024, yRadius: size * 185 / 1024)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.42, blue: 0.98, alpha: 1),
                        NSColor(red: 0.45, green: 0.20, blue: 0.90, alpha: 1)])!.draw(in: path, angle: -60)
    // Three lanes.
    NSColor.white.withAlphaComponent(0.22).setFill()
    for index in 0..<3 {
        let y = body.minY + body.height * (0.22 + CGFloat(index) * 0.22)
        NSBezierPath(roundedRect: NSRect(x: body.minX + body.width * 0.12, y: y, width: body.width * 0.76,
                                         height: body.height * 0.07), xRadius: size * 0.02, yRadius: size * 0.02).fill()
    }
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.34, weight: .semibold)
        .applying(.init(paletteColors: [.white, NSColor(red: 0.30, green: 0.30, blue: 0.92, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        symbol.draw(in: NSRect(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2,
                               width: symbolSize.width, height: symbolSize.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")
