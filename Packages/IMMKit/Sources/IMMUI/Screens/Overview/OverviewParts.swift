import IMMDesign
import IMMLedger
import SwiftUI

/// Row hover for rows that are not links: `muted` background, bleeding 8 pt past both sides, 120 ms ease.
struct OverviewHoverSurface: ViewModifier {
    var bleed: CGFloat = 8

    @Environment(\.immDisableMotion) private var disableMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                Rectangle().fill(hovering ? IMMColor.muted : Color.clear).padding(.horizontal, -bleed)
            }
            .contentShape(Rectangle())
            .animation(disableMotion ? nil : Motion.ease(0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func overviewHoverSurface(bleed: CGFloat = 8) -> some View {
        modifier(OverviewHoverSurface(bleed: bleed))
    }

    /// `border-b`: a 1 px rule inside the bottom edge of the view's own frame.
    func overviewRowRule(_ visible: Bool = true) -> some View {
        overlay(alignment: .bottom) {
            if visible { Rule() }
        }
    }
}

/// A right-aligned tabular amount in a fixed-width column (13/20).
struct OverviewAmount: View {
    let text: String
    var width: CGFloat = 100
    var color: Color = IMMColor.foreground

    var body: some View {
        Text(verbatim: text)
            .immFont(IMMFont.body.tabular)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

/// `Synced today, 08:42` (real clock) or `Not synced yet`.
func overviewSyncedText(_ date: Date?) -> String {
    guard let date else { return String(localized: "Not synced yet", bundle: .module) }
    return String(localized: "Synced \(ShellText.relative(date))", bundle: .module)
}
