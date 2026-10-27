import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Start images for image-to-image. Each chosen image is copied (as PNG) into
/// ~/Library/Application Support/CoreMLImageGen/StartImages, so queued jobs and saved
/// records keep working even if the original is moved or deleted.
enum StartImages {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "CoreMLImageGen/StartImages", directoryHint: .isDirectory)
    }()

    /// Copies any image file ImageIO can read (PNG, JPEG, HEIC, WebP…) into the folder
    /// and returns the copy's path.
    static func importImage(_ url: URL) throws -> String {
        guard let image = load(url.path) else {
            throw RuntimeError("\(url.lastPathComponent) isn't an image this Mac can read.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: "\(UUID().uuidString).png")
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
        return dest.path
    }

    static func load(_ path: String) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// The preset aspect closest to the image's shape, so the start image isn't squashed.
    static func closestAspect(to path: String) -> AspectChoice? {
        guard let image = load(path) else { return nil }
        let ratio = Double(image.width) / Double(image.height)
        let ratios: [(AspectChoice, Double)] = [(.square, 1), (.portrait, 3.0 / 4), (.landscape, 4.0 / 3),
                                                (.wide, 16.0 / 9), (.tall, 9.0 / 16)]
        return ratios.min { abs(log($0.1 / ratio)) < abs(log($1.1 / ratio)) }?.0
    }

    /// Scales and centre-crops `image` to exactly `width`×`height` (Core ML models take
    /// a fixed-size start image).
    static func fill(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        return context.makeImage()
    }
}
