import AppKit
import Foundation
// Original two-panel file-manager mark, rendered without external assets.
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels) / 1024
        NSAffineTransform(transform: AffineTransform(scale: s)).concat()
        NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 200, yRadius: 200).fill()
        for x: CGFloat in [140, 530] {
            NSColor(calibratedRed: 0.15, green: 0.30, blue: 0.46, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 180, width: 354, height: 664), xRadius: 28, yRadius: 28).fill()
            for y: CGFloat in [690, 570, 450, 330] {
                (y == 570 ? NSColor.systemTeal : NSColor(calibratedWhite: 0.85, alpha: 1)).setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 44, y: y, width: 266, height: 44), xRadius: 10, yRadius: 10).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size)\(suffix).png"))
    }
}
// ICNS PNG chunks avoid iconutil's dependence on host image services.
func word(_ value: UInt32) -> Data {
    var big = value.bigEndian
    return withUnsafeBytes(of: &big) { Data($0) }
}
var chunks = Data()
for (type, filename) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: URL(fileURLWithPath: "\(output)/\(filename)"))
    chunks.append(Data(type.utf8)); chunks.append(word(UInt32(png.count + 8))); chunks.append(png)
}
var icon = Data("icns".utf8)
icon.append(word(UInt32(chunks.count + 8))); icon.append(chunks)
try icon.write(to: URL(fileURLWithPath: "\(output)/AppIcon.icns"))
