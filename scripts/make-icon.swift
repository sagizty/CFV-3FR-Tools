// SPDX-License-Identifier: MIT
// Adapt the supplied artwork to standard macOS icon sizes.
import Foundation
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: make-icon logo.png output.iconset")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot decode logo PNG")
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes = [
    ("icon_16x16.png",16), ("icon_16x16@2x.png",32),
    ("icon_32x32.png",32), ("icon_32x32@2x.png",64),
    ("icon_128x128.png",128), ("icon_128x128@2x.png",256),
    ("icon_256x256.png",256), ("icon_256x256@2x.png",512),
    ("icon_512x512.png",512), ("icon_512x512@2x.png",1024)
]
for (filename, size) in sizes {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 48, y: 48, width: 928, height: 928),
        cornerWidth: 208, cornerHeight: 208, transform: nil))
    context.fillPath()
    // Keep the supplied canvas, transparency and proportions.
    let scale = min(896 / CGFloat(artwork.width), 896 / CGFloat(artwork.height))
    let width = CGFloat(artwork.width) * scale
    let height = CGFloat(artwork.height) * scale
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: (1024 - width) / 2, y: (1024 - height) / 2,
                                   width: width, height: height))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              output.appendingPathComponent(filename) as CFURL,
              "public.png" as CFString, 1, nil) else {
        fatalError("Cannot create icon PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "PNG export failed")
}
