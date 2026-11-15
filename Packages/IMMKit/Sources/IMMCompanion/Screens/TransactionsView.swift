import IMMDesign
import IMMLedger
import SwiftUI

/// Searchable list of bookings, newest first, grouped by day. `accountID` limits it to one account;
/// `uncategorisedOnly` keeps the bookings without a category.
struct TransactionsView: View {
    @Environment(CompanionModel.self) private var model
    private let accountID: String?
    private let uncategorisedOnly: Bool

    @State private var rows: [CompanionTransaction] = []
    @State private var search = ""
    @State private var loaded = false

    init(accountID: String? = nil, uncategorisedOnly: Bool = false) {
        self.accountID = accountID
        self.uncategorisedOnly = uncategorisedOnly
    }

    /// Reload when the search text changes or a sync finishes.
    private struct LoadKey: Equatable {
        var search: String
        var status: CompanionSyncStatus
    }

    private struct DayGroup: Identifiable {
        var date: LocalDate
        var rows: [CompanionTransaction]
        var id: LocalDate { date }
    }

    private var groups: [DayGroup] {
        var result: [DayGroup] = []
        for row in rows {
            if let last = result.last, last.date == row.bookingDate {
                result[result.count - 1].rows.append(row)
            } else {
                result.append(DayGroup(date: row.bookingDate, rows: [row]))
            }
        }
        return result
    }

    private var title: Text {
        if let accountID, let account = model.accounts.first(where: { $0.id == accountID }) {
            return Text(verbatim: account.name)
        }
        if uncategorisedOnly { return Text("Uncategorised", bundle: .module) }
        return Text("Transactions", bundle: .module)
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        NavigationLink {
                            TransactionDetailView(transactionID: row.id)
                        } label: {
                            TransactionRow(transaction: row)
                        }
                    }
                } header: {
                    Text(verbatim: CompanionFormat.dayTitle(group.date))
                        .immFont(CompanionFont.footnoteSemibold)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .textCase(nil)
                }
            }
        }
        .companionPlainList()
        .overlay {
            if loaded && rows.isEmpty {
                Group {
                    if search.isEmpty {
                        Text("No transactions.", bundle: .module)
                    } else {
                        Text("No matches.", bundle: .module)
                    }
                }
                .immFont(CompanionFont.callout)
                .foregroundStyle(IMMColor.mutedForeground)
            }
        }
        .searchable(text: $search, prompt: Text("Search transactions", bundle: .module))
        .refreshable { await model.syncNow() }
        .task(id: LoadKey(search: search, status: model.syncStatus)) { await load() }
        .navigationTitle(title)
        .companionInlineTitle()
    }

    private func load() async {
        if !search.isEmpty {
            // Debounce typing; a newer search cancels this task.
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
        var result = await model.transactions(accountID: accountID, search: search)
        if uncategorisedOnly { result = result.filter { $0.categoryName == nil } }
        if Task.isCancelled { return }
        rows = result
        loaded = true
    }
}

#Preview("Transactions") {
    NavigationStack { TransactionsView() }
        .environment(CompanionModel.preview(.ready))
}
