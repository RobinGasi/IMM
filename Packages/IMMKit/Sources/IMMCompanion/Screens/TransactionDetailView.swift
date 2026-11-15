import IMMDesign
import IMMLedger
import SwiftUI

/// One booking with its details; the category and the note can be edited and sync back to the Mac.
struct TransactionDetailView: View {
    @Environment(CompanionModel.self) private var model
    let transactionID: String

    @State private var detail: CompanionTransactionDetail?
    @State private var loaded = false
    @State private var categoryID: String?
    @State private var note = ""
    @State private var savedNote = ""
    @State private var errorMessage: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
        List {
            if let detail {
                header(detail.transaction)
                details(detail)
                if !detail.transaction.purpose.isEmpty {
                    Section {
                        Text(verbatim: detail.transaction.purpose)
                            .immFont(CompanionFont.callout)
                            .foregroundStyle(IMMColor.foreground)
                            .textSelection(.enabled)
                    } header: {
                        sectionLabel("Purpose")
                    }
                    .listRowBackground(IMMColor.muted)
                }
                editing
            }
        }
        .companionGroupedList()
        .overlay {
            if !loaded {
                ProgressView()
            } else if detail == nil {
                Text("This transaction is no longer available.", bundle: .module)
                    .immFont(CompanionFont.callout)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
        }
        .navigationTitle(Text("Transaction", bundle: .module))
        .companionInlineTitle()
        #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
        #endif
        .task { await load() }
        .onChange(of: noteFocused) { _, focused in
            if !focused { Task { await saveNoteIfNeeded() } }
        }
        .onDisappear { Task { await saveNoteIfNeeded() } }
        .alert(
            Text("Couldn't save", bundle: .module),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button { errorMessage = nil } label: { Text("OK", bundle: .module) }
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    // MARK: Sections

    private func header(_ transaction: CompanionTransaction) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: CompanionFormat.money(transaction.amount, currency: transaction.currency, sign: .always))
                    .immFont(CompanionFont.hero)
                    .foregroundStyle(CompanionColor.amount(transaction.amount))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(verbatim: transaction.counterparty.isEmpty ? "—" : transaction.counterparty)
                    .immFont(CompanionFont.headline)
                    .foregroundStyle(IMMColor.foreground)
                HStack(spacing: 8) {
                    CategoryMarker(name: selectedCategory?.name, colorToken: selectedCategory?.colorToken)
                    if transaction.isPending { PendingBadge() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
        }
    }

    private func details(_ detail: CompanionTransactionDetail) -> some View {
        Section {
            DetailRow(label: "Booked") { Text(verbatim: DateFormats.dayMonthYear(detail.transaction.bookingDate)) }
            DetailRow(label: "Value date") { Text(verbatim: DateFormats.dayMonthYear(detail.valueDate)) }
            DetailRow(label: "Account") { Text(verbatim: detail.accountName) }
            if let iban = detail.counterpartyIBAN, !iban.isEmpty {
                DetailRow(label: "IBAN") {
                    Text(verbatim: iban).immFont(CompanionFont.mono).textSelection(.enabled)
                }
            }
            if !detail.bookingText.isEmpty {
                DetailRow(label: "Booking text") { Text(verbatim: detail.bookingText) }
            }
        } header: {
            sectionLabel("Details")
        }
        .listRowBackground(IMMColor.muted)
    }

    private var editing: some View {
        Group {
            Section {
                Picker(selection: categoryBinding) {
                    Text("None", bundle: .module).tag(String?.none)
                    ForEach(model.categories) { category in
                        Text(verbatim: category.name).tag(Optional(category.id))
                    }
                } label: {
                    Text("Category", bundle: .module)
                }
                .immFont(CompanionFont.callout)
            }
            .listRowBackground(IMMColor.muted)
            Section {
                TextField(
                    "", text: $note, prompt: Text("Add a note", bundle: .module), axis: .vertical
                )
                .lineLimit(1...6)
                .focused($noteFocused)
                .immFont(CompanionFont.callout)
            } header: {
                sectionLabel("Note")
            }
            .listRowBackground(IMMColor.muted)
        }
    }

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .immFont(CompanionFont.footnoteSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .textCase(nil)
    }

    // MARK: Data

    private var selectedCategory: CompanionCategory? {
        guard let categoryID else { return nil }
        return model.categories.first { $0.id == categoryID }
    }

    private var categoryBinding: Binding<String?> {
        Binding(
            get: { categoryID },
            set: { newValue in
                let previous = categoryID
                guard newValue != previous else { return }
                categoryID = newValue
                Task {
                    do {
                        try await model.setCategory(newValue, transactionID: transactionID)
                    } catch {
                        categoryID = previous
                        errorMessage = error.localizedDescription
                    }
                }
            }
        )
    }

    private func load() async {
        let result = await model.detail(transactionID: transactionID)
        detail = result
        categoryID = result?.categoryID
        note = result?.note ?? ""
        savedNote = note
        loaded = true
    }

    private func saveNoteIfNeeded() async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, detail != nil, trimmed != savedNote else { return }
        do {
            try await model.setNote(trimmed, transactionID: transactionID)
            savedNote = trimmed
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Label on the left, value on the right (wraps for long values).
private struct DetailRow<Value: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label, bundle: .module)
                .immFont(CompanionFont.callout)
                .foregroundStyle(IMMColor.mutedForeground)
            Spacer(minLength: 12)
            value
                .immFont(CompanionFont.callout)
                .foregroundStyle(IMMColor.foreground)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview("Transaction detail") {
    NavigationStack { TransactionDetailView(transactionID: "tx-3") }
        .environment(CompanionModel.preview(.ready))
}
