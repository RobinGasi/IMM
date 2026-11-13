import AppKit
import IMMDesign
import IMMVault
import SwiftUI

/// The "Change database password" dialog: current, new and confirm field, errors under each.
///
/// Rules: the new password has at least 8 characters and the confirmation matches. A wrong current
/// password comes back from the vault (`VaultError.wrongPassword`).
struct ChangePasswordSheet: View {
    /// Field contents and error flags; the default is the empty dialog.
    struct Draft: Equatable {
        var current = ""
        var new = ""
        var confirm = ""
        var wrongCurrent = false
        var newTooShort = false
        var mismatch = false
    }

    /// Validation of the two local rules, in the order they are shown.
    static func validate(new: String, confirm: String) -> (tooShort: Bool, mismatch: Bool) {
        (new.count < 8, confirm != new)
    }

    @Environment(AppModel.self) private var model
    @State private var draft: Draft
    @State private var busy = false
    @FocusState private var currentFocused: Bool
    @FocusState private var newFocused: Bool
    @FocusState private var confirmFocused: Bool
    private let onClose: () -> Void

    init(draft: Draft, onClose: @escaping () -> Void) {
        self._draft = State(initialValue: draft)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change database password", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
            VStack(alignment: .leading, spacing: 14) {
                field(
                    Text("Current password", bundle: .module), text: $draft.current,
                    error: draft.wrongCurrent ? Text("Wrong password.", bundle: .module) : nil,
                    focused: $currentFocused, onSubmit: { newFocused = true })
                field(
                    Text("New password", bundle: .module), text: $draft.new,
                    prompt: Text("At least 8 characters", bundle: .module),
                    error: draft.newTooShort ? Text("Use at least 8 characters.", bundle: .module) : nil,
                    focused: $newFocused, onSubmit: { confirmFocused = true })
                field(
                    Text("Confirm new password", bundle: .module), text: $draft.confirm,
                    error: draft.mismatch ? Text("The passwords don't match.", bundle: .module) : nil,
                    focused: $confirmFocused, onSubmit: { submit() })
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    close()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .immButtonStyle(.outline)
                .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    Text("Change password", bundle: .module)
                }
                .immButtonStyle(.default)
                .keyboardShortcut(.defaultAction)
            }
            .disabled(busy)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .onChange(of: draft.current) { draft.wrongCurrent = false }
        .onChange(of: draft.new) { draft.newTooShort = false }
        .onChange(of: draft.confirm) { draft.mismatch = false }
        .onExitCommand { close() }
        .initialFocus($currentFocused)
    }

    private func field(
        _ label: Text, text: Binding<String>, prompt: Text? = nil, error: Text?,
        focused: FocusState<Bool>.Binding, onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label
                .immFont(.smallMedium)
                .foregroundStyle(IMMColor.foreground)
            IMMSecureField(text: text, prompt: prompt, isError: error != nil, focused: focused)
                .onSubmit(onSubmit)
                .accessibilityLabel(label)
                .disabled(busy)
            if let error {
                error
                    .immFont(.small)
                    .foregroundStyle(IMMColor.destructive)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func close() {
        draft = Draft()
        onClose()
    }

    private func submit() {
        guard !busy else { return }
        let check = Self.validate(new: draft.new, confirm: draft.confirm)
        draft.newTooShort = check.tooShort
        draft.mismatch = check.mismatch
        draft.wrongCurrent = false
        guard !check.tooShort, !check.mismatch else { return }
        busy = true
        let current = draft.current
        let new = draft.new
        Task {
            defer { busy = false }
            do {
                try await model.changePassword(current: current, new: new)
                close()
            } catch VaultError.wrongPassword {
                draft.wrongCurrent = true
            } catch {
                SettingsAlerts.show(
                    title: String(localized: "The password couldn't be changed.", bundle: .module),
                    detail: String(describing: error))
            }
        }
    }
}
