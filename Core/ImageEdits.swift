import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Colour and tone changes. Zero everywhere changes nothing.
struct Adjustments: Codable, Hashable {
    /// Stops of exposure, −2…2.
    var exposure = 0.0
    /// −1…1, from flat grey to double contrast.
    var contrast = 0.0
    /// −1…1, from black and white to double saturation.
    var saturation = 0.0
    /// −1…1, cooler to warmer.
    var warmth = 0.0

    var isIdentity: Bool { self == Adjustments() }

    var summary: String {
        var parts: [String] = []
        func add(_ name: String, _ value: Double) {
            if value != 0 { parts.append("\(name) \(value > 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(0...2))))") }
        }
        add("exposure", exposure)
        add("contrast", contrast)
        add("saturation", saturation)
        add("warmth", warmth)
        return parts.joined(separator: ", ")
    }
}

/// Rotation, flips and a crop rectangle. The rectangle is in 0–1 units of the picture after
/// rotating and flipping, measured from the top left.
struct CropSettings: Codable, Hashable {
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Clockwise quarter turns, 0–3.
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false

    var isIdentity: Bool { self == CropSettings() }

    var summary: String {
        var parts: [String] = []
        if quarterTurns % 4 != 0 { parts.append("rotated \(quarterTurns % 4 * 90)°") }
        if flipHorizontal { parts.append("flipped") }
        if flipVertical { parts.append("flipped vertically") }
        if rect != CGRect(x: 0, y: 0, width: 1, height: 1) { parts.append("cropped") }
        return parts.joined(separator: ", ")
    }
}

/// One brush stroke on a Paint to Redraw mask, in the picture's pixels (top-left origin).
struct BrushStroke: Codable, Hashable {
    var points: [CGPoint]
    var radius: Double
    /// An eraser stroke takes area back out of the mask.
    var erases = false
}

/// The image operations behind the Edit section. Everything runs off the main thread.
enum ImageEdits {
    /// Colour-managed, for the adjustments.
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// No colour management, so compositing gives back the original's exact values where the
    /// mask is zero.
    private static let rawContext = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func render(_ image: CIImage, size: CGSize? = nil, raw: Bool = false) throws -> CGImage {
        let extent = CGRect(origin: image.extent.origin, size: size ?? image.extent.size).integral
        guard let result = (raw ? rawContext : context).createCGImage(image, from: extent, format: .RGBA8, colorSpace: sRGB)
        else { throw RuntimeError("Couldn't draw the edited picture.") }
        return result
    }

    // MARK: Adjust

    static func adjusted(_ image: CIImage, _ a: Adjustments) -> CIImage {
        var result = image
        if a.exposure != 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        }
        if a.contrast != 0 || a.saturation != 0 {
            // In sRGB values, not Core Image's linear light, so contrast pivots on a perceptual
            // mid-grey (in linear light +20% contrast took sRGB 128 down to 110).
            result = result
                .applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1 + a.contrast * (a.contrast > 0 ? 1 : 0.75),
                    kCIInputSaturationKey: 1 + a.saturation,
                    kCIInputBrightnessKey: 0,
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        if a.warmth != 0 {
            // Treating the picture as lit at a higher colour temperature than 6500 K warms it
            // (9000 K turns mid-grey to 135/127/113); a lower one cools it, and much faster.
            result = result.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + a.warmth * (a.warmth > 0 ? 4000 : 1500), y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        return result.cropped(to: image.extent)
    }

    static func adjust(_ image: CGImage, _ a: Adjustments) throws -> CGImage {
        try render(adjusted(CIImage(cgImage: image), a))
    }

    // MARK: Crop and rotate

    /// The picture rotated and flipped (no crop), with its extent at the origin.
    static func oriented(_ image: CIImage, _ c: CropSettings) -> CIImage {
        // Core Image's orientations: .right is a quarter turn clockwise.
        let turns: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var result = image.oriented(turns[((c.quarterTurns % 4) + 4) % 4])
        if c.flipHorizontal { result = result.oriented(.upMirrored) }
        if c.flipVertical { result = result.oriented(.downMirrored) }
        return result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
    }

    static func transform(_ image: CGImage, _ c: CropSettings) throws -> CGImage {
        let oriented = oriented(CIImage(cgImage: image), c)
        let (w, h) = (oriented.extent.width, oriented.extent.height)
        // `rect` counts from the top; Core Image from the bottom.
        let r = c.rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let crop = CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h).integral
        guard crop.width >= 8, crop.height >= 8 else { throw RuntimeError("The crop is too small.") }
        let cropped = oriented.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        return try render(cropped, raw: true)
    }

    // MARK: Remove background

    /// The main subject on a transparent background, with macOS's built-in Vision model.
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw RuntimeError("No subject was found to keep.")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: false)
        return try render(CIImage(cvPixelBuffer: buffer), raw: true)
    }

    // MARK: Paint to redraw

    /// The mask the strokes paint: white where the picture is to be redrawn.
    static func mask(for strokes: [BrushStroke], width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Strokes are in top-left pixels; the context's origin is the bottom left.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes where !stroke.points.isEmpty {
            let gray: CGFloat = stroke.erases ? 0 : 1
            ctx.setStrokeColor(gray: gray, alpha: 1)
            ctx.setFillColor(gray: gray, alpha: 1)
            ctx.setLineWidth(stroke.radius * 2)
            if stroke.points.count == 1, let p = stroke.points.first {
                ctx.fillEllipse(in: CGRect(x: p.x - stroke.radius, y: p.y - stroke.radius,
                                           width: stroke.radius * 2, height: stroke.radius * 2))
            } else {
                ctx.addLines(between: stroke.points)
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    /// The painted area's bounding box in top-left pixels, or nil for an empty mask.
    static func bounds(of mask: CGImage) -> CGRect? {
        guard let data = mask.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let (w, h, row) = (mask.width, mask.height, mask.bytesPerRow)
        var (minX, minY, maxX, maxY) = (w, h, -1, -1)
        for y in 0..<h {
            let line = bytes + y * row
            for x in 0..<w where line[x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The part of the picture sent to the model: the painted area plus some surroundings for
    /// context, square for models with a fixed square size. Top-left pixels.
    static func redrawRegion(around box: CGRect, in size: CGSize, square: Bool) -> CGRect {
        let margin = max(48, 0.3 * max(box.width, box.height))
        var region = box.insetBy(dx: -margin, dy: -margin)
        // Small areas are redrawn from at least 256 px of picture, so the model sees enough.
        let minimum = min(256, min(size.width, size.height))
        if region.width < minimum { region = region.insetBy(dx: -(minimum - region.width) / 2, dy: 0) }
        if region.height < minimum { region = region.insetBy(dx: 0, dy: -(minimum - region.height) / 2) }
        if square {
            let side = min(max(region.width, region.height), min(size.width, size.height))
            region = CGRect(x: region.midX - side / 2, y: region.midY - side / 2, width: side, height: side)
        }
        // Slide (not shrink) back inside the picture where possible.
        region.origin.x = min(max(region.minX, 0), max(size.width - region.width, 0))
        region.origin.y = min(max(region.minY, 0), max(size.height - region.height, 0))
        return region.intersection(CGRect(origin: .zero, size: size)).integral
    }

    /// `base` with `patch` (the redrawn `region`, any size) blended in through the mask. The
    /// soft edge is grown inward from the brush's edge, so outside the painted area every pixel
    /// stays exactly as it was.
    static func composite(base: CGImage, patch: CGImage, region: CGRect, mask: CGImage, feather: Double) throws -> CGImage {
        let size = CGSize(width: base.width, height: base.height)
        let baseImage = CIImage(cgImage: base)
        // The patch scaled into the region; Core Image's y runs from the bottom.
        let patchImage = CIImage(cgImage: patch)
        let sx = region.width / patchImage.extent.width, sy = region.height / patchImage.extent.height
        let placed = patchImage
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
            .transformed(by: CGAffineTransform(translationX: region.minX, y: size.height - region.maxY))
        let hard = CIImage(cgImage: mask)
        let soft = hard
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: feather])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
            .cropped(to: hard.extent)
        // Clamp to the brush: zero outside it, whatever the blur spread.
        let alpha = soft.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: hard])
        let blended = placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: baseImage,
            kCIInputMaskImageKey: alpha,
        ])
        return try render(blended.cropped(to: baseImage.extent), raw: true)
    }

    /// `image` drawn over white, for models that don't take transparency.
    static func flattened(_ image: CGImage) throws -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return image }
        let input = CIImage(cgImage: image)
        return try render(input.composited(over: CIImage(color: .white).cropped(to: input.extent)), raw: true)
    }

    /// `image` scaled down so its long side is at most `maxSide` (unchanged if already smaller).
    static func limited(_ image: CGImage, maxSide: Int) throws -> CGImage {
        let side = max(image.width, image.height)
        guard side > maxSide else { return image }
        let scale = Double(maxSide) / Double(side)
        let scaled = CIImage(cgImage: image).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
        return try render(scaled, size: CGSize(width: (Double(image.width) * scale).rounded(),
                                               height: (Double(image.height) * scale).rounded()), raw: true)
    }

    /// `image` scaled to exactly `size`.
    static func resized(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let sx = size.width / input.extent.width, sy = size.height / input.extent.height
        let scaled = input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        return try render(scaled, size: size, raw: true)
    }

    /// The top-left-pixel `rect` of `image`.
    static func cropped(_ image: CGImage, to rect: CGRect) -> CGImage? {
        image.cropping(to: rect.integral)
    }
}
