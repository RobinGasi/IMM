import AppKit
import IMMDesign
import SwiftUI

enum ScreenRendererError: Error, CustomStringConvertible {
    case invalidSize(CGSize)
    case captureFailed

    var description: String {
        switch self {
        case .invalidSize(let size): "Cannot render a view at size \(size)."
        case .captureFailed: "Could not capture the hosting view into a bitmap."
        }
    }
}

extension NSBitmapImageRep {
    /// The bitmap as a `CGImage`; throws instead of returning nil.
    func requireCGImage() throws -> CGImage {
        guard let image = cgImage else { throw ScreenRendererError.captureFailed }
        return image
    }
}

/// Renders a SwiftUI view offscreen at 1x, the way the design reference screenshots are made.
@MainActor
enum ScreenRenderer {
    /// Hosts `view` in an `NSHostingView` inside an offscreen borderless window of `size` points,
    /// forces `appearance`, disables motion and returns a bitmap of `size` × `scale` pixels (sRGB). Design comparisons use
    /// the default scale 1, matching the 1x references; the README screenshot renders at 2.
    ///
    /// - Parameters:
    ///   - environment: applied after the harness' own environment, so it can override it
    ///     (for example `{ AnyView($0.environment(appModel)) }`).
    ///   - settle: minimum time the run loop is spun before capture, for views that load data asynchronously.
    static func render<V: View>(
        _ view: V,
        size: CGSize,
        appearance: NSAppearance.Name = .aqua,
        settle: TimeInterval = 0.15,
        scale: Int = 1,
        environment: (AnyView) -> AnyView = { $0 }
    ) async throws -> NSBitmapImageRep {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { throw ScreenRendererError.invalidSize(size) }

        pinRenderingDefaults()
        _ = NSApplication.shared
        IMMFonts.registerIfNeeded()

        let content = view
            .environment(\.immDisableMotion, true)
            .frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
        let host = NSHostingView(rootView: environment(AnyView(content)))
        host.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        // Draw in sRGB whatever the display's profile is, so captures match on every Mac (and CI's virtual display).
        window.colorSpace = .sRGB
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        await settleLayout(host, for: settle)

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let rep = try makeRep(width: width, height: height, scale: scale)
        host.cacheDisplay(in: bounds, to: rep)
        if isTransparent(rep) {
            // Fallback: let AppKit choose the rep (backing scale of the window) and resample to 1x.
            guard let native = host.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw ScreenRendererError.captureFailed
            }
            host.cacheDisplay(in: bounds, to: native)
            let resampled = try resample(try native.requireCGImage(), width: width * scale, height: height * scale)
            return NSBitmapImageRep(cgImage: resampled)
        }
        return rep
    }

    private static func settleLayout(_ host: NSHostingView<AnyView>, for duration: TimeInterval) async {
        let deadline = Date(timeIntervalSinceNow: duration)
        var turns = 0
        repeat {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
            turns += 1
        } while turns < 3 || Date() < deadline
        host.layoutSubtreeIfNeeded()
    }

    /// A zeroed sRGB RGBA bitmap of `scale` pixels per point, so `cacheDisplay` draws at that scale.
    private static func makeRep(width: Int, height: Int, scale: Int) throws -> NSBitmapImageRep {
        guard
            let base = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { throw ScreenRendererError.captureFailed }
        let rep = base.retagging(with: .sRGB) ?? base
        rep.size = NSSize(width: width, height: height)
        if let data = rep.bitmapData { memset(data, 0, rep.bytesPerRow * rep.pixelsHigh) }
        return rep
    }

    private static func isTransparent(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData else { return true }
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide where row[x * 4 + 3] != 0 { return false }
        }
        return true
    }

    /// Draws `image` into an sRGB premultiplied-alpha bitmap of the given pixel size.
    static func resample(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenRendererError.captureFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ScreenRendererError.captureFailed }
        return result
    }
}

extension ScreenRenderer {
    /// Rendering preferences the references assume, set for this test process only (argument domain, nothing is
    /// written to disk):
    /// - overlay scroll bars: a Mac without a trackpad (a CI runner) shows legacy scroll bars, which take width from
    ///   every scroll view and shift the columns;
    /// - no font smoothing: macOS draws text without it on Retina screens, where the references were made, but a
    ///   headless runner falls back to a 1x screen and thickens light text on dark backgrounds.
    private static func pinRenderingDefaults() {
        let pinned: [String: Any] = ["AppleShowScrollBars": "WhenScrolling", "AppleFontSmoothing": 0]
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        guard pinned.contains(where: { arguments[$0.key] == nil }) else { return }
        arguments.merge(pinned) { _, new in new }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
