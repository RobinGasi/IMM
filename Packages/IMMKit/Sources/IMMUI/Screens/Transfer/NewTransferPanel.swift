import IMMBanking
import IMMDesign
import IMMLedger
import SwiftUI

/// The New transfer panel (560 wide; `PanelHost` adds dim, background, radius, shadow and motion).
/// The form starts from the `TransferDraft` of `Panel.newTransfer`.
public struct NewTransferPanel: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        let seed: TransferDraft? = {
            if case .newTransfer(let draft) = model.panel { return draft }
            return nil
        }()
        TransferForm(seed: seed)
    }
}

private struct TransferForm: View {
    @Environment(AppModel.self) private var model
    @State private var form: TransferFormModel
    @FocusState private var recipientFocused: Bool

    /// Label column 96 + gap 12 inside the 24 px padding of the 560 px panel.
    private let controlWidth: CGFloat = 560 - 48 - 96 - 12

    init(seed: TransferDraft?) {
        _form = State(initialValue: TransferFormModel(seed: seed))
    }

    var body: some View {
        @Bindable var form = form
        VStack(alignment: .leading, spacing: 0) {
            Text("New transfer", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 4, trailing: 24))

            VStack(alignment: .leading, spacing: 14) {
                fromRow(form)
                recipientRow($form)
                ibanRow($form)
                amountRow($form)
                purposeRow($form)
                executeRow($form)
                if form.mode != .now { dateRow($form) }
                if form.mode == .now { instantRow($form) }
            }
            .padding(EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24))

            footer
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: model.ledger.map { ObjectIdentifier($0) }) {
            guard let ledger = model.ledger else { return }
            await form.follow(ledger: ledger)
        }
        // The panel opens with the cursor in "To" (the first empty field of a blank form).
        .initialFocus($recipientFocused, isEnabled: form.recipient.isEmpty)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("New transfer", bundle: .module))
    }

    // MARK: Rows

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title, bundle: .module)
                .immFont(IMMFont.body.withLineHeight(28))
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(width: 96, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hint(_ text: Text, error: Bool = false) -> some View {
        text
            .immFont(.small)
            .foregroundStyle(error ? IMMColor.destructive : IMMColor.mutedForeground)
    }

    private func fromRow(_ form: TransferFormModel) -> some View {
        row("From") {
            SelectTrigger(
                selection: Binding(get: { form.fromAccount ?? "" }, set: { form.fromAccount = $0 }),
                options: (form.snapshot?.sources ?? []).map { source in
                    IMMOption(source.id, verbatim: "\(source.name) · \(MoneyFormatter.string(source.balance, currency: source.currency))")
                },
                width: controlWidth)
        }
    }

    private func recipientRow(_ form: Bindable<TransferFormModel>) -> some View {
        row("To") {
            VStack(alignment: .leading, spacing: 4) {
                IMMTextField(text: form.recipient, focused: $recipientFocused)
                    .onChange(of: form.wrappedValue.recipient) { form.wrappedValue.recipientEdited() }
                    .accessibilityLabel(Text("To", bundle: .module))
                if form.wrappedValue.showsSavedRecipientHint {
                    hint(Text("Saved recipient, IBAN filled in from your last transfer", bundle: .module))
                }
            }
        }
    }

    private func ibanRow(_ form: Bindable<TransferFormModel>) -> some View {
        row("IBAN") {
            VStack(alignment: .leading, spacing: 4) {
                IMMTextField(text: form.iban, isError: form.wrappedValue.showsIBANError, style: .mono)
                    .overlay(alignment: .trailing) {
                        if form.wrappedValue.ibanIsValid {
                            IMMIcon("circle-check", size: 16, color: IMMColor.credit)
                                .immPopIn(duration: 0.16, delay: 0.32)
                                .padding(.trailing, 8)
                                .accessibilityHidden(true)
                        }
                    }
                    .onChange(of: form.wrappedValue.iban) { form.wrappedValue.ibanEdited() }
                    .accessibilityLabel(Text("IBAN", bundle: .module))
                if let bank = form.wrappedValue.bankDescription {
                    hint(Text(verbatim: bank))
                } else if form.wrappedValue.showsIBANError {
                    hint(Text("This IBAN is not valid. Check the digits.", bundle: .module), error: true)
                }
            }
        }
    }

    private func amountRow(_ form: Bindable<TransferFormModel>) -> some View {
        row("Amount") {
            InputGroup(text: form.amountText, leading: { EmptyView() }, trailing: { Text(verbatim: "€") })
                .multilineTextAlignment(.trailing)
                .frame(width: 160)
                .onSubmit { form.wrappedValue.normalizeAmount() }
                .accessibilityLabel(Text("Amount", bundle: .module))
        }
    }

    private func purposeRow(_ form: Bindable<TransferFormModel>) -> some View {
        row("Purpose") {
            IMMTextField(text: form.purpose)
                .accessibilityLabel(Text("Purpose", bundle: .module))
        }
    }

    private func executeRow(_ form: Bindable<TransferFormModel>) -> some View {
        row("Execute") {
            ToggleGroup(
                selection: Binding(
                    get: { form.wrappedValue.mode },
                    set: { choice in
                        if choice == .standingOrder, form.wrappedValue.mode != .standingOrder {
                            // The designed link of "Standing order": the Standing orders screen.
                            model.closePanel()
                            model.navigate(to: .standingOrders)
                        } else {
                            form.wrappedValue.select(choice)
                        }
                    }),
                options: [
                    IMMOption(.now, Text("Now", bundle: .module)),
                    IMMOption(.onDate, Text("On date", bundle: .module)),
                    IMMOption(.standingOrder, Text("Standing order", bundle: .module)),
                ])
        }
        .padding(.top, 6)
    }

    private func dateRow(_ form: Bindable<TransferFormModel>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(form.wrappedValue.mode == .standingOrder ? "First on" : "Date", bundle: .module)
                .immFont(IMMFont.body.withLineHeight(28))
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(width: 96, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                IMMTextField(
                    text: form.dateText, prompt: Text(verbatim: "dd.MM.yyyy"),
                    isError: !form.wrappedValue.dateIsValid)
                    .frame(width: 140)
                    .accessibilityLabel(Text("Execution date", bundle: .module))
                if !form.wrappedValue.dateIsValid {
                    hint(Text("Enter a date from today on, like 20.11.2026.", bundle: .module), error: true)
                }
            }
        }
    }

    private func instantRow(_ form: Bindable<TransferFormModel>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: 96, height: 1)
            HStack(alignment: .top, spacing: 10) {
                IMMSwitch(isOn: form.instant)
                    .frame(height: 20)
                    .accessibilityLabel(Text("Instant payment (SEPA Instant)", bundle: .module))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Instant payment (SEPA Instant)", bundle: .module)
                        .immFont(IMMFont.body)
                        .foregroundStyle(IMMColor.foreground)
                    Text("Arrives within 10 seconds", bundle: .module)
                        .immFont(.small)
                        .foregroundStyle(IMMColor.mutedForeground)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("You'll confirm with pushTAN.", bundle: .module)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.closePanel()
            } label: {
                Text("Cancel", bundle: .module)
            }
            .immButtonStyle(.outline)
            Button {
                guard form.canSend else { return }
                model.bank.submit(form.draft)
            } label: {
                Text(form.sendTitle)
            }
            .immButtonStyle(.default)
            .disabled(!form.canSend)
            .keyboardShortcut(.defaultAction)
        }
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 16, trailing: 24))
        .overlay(alignment: .top) { Rule() }
    }
}
