import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var iconChunks = Data()
func bigEndian(_ value: UInt32) -> Data {
    var encoded = value.bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}
for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("icon context failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let side = CGFloat(size)
    NSColor(red: 0.055, green: 0.075, blue: 0.11, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect.insetBy(dx: side * 0.02, dy: side * 0.02), xRadius: side * 0.22, yRadius: side * 0.22).fill()
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: side * 0.2, dy: side * 0.2))
    ring.lineWidth = side * 0.028
    NSColor(red: 0.79, green: 0.64, blue: 0.38, alpha: 0.9).setStroke(); ring.stroke()
    let wave = NSBezierPath(); wave.move(to: NSPoint(x: side * 0.28, y: side * 0.46))
    wave.curve(to: NSPoint(x: side * 0.51, y: side * 0.61), controlPoint1: NSPoint(x: side * 0.36, y: side * 0.44), controlPoint2: NSPoint(x: side * 0.44, y: side * 0.74))
    wave.curve(to: NSPoint(x: side * 0.72, y: side * 0.54), controlPoint1: NSPoint(x: side * 0.6, y: side * 0.44), controlPoint2: NSPoint(x: side * 0.62, y: side * 0.56))
    wave.lineWidth = side * 0.039; wave.lineCapStyle = .round; wave.stroke()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("icon render failed") }
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try png.write(to: root.appendingPathComponent(name)) }
    let type = [16: "icp4", 32: "icp5", 64: "icp6", 128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10"][size]!
    iconChunks.append(Data(type.utf8)); iconChunks.append(bigEndian(UInt32(png.count + 8))); iconChunks.append(png)
}
if CommandLine.arguments.count > 2 {
    var icon = Data("icns".utf8); icon.append(bigEndian(UInt32(iconChunks.count + 8))); icon.append(iconChunks)
    try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
