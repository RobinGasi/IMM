import GRDB
import IMMLedger
@testable import IMMUI
import Testing

/// The inspector and Suggestions edits write through `LedgerWriter` (op log + field clock) and the screens'
/// models follow. Every test works on its own vault; the shared fixture stays untouched.
@MainActor
@Suite struct EditTests {
    /// Blocking read (a plain function picks GRDB's synchronous overload; async tests would pick the async one).
    private func read<T>(_ store: LedgerStore, _ body: (Database) throws -> T) throws -> T {
        try store.database.read(body)
    }

    private func opCount(_ store: LedgerStore, table: String, rowID: String, column: String) throws -> Int {
        try read(store) {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_op WHERE tbl = ? AND row_id = ? AND col = ?", arguments: [table, rowID, column]) ?? 0
        }
    }

    private func hasFieldClock(_ store: LedgerStore, table: String, rowID: String, column: String) throws -> Bool {
        try read(store) {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM field_clock WHERE tbl = ? AND row_id = ? AND col = ?", arguments: [table, rowID, column]) == 1
        }
    }

    private func categoryID(_ store: LedgerStore, _ name: String) throws -> String {
        try read(store) { try #require(try CategoryRecord.live().filter(Column("name") == name).fetchOne($0)).id }
    }

    /// A model over all accounts and all time, following the ledger until the returned task is cancelled.
    private func startedModel(_ store: LedgerStore) async throws -> (TransactionsModel, Task<Void, Never>) {
        let model = TransactionsModel(filter: TransactionFilter(scope: .all, period: .allTime))
        let task = Task { await model.observe(store) }
        for _ in 0..<200 where model.snapshot == nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.snapshot != nil)
        return (model, task)
    }

    private func item(_ model: TransactionsModel, payee: String, categorised: Bool) throws -> TransactionItem {
        try #require(model.snapshot?.items.first { $0.payee == payee && ($0.categoryID != nil) == categorised })
    }

    @Test func categorySelectWritesThroughTheLedger() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let store = fixture.store
        let (model, task) = try await startedModel(store)
        defer { task.cancel() }

        let amazon = try item(model, payee: "Amazon EU S.a.r.l.", categorised: false)
        let uncategorisedBefore = try read(store) { try LedgerDefinitions.uncategorisedCount($0) }
        let health = try categoryID(store, "Health & drugstore")
        model.selection = amazon.id

        let before = try opCount(store, table: "ledger_transaction", rowID: amazon.id, column: "category_id")
        try model.setCategory(health, of: amazon.id, ledger: store)

        #expect(model.selectedItem?.categoryID == health)
        let stored = try read(store) { try String.fetchOne($0, sql: "SELECT category_id FROM ledger_transaction WHERE id = ?", arguments: [amazon.id]) }
        #expect(stored == health)
        #expect(try opCount(store, table: "ledger_transaction", rowID: amazon.id, column: "category_id") == before + 1)
        #expect(try hasFieldClock(store, table: "ledger_transaction", rowID: amazon.id, column: "category_id"))
        #expect(try read(store) { try LedgerDefinitions.uncategorisedCount($0) } == uncategorisedBefore - 1)

        // "Without category" clears it again.
        try model.setCategory(nil, of: amazon.id, ledger: store)
        #expect(model.selectedItem?.categoryID == nil)
        #expect(try opCount(store, table: "ledger_transaction", rowID: amazon.id, column: "category_id") == before + 2)
        #expect(try read(store) { try LedgerDefinitions.uncategorisedCount($0) } == uncategorisedBefore)
    }

    @Test func noteIsStoredAndClearedThroughTheLedger() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let store = fixture.store
        let (model, task) = try await startedModel(store)
        defer { task.cancel() }

        let row = try item(model, payee: "Amazon EU S.a.r.l.", categorised: false)
        model.selection = row.id
        try model.setNote("Birthday present", of: row.id, ledger: store)

        #expect(model.selectedItem?.note == "Birthday present")
        let stored = try read(store) { try String.fetchOne($0, sql: "SELECT note FROM ledger_transaction WHERE id = ?", arguments: [row.id]) }
        #expect(stored == "Birthday present")
        #expect(try opCount(store, table: "ledger_transaction", rowID: row.id, column: "note") == 1)
        #expect(try hasFieldClock(store, table: "ledger_transaction", rowID: row.id, column: "note"))

        try model.setNote(nil, of: row.id, ledger: store)
        #expect(model.selectedItem?.note == nil)
        #expect(try opCount(store, table: "ledger_transaction", rowID: row.id, column: "note") == 2)
    }

    @Test func ruleCheckboxTogglesTheRuleAndFilesMatchingTransactions() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let store = fixture.store
        let (model, task) = try await startedModel(store)
        defer { task.cancel() }

        // Apotheke am Neumarkt has a demo rule and one uncategorised Visa booking.
        let filed = try item(model, payee: "Apotheke am Neumarkt", categorised: true)
        let open = try item(model, payee: "Apotheke am Neumarkt", categorised: false)
        model.selection = filed.id
        await model.loadRuleInfo(store)
        #expect(model.ruleInfo?.ruleExists == true)

        // Off: the rule is disabled through the writer, nothing else changes.
        try model.setRule(false, ledger: store)
        #expect(model.ruleInfo?.ruleExists == false)
        let rule = try read(store) {
            try #require(try RuleRecord.live().filter(Column("pattern") == "Apotheke am Neumarkt").fetchOne($0))
        }
        #expect(!(try read(store) { try #require(try RuleRecord.fetchOne($0, key: rule.id)).enabled }))
        #expect(try opCount(store, table: "rule", rowID: rule.id, column: "enabled") == 1)
        #expect(try hasFieldClock(store, table: "rule", rowID: rule.id, column: "enabled"))
        #expect(try read(store) { try String.fetchOne($0, sql: "SELECT category_id FROM ledger_transaction WHERE id = ?", arguments: [open.id]) } == nil)

        // On: the rule is enabled again and the payee's uncategorised booking is filed under the category.
        try model.setRule(true, ledger: store)
        #expect(model.ruleInfo?.ruleExists == true)
        #expect(try read(store) { try String.fetchOne($0, sql: "SELECT category_id FROM ledger_transaction WHERE id = ?", arguments: [open.id]) } == filed.categoryID)
        #expect(try opCount(store, table: "ledger_transaction", rowID: open.id, column: "category_id") == 1)
    }

    @Test func ruleCheckboxAddsAManualRuleForAnUncoveredPayee() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let store = fixture.store
        let (model, task) = try await startedModel(store)
        defer { task.cancel() }

        let row = try item(model, payee: "Trattoria Da Marco", categorised: true)
        model.selection = row.id
        await model.loadRuleInfo(store)
        #expect(model.ruleInfo?.ruleExists == false)
        let rulesBefore = try read(store) { try RuleRecord.live().fetchCount($0) }

        try model.setRule(true, ledger: store)

        #expect(model.ruleInfo?.ruleExists == true)
        let rules = try read(store) { try RuleRecord.live().filter(Column("pattern") == "Trattoria Da Marco").fetchAll($0) }
        let added = try #require(rules.first)
        #expect(rules.count == 1)
        #expect(added.categoryId == row.categoryID)
        #expect(added.origin == .manual)
        #expect(added.enabled)
        #expect(try read(store) { try RuleRecord.live().fetchCount($0) } == rulesBefore + 1)
        #expect(try read(store) {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_op WHERE tbl = 'rule' AND row_id = ? AND kind = 'insert'", arguments: [added.id])
        } == 1)
    }

    @Test func acceptingTheSureSuggestionsLeavesTheOthers() throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let store = fixture.store
        let before = try read(store, SuggestionsQueries.snapshot)
        #expect(before.rows.count == 6)
        #expect(before.sureCount == 3)
        let sure = before.rows.filter { $0.confidence == .sure }
        #expect(sure.allSatisfy { $0.suggestedCategoryID != nil })

        try SuggestionsEdits.accept(sure, writer: store.writer)

        let after = try read(store, SuggestionsQueries.snapshot)
        #expect(after.rows.count == 3)
        #expect(after.sureCount == 0)
        #expect(Set(after.rows.map(\.id)) == Set(before.rows.filter { $0.confidence != .sure }.map(\.id)))
        for row in sure {
            let stored = try read(store) { try String.fetchOne($0, sql: "SELECT category_id FROM ledger_transaction WHERE id = ?", arguments: [row.id]) }
            #expect(stored == row.suggestedCategoryID)
            #expect(try opCount(store, table: "ledger_transaction", rowID: row.id, column: "category_id") == 1)
            #expect(try hasFieldClock(store, table: "ledger_transaction", rowID: row.id, column: "category_id"))
        }
        // The sidebar's uncategorised count follows the same rows.
        #expect(try read(store) { try LedgerDefinitions.uncategorisedCount($0) } == 3)
    }

    @Test func acceptAndChangeFileOneRow() throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let store = fixture.store
        let before = try read(store, SuggestionsQueries.snapshot)
        let row = try #require(before.rows.first { $0.confidence == .check })
        let groceries = try #require(before.categories.first { $0.name == "Groceries" })

        // Change: the chosen category wins over the suggestion.
        try SuggestionsEdits.file([row.id], under: groceries.id, writer: store.writer)
        let after = try read(store, SuggestionsQueries.snapshot)
        #expect(!after.rows.contains { $0.id == row.id })
        #expect(after.rows.count == before.rows.count - 1)
        let stored = try read(store) { try String.fetchOne($0, sql: "SELECT category_id FROM ledger_transaction WHERE id = ?", arguments: [row.id]) }
        #expect(stored == groceries.id)

        // Accept: the suggested category.
        let next = try #require(after.rows.first)
        try SuggestionsEdits.accept([next], writer: store.writer)
        let final = try read(store, SuggestionsQueries.snapshot)
        #expect(!final.rows.contains { $0.id == next.id })
        let nextStored = try read(store) { try String.fetchOne($0, sql: "SELECT category_id FROM ledger_transaction WHERE id = ?", arguments: [next.id]) }
        #expect(nextStored == next.suggestedCategoryID)
    }
}
