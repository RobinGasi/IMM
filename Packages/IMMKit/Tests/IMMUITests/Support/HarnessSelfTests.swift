import AppKit
import IMMDesign
import IMMLedger
import SwiftUI
import Testing

@MainActor
@Suite struct HarnessSelfTests {
    /// Vertical 6 px stripes plus a block, so edges exist everywhere; `shift` moves the content right.
    private func pattern(width: Int = 240, height: Int = 120, shift: Int = 0, background: CGFloat = 1) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: background, green: background, blue: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        var x = -12
        while x < width {
            context.fill(CGRect(x: x + shift, y: 0, width: 6, height: height))
            x += 12
        }
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 40 + shift, y: 30, width: 50, height: 30))
        return try #require(context.makeImage())
    }

    @Test func identicalImagesMismatchNothing() throws {
        let image = try pattern()
        let result = try DesignDiff.mismatch(image, image)
        #expect(result.fraction == 0)
        #expect(result.diff.width == image.width && result.diff.height == image.height)
    }

    @Test func shiftedImageExceedsThreshold() throws {
        let result = try DesignDiff.mismatch(try pattern(), try pattern(shift: 8))
        #expect(result.fraction > DesignThresholds.initialLimit)
    }

    @Test func blackAgainstWhiteIsFullMismatch() throws {
        let result = try DesignDiff.mismatch(try pattern(background: 0), try pattern(background: 1))
        #expect(result.fraction > 0.4)
    }

    @Test func differentSizesAreRejected() throws {
        #expect(throws: DesignDiffError.self) {
            try DesignDiff.mismatch(try pattern(width: 100), try pattern(width: 120))
        }
    }

    @Test func renderProducesRequestedPixelSize() async throws {
        let rep = try await ScreenRenderer.render(
            Color(red: 0.9, green: 0.1, blue: 0.1), size: CGSize(width: 200, height: 100))
        #expect(rep.pixelsWide == 200)
        #expect(rep.pixelsHigh == 100)
        let image = try rep.requireCGImage()
        #expect(image.width == 200 && image.height == 100)
        let centre = try #require(rep.colorAt(x: 100, y: 50)?.usingColorSpace(.sRGB))
        #expect(centre.redComponent > 0.8 && centre.greenComponent < 0.3 && centre.alphaComponent > 0.99)
    }

    @Test func renderFollowsRequestedAppearance() async throws {
        let size = CGSize(width: 60, height: 40)
        let light = try await ScreenRenderer.render(IMMColor.background, size: size, appearance: .aqua)
        let dark = try await ScreenRenderer.render(IMMColor.background, size: size, appearance: .darkAqua)
        let lightPixel = try #require(light.colorAt(x: 30, y: 20)?.usingColorSpace(.sRGB))
        let darkPixel = try #require(dark.colorAt(x: 30, y: 20)?.usingColorSpace(.sRGB))
        #expect(lightPixel.brightnessComponent > 0.95)
        #expect(darkPixel.brightnessComponent < 0.2)
    }

    @Test func renderedImageMatchesItselfWhenRerendered() async throws {
        let view = Text(verbatim: "Ich mag Moneten").font(.system(size: 20)).padding(12)
        let size = CGSize(width: 220, height: 60)
        let first = try await ScreenRenderer.render(view, size: size).requireCGImage()
        let second = try await ScreenRenderer.render(view, size: size).requireCGImage()
        #expect(try DesignDiff.mismatch(first, second).fraction == 0)
    }
}

@Suite struct DemoVaultFixtureTests {
    @Test func sharedStoreHoldsDemoLedger() throws {
        let fixture = try DemoVaultFixture.shared()
        let netWorth = try fixture.store.database.read { try LedgerDefinitions.netWorth($0) }
        #expect(netWorth == 6_305_854)
        #expect(try DemoVaultFixture.shared() === fixture)
    }
}
