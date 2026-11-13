import Foundation
import ImageIO
import SwiftUI
import Testing

/// Reference screenshots exported from Ocelot (`DesignReference/screens/<slug>@1x.png`, slugs in `index.tsv`).
enum DesignReference {
    static func url(slug: String) -> URL {
        RepoPaths.referenceScreens.appendingPathComponent("\(slug)@1x.png")
    }

    static func image(slug: String) throws -> CGImage {
        let url = url(slug: slug)
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw DesignDiffError.referenceMissing(slug: slug, path: url.path) }
        return image
    }
}

/// Allowed mismatch share. 6 % until `DesignReference/thresholds.json` exists; then 1.5 × the larger of the
/// measured Overview and Transactions values.
enum DesignThresholds {
    static let initialLimit = 0.06
    static let factor = 1.5

    static var limit: Double {
        guard
            let data = try? Data(contentsOf: RepoPaths.thresholds),
            let values = try? JSONDecoder().decode([String: Double].self, from: data),
            let measured = [values["overview"], values["transactions"]].compactMap({ $0 }).max()
        else { return initialLimit }
        return measured * factor
    }
}

/// Renders `view`, compares it with the reference screenshot `slug`, records the result under
/// `build/design-diff/` and expects the mismatch to be within `DesignThresholds.limit`.
/// `size` defaults to the reference's pixel size. Returns the mismatch share.
@MainActor
@discardableResult
func assertMatchesDesign<V: View>(
    _ view: V,
    slug: String,
    size: CGSize? = nil,
    appearance: NSAppearance.Name = .aqua,
    settle: TimeInterval = 0.15,
    environment: (AnyView) -> AnyView = { $0 },
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Double {
    let reference = try DesignReference.image(slug: slug)
    let renderSize = size ?? CGSize(width: reference.width, height: reference.height)
    let rep = try await ScreenRenderer.render(
        view, size: renderSize, appearance: appearance, settle: settle, environment: environment)
    let rendered = try rep.requireCGImage()
    let result = try DesignDiff.mismatch(reference, rendered)
    try DesignDiff.record(slug: slug, fraction: result.fraction, diff: result.diff, rendered: rendered)
    let limit = DesignThresholds.limit
    #expect(
        result.fraction <= limit,
        "\(slug) mismatch \(result.fraction) exceeds \(limit)",
        sourceLocation: sourceLocation)
    return result.fraction
}
