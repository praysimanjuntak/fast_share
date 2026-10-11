// Renders the app icon into an .iconset folder for `iconutil`.
// Usage: swift scripts/make-icon.swift <output.iconset>
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Continuous-corner rounded rectangle: the shape macOS expects for app icons.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

/// Draws on a 1024 × 1024 canvas using the macOS icon grid: an 824 × 824 body with 100 pt margins.
func drawIcon(in context: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body, radius: 185)

    // Soft drop shadow under the body.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, alpha: 0.22))
    context.addPath(bodyPath)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    // White body with a faint top-to-bottom gradient.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let gradient = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF), color(0xEEF2F7)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()

    // Hairline edge so the white body reads on white backgrounds.
    context.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5), radius: 183.5))
    context.setStrokeColor(color(0xCBD5E1))
    context.setLineWidth(3)
    context.strokePath()

    let blue = color(0x2563EB)

    // Three QR finder patterns.
    for origin in [CGPoint(x: 212, y: 596), CGPoint(x: 596, y: 596), CGPoint(x: 212, y: 212)] {
        let square = CGRect(origin: origin, size: CGSize(width: 216, height: 216))
        context.addPath(squircle(square.insetBy(dx: 20, dy: 20), radius: 44))
        context.setStrokeColor(blue)
        context.setLineWidth(40)
        context.strokePath()
        context.addPath(squircle(square.insetBy(dx: 70, dy: 70), radius: 18))
        context.setFillColor(blue)
        context.fillPath()
    }

    // A few data modules between them.
    context.setFillColor(blue)
    let modules: [(CGFloat, CGFloat)] = [(488, 752), (488, 632), (296, 488), (392, 488), (488, 488), (548, 548), (644, 488)]
    for (x, y) in modules {
        context.addPath(squircle(CGRect(x: x, y: y, width: 48, height: 48), radius: 12))
        context.fillPath()
    }

    // Share badge in the free corner: a blue disc with an up arrow.
    let center = CGPoint(x: 704, y: 320)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x1D4ED8, alpha: 0.35))
    context.addEllipse(in: CGRect(x: center.x - 112, y: center.y - 112, width: 224, height: 224))
    context.setFillColor(blue)
    context.fillPath()
    context.restoreGState()

    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(30)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: center.x, y: center.y - 58))
    context.addLine(to: CGPoint(x: center.x, y: center.y + 56))
    context.move(to: CGPoint(x: center.x - 48, y: center.y + 10))
    context.addLine(to: CGPoint(x: center.x, y: center.y + 58))
    context.addLine(to: CGPoint(x: center.x + 48, y: center.y + 10))
    context.strokePath()
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in sizes {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Couldn't create a \(pixels)px bitmap") }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: context)

    let url = output.appendingPathComponent("\(name).png")
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Couldn't write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}
