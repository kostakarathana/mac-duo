// Draws the Mac Duo app icon: a glass pane folding over a dark base, macOS squircle style.
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // Base squircle
    let base = CGRect(x: 100, y: 100, width: 824, height: 824)
    let basePath = CGPath(roundedRect: base, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(basePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(basePath); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [NSColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1).cgColor,
                                                   NSColor(red: 0.16, green: 0.18, blue: 0.28, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Back pane (the screen that stays)
    let back = CGRect(x: 250, y: 300, width: 524, height: 470)
    ctx.addPath(CGPath(roundedRect: back, cornerWidth: 46, cornerHeight: 46, transform: nil)); ctx.clip()
    let wall = CGGradient(colorsSpace: nil, colors: [NSColor(red: 0.20, green: 0.45, blue: 1.0, alpha: 1).cgColor,
                                                     NSColor(red: 0.62, green: 0.36, blue: 1.0, alpha: 1).cgColor,
                                                     NSColor(red: 1.0, green: 0.50, blue: 0.62, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(wall, start: CGPoint(x: 250, y: 300), end: CGPoint(x: 774, y: 770), options: [])
    ctx.restoreGState()

    // Folding glass pane, hinged at the bottom, tilted toward the viewer (drawn as a trapezoid)
    ctx.saveGState(); ctx.addPath(basePath); ctx.clip()
    let pane = CGMutablePath()
    pane.move(to: CGPoint(x: 230, y: 300)); pane.addLine(to: CGPoint(x: 794, y: 300))
    pane.addLine(to: CGPoint(x: 850, y: 560)); pane.addLine(to: CGPoint(x: 174, y: 560)); pane.closeSubpath()
    ctx.addPath(pane); ctx.clip()
    let glass = CGGradient(colorsSpace: nil, colors: [NSColor(white: 1, alpha: 0.55).cgColor,
                                                      NSColor(white: 1, alpha: 0.18).cgColor,
                                                      NSColor(white: 1, alpha: 0.38).cgColor] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(glass, start: CGPoint(x: 512, y: 300), end: CGPoint(x: 512, y: 560), options: [])
    // Specular streak
    let streak = CGMutablePath()
    streak.move(to: CGPoint(x: 330, y: 300)); streak.addLine(to: CGPoint(x: 430, y: 300))
    streak.addLine(to: CGPoint(x: 360, y: 560)); streak.addLine(to: CGPoint(x: 280, y: 560)); streak.closeSubpath()
    ctx.addPath(streak); ctx.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor); ctx.fillPath()
    ctx.restoreGState()
    // Glass rim
    ctx.addPath(pane); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor); ctx.setLineWidth(5); ctx.strokePath()
    // Hinge
    let hinge = CGRect(x: 200, y: 280, width: 624, height: 26)
    ctx.addPath(CGPath(roundedRect: hinge, cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor); ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
