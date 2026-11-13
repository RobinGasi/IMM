import SwiftUI

/// The design's `Tabs` list: 32 px muted track with 3 px padding, active tab on `background`.
/// Switching content is the screen's job (it reads `selection`).
public struct SegmentedTabs<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [IMMOption<Value>]

    public init(selection: Binding<Value>, options: [IMMOption<Value>]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    option.title
                }
                .buttonStyle(TabTriggerStyle(selected: option.value == selection))
                .focusEffectDisabled()
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous).fill(IMMColor.muted))
        .fixedSize()
    }
}

private struct TabTriggerStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TabTriggerBody(configuration: configuration, selected: selected)
    }
}

private struct TabTriggerBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.immDisableMotion) private var disableMotion
    @State private var hovering = false

    private var foreground: Color {
        if configuration.isPressed { return IMMColor.accentForeground }
        return selected || hovering ? IMMColor.foreground : IMMColor.tabText
    }

    private var fill: Color {
        if configuration.isPressed { return IMMColor.accent }
        return selected ? IMMColor.tabActiveFill : Color.clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        configuration.label
            .immFont(.smallMedium)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(maxHeight: .infinity)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(selected ? IMMColor.tabActiveBorder : Color.clear, lineWidth: 1))
            .overlay {
                if isFocused { shape.stroke(IMMColor.focusRingStrong, lineWidth: 3).padding(-1.5) }
            }
            .contentShape(shape)
            .animation(disableMotion ? nil : Motion.ease(0.12), value: hovering)
            .animation(disableMotion ? nil : Motion.ease(0.12), value: configuration.isPressed)
            .animation(disableMotion ? nil : Motion.ease(0.12), value: selected)
            .onHover { hovering = $0 }
    }
}
