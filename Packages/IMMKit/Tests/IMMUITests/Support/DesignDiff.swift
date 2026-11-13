import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

enum DesignDiffError: Error, CustomStringConvertible {
    case sizeMismatch(reference: CGSize, rendered: CGSize)
    case imageConversionFailed
    case filterFailed(String)
    case referenceMissing(slug: String, path: String)

    var description: String {
        switch self {
        case .sizeMismatch(let reference, let rendered):
            "Image sizes differ: reference \(Int(reference.width))×\(Int(reference.height)) px, rendered \(Int(rendered.width))×\(Int(rendered.height)) px."
        case .imageConversionFailed: "Could not convert an image to sRGB RGBA."
        case .filterFailed(let reason): "Core Image comparison failed: \(reason)"
        case .referenceMissing(let slug, let path): "No reference screenshot for slug \"\(slug)\" at \(path)."
        }
    }
}

/// Perceptual comparison of two screenshots: both are blurred (`CIGaussianBlur`, radius 1.5), compared per
/// pixel with `CILabDeltaE`; the result is the share of pixels whose ΔE exceeds 12.
enum DesignDiff {
    static let blurRadius: Double = 1.5
    static let deltaEThreshold: Float = 12

    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Compares `rendered` against `reference` (same pixel size required; alpha is flattened onto white).
    /// Returns the mismatch share in 0…1 and a diff image: the reference faded to grey with
    /// mismatching pixels painted red.
    static func mismatch(_ reference: CGImage, _ rendered: CGImage) throws -> (fraction: Double, diff: CGImage) {
        guard reference.width == rendered.width, reference.height == rendered.height else {
            throw DesignDiffError.sizeMismatch(
                reference: CGSize(width: reference.width, height: reference.height),
                rendered: CGSize(width: rendered.width, height: rendered.height))
        }
        let width = reference.width
        let height = reference.height
        let referencePixels = try flattenedPixels(reference, width: width, height: height)
        let renderedPixels = try flattenedPixels(rendered, width: width, height: height)
        let deltas = try deltaEMap(referencePixels, renderedPixels, width: width, height: height)
        let scale = deltaEScale
        let limit = deltaEThreshold

        var out = [UInt8](repeating: 255, count: width * height * 4)
        var mismatching = 0
        for pixel in 0..<(width * height) {
            let o = pixel * 4
            if deltas[pixel] * scale > limit {
                mismatching += 1
                out[o] = 255; out[o + 1] = 0; out[o + 2] = 0
            } else {
                let r = Float(referencePixels[o]), g = Float(referencePixels[o + 1]), b = Float(referencePixels[o + 2])
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let faded = UInt8(max(0, min(255, luma * 0.35 + 255 * 0.65)))
                out[o] = faded; out[o + 1] = faded; out[o + 2] = faded
            }
        }
        let diff = try makeImage(out, width: width, height: height)
        return (Double(mismatching) / Double(width * height), diff)
    }

    // MARK: Pixels

    /// sRGB RGBA8 pixels (row 0 on top), flattened onto white, scaled to `width × height` if needed.
    private static func flattenedPixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data
        else { throw DesignDiffError.imageConversionFailed }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw DesignDiffError.imageConversionFailed }
        return image
    }

    // MARK: Core Image

    private static func ciImage(_ pixels: [UInt8], width: Int, height: Int) -> CIImage {
        CIImage(
            bitmapData: Data(pixels), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
            format: .RGBA8, colorSpace: srgb)
    }

    private static func blurred(_ image: CIImage) -> CIImage {
        image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: image.extent)
    }

    /// Raw `CILabDeltaE` output (red channel) per pixel, row 0 on top.
    private static func deltaEMap(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) throws -> [Float] {
        let filter = CIFilter.labDeltaE()
        filter.inputImage = blurred(ciImage(a, width: width, height: height))
        filter.image2 = blurred(ciImage(b, width: width, height: height))
        guard let output = filter.outputImage else { throw DesignDiffError.filterFailed("no output image") }
        var buffer = [Float](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { bytes in
            context.render(
                output, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
        }
        return (0..<(width * height)).map { buffer[$0 * 4] }
    }

    /// Factor that turns the filter's red-channel value into ΔE (0…100). Calibrated once with black vs white,
    /// whose ΔE is 100, so the threshold of 12 holds whether the filter reports 0…100 or 0…1.
    private static let deltaEScale: Float = {
        let side = 8
        var black = [UInt8](repeating: 0, count: side * side * 4)
        for pixel in 0..<(side * side) { black[pixel * 4 + 3] = 255 }
        let white = [UInt8](repeating: 255, count: side * side * 4)
        guard let map = try? deltaEMap(black, white, width: side, height: side), let value = map.first, value > 0
        else { return 1 }
        return abs(value - 100) < 10 ? 1 : 100 / value
    }()

    // MARK: Output

    private static let reportLock = NSLock()

    /// Writes `build/design-diff/<slug>.png` (diff), `<slug>-app.png` (rendered) and merges `{slug: fraction}`
    /// into `build/design-diff/report.json`. Serialised process-wide; safe for parallel tests.
    static func record(slug: String, fraction: Double, diff: CGImage, rendered: CGImage) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: RepoPaths.diffOutput, withIntermediateDirectories: true)
        try writePNG(diff, to: RepoPaths.diffOutput.appendingPathComponent("\(slug).png"))
        try writePNG(rendered, to: RepoPaths.diffOutput.appendingPathComponent("\(slug)-app.png"))
        try reportLock.withLock {
            var report: [String: Double] = [:]
            if let data = try? Data(contentsOf: RepoPaths.diffReport),
                let existing = try? JSONDecoder().decode([String: Double].self, from: data)
            {
                report = existing
            }
            report[slug] = fraction
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: RepoPaths.diffReport, options: .atomic)
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw DesignDiffError.imageConversionFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DesignDiffError.imageConversionFailed }
    }
}
