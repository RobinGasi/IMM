import GRDB
import IMMDesign
import IMMLedger
import SwiftUI

/// The values behind the "New booking" sheet.
struct ManualBookingFormModel: Equatable {
    var accountID: String?
    var dateText: String
    var isExpense = true
    var amountText = ""
    var counterparty = ""
    var purpose = ""
    var categoryID: String?
    var note = ""

    init(accountID: String?, today: LocalDate) {
        self.accountID = accountID
        self.dateText = DateFormats.dayMonthYear(today)
    }

    /// The booking date; nil for text that is not a real `dd.MM.yyyy` day.
    var date: LocalDate? { TransferInput.date(dateText) }

    /// The amount as typed, above zero; the expense/income control carries the sign.
    var amountMinor: Int? {
        guard let value = ManualMoney.parse(amountText), value > 0 else { return nil }
        return value
    }

    var trimmedCounterparty: String { counterparty.trimmingCharacters(in: .whitespacesAndNewlines) }

    var amountIsInvalid: Bool {
        !amountText.trimmingCharacters(in: .whitespaces).isEmpty && amountMinor == nil
    }

    var dateIsInvalid: Bool { date == nil }

    /// The category kind that fits the direction of the booking.
    var categoryKind: CategoryKind { isExpense ? .expense : .income }

    /// The ledger input: expenses are negative, income positive. Nil until every required field is valid.
    var input: ManualBookingInput? {
        guard let accountID, let date, let amount = amountMinor, !trimmedCounterparty.isEmpty else { return nil }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManualBookingInput(
            accountID: accountID, bookingDate: date, amount: isExpense ? -amount : amount,
            counterparty: trimmedCounterparty, purpose: purpose.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryID: categoryID, note: trimmedNote.isEmpty ? nil : trimmedNote)
    }

    var canSave: Bool { input != nil }
}

/// "New booking" (520 wide; `PanelHost` adds dim, background, radius, shadow and motion): a booking in a
/// manual account. Without manual accounts it explains that and offers "New manual account".
struct ManualBookingSheet: View {
    @Environment(AppModel.self) private var model

    private struct Loaded {
        var accounts: [AccountRecord]
        var categories: [CategoryRecord]
        var today: LocalDate
    }

    @State private var loaded: Loaded?

    var body: some View {
        Group {
            if let loaded {
                if loaded.accounts.isEmpty {
                    emptyState
                } else {
                    ManualBookingForm(
                        accounts: loaded.accounts, categories: loaded.categories, today: loaded.today,
                        preselected: preselectedAccount(in: loaded.accounts))
                }
            } else {
                Color.clear.frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: model.ledger.map { ObjectIdentifier($0) }) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("New booking", bundle: .module))
    }

    private func load() async {
        guard let ledger = model.ledger else { return }
        let accounts = await model.manualAccounts()
        let data = try? await ledger.database.read { db -> ([CategoryRecord], LocalDate) in
            let categories = try CategoryRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
            return (categories, try LedgerClock.today(db))
        }
        loaded = Loaded(accounts: accounts, categories: data?.0 ?? [], today: data?.1 ?? LocalDate(Date()))
    }

    /// The account shown in Transactions when it is a manual one, else the first manual account.
    private func preselectedAccount(in accounts: [AccountRecord]) -> String? {
        if case .transactions(.account(let id)) = model.route, accounts.contains(where: { $0.id == id }) { return id }
        return accounts.first?.id
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New booking", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 4, trailing: 24))
            Text("You don't have a manual account yet. Create one first, then add its bookings here.", bundle: .module)
                .immFont(.body)
                .foregroundStyle(IMMColor.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 0, leading: 24, bottom: 20, trailing: 24))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { model.closePanel() } label: { Text("Cancel", bundle: .module) }
                    .immButtonStyle(.outline)
                Button { model.panel = .newManualAccount } label: { Text("New manual account", bundle: .module) }
                    .immButtonStyle(.default)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: 14, leading: 24, bottom: 16, trailing: 24))
            .overlay(alignment: .top) { Rule() }
        }
    }
}

private struct ManualBookingForm: View {
    @Environment(AppModel.self) private var model

    let accounts: [AccountRecord]
    let categories: [CategoryRecord]

    @State private var form: ManualBookingFormModel
    @State private var errorText: String?
    @State private var isSaving = false
    @FocusState private var counterpartyFocused: Bool

    /// Label column 96 + gap 12 inside the 24 px padding of the 520 px panel.
    private let controlWidth: CGFloat = 520 - 48 - 96 - 12

    init(accounts: [AccountRecord], categories: [CategoryRecord], today: LocalDate, preselected: String?) {
        self.accounts = accounts
        self.categories = categories
        _form = State(initialValue: ManualBookingFormModel(accountID: preselected, today: today))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New booking", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 4, trailing: 24))

            VStack(alignment: .leading, spacing: 14) {
                row("Account") {
                    SelectTrigger(
                        selection: Binding(get: { form.accountID ?? "" }, set: { form.accountID = $0 }),
                        options: accounts.map { IMMOption($0.id, verbatim: $0.name) },
                        width: controlWidth)
                        .accessibilityLabel(Text("Account", bundle: .module))
                }
                row("Date") {
                    VStack(alignment: .leading, spacing: 4) {
                        IMMTextField(
                            text: $form.dateText, prompt: Text(verbatim: "dd.MM.yyyy"), isError: form.dateIsInvalid)
                            .frame(width: 140)
                            .accessibilityLabel(Text("Date", bundle: .module))
                        if form.dateIsInvalid {
                            hint(Text("Enter a date like 20.11.2026.", bundle: .module), error: true)
                        }
                    }
                }
                row("Amount") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ToggleGroup(
                                selection: $form.isExpense,
                                options: [
                                    IMMOption(true, Text("Expense", bundle: .module)),
                                    IMMOption(false, Text("Income", bundle: .module)),
                                ])
                            InputGroup(
                                text: $form.amountText, prompt: Text(verbatim: "0,00"), isError: form.amountIsInvalid,
                                leading: { EmptyView() }, trailing: { Text(verbatim: "€") })
                                .multilineTextAlignment(.trailing)
                                .frame(width: 140)
                                .accessibilityLabel(Text("Amount", bundle: .module))
                        }
                        if form.amountIsInvalid {
                            hint(Text("Enter an amount above zero, like 12,50.", bundle: .module), error: true)
                        }
                    }
                }
                row("Counterparty") {
                    IMMTextField(text: $form.counterparty, focused: $counterpartyFocused)
                        .accessibilityLabel(Text("Counterparty", bundle: .module))
                }
                row("Purpose") {
                    IMMTextField(text: $form.purpose)
                        .accessibilityLabel(Text("Purpose", bundle: .module))
                }
                row("Category") {
                    SelectTrigger(
                        selection: Binding(get: { form.categoryID ?? "" }, set: { form.categoryID = $0.isEmpty ? nil : $0 }),
                        options: [IMMOption("", Text("Without category", bundle: .module))]
                            + availableCategories.map { IMMOption($0.id, verbatim: $0.name) },
                        width: controlWidth)
                        .accessibilityLabel(Text("Category", bundle: .module))
                }
                row("Note") {
                    IMMTextField(text: $form.note)
                        .accessibilityLabel(Text("Note", bundle: .module))
                }
                if let errorText {
                    Text(verbatim: errorText)
                        .immFont(.controlRegular)
                        .foregroundStyle(IMMColor.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 108)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24))

            footer
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .initialFocus($counterpartyFocused)
        .onChange(of: form) { errorText = nil }
        .onChange(of: form.isExpense) {
            // A category of the other direction no longer fits.
            if let id = form.categoryID, categories.first(where: { $0.id == id })?.kind != form.categoryKind {
                form.categoryID = nil
            }
        }
    }

    private var availableCategories: [CategoryRecord] {
        categories.filter { $0.kind == form.categoryKind }
    }

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

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button { model.closePanel() } label: { Text("Cancel", bundle: .module) }
                .immButtonStyle(.outline)
            Button(action: save) { Text("Save booking", bundle: .module) }
                .immButtonStyle(.default)
                .disabled(!form.canSave || isSaving)
                .keyboardShortcut(.defaultAction)
        }
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 16, trailing: 24))
        .overlay(alignment: .top) { Rule() }
    }

    private func save() {
        guard let input = form.input, !isSaving else { return }
        isSaving = true
        errorText = nil
        Task {
            do {
                _ = try await model.addManualBooking(input)
                model.closePanel()
            } catch {
                errorText = error.localizedDescription
            }
            isSaving = false
        }
    }
}
