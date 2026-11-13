import AppKit
import SwiftUI
import Testing

@testable import IMMDesign

private struct SmokeSheet: View {
    @State var choice = "90"
    @State var tab = "month"
    @State var toggle = "all"
    @State var text = ""
    @State var on = true
    @State var off = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button {} label: {
                    HStack(spacing: 4) {
                        IMMIcon("arrow-up-right", size: 14)
                        Text(verbatim: "New transfer")
                    }
                }
                .immButtonStyle(.default)
                Button {} label: { Text(verbatim: "Outline") }.immButtonStyle(.outline)
                Button {} label: { Text(verbatim: "Ghost") }.immButtonStyle(.ghost, size: .sm)
                Button {} label: { IMMIcon("refresh", size: 14) }.immButtonStyle(.ghost, size: .icon)
                Button {} label: { Text(verbatim: "Inert") }.immButtonStyle(.outline).inertControl()
            }
            HStack(spacing: 8) {
                SelectTrigger(
                    selection: $choice,
                    options: [
                        IMMOption("30", verbatim: "Last 30 days"), IMMOption("90", verbatim: "Last 90 days"),
                    ], width: 140)
                SelectTrigger(
                    selection: $choice,
                    options: [
                        IMMOption("30", verbatim: "Last 30 days"), IMMOption("90", verbatim: "Last 90 days"),
                    ])
                ToggleGroup(
                    selection: $toggle,
                    options: [IMMOption("all", verbatim: "All"), IMMOption("income", verbatim: "Income")])
            }
            HStack(spacing: 8) {
                SegmentedTabs(
                    selection: $tab,
                    options: [IMMOption("month", verbatim: "Month"), IMMOption("year", verbatim: "Year")])
                Badge(verbatim: "Sure")
                Badge(verbatim: "Likely", variant: .outline)
                Badge(verbatim: "Check this", variant: .warning)
                Kbd("⌘K")
                IMMSwitch(isOn: $on)
                IMMSwitch(isOn: $off)
                IMMCheckbox(isOn: $on)
                IMMLogoMark(width: 40)
            }
            HStack(spacing: 8) {
                IMMTextField(text: $text, prompt: Text(verbatim: "Placeholder")).frame(width: 160)
                IMMTextField(text: $text, prompt: Text(verbatim: "Error"), isError: true).frame(width: 160)
            }
            ProgressBar(value: 0.5).frame(width: 200)
        }
        .padding(16)
        .frame(width: 560, alignment: .leading)
        .background(IMMColor.background)
        .environment(\.immDisableMotion, true)
    }
}

@MainActor
@Suite struct RenderSmokeTests {
    @Test func controlsRenderWithoutBlankOutput() throws {
        let host = NSHostingView(rootView: SmokeSheet())
        let size = host.fittingSize
        #expect(size.width > 100 && size.height > 100)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imm-design-smoke.png")
        try png.write(to: url)
        // Not all pixels may be the plain background colour.
        var distinct = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    distinct.insert(
                        UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
        }
        #expect(distinct.count > 8)
    }
}
