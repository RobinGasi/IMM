#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing

@testable import IMMCompanion

/// Renders every companion screen with a preview model at iPhone size (393 × 852 pt) to PNG files in
/// `/tmp/imm-companion/`, light and dark. Skipped unless `IMM_COMPANION_RENDER` is set:
///
///     IMM_COMPANION_RENDER=1 swift test --package-path Packages/IMMKit --filter CompanionScreensRenderTests
///
/// The views are hosted in an offscreen `NSHostingView` rather than rendered with `ImageRenderer`, because
/// `ImageRenderer` cannot draw `List`, `TabView` and `NavigationStack`.
@MainActor
@Suite struct CompanionScreensRenderTests {
    private static let size = CGSize(width: 393, height: 852)
    private static let directory = URL(fileURLWithPath: "/tmp/imm-companion", isDirectory: true)

    private struct Screen {
        var name: String
        var view: AnyView
    }

    private static func screens() -> [Screen] {
        func root(_ state: CompanionPreviewState) -> AnyView {
            AnyView(CompanionRootView(model: .preview(state)))
        }
        func stack<V: View>(_ view: V) -> AnyView {
            AnyView(NavigationStack { view }.environment(CompanionModel.preview(.ready)))
        }
        return [
            Screen(name: "welcome", view: root(.welcome)),
            Screen(name: "pair-scan", view: root(.scanning)),
            Screen(name: "pair-connecting", view: root(.connecting)),
            Screen(name: "pair-confirm", view: root(.confirm)),
            Screen(name: "pair-waiting", view: root(.waitingForMac)),
            Screen(name: "pair-importing", view: root(.importing)),
            Screen(name: "pair-failed", view: root(.failed)),
            Screen(name: "locked", view: root(.locked)),
            Screen(name: "ready-tabs", view: root(.ready)),
            Screen(name: "overview", view: stack(OverviewView())),
            Screen(name: "accounts", view: stack(AccountsView())),
            Screen(name: "transactions", view: stack(TransactionsView())),
            Screen(name: "transactions-uncategorised", view: stack(TransactionsView(uncategorisedOnly: true))),
            Screen(name: "transaction-detail", view: stack(TransactionDetailView(transactionID: "tx-3"))),
            Screen(name: "settings", view: stack(CompanionSettingsView())),
        ]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMM_COMPANION_RENDER"] != nil))
    func renderScreens() async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for screen in Self.screens() {
                let png = try await Self.render(screen.view, appearance: appearance)
                #expect(png.count > 1_000, "\(screen.name) rendered an empty image")
                try png.write(to: Self.directory.appendingPathComponent("\(screen.name)-\(suffix).png"))
            }
        }
    }

    private static func render(_ view: AnyView, appearance: NSAppearance.Name) async throws -> Data {
        _ = NSApplication.shared
        let width = Int(size.width)
        let height = Int(size.height)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        // Let the views load their data and settle.
        let deadline = Date(timeIntervalSinceNow: 0.8)
        var turns = 0
        repeat {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
            turns += 1
        } while turns < 3 || Date() < deadline

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { throw RenderError.captureFailed }
        host.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError.captureFailed }
        return data
    }

    private enum RenderError: Error { case captureFailed }
}
#endif
