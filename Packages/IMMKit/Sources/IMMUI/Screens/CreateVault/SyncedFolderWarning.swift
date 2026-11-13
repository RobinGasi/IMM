import IMMDesign
import SwiftUI

/// The in-window panel "This folder is synced by a cloud service." (`States / Create vault — Synced
/// folder`): a full-window dim and a 420 px card centred in the area right of `leadingInset`.
///
/// Create vault shows it when the chosen location is synced; Unlock shows the same panel once for a
/// database that sits in a synced folder.
struct SyncedFolderWarning: View {
    /// Width of the area left uncovered by the card's centring (Create vault's 440 px form column).
    var leadingInset: CGFloat = 0
    /// "Use this folder".
    var useFolder: () -> Void
    /// "Choose another folder" (the default action).
    var chooseAnother: () -> Void
    /// Esc; nil when the panel can only be answered with one of the two buttons.
    var dismiss: (() -> Void)?

    var body: some View {
        ZStack {
            IMMColor.foreground.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture {}
            HStack(spacing: 0) {
                Color.clear.frame(width: leadingInset)
                ZStack {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("This folder is synced by a cloud service.", bundle: .module)
                                .immFont(IMMFont.titleMD)
                            Text("Syncing an open database can corrupt it. Choose a folder that is not synced, or continue if you only open the database on this Mac.", bundle: .module)
                                .immFont(.body)
                                .foregroundStyle(IMMColor.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Button { useFolder() } label: {
                                Text("Use this folder", bundle: .module)
                            }
                            .immButtonStyle(.outline)
                            Button { chooseAnother() } label: {
                                Text("Choose another folder", bundle: .module)
                            }
                            .immButtonStyle(.default)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 24)
                    .frame(width: 420)
                    .background(
                        RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous)
                            .fill(IMMColor.background)
                            .shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 18)
                    )
                    .immFadeIn(duration: 0.2)
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let dismiss {
                Button("") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
