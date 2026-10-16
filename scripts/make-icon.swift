// Renders Resources/AppIcon.icns: a window outline with a sidebar column, white on slate.
// Run: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func hex(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Apple's macOS grid: body is 824/1024 of the canvas, centred. Glyph is drawn in a 100-unit body space, y down.
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(hex(0x1E272C))
    ctx.fillPath()

    let u: CGFloat = 8.24
    ctx.translateBy(x: 100, y: 100)
    ctx.scaleBy(x: u, y: u)
    ctx.setStrokeColor(hex(0xEEFFFF))
    ctx.setLineWidth(max(4.5, 1.2 / (s * u)))   // keep at least ~1.2 px at 16 px
    ctx.addPath(CGPath(roundedRect: CGRect(x: 24, y: 29, width: 52, height: 42), cornerWidth: 7, cornerHeight: 7, transform: nil))
    ctx.move(to: CGPoint(x: 39, y: 29))
    ctx.addLine(to: CGPoint(x: 39, y: 71))
    ctx.strokePath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for pt in [16, 32, 128, 256, 512] {
    try render(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try render(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run()
p.waitUntilExit()
exit(p.terminationStatus)
