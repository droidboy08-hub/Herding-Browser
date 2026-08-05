// Turn a designed 1024×1024 icon into the loose PNGs an alternate app icon needs.
//
//   swift tools/import-app-icon.swift <source.png> <Name>
//
// Two things have to happen to a designed icon before iOS will take it, and
// both are easy to miss because the source looks perfect in Preview:
//
// 1. **The alpha has to go.** An app icon is composited by the system against
//    nothing — transparent pixels come out black, or worse, show whatever the
//    icon is being drawn over. So the artwork is flattened onto its own
//    background colour, sampled from the source rather than guessed, which is
//    why this doesn't need to be told what that colour is.
//
// 2. **The rounding has to go.** Icon artwork almost always ships with the
//    squircle already drawn in, plus a soft shadow outside it. iOS then applies
//    its *own* mask on top, and the two roundings don't coincide — you get a
//    thin double edge and a grey halo in the corners. Overscanning slightly
//    pushes the baked corners and the shadow outside the frame, leaving the
//    system's mask to do the only rounding.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: import-app-icon.swift <source.png> <Name>\n".utf8))
    exit(1)
}
let sourcePath = arguments[1]
let iconName = arguments[2]

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("could not read \(sourcePath)\n".utf8))
    exit(1)
}

let space = CGColorSpaceCreateDeviceRGB()

/// Read one pixel, to learn what the artwork's own background is.
func sample(_ image: CGImage, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat) {
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                              bytesPerRow: 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return (0, 0, 0)
    }
    ctx.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - y),
                               width: CGFloat(image.width), height: CGFloat(image.height)))
    return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
}

// Just inside the top edge of the artwork, above the moon and clear of the
// shadow: that is the background, whatever the designer made it.
let background = sample(image, x: image.width / 2, y: image.height / 12)

/// How much of the source to throw away on each side. Enough to lose the drawn
/// corner radius and its shadow, little enough that nothing of the subject goes.
let overscan: CGFloat = 1.06

func write(size: Int, to url: URL) {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              // `noneSkipLast`: an opaque buffer, so the result
                              // has no alpha channel at all rather than an
                              // alpha channel that happens to be full.
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
    ctx.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.interpolationQuality = .high

    let side = CGFloat(size) * overscan
    let offset = (CGFloat(size) - side) / 2
    ctx.draw(image, in: CGRect(x: offset, y: offset, width: side, height: side))

    guard let out = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.lastPathComponent) (\(size)×\(size))")
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("prototype/MinimalBrowser")
// 60pt at 2x and 3x — the two sizes an iPhone alternate icon is asked for.
write(size: 120, to: root.appendingPathComponent("AppIcon-\(iconName)@2x.png"))
write(size: 180, to: root.appendingPathComponent("AppIcon-\(iconName)@3x.png"))
