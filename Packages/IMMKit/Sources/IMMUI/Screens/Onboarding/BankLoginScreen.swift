import IMMBanking
import IMMDesign
import IMMLedger
import SwiftUI

/// Setup step 3: sign in to the chosen bank, then choose the accounts to import.
///
/// Left half: login name, PIN, "Store PIN in macOS Keychain", TAN method and the approval status line.
/// Right half: "Sign in to see your accounts." until the bank confirms, then the offered accounts with
/// their checkboxes and "Fetch transactions since". The footer button reads "Sign in" until then and
/// "Import N accounts" afterwards.
///
/// `Onboarding3BankLoginSetup.tsx`, `StatesBankLoginBeforeSignInSetup.tsx`, `StatesBankLoginWaitingSetup.tsx`.
public struct BankLoginScreen: View {
    @Environment(AppModel.self) private var model

    @State private var loginName: String
    @State private var pin: String
    @State private var storePIN = true
    @State private var tanMethod = TANMethod.pushTAN
    @State private var fetchSince = FetchSince.bankLimit
    /// Accounts the user switched off; everything the bank offers is on by default.
    @State private var deselected: Set<String> = []
    @State private var importing = false
    @State private var importError: String?
    @State private var signInTask: Task<Void, Never>?
    @FocusState private var loginFocused: Bool
    @FocusState private var pinFocused: Bool

    public init() {
        self.init(loginName: "", pin: "")
    }

    /// Starts with the fields filled (screenshot tests of the designed states).
    init(loginName: String, pin: String) {
        _loginName = State(initialValue: loginName)
        _pin = State(initialValue: pin)
    }

    private enum TANMethod: Hashable { case pushTAN }

    private enum FetchSince: Hashable {
        case bankLimit, thisYear, last90Days

        /// The date handed to `BankController.importAccounts(since:)`.
        func date(calendar: Calendar = .current, now: Date = Date()) -> Date {
            switch self {
            case .bankLimit:
                return calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)) ?? now
            case .thisYear:
                return calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? now
            case .last90Days:
                return calendar.date(byAdding: .day, value: -90, to: now) ?? now
            }
        }
    }

    // MARK: State

    private var signInState: SignInState { model.bank.signInState }

    private var isWorking: Bool {
        switch signInState {
        case .signingIn, .waiting: return true
        default: return false
        }
    }

    private var confirmedAccounts: [BankAccount]? {
        if case .confirmed(_, let accounts) = signInState { return accounts }
        return nil
    }

    private var selectedAccountCount: Int {
        (confirmedAccounts ?? []).filter { !deselected.contains($0.id) }.count
    }

    private var canSignIn: Bool {
        !loginName.trimmingCharacters(in: .whitespaces).isEmpty && !pin.isEmpty && !isWorking
    }

    private var bank: BankDirectoryEntry? { model.bank.selectedBank }

    // MARK: Body

    public var body: some View {
        VStack(spacing: 0) {
            SetupTitlebar(step: String(localized: "Step 3 of 3", bundle: .module), title: String(localized: "Set up IMM", bundle: .module))
            GeometryReader { proxy in
                let column = max(0, proxy.size.width / 2 - 80)
                HStack(spacing: 0) {
                    leftSection(column: column)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    rightSection(column: column - 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .overlay(alignment: .leading) { VerticalRule(height: proxy.size.height) }
                }
            }
            .immSlideInRight(duration: 0.28)
            footer
        }
        .background(IMMColor.background)
        .onDisappear { signInTask?.cancel() }
    }

    // MARK: Left half

    private func leftSection(column: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to \(bank?.name ?? "")", bundle: .module)
                    .immFont(.titleLG)
                    .foregroundStyle(IMMColor.foreground)
                Text(verbatim: subtitle)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
            }

            VStack(alignment: .leading, spacing: 16) {
                OnboardingField(label: Text(verbatim: "Anmeldename")) {
                    if isWorking {
                        OnboardingDisabledInput(text: loginName)
                    } else {
                        IMMTextField(
                            text: userEdited($loginName),
                            prompt: Text("Login name from your bank", bundle: .module), focused: $loginFocused)
                            .onSubmit { pinFocused = true }
                            .accessibilityLabel(Text(verbatim: "Anmeldename"))
                    }
                }
                OnboardingField(label: Text(verbatim: "Online-Banking PIN")) {
                    if isWorking {
                        OnboardingDisabledInput(text: String(repeating: "\u{2022}", count: pin.count))
                    } else {
                        IMMSecureField(
                            text: userEdited($pin),
                            prompt: Text("Online-banking PIN", bundle: .module), focused: $pinFocused)
                            .onSubmit { if canSignIn { signIn() } }
                            .accessibilityLabel(Text(verbatim: "Online-Banking PIN"))
                    }
                }
                IMMCheckbox(isOn: $storePIN) {
                    Text("Store PIN in macOS Keychain", bundle: .module)
                        .immFont(IMMFont.smallMedium.withLineHeight(16.5))
                        .foregroundStyle(IMMColor.foreground)
                }
                .allowsHitTesting(!isWorking)
            }

            OnboardingField(label: Text("TAN method", bundle: .module)) {
                SelectTrigger(
                    selection: userEdited($tanMethod),
                    options: [IMMOption(TANMethod.pushTAN, Text("pushTAN — S-pushTAN app", bundle: .module))],
                    width: column
                )
                .allowsHitTesting(!isWorking)
            }

            statusLine
        }
        .padding(.horizontal, 40)
        .padding(.top, 32)
        .initialFocus($loginFocused, isEnabled: confirmedAccounts == nil && !isWorking)
    }

    private var subtitle: String {
        guard let bank else { return "" }
        let code = bank.bankCode.isEmpty ? "" : "BLZ \(bank.bankCodeFormatted) · "
        return code + String(localized: "FinTS online banking", bundle: .module)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch signInState {
        case .idle:
            if let importError {
                failure(importError)
            }
        case .signingIn, .waiting:
            OnboardingStatusLine(
                text: String(localized: "Waiting for approval in S-pushTAN…", bundle: .module),
                color: IMMColor.mutedForeground
            ) {
                OnboardingSpinner()
            }
        case .confirmed(let at, _):
            OnboardingStatusLine(
                text: String(localized: "Confirmed in S-pushTAN at \(OnboardingClock.string(at))", bundle: .module),
                color: IMMColor.credit
            ) {
                OnboardingCircleCheck(color: IMMColor.credit)
            }
        case .failed(let message):
            failure(message)
        }
    }

    private func failure(_ message: String) -> some View {
        OnboardingStatusLine(text: message, color: IMMColor.destructive) {
            IMMIcon("circle-alert", size: 16)
        }
    }

    // MARK: Right half

    @ViewBuilder
    private func rightSection(column: CGFloat) -> some View {
        if let accounts = confirmedAccounts {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    (accounts.count == 1 ? Text("1 account found", bundle: .module) : Text("\(accounts.count) accounts found", bundle: .module))
                        .immFont(.titleMD)
                        .foregroundStyle(IMMColor.foreground)
                    Text("Choose which accounts IMM should import.", bundle: .module)
                        .immFont(.small)
                        .foregroundStyle(IMMColor.mutedForeground)
                }

                VStack(spacing: 0) {
                    Rule()
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        AccountChoiceRow(
                            account: account,
                            isOn: Binding(
                                get: { !deselected.contains(account.id) },
                                set: { on in
                                    if on { deselected.remove(account.id) } else { deselected.insert(account.id) }
                                })
                        )
                        .immRiseIn(duration: 0.3, delay: 0.25 + 0.05 * Double(index))
                    }
                }
                .padding(.horizontal, -8)

                OnboardingField(label: Text("Fetch transactions since", bundle: .module)) {
                    SelectTrigger(
                        selection: $fetchSince,
                        options: [
                            IMMOption(FetchSince.bankLimit, Text("01.01.2025 (as far as the bank allows)", bundle: .module)),
                            IMMOption(FetchSince.thisYear, Text("01.01.2026", bundle: .module)),
                            IMMOption(FetchSince.last90Days, Text("Last 90 days", bundle: .module)),
                        ],
                        width: column
                    )
                }

                HStack(alignment: .top, spacing: 8) {
                    IMMIcon("clock", size: 16)
                        .padding(.top, 1)
                    Text("IMM syncs when you press Sync.", bundle: .module)
                        .immFont(IMMFont.small.withLineHeight(18))
                        .frame(maxWidth: 380, alignment: .leading)
                }
                .foregroundStyle(IMMColor.mutedForeground)
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
        } else {
            Text("Sign in to see your accounts.", bundle: .module)
                .immFont(.body)
                .foregroundStyle(IMMColor.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                back()
            } label: {
                HStack(spacing: 4) {
                    IMMIcon("chevron-left", size: 14)
                    Text("Back", bundle: .module)
                }
            }
            .immButtonStyle(.ghost, leadingIcon: true)
            .padding(.leading, -8)
            Spacer()
            if confirmedAccounts != nil {
                OnboardingPrimaryButton(title: importTitle, enabled: selectedAccountCount > 0 && !importing) {
                    importAccounts()
                }
            } else {
                OnboardingPrimaryButton(title: Text("Sign in", bundle: .module), enabled: canSignIn) {
                    signIn()
                }
            }
        }
        .padding(.horizontal, 40)
        .frame(height: 60)
        .overlay(alignment: .top) { Rule() }
    }

    private var importTitle: Text {
        selectedAccountCount == 1
            ? Text("Import 1 account", bundle: .module)
            : Text("Import \(selectedAccountCount) accounts", bundle: .module)
    }

    // MARK: Actions

    /// Binding for a credential field: a change by the user after the bank confirmed (or refused)
    /// invalidates the sign-in. The Keychain checkbox, the account checkboxes and "Fetch transactions
    /// since" are import choices and leave the sign-in alone.
    private func userEdited<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                binding.wrappedValue = value
                if signInState != .idle, !isWorking { model.bank.resetSignIn() }
                importError = nil
            })
    }

    private func back() {
        signInTask?.cancel()
        signInTask = nil
        model.bank.resetSignIn()
        model.bank.selectedBank = nil
    }

    private func signIn() {
        guard let bank, canSignIn else { return }
        let credentials = BankCredentials(
            loginName: loginName.trimmingCharacters(in: .whitespaces), pin: pin, tanMethod: "pushTAN")
        importError = nil
        deselected = []
        signInTask?.cancel()
        signInTask = Task { @MainActor in
            do {
                try await model.bank.signIn(bank: bank, credentials: credentials)
                // The bank controller keeps what it needs; the typed PIN does not stay on screen.
                pin = ""
            } catch {
                if Task.isCancelled { model.bank.resetSignIn() }
            }
        }
    }

    private func importAccounts() {
        let since = fetchSince.date()
        let ids = Set((confirmedAccounts ?? []).map(\.id)).subtracting(deselected)
        let store = storePIN
        importing = true
        importError = nil
        Task { @MainActor in
            defer { importing = false }
            do {
                try await model.bank.importAccounts(since: since, accountIDs: ids, storePIN: store)
            } catch {
                importError = BankController.message(for: error)
            }
        }
    }
}

/// One offered account: checkbox, name over IBAN, balance. The whole row toggles the checkbox.
private struct AccountChoiceRow: View {
    let account: BankAccount
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: 0) {
            row
            Rule()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var row: some View {
        DataRow(bleed: 0, action: { isOn.toggle() }) {
            HStack(spacing: 12) {
                IMMCheckbox(isOn: $isOn)
                    .allowsHitTesting(false)
                    .focusable(false)
                    .frame(width: 16, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: account.name)
                        .immFont(IMMFont.bodyMedium.withLineHeight(18))
                    Text(verbatim: identifier)
                        .immFont(.mono)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: MoneyFormatter.string(account.balance, currency: account.currency))
                    .immFont(IMMFont.bodyMedium.withLineHeight(18).tabular)
                    .lineLimit(1)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
    }

    private var identifier: String {
        if let iban = account.iban { return IBAN.formatted(iban) }
        return account.number ?? ""
    }
}
