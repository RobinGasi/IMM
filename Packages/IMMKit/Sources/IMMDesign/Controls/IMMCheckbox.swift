import SwiftUI

/// The design's `Checkbox`: 16 px box, 4 px radius, primary fill when checked. The label (optional)
/// is part of the click target.
public struct IMMCheckbox<Label: View>: View {
    @Binding private var isOn: Bool
    private let isError: Bool
    private let label: Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.immInert) private var inert
    @Environment(\.isFocused) private var isFocused
    @Environment(\.immDisableMotion) private var disableMotion

    public init(isOn: Binding<Bool>, isError: Bool = false, @ViewBuilder label: () -> Label) {
        self._isOn = isOn
        self.isError = isError
        self.label = label()
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                box
                label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(IMMBareButtonStyle())
        .focusEffectDisabled()
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) { label }
        }
    }

    private var box: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return ZStack {
            shape.fill(isOn ? IMMColor.primary : IMMColor.inputFill)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(IMMColor.primaryForeground)
            }
        }
        .frame(width: 16, height: 16)
        .overlay(
            shape.strokeBorder(
                isError ? IMMColor.destructiveBorder : (isOn || isFocused ? (isOn ? IMMColor.primary : IMMColor.ring) : IMMColor.input),
                lineWidth: 1)
        )
        .overlay {
            if isError {
                shape.stroke(IMMColor.destructiveRing, lineWidth: 2).padding(-1)
            } else if isFocused {
                shape.stroke(IMMColor.focusRing, lineWidth: 2).padding(-1)
            }
        }
        .opacity(isEnabled || inert ? 1 : 0.5)
        .animation(disableMotion ? nil : Motion.ease(0.15), value: isOn)
    }
}

extension IMMCheckbox where Label == EmptyView {
    public init(isOn: Binding<Bool>, isError: Bool = false) {
        self.init(isOn: isOn, isError: isError) { EmptyView() }
    }
}
