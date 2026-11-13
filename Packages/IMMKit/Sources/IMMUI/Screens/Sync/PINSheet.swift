import GRDB
import IMMDesign
import IMMLedger
import SwiftUI

/// The PIN sheet (`Errors / 1 Sync failed`, `States / PIN sheet — empty`): asks for a new online-banking
/// PIN after a bank rejected the old one. The shell's `PanelHost` supplies width, dim, background and
/// entrance; this view is the content (`py 20, px 24`, 20 pt apart).
///
/// The rejection text comes from the failure that opened the sheet and goes away as soon as the user
/// types. "Sync with new PIN" runs `BankController.sync(newPIN:storePIN:)`, which closes the sheet.
public struct PINSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.syncPINSheetStartsClean) private var startsClean

    @State private var pin = ""
    @State private var storePIN = true
    @State private var edited = false
    @State private var loginName: String?
    @FocusState private var pinFocused: Bool

    public init() {}

    /// The bank whose PIN is asked for: the first one that rejected it.
    private var rejected: BankSyncFailure? {
        model.bank.syncState.byBank.first { if case .pinRejected = $0.reason { return true } else { return false } }
    }

    private var rejection: (code: Int, attemptsLeft: Int)? {
        guard !edited, !startsClean, let rejected, case .pinRejected(let code, let attemptsLeft) = rejected.reason else { return nil }
        return (code, attemptsLeft)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Enter your Online-Banking PIN", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)

            VStack(alignment: .leading, spacing: 16) {
                Field(label: Text(verbatim: loginLabel)) {
                    ReadOnlyInput(text: loginName ?? "")
                }
                Field(label: Text("PIN", bundle: .module), error: rejection.map { Text(verbatim: Self.rejectionText($0)) }) {
                    IMMSecureField(text: $pin, prompt: Text("Online-Banking PIN", bundle: .module), focused: $pinFocused)
                        .onSubmit(submit)
                        .accessibilityLabel(Text("PIN", bundle: .module))
                }
                IMMCheckbox(isOn: $storePIN) {
                    Text("Update PIN in macOS Keychain", bundle: .module)
                        .immFont(.label)
                        .foregroundStyle(IMMColor.foreground)
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { model.closePanel() } label: { Text("Cancel", bundle: .module) }
                    .immButtonStyle(.outline)
                Button(action: submit) { Text("Sync with new PIN", bundle: .module) }
                    .immButtonStyle(.default)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: pin) { _, _ in edited = true }
        .task(id: rejected?.loginID) { await loadLoginName() }
        .initialFocus($pinFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Enter your Online-Banking PIN", bundle: .module))
    }

    private var loginLabel: String {
        let bank = rejected?.bankName ?? String(localized: "your bank", bundle: .module)
        return String(localized: "Anmeldename at \(bank)", bundle: .module)
    }

    static func rejectionText(_ rejection: (code: Int, attemptsLeft: Int)) -> String {
        let code = String(rejection.code)
        return String(
            localized: "The bank rejected this PIN (error \(code)). After 3 wrong attempts the bank locks online banking; you have \(rejection.attemptsLeft) left.",
            bundle: .module)
    }

    private func submit() {
        guard !pin.isEmpty else { return }
        model.bank.sync(newPIN: pin, storePIN: storePIN)
    }

    private func loadLoginName() async {
        guard let loginID = rejected?.loginID, let ledger = model.ledger else { return }
        loginName = try? await ledger.database.read { db in try BankLoginRecord.fetchOne(db, key: loginID)?.loginName }
    }
}

/// A display-only input: the design's `Input` with `muted` fill and `muted-foreground` text.
private struct ReadOnlyInput: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        Text(verbatim: text)
            .immFont(.controlRegular)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .background(shape.fill(IMMColor.muted))
            .overlay(shape.strokeBorder(IMMColor.input, lineWidth: 1))
            .textSelection(.enabled)
    }
}

private struct SyncPINSheetStartsCleanKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Tests: show the sheet as if the user had already started typing (no rejection text).
    var syncPINSheetStartsClean: Bool {
        get { self[SyncPINSheetStartsCleanKey.self] }
        set { self[SyncPINSheetStartsCleanKey.self] = newValue }
    }
}
