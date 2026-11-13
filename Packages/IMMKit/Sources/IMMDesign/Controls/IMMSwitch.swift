import SwiftUI

/// The design's `Switch`: 28 × 16.6 (small 24 × 14), primary when on.
public struct IMMSwitch: View {
    public enum Size: Sendable, Equatable {
        case `default`, sm

        var width: CGFloat { self == .sm ? 24 : 28 }
        var height: CGFloat { self == .sm ? 14 : 16.6 }
        var thumb: CGFloat { self == .sm ? 12 : 14 }
    }

    @Binding private var isOn: Bool
    private let size: Size
    private let isError: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.immInert) private var inert
    @Environment(\.isFocused) private var isFocused
    @Environment(\.immDisableMotion) private var disableMotion

    public init(isOn: Binding<Bool>, size: Size = .default, isError: Bool = false) {
        self._isOn = isOn
        self.size = size
        self.isError = isError
    }

    private var thumbColor: Color {
        // Light: background. Dark: primary-foreground when on, foreground when off.
        IMMColor.makeDynamic(
            light: IMMColor.resolved("background", dark: false) ?? IMMRGBA(r: 1, g: 1, b: 1, a: 1),
            dark: IMMColor.resolved(isOn ? "primary-foreground" : "foreground", dark: true) ?? IMMRGBA(r: 1, g: 1, b: 1, a: 1))
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            track
        }
        .buttonStyle(IMMBareButtonStyle())
        .focusEffectDisabled()
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) { EmptyView() }
        }
    }

    private var track: some View {
        let travel = size.thumb - 2
        return ZStack(alignment: .leading) {
            Capsule(style: .circular).fill(isOn ? IMMColor.primary : IMMColor.switchOff)
            Circle()
                .fill(thumbColor)
                .frame(width: size.thumb, height: size.thumb)
                .offset(x: 1 + (isOn ? travel : 0))
        }
        .frame(width: size.width, height: size.height)
        .overlay(
            Capsule(style: .circular).strokeBorder(
                isError ? IMMColor.destructiveBorder : (isFocused ? IMMColor.ring : Color.clear), lineWidth: 1)
        )
        .overlay {
            if isError {
                Capsule(style: .circular).stroke(IMMColor.destructiveRing, lineWidth: 2).padding(-1)
            } else if isFocused {
                Capsule(style: .circular).stroke(IMMColor.focusRing, lineWidth: 2).padding(-1)
            }
        }
        .opacity(isEnabled || inert ? 1 : 0.5)
        .animation(disableMotion ? nil : Motion.ease(0.15), value: isOn)
        .contentShape(Capsule(style: .circular))
    }
}
