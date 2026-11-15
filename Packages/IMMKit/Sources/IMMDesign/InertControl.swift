import SwiftUI

/// Controls that would change data and have no designed target look as designed, do nothing and
/// carry the tooltip "Not available in this version".
///
/// Usage in a screen: give the control an empty action (or a constant binding) and add the modifier. This
/// holds for `IMMButtonStyle` buttons, `IMMSwitch`, `IMMCheckbox` and the field controls alike:
///
///     Button { } label: { Text("Split transaction", bundle: .module) }
///         .immButtonStyle(.outline, size: .sm)
///         .inertControl(String(localized: "Not available in this version", bundle: .module))
///
/// The modifier disables the control (the action cannot run) and sets `immInert`, so IMM controls
/// keep their enabled look and hover state. Plain views with `onTapGesture` are not blocked:
/// give those no gesture at all.
public enum IMMInert {
    public static let helpText = "Not available in this version"
}

private struct InertControlModifier: ViewModifier {
    let help: String

    func body(content: Content) -> some View {
        content
            .environment(\.immInert, true)
            .disabled(true)
            .help(Text(verbatim: help))
            .accessibilityHint(Text(verbatim: help))
    }
}

/// `InertControlModifier` plus a badge placed after the control. The badge is decoration: it takes no
/// clicks and is hidden from accessibility (the hint on the control carries the message).
private struct ComingSoonModifier: ViewModifier {
    let help: String
    let badge: String

    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            content.modifier(InertControlModifier(help: help))
            Badge(verbatim: badge, variant: .outline)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The button style under `IMMSwitch` and `IMMCheckbox`. Unlike `.plain`, it never dims its label when the
/// control is disabled, so `.inertControl()` keeps the enabled look; the controls draw their own
/// disabled state (`opacity(isEnabled || inert ? 1 : 0.5)`).
struct IMMBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension View {
    public func inertControl(_ help: String = IMMInert.helpText) -> some View {
        modifier(InertControlModifier(help: help))
    }

    /// `inertControl` for a feature that is planned but not built yet (sending money): the same disabled
    /// look-alike with `help` as tooltip and accessibility hint, plus a small outline `badge` ("Soon")
    /// placed to the right of the control. The view grows by the badge width and spacing.
    public func comingSoonControl(_ help: String, badge: String) -> some View {
        modifier(ComingSoonModifier(help: help, badge: badge))
    }
}
