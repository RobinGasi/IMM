import IMMDesign
import IMMVault
import SwiftUI

/// Unlock: the 960 × 640 setup window for a database that is closed (after launch, auto-lock, sleep or
/// ⌘L). Touch ID prompts by itself once per lock and on click; the password field is always there.
///
/// Reads `AppModel.phase` (`.locked(LockedInfo)`), `AppModel.lockReason` and unlocks with
/// `AppModel.unlock(password:)` / `unlockWithTouchID()`.
public struct UnlockScreen: View {
    @Environment(AppModel.self) private var model

    @State private var password: String
    @State private var error: String?
    @State private var isBusy = false
    @State private var didPrompt = false
    @FocusState private var passwordFocused: Bool

    private let titlebarStep: String
    private let autoPrompt: Bool

    public init() {
        self.init(titlebarStep: String(localized: "Locked", bundle: .module))
    }

    /// - Parameters:
    ///   - titlebarStep: text at the right of the title bar ("Locked"; the first artboard draws none).
    ///   - password: field content to start with (screenshot tests).
    ///   - error: error line to start with (screenshot tests).
    ///   - autoPrompt: ask for Touch ID on appearance; tests turn it off.
    init(titlebarStep: String, password: String = "", error: String? = nil, autoPrompt: Bool = true) {
        self.titlebarStep = titlebarStep
        self.autoPrompt = autoPrompt
        self._password = State(initialValue: password)
        self._error = State(initialValue: error)
    }

    public var body: some View {
        VStack(spacing: 0) {
            SetupTitlebar(step: titlebarStep, title: "Ich mag Moneten")
            if case .locked(let info) = model.phase {
                content(info)
                UnlockFooter(text: UnlockText.footer(lastOpened: info.lastOpened, accountCount: info.accountCount))
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard case .locked(let info) = model.phase else { return }
            if info.touchID == .ready {
                guard autoPrompt, !didPrompt else { return }
                didPrompt = true
                await unlockWithTouchID()
            } else if autoPrompt {
                focusPassword()
            }
        }
        .onChange(of: password) { error = nil }
        .modifier(UnlockSyncedFolderGate())
    }

    private func content(_ info: AppModel.LockedInfo) -> some View {
        VStack(spacing: 0) {
            UnlockHeading(
                title: String(localized: "\(info.displayName) is locked", bundle: .module),
                subtitle: UnlockText.subtitle(for: model.lockReason))

            switch info.touchID {
            case .ready:
                TouchIDBlock { Task { await unlockWithTouchID() } }
                    .padding(.top, 40)
                    .immFadeIn(duration: 0.4, delay: 0.3)
            case .invalidated:
                TouchIDInvalidatedBlock()
                    .padding(.top, 40)
                    .immFadeIn(duration: 0.4, delay: 0.3)
            case .unavailable:
                Text("Type your database password", bundle: .module)
                    .immFont(.body)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .padding(.top, 36)
            }

            HStack(spacing: 8) {
                IMMSecureField(
                    text: $password, prompt: Text("Database password", bundle: .module), isError: error != nil,
                    focused: $passwordFocused
                )
                .frame(maxWidth: .infinity)
                .onSubmit(unlock)
                .accessibilityLabel(Text("Database password", bundle: .module))
                Button {
                    unlock()
                } label: {
                    Text("Unlock", bundle: .module)
                }
                .immButtonStyle(.default)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)

            if let error {
                Text(verbatim: error)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .frame(maxWidth: 360)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    /// Puts the cursor in the password field. Deferred one turn: the field may not be in the window yet
    /// when this runs from `.task` on appearance.
    private func focusPassword() {
        Task { @MainActor in passwordFocused = true }
    }

    /// Unlock button and Return in the field. With an empty field the click only moves focus there:
    /// that is what "press ⏎ to type your password" means.
    private func unlock() {
        guard !isBusy else { return }
        guard !password.isEmpty else {
            focusPassword()
            return
        }
        isBusy = true
        let attempt = password
        Task {
            defer { isBusy = false }
            do {
                try await model.unlock(password: attempt)
            } catch VaultError.wrongPassword {
                error = String(localized: "Wrong password. Try again.", bundle: .module)
                focusPassword()
            } catch {
                self.error = Self.message(for: error)
                focusPassword()
            }
        }
    }

    private func unlockWithTouchID() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await model.unlockWithTouchID()
        } catch BiometryError.cancelled, BiometryError.failed, BiometryError.keyInvalidated {
            // Stay on this screen; an invalidated key has already switched the block to the
            // "fingerprints changed" text.
            focusPassword()
        } catch {
            self.error = Self.message(for: error)
            focusPassword()
        }
    }

    private static func message(for error: Error) -> String {
        if case VaultError.io(let detail) = error { return detail }
        return String(localized: "The database could not be opened.", bundle: .module)
    }
}
