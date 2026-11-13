import SwiftUI

/// The design's `Badge`: 20 px pill, 10 px medium text.
///
/// `.warning` is the outline badge with `warning` text ("Check this", "Needs receipt").
public struct Badge<Label: View>: View {
    public enum Variant: Sendable, Equatable {
        case `default`, secondary, outline, ghost, warning
    }

    private let variant: Variant
    private let label: Label
    @State private var hovering = false

    public init(_ variant: Variant = .secondary, @ViewBuilder label: () -> Label) {
        self.variant = variant
        self.label = label()
    }

    private var foreground: Color {
        switch variant {
        case .default: return IMMColor.primaryForeground
        case .secondary: return IMMColor.secondaryForeground
        case .outline: return IMMColor.foreground
        // Ghost has no text colour of its own in the design; both places that use it (Paused) sit in muted text.
        case .ghost: return IMMColor.mutedForeground
        case .warning: return IMMColor.warning
        }
    }

    private var fill: Color {
        switch variant {
        case .default: return IMMColor.primary
        case .secondary: return IMMColor.secondary
        case .outline, .warning: return IMMColor.inputFill
        case .ghost: return hovering ? IMMColor.ghostHover : Color.clear
        }
    }

    private var hasBorder: Bool { variant == .outline || variant == .warning }

    public var body: some View {
        HStack(spacing: 4) {
            label
        }
        .immFont(.badge)
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 10, style: .circular).fill(fill))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .circular)
                .strokeBorder(hasBorder ? IMMColor.border : Color.clear, lineWidth: 1))
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

extension Badge where Label == Text {
    public init(_ title: Text, variant: Variant = .secondary) {
        self.init(variant) { title }
    }

    public init(verbatim title: String, variant: Variant = .secondary) {
        self.init(variant) { Text(verbatim: title) }
    }
}
