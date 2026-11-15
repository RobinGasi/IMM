import IMMDesign
import IMMLedger
import SwiftUI

/// German money input of the manual account and booking forms.
enum ManualMoney {
    /// Signed minor units for "1.234,56", "-50", "−50", "+12,5", "12"; nil for empty or malformed text.
    /// Exact integer math (no floating point), at most two decimals.
    static func parse(_ text: String) -> Int? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var negative = false
        if let first = rest.first, first == "-" || first == "\u{2212}" || first == "+" {
            negative = first != "+"
            rest = rest.dropFirst()
        }
        guard let magnitude = TransferInput.amount(String(rest)) else { return nil }
        return negative ? -magnitude : magnitude
    }
}

/// The values behind `ManualAccountForm`.
struct ManualAccountFormModel: Equatable {
    var name = ""
    var kind: AccountKind = .giro
    var balanceText = ""

    /// The kinds a manual account can have, in picker order.
    static let kinds: [AccountKind] = [.giro, .savings, .creditCard, .wallet]

    static func title(of kind: AccountKind) -> String {
        switch kind {
        case .giro: return String(localized: "Current account", bundle: .module)
        case .savings: return String(localized: "Savings", bundle: .module)
        case .creditCard: return String(localized: "Credit card", bundle: .module)
        case .wallet: return String(localized: "Cash / wallet", bundle: .module)
        case .depot: return String(localized: "Depot", bundle: .module)
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var trimmedBalance: String { balanceText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Opening balance in minor units; an empty field means 0,00 €. Nil for text that is not an amount.
    var openingBalance: Int? { trimmedBalance.isEmpty ? 0 : ManualMoney.parse(trimmedBalance) }

    var balanceIsInvalid: Bool { openingBalance == nil }

    /// The parsed balance when the user typed one, for the line under the field.
    var typedBalance: Int? { trimmedBalance.isEmpty ? nil : ManualMoney.parse(trimmedBalance) }

    var input: ManualAccountInput? {
        guard !trimmedName.isEmpty, let balance = openingBalance else { return nil }
        return ManualAccountInput(name: trimmedName, kind: kind, openingBalance: balance)
    }

    var canSubmit: Bool { input != nil }
}

/// Name, kind and opening balance of a manual account, with the submit button and the error of a failed
/// submit. Used by the onboarding's Manual account tab and by the main window's "New manual account" sheet.
struct ManualAccountForm: View {
    let submitTitle: Text
    let onSubmit: (ManualAccountInput) async throws -> Void
    private var onCancel: (() -> Void)?

    @State private var form = ManualAccountFormModel()
    @State private var errorText: String?
    @State private var isSubmitting = false
    @FocusState private var nameFocused: Bool

    init(submitTitle: Text, onSubmit: @escaping (ManualAccountInput) async throws -> Void) {
        self.submitTitle = submitTitle
        self.onSubmit = onSubmit
    }

    /// Adds a Cancel button left of the submit button.
    func cancelAction(_ action: @escaping () -> Void) -> ManualAccountForm {
        var copy = self
        copy.onCancel = action
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Field(label: Text("Name", bundle: .module)) {
                IMMTextField(
                    text: $form.name, prompt: Text("e.g. Household cash", bundle: .module), focused: $nameFocused)
                    .accessibilityLabel(Text("Name", bundle: .module))
            }
            Field(label: Text("Type", bundle: .module)) {
                SelectTrigger(
                    selection: $form.kind,
                    options: ManualAccountFormModel.kinds.map { IMMOption($0, verbatim: ManualAccountFormModel.title(of: $0)) },
                    width: 220)
                    .accessibilityLabel(Text("Type", bundle: .module))
            }
            Field(
                label: Text("Opening balance", bundle: .module),
                description: balanceDescription,
                error: form.balanceIsInvalid ? Text("Enter an amount like 1.234,56.", bundle: .module) : nil
            ) {
                InputGroup(
                    text: $form.balanceText, prompt: Text(verbatim: "0,00"), isError: form.balanceIsInvalid,
                    leading: { EmptyView() }, trailing: { Text(verbatim: "€") })
                    .multilineTextAlignment(.trailing)
                    .frame(width: 180)
                    .accessibilityLabel(Text("Opening balance", bundle: .module))
            }
            if let errorText {
                Text(verbatim: errorText)
                    .immFont(.controlRegular)
                    .foregroundStyle(IMMColor.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let onCancel {
                    Button(action: onCancel) { Text("Cancel", bundle: .module) }
                        .immButtonStyle(.outline)
                }
                Button(action: submit) { submitTitle }
                    .immButtonStyle(.default)
                    .disabled(!form.canSubmit || isSubmitting)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .initialFocus($nameFocused)
        .onChange(of: form) { errorText = nil }
    }

    private var balanceDescription: Text {
        if let balance = form.typedBalance {
            let formatted = MoneyFormatter.string(balance)
            return Text("Starts at \(formatted)", bundle: .module)
        }
        return Text("Leave empty to start at 0,00 €. A debt is negative, like -50.", bundle: .module)
    }

    private func submit() {
        guard let input = form.input, !isSubmitting else { return }
        isSubmitting = true
        errorText = nil
        Task {
            do {
                try await onSubmit(input)
            } catch {
                errorText = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}
