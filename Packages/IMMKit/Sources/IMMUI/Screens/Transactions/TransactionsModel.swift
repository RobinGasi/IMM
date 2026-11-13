import Foundation
import IMMLedger
import Observation

/// State of one Transactions screen: the filter, the observed list, the selected row (the inspector
/// shows it) and the rule info of the selection. A new instance is created per account scope.
@MainActor @Observable
final class TransactionsModel {
    var filter: TransactionFilter
    private(set) var snapshot: TransactionListSnapshot?
    /// Transaction id of the selected row; the inspector is open while it names a listed row.
    var selection: String?
    private(set) var ruleInfo: TransactionRuleInfo?

    /// A selection requested by a deep link that has not been found in the list yet.
    @ObservationIgnored private var wanted: String?

    init(filter: TransactionFilter, selection: String? = nil) {
        self.filter = filter
        self.selection = selection
    }

    var selectedItem: TransactionItem? {
        guard let selection, let snapshot else { return nil }
        return snapshot.items.first { $0.id == selection }
    }

    var isInspectorOpen: Bool { selectedItem != nil }

    /// Selects `id` as soon as it is listed; widens the filter to everything when the current one hides it.
    func requestSelection(_ id: String) {
        wanted = id
        guard let snapshot else { return }
        resolveWanted(in: snapshot)
    }

    /// Selects the wanted row when listed; otherwise widens the filter once so the next list can contain it.
    private func resolveWanted(in value: TransactionListSnapshot) {
        guard let id = wanted else { return }
        if value.items.contains(where: { $0.id == id }) {
            selection = id
            wanted = nil
        } else if value.filter.period != .allTime || value.filter.direction != .all || value.filter.category != .all {
            filter.period = .allTime
            filter.direction = .all
            filter.category = .all
        } else {
            wanted = nil
        }
    }

    func clearSelection() {
        selection = nil
        wanted = nil
    }

    /// Loads the list for the current filter, then keeps it current until the task is cancelled.
    /// Run from `.task(id: filter)`.
    func observe(_ ledger: LedgerStore) async {
        let current = filter
        if let initial = Self.readNow(ledger, filter: current) {
            apply(initial)
        }
        do {
            for try await value in TransactionQueries.observe(in: ledger, filter: current) {
                try Task.checkCancellation()
                apply(value)
            }
        } catch {
            // Cancelled (filter change, screen left) or the database was closed (lock).
        }
    }

    /// Reads the rule info of the selected transaction. Run from `.task(id: selection)`.
    func loadRuleInfo(_ ledger: LedgerStore) async {
        guard let item = selectedItem else {
            ruleInfo = nil
            return
        }
        ruleInfo = Self.readRuleInfoNow(ledger, item: item)
    }

    // MARK: Edits (through the ledger writer)

    /// Files `id` under `categoryID` (nil clears it) and re-reads the list at once.
    func setCategory(_ categoryID: String?, of id: String, ledger: LedgerStore) throws {
        guard snapshot?.items.first(where: { $0.id == id })?.categoryID != categoryID else { return }
        try ledger.writer.setCategory(transactionID: id, categoryID: categoryID)
        refresh(ledger)
    }

    func setNote(_ note: String?, of id: String, ledger: LedgerStore) throws {
        try ledger.writer.setNote(transactionID: id, note: note)
        refresh(ledger)
    }

    /// Turns "Always file <payee> under <category>" on or off for the selected transaction. On: stores a
    /// manual rule for the payee and files the payee's other uncategorised bookings under the category.
    /// Off: disables the rules that file this payee under the category.
    func setRule(_ on: Bool, ledger: LedgerStore) throws {
        guard let item = selectedItem, let category = item.categoryID else { return }
        let writer = ledger.writer
        if on {
            try writer.addRule(pattern: item.payee, categoryID: category, origin: .manual)
            let ids = try ledger.database.read { try TransactionQueries.uncategorisedMatches($0, pattern: item.payee) }
            if !ids.isEmpty { try writer.setCategory(transactionIDs: ids, categoryID: category) }
        } else {
            let ids = try ledger.database.read { try TransactionQueries.matchingRuleIDs($0, item: item) }
            for id in ids { try writer.setRule(id: id, enabled: false) }
        }
        refresh(ledger)
    }

    /// Reads the list and the selection's rule info now instead of waiting for the observation.
    private func refresh(_ ledger: LedgerStore) {
        if let value = Self.readNow(ledger, filter: filter) { apply(value) }
        ruleInfo = selectedItem.flatMap { Self.readRuleInfoNow(ledger, item: $0) }
    }

    // Synchronous reads (a non-async context picks GRDB's blocking overload): the first frame already shows data.
    private static func readNow(_ ledger: LedgerStore, filter: TransactionFilter) -> TransactionListSnapshot? {
        try? ledger.database.read { try TransactionQueries.snapshot($0, filter: filter) }
    }

    private static func readRuleInfoNow(_ ledger: LedgerStore, item: TransactionItem) -> TransactionRuleInfo? {
        try? ledger.database.read { try TransactionQueries.ruleInfo($0, item: item) }
    }

    private func apply(_ value: TransactionListSnapshot) {
        guard value.filter == filter else { return }
        snapshot = value
        if wanted != nil {
            resolveWanted(in: value)
            return
        }
        if let selection, !value.items.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }
}
