import SwiftUI

/// The design's `Button`: variants default, outline, ghost (plus secondary and destructive),
/// sizes default 28, sm 24, icon 28 and icon-sm 24.
///
/// Apply with `.immButtonStyle(.outline, size: .sm)`; that also turns off the system focus ring,
/// because the style draws the design's own ring. A label with an icon is an `HStack(spacing: 4)`
/// of `IMMIcon(…, size: IMMButtonStyle.Size.sm.iconSize)` and a `Text`; pass `leadingIcon: true` for a
/// label that starts with the icon.
///
/// Every variant has a 1 px border (transparent except for outline) outside the 8 px padding, so the
/// horizontal inset is 9. With a leading icon the design's `pl-1.5` makes the left inset 7.
public struct IMMButtonStyle: ButtonStyle {
    public enum Variant: Sendable, Equatable {
        case `default`, outline, ghost, secondary, destructive
    }

    public enum Size: Sendable, Equatable {
        case `default`, sm, icon, iconSm

        /// Control height.
        public var height: CGFloat {
            switch self {
            case .default, .icon: return 28
            case .sm, .iconSm: return 24
            }
        }

        /// Icon size inside the control.
        public var iconSize: CGFloat {
            switch self {
            case .default, .icon: return 14
            case .sm, .iconSm: return 12
            }
        }

        var isSquare: Bool { self == .icon || self == .iconSm }
    }

    public let variant: Variant
    public let size: Size
    public let leadingIcon: Bool

    public init(_ variant: Variant = .default, size: Size = .default, leadingIcon: Bool = false) {
        self.variant = variant
        self.size = size
        self.leadingIcon = leadingIcon
    }

    public func makeBody(configuration: Configuration) -> some View {
        IMMButtonBody(configuration: configuration, variant: variant, size: size, leadingIcon: leadingIcon)
    }
}

extension ButtonStyle where Self == IMMButtonStyle {
    public static func imm(
        _ variant: IMMButtonStyle.Variant = .default, size: IMMButtonStyle.Size = .default, leadingIcon: Bool = false
    ) -> IMMButtonStyle {
        IMMButtonStyle(variant, size: size, leadingIcon: leadingIcon)
    }
}

extension View {
    /// `IMMButtonStyle` without the system focus ring.
    public func immButtonStyle(
        _ variant: IMMButtonStyle.Variant = .default, size: IMMButtonStyle.Size = .default, leadingIcon: Bool = false
    ) -> some View {
        buttonStyle(IMMButtonStyle(variant, size: size, leadingIcon: leadingIcon))
            .focusEffectDisabled()
    }
}

private struct IMMButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: IMMButtonStyle.Variant
    let size: IMMButtonStyle.Size
    let leadingIcon: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.immInert) private var inert
    @Environment(\.isFocused) private var isFocused
    @Environment(\.immDisableMotion) private var disableMotion
    @State private var hovering = false

    private var radius: CGFloat { IMMRadius.md }

    private var foreground: Color {
        switch variant {
        case .default: return IMMColor.primaryForeground
        case .outline, .ghost: return IMMColor.foreground
        case .secondary: return IMMColor.secondaryForeground
        case .destructive: return IMMColor.destructive
        }
    }

    private var fill: Color {
        switch variant {
        case .default: return hovering ? IMMColor.primaryHover : IMMColor.primary
        case .outline: return hovering ? IMMColor.outlineButtonHover : IMMColor.outlineButtonFill
        case .secondary: return hovering ? IMMColor.secondaryHover : IMMColor.secondary
        case .ghost: return hovering ? IMMColor.ghostHover : Color.clear
        case .destructive: return hovering ? IMMColor.destructiveFillHover : IMMColor.destructiveFill
        }
    }

    private var border: Color {
        if isFocused { return IMMColor.ring }
        return variant == .outline ? IMMColor.border : Color.clear
    }

    var body: some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .immFont(.control)
            .foregroundStyle(foreground)
            .padding(.leading, size.isSquare ? 0 : (leadingIcon ? 7 : 9))
            .padding(.trailing, size.isSquare ? 0 : 9)
            .frame(minWidth: size.isSquare ? size.height : nil)
            .frame(width: size.isSquare ? size.height : nil, height: size.height)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .overlay {
                if isFocused {
                    shape.stroke(IMMColor.focusRing, lineWidth: 2).padding(-1)
                }
            }
            .contentShape(shape)
            .scaleEffect(pressed ? Motion.pressedScale : 1)
            .opacity(isEnabled || inert ? 1 : 0.5)
            .animation(disableMotion ? nil : Motion.press, value: pressed)
            .animation(disableMotion ? nil : Motion.ease(0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}
