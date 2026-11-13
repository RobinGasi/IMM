import AppKit
import IMMDesign
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

/// Reduced motion shows the final state at once, and the spoken value of a chart names its range.
/// SwiftUI builds the accessibility tree only for a running assistive client, so labels themselves are
/// not read back here; the screens' labels are plain `.accessibilityLabel` modifiers.
///
/// `EnvironmentValues.accessibilityReduceMotion` is read-only (it mirrors the system setting), so the
/// tests drive the same code path through `immDisableMotion`: every motion helper settles when either is
/// set (`disableMotion || reduceMotion`), and a source scan guards that no animation is added without
/// consulting one of them.
@MainActor
@Suite(.serialized) struct AccessibilityTests {
    private let nbsp = "\u{00A0}"

    // MARK: Chart values

    @Test func chartSummaryNamesTheRangeAndTheExtremes() {
        let text = AccessibilitySummary.series(
            startLabel: "Dec", endLabel: "Nov", values: [3_161_725, 4_210_000, 2_900_050, 6_305_854])
        #expect(text == "From Dec 31.617,25\(nbsp)€ to Nov 63.058,54\(nbsp)€, lowest 29.000,50\(nbsp)€, highest 63.058,54\(nbsp)€.")
        #expect(AccessibilitySummary.series(startLabel: "Dec", endLabel: "Nov", values: [100]).isEmpty)
        #expect(AccessibilitySummary.series(startLabel: "", endLabel: "", values: []).isEmpty)
    }

    // MARK: Reduce Motion

    private func centre(_ rep: NSBitmapImageRep) -> NSColor {
        (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2) ?? .clear).usingColorSpace(.sRGB) ?? .clear
    }

    private func render<V: View>(_ view: V, disableMotion: Bool, settle: TimeInterval = 0.2) async throws -> NSBitmapImageRep {
        // The renderer forces `immDisableMotion` for the whole tree; a value set inside the view is nearer to
        // the content and wins.
        try await ScreenRenderer.render(
            view.environment(\.immDisableMotion, disableMotion), size: CGSize(width: 80, height: 80), settle: settle)
    }

    /// Opaque red once an entrance animation has finished (or was skipped), the white window before.
    private var entrance: some View {
        ZStack {
            Color.white
            Color.red.immRiseIn(duration: 600, delay: 600)
        }
    }

    @Test func settledMotionShowsTheFinalStateAtOnce() async throws {
        let animating = centre(try await render(entrance, disableMotion: false))
        #expect(animating.redComponent > 0.95 && animating.greenComponent > 0.9, "the entrance has not started, got \(animating)")

        let settled = centre(try await render(entrance, disableMotion: true))
        #expect(settled.redComponent > 0.95 && settled.greenComponent < 0.5, "settled motion must show the final state, got \(settled)")
    }

    @Test func drawnStrokeIsCompleteWhenMotionIsSettled() async throws {
        struct Line: Shape {
            func path(in rect: CGRect) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                return path
            }
        }
        let view = ZStack {
            Color.white
            DrawnStroke(Line(), color: .red, lineWidth: 20, duration: 600, delay: 600)
        }
        let settled = centre(try await render(view, disableMotion: true))
        #expect(settled.greenComponent < 0.5, "the whole line is drawn at once, got \(settled)")
        let running = centre(try await render(view, disableMotion: false))
        #expect(running.greenComponent > 0.9, "the line has not started to draw, got \(running)")
    }

    private func bitmapData(_ rep: NSBitmapImageRep) -> Data {
        guard let data = rep.bitmapData else { return Data() }
        return Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    @Test func syncSpinnerStandsStillWhenMotionIsSettled() async throws {
        let spinner = SpinningIcon(name: "refresh", size: 56, spinning: true)
        let still1 = bitmapData(try await render(spinner, disableMotion: true, settle: 0.1))
        let still2 = bitmapData(try await render(spinner, disableMotion: true, settle: 0.45))
        #expect(!still1.isEmpty && still1 == still2, "the sync symbol must not turn when motion is settled")

        // Otherwise the symbol turns, so two captures 0.35 s apart differ.
        let moving1 = bitmapData(try await render(spinner, disableMotion: false, settle: 0.1))
        let moving2 = bitmapData(try await render(spinner, disableMotion: false, settle: 0.45))
        #expect(moving1 != moving2, "the sync symbol turns while syncing")
    }

    /// Every file that starts an animation by itself (an entrance, a draw-on, a spinner) must consult
    /// Reduce Motion or `immDisableMotion`.
    @Test func everySelfStartingAnimationConsultsReduceMotion() throws {
        let sources = RepoPaths.root.appendingPathComponent("Packages/IMMKit/Sources", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" && !url.path.contains("/Generated/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            let startsAnimation = text.contains("TimelineView(.animation") || text.contains("withAnimation(")
            let consults = text.contains("accessibilityReduceMotion") || text.contains("immDisableMotion")
            if startsAnimation && !consults { offenders.append(url.lastPathComponent) }
        }
        #expect(scanned > 100)
        #expect(offenders.isEmpty, "animations without a Reduce Motion check: \(offenders)")
    }
}
