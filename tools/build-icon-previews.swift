#!/usr/bin/env swift
//
// Flattens an Icon Composer `.icon` bundle into a single PNG, for use as a
// preview in the app's own icon picker.
//
// This exists because an app cannot load its own icon at runtime. Icon
// Composer icons compile into the asset catalogue as `Icon Image` renditions,
// and `UIImage(named:)` does not merely fail on those — it raises, and takes
// the app with it. Loose PNGs beside the icons are the only thing a picker can
// draw.
//
// The subset implemented here is the subset these icons use: a solid
// background fill, and visible layers composited in order with their own
// translation and scale. Appearance-specific tints and the specular pass are
// not reproduced — the light-appearance icon is what a picker row shows, and
// the art already carries its own colour.
//
// Usage:
//   swift tools/build-icon-previews.swift Herding/AppIcon.icon Herding/AppIcon-Preview.png

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Icon Composer lays every icon out on a 1024-point square.
let canvas = 1024.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Parse the colour syntax the icon manifest uses.
///
/// `extended-gray:G,A` and `display-p3:R,G,B,A`. The P3 components are read as
/// sRGB, which is close enough for a 56-point thumbnail and avoids dragging a
/// colour-management dependency into a build script.
func colour(_ value: String) -> CGColor {
    let parts = value.split(separator: ":")
    guard parts.count == 2 else { fail("unparsable colour \(value)") }
    let numbers = parts[1].split(separator: ",").compactMap { Double($0) }
    switch parts[0] {
    case "extended-gray" where numbers.count == 2:
        return CGColor(red: numbers[0], green: numbers[0], blue: numbers[0], alpha: numbers[1])
    case "display-p3" where numbers.count == 4:
        return CGColor(red: numbers[0], green: numbers[1], blue: numbers[2], alpha: numbers[3])
    default:
        fail("unparsable colour \(value)")
    }
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("could not read \(url.path)")
    }
    return image
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("usage: build-icon-previews.swift <icon bundle> <output png>")
}
let bundle = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])

guard let manifestData = try? Data(contentsOf: bundle.appendingPathComponent("icon.json")),
      let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
    fail("no readable icon.json in \(bundle.path)")
}

guard let context = CGContext(data: nil,
                              width: Int(canvas), height: Int(canvas),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fail("could not create the drawing context")
}

// Background.
if let fill = manifest["fill"] as? [String: Any], let solid = fill["solid"] as? String {
    context.setFillColor(colour(solid))
    context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
}

// Layers, back to front. The manifest lists them front-first, the way a layers
// palette does, so each group's list is reversed before drawing.
for group in (manifest["groups"] as? [[String: Any]] ?? []) {
    for layer in (group["layers"] as? [[String: Any]] ?? []).reversed() {
        if layer["hidden"] as? Bool == true { continue }
        guard let name = layer["image-name"] as? String else { continue }

        let image = loadImage(bundle.appendingPathComponent("Assets").appendingPathComponent(name))

        let position = layer["position"] as? [String: Any] ?? [:]
        let scale = position["scale"] as? Double ?? 1
        let translation = position["translation-in-points"] as? [Double] ?? [0, 0]

        let side = canvas * scale
        let inset = (canvas - side) / 2
        // CoreGraphics draws bottom-up; the manifest measures downward, so the
        // vertical offset is subtracted rather than added.
        let rect = CGRect(x: inset + translation[0],
                          y: inset - translation[1],
                          width: side, height: side)

        context.setAlpha(layer["opacity"] as? Double ?? 1)
        context.draw(image, in: rect)
        context.setAlpha(1)
    }
}

guard let rendered = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("could not write \(output.path)")
}
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not finalise \(output.path)") }

print("wrote \(output.lastPathComponent)")
