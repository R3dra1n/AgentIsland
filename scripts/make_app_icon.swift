#!/usr/bin/env swift
// Draws the AgentIsland app icon and writes AppIcon.icns.
//
//   swift scripts/make_app_icon.swift Resources/AppIcon.icns [preview.png]
//
// The icon is the collapsed island: a black tile, a capsule, and three status
// lights in the HUD's own colours (docs/hud-style.md). Everything is drawn from
// numbers, so changing the design means changing this file and running it again.
import AppKit

// MARK: - Design (units of a 1024 canvas)

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)         // Apple's icon grid
let pill = CGRect(x: 172, y: 392, width: 680, height: 240)         // the collapsed island
let dotRadius: CGFloat = 62
let dotSpacing: CGFloat = 196

// The HUD's lights: executing, finished, needs action.
let lights: [NSColor] = [
    NSColor(srgbRed: 1.000, green: 0.761, blue: 0.294, alpha: 1),   // #FFC24B
    NSColor(srgbRed: 0.239, green: 0.863, blue: 0.518, alpha: 1),   // #3DDC84
    NSColor(srgbRed: 1.000, green: 0.361, blue: 0.361, alpha: 1),   // #FF5C5C
]

// MARK: - Drawing

/// Apple's icon corner is a continuous curve, closer to a superellipse than to a
/// plain rounded rectangle.
func squircle(in r: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map { $0.cgColor } as CFArray, locations: locations)!
}

func draw(in ctx: CGContext) {
    // Soft shadow under the tile, as every macOS icon has.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    ctx.addPath(squircle(in: tile)); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Tile: black, with a faint lift at the top so it does not vanish on a dark Dock.
    ctx.saveGState()
    ctx.addPath(squircle(in: tile)); ctx.clip()
    ctx.drawLinearGradient(gradient([NSColor(srgbRed: 0.118, green: 0.122, blue: 0.145, alpha: 1),
                                     NSColor(srgbRed: 0.000, green: 0.000, blue: 0.000, alpha: 1)], [0, 0.75]),
                           start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle(in: tile.insetBy(dx: 1.5, dy: 1.5)))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()

    // The island: a capsule one step lighter than the tile.
    ctx.addPath(roundedRect(pill, pill.height / 2))
    ctx.setFillColor(NSColor(srgbRed: 0.055, green: 0.058, blue: 0.070, alpha: 1).cgColor); ctx.fillPath()
    ctx.addPath(roundedRect(pill.insetBy(dx: 1.5, dy: 1.5), pill.height / 2 - 1.5))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(3); ctx.strokePath()

    // Three lights, with the faint glow the HUD gives them.
    for (i, light) in lights.enumerated() {
        let c = CGPoint(x: pill.midX + CGFloat(i - 1) * dotSpacing, y: pill.midY)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 46, color: light.withAlphaComponent(0.70).cgColor)
        ctx.setFillColor(light.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - dotRadius, y: c.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
        ctx.restoreGState()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let ctx = g.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Output

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: make_app_icon.swift out.icns [preview.png]\n".utf8)); exit(2) }
let out = URL(fileURLWithPath: args[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AgentIsland-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if args.count >= 3 { try png(size: 1024).write(to: URL(fileURLWithPath: args[2])) }

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run(); task.waitUntilExit()
exit(task.terminationStatus)
