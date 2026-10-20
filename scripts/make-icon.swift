// Draws the Limelight app icon and writes Resources/AppIcon.icns.
// usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Limelight.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Body on Apple's 1024 grid: 824pt square, ~185pt corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.09, green: 0.12, blue: 0.08, alpha: 1).cgColor,
        NSColor(red: 0.03, green: 0.04, blue: 0.03, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The beam: a soft cone of lime light from above, landing on the lens.
    let lime = NSColor(red: 0.78, green: 0.96, blue: 0.20, alpha: 1)
    ctx.saveGState()
    let beam = CGMutablePath()
    beam.move(to: CGPoint(x: 430, y: 940))
    beam.addLine(to: CGPoint(x: 594, y: 940))
    beam.addLine(to: CGPoint(x: 760, y: 360))
    beam.addLine(to: CGPoint(x: 264, y: 360))
    beam.closeSubpath()
    ctx.addPath(beam)
    ctx.clip()
    let beamGradient = CGGradient(colorsSpace: space, colors: [
        lime.withAlphaComponent(0.05).cgColor, lime.withAlphaComponent(0.30).cgColor, lime.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 0.75, 1])!
    ctx.drawLinearGradient(beamGradient, start: CGPoint(x: 512, y: 940), end: CGPoint(x: 512, y: 360), options: [])
    ctx.restoreGState()

    // Glow pool behind the lens.
    let glow = CGGradient(colorsSpace: space, colors: [
        lime.withAlphaComponent(0.55).cgColor, lime.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 470, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 520), endRadius: 330, options: [])

    // Magnifier: lens ring and handle.
    let center = CGPoint(x: 470, y: 530)
    let radius: CGFloat = 165
    ctx.setStrokeColor(lime.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(64)
    ctx.move(to: CGPoint(x: center.x + radius * 0.74, y: center.y - radius * 0.74))
    ctx.addLine(to: CGPoint(x: 735, y: 262))
    ctx.strokePath()
    ctx.setLineWidth(56)
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.strokePath()
    let lens = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.55).cgColor, lime.withAlphaComponent(0.12).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius + 28, y: center.y - radius + 28, width: (radius - 28) * 2, height: (radius - 28) * 2))
    ctx.clip()
    ctx.drawRadialGradient(lens, startCenter: CGPoint(x: center.x - 50, y: center.y + 60), startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try draw(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
