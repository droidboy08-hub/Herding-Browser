// Renders the alternate app icons.
//
// Alternate icons cannot come from an asset catalog the way the primary one
// does — iOS looks for loose PNGs in the bundle root, named in Info.plist. So
// they are generated here rather than drawn by hand, which also means the icon
// set and the wallpaper presets are the same colours by construction instead of
// by somebody remembering to match them.
//
// Usage:  swift tools/build-app-icons.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconStyle {
    let name: String
    let colors: [(CGFloat, CGFloat, CGFloat)]   // top → bottom, 0…1
    let mark: (CGFloat, CGFloat, CGFloat)       // the ring
}

let styles = [
    // A stand-in for the shipped icon, used only as the picker's "Default" row
    // — the real one lives in the asset catalogue, which cannot be read back at
    // that size from inside the app.
    IconStyle(name: "Default",
              colors: [(0.96, 0.96, 0.97), (0.78, 0.79, 0.82)],
              mark: (0.15, 0.15, 0.17)),
    IconStyle(name: "Dusk",
              colors: [(0.11, 0.16, 0.29), (0.76, 0.33, 0.48)],
              mark: (1, 1, 1)),
    IconStyle(name: "Ink",
              colors: [(0.04, 0.04, 0.05), (0.29, 0.29, 0.33)],
              mark: (0.95, 0.95, 0.97)),
    IconStyle(name: "Sand",
              colors: [(0.42, 0.31, 0.18), (0.94, 0.85, 0.66)],
              mark: (0.16, 0.12, 0.07)),
]

/// One icon at one size. The mark is a ring with a gap — a browser is a window
/// onto something, and a closed circle reads as a record button.
func render(_ style: IconStyle, size: Int) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    var components: [CGFloat] = []
    for colour in style.colors {
        components.append(contentsOf: [colour.0, colour.1, colour.2, 1])
    }
    guard let gradient = CGGradient(colorSpace: space, colorComponents: components,
                                    locations: [0, 1], count: 2) else { return nil }
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])

    let side = CGFloat(size)
    let lineWidth = side * 0.085
    let radius = side * 0.29
    context.setStrokeColor(red: style.mark.0, green: style.mark.1, blue: style.mark.2, alpha: 1)
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: radius,
                   startAngle: .pi * 0.28, endAngle: .pi * 2, clockwise: false)
    context.strokePath()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let output = URL(fileURLWithPath: "prototype/MinimalBrowser")
for style in styles {
    // 60pt at @2x and @3x, which is what the home screen asks for.
    for (scale, size) in [(2, 120), (3, 180)] {
        guard let image = render(style, size: size) else { continue }
        let name = "AppIcon-\(style.name)@\(scale)x.png"
        write(image, to: output.appendingPathComponent(name))
        print("wrote \(name)")
    }
}
