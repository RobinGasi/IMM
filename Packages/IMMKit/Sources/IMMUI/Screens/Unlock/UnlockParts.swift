import IMMDesign
import SwiftUI

/// Page footer of the setup screens: `Last opened today, 08:12 · 5 accounts · Encrypted on this Mac`.
struct UnlockFooter: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .immFont(.small)
            .foregroundStyle(IMMColor.mutedForeground)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
    }
}

/// Logo, title and the line under it.
struct UnlockHeading: View {
    let title: String
    let subtitle: String
    var showsLogo = true

    var body: some View {
        VStack(spacing: 0) {
            if showsLogo {
                IMMLogoMark(width: 60, animated: true)
            }
            Text(verbatim: title)
                .immFont(.titleXL)
                .foregroundStyle(IMMColor.foreground)
                .padding(.top, showsLogo ? 20 : 0)
            Text(verbatim: subtitle)
                .immFont(.body)
                .foregroundStyle(IMMColor.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
    }
}

/// The Touch ID block: fingerprint, "Touch ID to unlock", the hint to type the password.
/// Hover `muted`, pressed `accent`, 120 ms.
struct TouchIDBlock: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                IMMIcon("fingerprint", size: 48, color: nil)
                    .foregroundStyle(IMMColor.primary)
                Text("Touch ID to unlock", bundle: .module)
                    .immFont(.bodyMedium)
                    .padding(.top, 12)
                Text("or press ⏎ to type your password", bundle: .module)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
        }
        .buttonStyle(TouchIDBlockStyle())
        .focusEffectDisabled()
        .accessibilityLabel(Text("Unlock with Touch ID", bundle: .module))
    }
}

private struct TouchIDBlockStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TouchIDBlockBody(configuration: configuration)
    }
}

private struct TouchIDBlockBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused
    @Environment(\.immDisableMotion) private var disableMotion
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous)
        configuration.label
            .foregroundStyle(configuration.isPressed ? IMMColor.accentForeground : IMMColor.foreground)
            .background {
                shape.fill(configuration.isPressed ? IMMColor.accent : (hovering ? IMMColor.muted : Color.clear))
            }
            .overlay {
                if isFocused {
                    shape.inset(by: 1).stroke(IMMColor.ring, lineWidth: 2)
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(disableMotion ? nil : Motion.ease(0.12), value: hovering)
            .animation(disableMotion ? nil : Motion.ease(0.12), value: configuration.isPressed)
    }
}

/// "Your fingerprints changed…": the block when the system invalidated the Touch ID key. Not clickable.
struct TouchIDInvalidatedBlock: View {
    var body: some View {
        VStack(spacing: 0) {
            IMMIcon("fingerprint", size: 48, color: nil)
                .foregroundStyle(IMMColor.primary)
                .opacity(0.4)
            Text("Your fingerprints changed. Enter your password once to turn Touch ID back on.", bundle: .module)
                .immFont(.body)
                .foregroundStyle(IMMColor.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: 320)
        .accessibilityElement(children: .combine)
    }
}
