import SwiftUI

/// A list or table row: `muted` on hover, `accent` with `accent-foreground` text while pressed,
/// 120 ms ease, background bleeding `bleed` points past the row on both sides, focus outline inside.
///
/// Rows that are not links keep the default empty action.
public struct DataRow<Content: View>: View {
    private let height: CGFloat?
    private let bleed: CGFloat
    private let action: () -> Void
    private let content: Content

    public init(
        height: CGFloat? = nil, bleed: CGFloat = 8, action: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.height = height
        self.bleed = bleed
        self.action = action
        self.content = content()
    }

    public var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height)
        }
        .buttonStyle(DataRowStyle(bleed: bleed))
        .focusEffectDisabled()
    }
}

private struct DataRowStyle: ButtonStyle {
    let bleed: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        DataRowBody(configuration: configuration, bleed: bleed)
    }
}

private struct DataRowBody: View {
    let configuration: ButtonStyleConfiguration
    let bleed: CGFloat

    @Environment(\.isFocused) private var isFocused
    @Environment(\.immDisableMotion) private var disableMotion
    @State private var hovering = false

    private var fill: Color {
        if configuration.isPressed { return IMMColor.accent }
        return hovering ? IMMColor.muted : Color.clear
    }

    var body: some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? IMMColor.accentForeground : IMMColor.foreground)
            .background {
                Rectangle().fill(fill).padding(.horizontal, -bleed)
            }
            .overlay {
                if isFocused {
                    Rectangle().strokeBorder(IMMColor.ring, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .animation(disableMotion ? nil : Motion.ease(0.12), value: hovering)
            .animation(disableMotion ? nil : Motion.ease(0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
