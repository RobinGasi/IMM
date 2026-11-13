import SwiftUI

/// Item size of a `ToggleGroup`: default 28 px, small 24 px with 10 px text.
public enum ToggleGroupSize: Sendable, Equatable {
    case `default`, sm

    var height: CGFloat { self == .sm ? 24 : 28 }
    var font: IMMFont { self == .sm ? IMMFont.control.sized(10, lineHeight: 16) : IMMFont.control }
}

/// The design's outline `ToggleGroup` with single selection ("All / Income / Spending",
/// "Now / On date"). Items are outlined boxes 8 px apart; the selected item is filled with `muted`.
public struct ToggleGroup<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [IMMOption<Value>]
    private let size: ToggleGroupSize

    public init(selection: Binding<Value>, options: [IMMOption<Value>], size: ToggleGroupSize = .default) {
        self._selection = selection
        self.options = options
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    option.title
                }
                .buttonStyle(ToggleItemStyle(on: option.value == selection, size: size))
                .focusEffectDisabled()
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

private struct ToggleItemStyle: ButtonStyle {
    let on: Bool
    let size: ToggleGroupSize

    func makeBody(configuration: Configuration) -> some View {
        ToggleItemBody(configuration: configuration, on: on, size: size)
    }
}

private struct ToggleItemBody: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    let size: ToggleGroupSize

    @Environment(\.isFocused) private var isFocused
    @Environment(\.immDisableMotion) private var disableMotion
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        configuration.label
            .immFont(size.font)
            .foregroundStyle(IMMColor.foreground)
            .padding(.horizontal, 9)
            .frame(minWidth: size.height, minHeight: size.height, maxHeight: size.height)
            .background(shape.fill(on || hovering ? IMMColor.muted : Color.clear))
            .overlay(shape.strokeBorder(isFocused ? IMMColor.ring : IMMColor.input, lineWidth: 1))
            .overlay {
                if isFocused { shape.stroke(IMMColor.focusRingStrong, lineWidth: 3).padding(-1.5) }
            }
            .contentShape(shape)
            .animation(disableMotion ? nil : Motion.ease(0.15), value: hovering)
            .animation(disableMotion ? nil : Motion.ease(0.15), value: on)
            .onHover { hovering = $0 }
    }
}
