import AppKit
import GRDB
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Renders the README image `.github/images/imm.png` from the real views and the demo ledger: the light Overview in
/// front of the dark Transactions list, at 2x, on the brand green. Skipped unless `IMM_README_SCREENSHOT` is set:
///
///     IMM_README_SCREENSHOT=1 swift test --package-path Packages/IMMKit --filter ReadmeScreenshotTests
@MainActor
@Suite struct ReadmeScreenshotTests {
    /// Canvas in points. Windows render at `renderScale` and are drawn onto a canvas of `outputScale` pixels per point
    /// (2400 × 1500 px: sharp on Retina, about 2 MB).
    private static let canvas = CGSize(width: 1600, height: 1000)
    private static let renderScale = 2
    private static let outputScale: CGFloat = 1.5
    private static let window = CGSize(width: 1440, height: 900)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMM_README_SCREENSHOT"] != nil))
    func renderReadmeImage() async throws {
        let fixture = try DemoVaultFixture.shared()
        let girokonto = try await fixture.store.database.read { db in
            try AccountRecord.live().filter(Column("name") == "Girokonto").fetchOne(db)?.id
        }
        let giro = try #require(girokonto)

        let back = try await Self.renderWindow(.transactions(.account(giro)), appearance: .darkAqua, fixture: fixture)
        let front = try await Self.renderWindow(.overview, appearance: .aqua, fixture: fixture)
        let image = try Self.compose(back: back, front: front)

        let directory = RepoPaths.root.appendingPathComponent(".github/images", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("imm.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenRendererError.captureFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        print("README image written to \(url.path)")
    }

    private static func renderWindow(
        _ route: MainRoute, appearance: NSAppearance.Name, fixture: DemoVaultFixture
    ) async throws -> CGImage {
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: route)
        let size = window
        let rep = try await ScreenRenderer.render(
            MainWindowView().environment(model), size: size, appearance: appearance, settle: 0.6, scale: renderScale,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        return try rep.requireCGImage()
    }

    // MARK: Composition (pixel space, origin bottom left)

    private static func compose(back: CGImage, front: CGImage) throws -> CGImage {
        let s = outputScale
        let width = Int(canvas.width * s), height = Int(canvas.height * s)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenRendererError.captureFailed }
        context.interpolationQuality = .high

        drawBackground(context, width: CGFloat(width), height: CGFloat(height))
        // Positions in points from the top left; windows are scaled down to fit both on the canvas.
        drawWindow(context, image: back, origin: CGPoint(x: 600, y: 70), zoom: 0.64, dark: true, canvasHeight: CGFloat(height))
        drawWindow(context, image: front, origin: CGPoint(x: 90, y: 300), zoom: 0.70, dark: false, canvasHeight: CGFloat(height))

        guard let image = context.makeImage() else { throw ScreenRendererError.captureFailed }
        return image
    }

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func drawBackground(_ context: CGContext, width: CGFloat, height: CGFloat) {
        // The design system's primary green (#11604A) as a diagonal gradient with a soft light from the top left.
        let colors = [color(0x16775B), color(0x11604A), color(0x0A3529)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.45, 1]) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        }
        let glow = [color(0xFFFFFF, alpha: 0.14), color(0xFFFFFF, alpha: 0)] as CFArray
        if let radial = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glow, locations: [0, 1]) {
            let center = CGPoint(x: width * 0.18, y: height * 0.92)
            context.drawRadialGradient(
                radial, startCenter: center, startRadius: 0, endCenter: center, endRadius: width * 0.6, options: [])
        }
    }

    private static func drawWindow(
        _ context: CGContext, image: CGImage, origin: CGPoint, zoom: CGFloat, dark: Bool, canvasHeight: CGFloat
    ) {
        let s = outputScale
        let w = window.width * zoom * s, h = window.height * zoom * s
        let rect = CGRect(x: origin.x * s, y: canvasHeight - origin.y * s - h, width: w, height: h)
        let radius = 16 * zoom * s
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -28 * s), blur: 70 * s, color: color(0x000000, alpha: 0.38))
        context.addPath(path)
        context.setFillColor(color(dark ? 0x121614 : 0xFFFFFF))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.setLineWidth(1 * s)
        context.setStrokeColor(dark ? color(0xFFFFFF, alpha: 0.16) : color(0x000000, alpha: 0.18))
        context.strokePath()
        context.restoreGState()

        // Window buttons at the design's centres (24, 28), (44, 28), (64, 28), radius 6; the offscreen render has none.
        for (index, fill) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            let center = CGPoint(
                x: rect.minX + CGFloat(24 + index * 20) * zoom * s, y: rect.maxY - 28 * zoom * s)
            let r = 6 * zoom * s
            let dot = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            context.setFillColor(color(fill))
            context.fillEllipse(in: dot)
            context.setStrokeColor(color(0x000000, alpha: 0.12))
            context.setLineWidth(0.5 * s)
            context.strokeEllipse(in: dot)
        }
    }
}
