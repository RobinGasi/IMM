import AppKit
import SwiftUI
import Testing

@testable import IMMDesign

@MainActor
@Suite struct InertLookTests {
    private func png<V: View>(_ view: V) throws -> Data {
        let host = NSHostingView(rootView: view.padding(8).background(IMMColor.background).environment(\.immDisableMotion, true))
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// `.inertControl()` must not change how a control looks; `.disabled(true)` does (half opacity).
    @Test func inertSwitchAndCheckboxKeepTheEnabledLook() throws {
        func sheet(_ modify: (AnyView) -> AnyView) -> some View {
            HStack(spacing: 12) {
                modify(AnyView(IMMSwitch(isOn: .constant(true))))
                modify(AnyView(IMMCheckbox(isOn: .constant(true)) { Text(verbatim: "Label") }))
                modify(AnyView(Button {} label: { Text(verbatim: "Button") }.immButtonStyle(.outline)))
            }
        }
        let normal = try png(sheet { $0 })
        let inert = try png(sheet { AnyView($0.inertControl()) })
        let disabled = try png(sheet { AnyView($0.disabled(true)) })
        #expect(normal == inert)
        #expect(normal != disabled)
    }
}
