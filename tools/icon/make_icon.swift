// Draws the Daydream app icon as an Icon Composer icon (AppIcon.icon).
//
//   swift tools/icon/make_icon.swift App/AppIcon.icon
//
// A gold sparkle (the Create button's colour and the app's "make a picture" symbol) over
// rolling hills, in two looks: a daytime sky for light mode and a night sky for dark mode.
// It's two layers, the sky and hills, and the sparkles, each with a light image and a
// dark one; macOS picks the one matching the system appearance and adds the rounded shape,
// shadow and glass itself, so the artwork is full-bleed. Xcode makes the icons for older
// macOS versions from the same file. Edit the drawing here and rerun to change the icon.

import AppKit
import CoreGraphics

let size: CGFloat = 1024

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// The colours that differ between the light and dark icons.
struct Palette {
    let name: String
    let skyTop, skyBottom: CGColor
    let glow: CGColor
    let backHillTop, backHillBottom: CGColor
    let frontHillTop, frontHillBottom: CGColor
    let blueSparkle, smallGoldSparkle: CGColor

    static let light = Palette(
        name: "light",
        skyTop: color(0.62, 0.78, 0.98), skyBottom: color(0.99, 0.90, 0.80),
        glow: color(1.0, 0.86, 0.45, 0.55),
        backHillTop: color(0.45, 0.66, 0.95), backHillBottom: color(0.30, 0.50, 0.85),
        frontHillTop: color(0.24, 0.45, 0.82), frontHillBottom: color(0.15, 0.30, 0.62),
        blueSparkle: color(1.0, 1.0, 1.0, 0.95), smallGoldSparkle: color(1.0, 0.97, 0.85))

    static let dark = Palette(
        name: "dark",
        skyTop: color(0.17, 0.19, 0.26), skyBottom: color(0.07, 0.075, 0.09),
        glow: color(0.96, 0.78, 0.26, 0.45),
        backHillTop: color(0.20, 0.36, 0.62), backHillBottom: color(0.10, 0.17, 0.30),
        frontHillTop: color(0.13, 0.22, 0.40), frontHillBottom: color(0.06, 0.09, 0.16),
        blueSparkle: color(0.55, 0.78, 1.0), smallGoldSparkle: color(1.0, 0.90, 0.60, 0.9))
}

/// A four-point sparkle: long points top/bottom, slightly shorter left/right, concave sides.
func sparkle(center c: CGPoint, radius r: CGFloat, waist: CGFloat = 0.16) -> CGPath {
    let path = CGMutablePath()
    let w = r * waist
    let side = r * 0.82
    path.move(to: CGPoint(x: c.x, y: c.y + r))
    path.addQuadCurve(to: CGPoint(x: c.x + side, y: c.y), control: CGPoint(x: c.x + w, y: c.y + w))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + w, y: c.y - w))
    path.addQuadCurve(to: CGPoint(x: c.x - side, y: c.y), control: CGPoint(x: c.x - w, y: c.y - w))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - w, y: c.y + w))
    path.closeSubpath()
    return path
}

// Positions below are on a 1024 canvas; the whole canvas is the icon shape.
let sparkleCenter = CGPoint(x: 512, y: 530)

/// The sky, the glow behind the sparkle and the hills.
func drawBackground(in ctx: CGContext, palette p: Palette) {
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.drawLinearGradient(gradient([p.skyTop, p.skyBottom], [0, 1]),
                           start: CGPoint(x: 0, y: canvas.maxY), end: .zero, options: [])
    ctx.drawRadialGradient(gradient([p.glow, p.glow.copy(alpha: 0)!], [0, 1]),
                           startCenter: sparkleCenter, startRadius: 0, endCenter: sparkleCenter, endRadius: 410,
                           options: [])

    func hill(_ points: [CGPoint], _ top: CGColor, _ bottom: CGColor) {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: points[0])
        for i in stride(from: 1, to: points.count - 1, by: 2) {
            path.addQuadCurve(to: points[i + 1], control: points[i])
        }
        path.addLine(to: CGPoint(x: canvas.maxX, y: 0))
        path.closeSubpath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient([top, bottom], [0, 1]),
                               start: CGPoint(x: 0, y: 460), end: .zero, options: [])
        ctx.restoreGState()
    }
    hill([CGPoint(x: 0, y: 285), CGPoint(x: 286, y: 460), CGPoint(x: 572, y: 298),
          CGPoint(x: 820, y: 161), CGPoint(x: 1024, y: 348)],
         p.backHillTop, p.backHillBottom)
    hill([CGPoint(x: 0, y: 186), CGPoint(x: 398, y: 75), CGPoint(x: 671, y: 199),
          CGPoint(x: 895, y: 286), CGPoint(x: 1024, y: 161)],
         p.frontHillTop, p.frontHillBottom)
}

/// The gold sparkle (the same in both looks) and its two small companions, on transparency.
func drawSparkles(in ctx: CGContext, palette p: Palette) {
    let big = sparkle(center: sparkleCenter, radius: 310)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 48, color: color(1.0, 0.82, 0.30, 0.8))
    ctx.addPath(big)
    ctx.setFillColor(color(0.96, 0.78, 0.26))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(big)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(1.0, 0.95, 0.70), color(0.96, 0.78, 0.26), color(0.88, 0.60, 0.14)], [0, 0.5, 1]),
                           start: CGPoint(x: sparkleCenter.x - 186, y: sparkleCenter.y + 310),
                           end: CGPoint(x: sparkleCenter.x + 186, y: sparkleCenter.y - 310), options: [])
    ctx.restoreGState()

    ctx.addPath(sparkle(center: CGPoint(x: 801, y: 820), radius: 97))
    ctx.setFillColor(p.blueSparkle)
    ctx.fillPath()
    ctx.addPath(sparkle(center: CGPoint(x: 236, y: 832), radius: 55))
    ctx.setFillColor(p.smallGoldSparkle)
    ctx.fillPath()
}

func render(_ draw: (CGContext) -> Void) -> Data {
    let pixels = Int(size)
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icon")
let assets = out.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: assets)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

for palette in [Palette.light, Palette.dark] {
    try render { drawBackground(in: $0, palette: palette) }
        .write(to: assets.appendingPathComponent("background-\(palette.name).png"))
    try render { drawSparkles(in: $0, palette: palette) }
        .write(to: assets.appendingPathComponent("sparkles-\(palette.name).png"))
}

/// A layer showing `<name>-light.png`, or `<name>-dark.png` in dark mode.
func layer(_ name: String) -> [String: Any] {
    [
        "name": name,
        "image-name-specializations": [
            ["value": "\(name)-light.png"],
            ["appearance": "dark", "value": "\(name)-dark.png"],
        ],
        "glass": false,
    ]
}

// Groups and layers are listed front to back.
let icon: [String: Any] = [
    "fill": ["solid": "srgb:0.07000,0.07500,0.09000,1.00000"],
    "groups": [
        ["layers": [layer("sparkles")]],
        ["layers": [layer("background")]],
    ],
    "supported-platforms": ["squares": ["macOS"]],
]
try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("icon.json"))
print("Wrote \(out.path)")
