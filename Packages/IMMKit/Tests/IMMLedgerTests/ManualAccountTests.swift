import Foundation
import GRDB
import Testing
@testable import IMMLedger

@Suite struct ManualAccountTests {
    private func makeAccount(
        _ replica: Replica, name: String = "Wallet", kind: AccountKind = .wallet, opening: Int = 12_345
    ) throws -> String {
        try replica.database.write { db in
            try replica.writer.createManualAccount(
                ManualAccountInput(name: name, kind: kind, openingBalance: opening), now: Date(), in: db)
        }
    }

    @discardableResult
    private func book(
        _ replica: Replica, _ account: String, _ day: String, _ amount: Int, counterparty: String = "Bakery",
        category: String? = nil, note: String? = nil
    ) throws -> String {
        try replica.database.write { db in
            try replica.writer.addManualBooking(
                ManualBookingInput(
                    accountID: account, bookingDate: d(day), amount: amount, counterparty: counterparty, purpose: "Rolls",
                    categoryID: category, note: note),
                now: Date(), in: db)
        }
    }

    private func account(_ replica: Replica, _ id: String) throws -> AccountRecord {
        try #require(try replica.database.read { try AccountRecord.fetchOne($0, key: id) })
    }

    private func balance(_ replica: Replica, _ id: String) throws -> Int { try account(replica, id).balance }

    /// Opening balance plus the live bookings: what the stored balance must equal.
    private func expectedBalance(_ replica: Replica, _ id: String, opening: Int) throws -> Int {
        let sum = try replica.database.read {
            try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(amount), 0) FROM ledger_transaction WHERE account_id = ? AND deleted_at IS NULL", arguments: [id]) ?? 0
        }
        return opening + sum
    }

    @Test func createdAccountIsRecognisableAndHasNoBankLogin() throws {
        let replica = try Replica()
        let id = try makeAccount(replica, name: "Cash", kind: .wallet, opening: 5_000)
        let record = try account(replica, id)
        #expect(id.hasPrefix("manual-") && id == id.lowercased())
        #expect(record.isManual)
        #expect(record.name == "Cash" && record.kind == .wallet && record.balance == 5_000)
        #expect(record.bankName == "" && record.subtitle == nil && record.currency == "EUR")
        #expect(record.overdraftLimit == 0 && record.syncStatus == .never && record.lastSyncedAt == nil)
        #expect(record.bankLoginId == nil && record.connectorAccountId == nil)
        #expect(!AccountRecord(id: "acc-1", kind: .giro, name: "x", balance: 0).isManual)
    }

    @Test func newAccountsSortAfterTheExistingOnes() throws {
        let replica = try Replica()
        try replica.writer.insertImmutable(table: "account", row: accountRow("bank-1").merging(["sort_order": SyncValue(4)]) { $1 })
        let first = try makeAccount(replica, name: "A")
        let second = try makeAccount(replica, name: "B")
        #expect(try account(replica, first).sortOrder == 5)
        #expect(try account(replica, second).sortOrder == 6)
        let empty = try Replica()
        #expect(try account(empty, try makeAccount(empty)).sortOrder == 0)
    }

    @Test func bookingsMoveTheBalanceAndKeepTheInvariant() throws {
        let replica = try Replica()
        let id = try makeAccount(replica, opening: 10_000)
        let income = try book(replica, id, "2026-11-02", 2_500, counterparty: "Aunt Meg")
        let expense = try book(replica, id, "2026-11-03", -1_299, category: nil, note: "treat")
        let later = try book(replica, id, "2026-11-03", -101)

        #expect(try balance(replica, id) == 10_000 + 2_500 - 1_299 - 101)
        #expect(try balance(replica, id) == expectedBalance(replica, id, opening: 10_000))

        let row = try #require(try replica.database.read { try TransactionRecord.fetchOne($0, key: expense) })
        #expect(row.accountId == id && row.amount == -1_299 && row.currency == "EUR")
        #expect(row.bookingDate == d("2026-11-03") && row.valueDate == d("2026-11-03"))
        #expect(row.counterpartyName == "Bakery" && row.shortName == "Bakery" && row.purpose == "Rolls")
        #expect(row.bookingText == "" && row.note == "treat" && row.isNew == false && row.isOwnTransfer == false)
        #expect(row.bankRefKind == "manual" && row.bankRef == expense)
        #expect(UUID(uuidString: expense) != nil)

        // Intra-day order: the second booking of a day is the newer one.
        let seqs = try replica.database.read {
            try Int.fetchAll($0, sql: "SELECT booking_seq FROM ledger_transaction WHERE id IN (?, ?) ORDER BY booking_seq", arguments: [expense, later])
        }
        #expect(seqs == [1, 2])

        // Running balances count backwards from the stored balance; the oldest row lands on opening + its amount.
        let running = try replica.database.read { try LedgerDefinitions.runningBalances($0, accountID: id) }
        #expect(running[later] == 10_000 + 2_500 - 1_299 - 101)
        #expect(running[expense] == 10_000 + 2_500 - 1_299)
        #expect(running[income] == 10_000 + 2_500)

        // Net worth moves with the bookings, and a day before the first booking shows the opening balance.
        let netWorth = try replica.database.read { try LedgerDefinitions.netWorth($0) }
        #expect(netWorth == 10_000 + 2_500 - 1_299 - 101)
        #expect(try replica.database.read { try LedgerDefinitions.netWorth($0, on: d("2026-11-01")) } == 10_000)
    }

    @Test func categoryIsStoredWhenGiven() throws {
        let replica = try Replica()
        try replica.writer.insertImmutable(table: "category", row: categoryRow("c1"))
        let id = try makeAccount(replica)
        let booking = try book(replica, id, "2026-11-02", -500, category: "c1")
        #expect(try replica.value("ledger_transaction", booking, "category_id") == .text("c1"))
    }

    @Test func deletingReversesTheBalanceOnce() throws {
        let replica = try Replica()
        let id = try makeAccount(replica, opening: 1_000)
        let keep = try book(replica, id, "2026-11-02", 400)
        let gone = try book(replica, id, "2026-11-03", -250)
        #expect(try balance(replica, id) == 1_150)

        try replica.database.write { try replica.writer.deleteManualBooking(id: gone, now: Date(), in: $0) }
        #expect(try balance(replica, id) == 1_400)
        #expect(try replica.value("ledger_transaction", gone, "deleted_at")?.isNull == false)
        #expect(try replica.value("ledger_transaction", keep, "deleted_at")?.isNull == true)
        #expect(try balance(replica, id) == expectedBalance(replica, id, opening: 1_000))

        // A second delete changes nothing, neither the balance nor the op log.
        let ops = try replica.ownOps().count
        try replica.database.write { try replica.writer.deleteManualBooking(id: gone, now: Date(), in: $0) }
        #expect(try balance(replica, id) == 1_400)
        #expect(try replica.ownOps().count == ops)

        // The deleted row leaves the running balances.
        let running = try replica.database.read { try LedgerDefinitions.runningBalances($0, accountID: id) }
        #expect(Set(running.keys) == [keep] && running[keep] == 1_400)
    }

    @Test func bankRowsAndAccountsAreRefused() throws {
        let replica = try Replica()
        try replica.writer.insertImmutable(table: "account", row: accountRow("bank-1", balance: 9_000))
        try replica.writer.insertImmutable(table: "ledger_transaction", row: transactionRow("bank-tx", account: "bank-1", amount: -100))
        let manual = try makeAccount(replica, opening: 100)
        let ops = try replica.ownOps().count

        #expect(throws: ManualLedgerError.notManual(id: "bank-1")) {
            try replica.database.write { db in
                try replica.writer.addManualBooking(
                    ManualBookingInput(accountID: "bank-1", bookingDate: d("2026-11-02"), amount: 50, counterparty: "x"), now: Date(), in: db)
            }
        }
        #expect(throws: ManualLedgerError.notManual(id: "bank-tx")) {
            try replica.database.write { try replica.writer.deleteManualBooking(id: "bank-tx", now: Date(), in: $0) }
        }
        #expect(throws: ManualLedgerError.noSuchBooking(id: "missing")) {
            try replica.database.write { try replica.writer.deleteManualBooking(id: "missing", now: Date(), in: $0) }
        }
        #expect(throws: ManualLedgerError.noSuchAccount(id: "manual-missing")) {
            try replica.database.write { db in
                try replica.writer.addManualBooking(
                    ManualBookingInput(accountID: "manual-missing", bookingDate: d("2026-11-02"), amount: 50, counterparty: "x"), now: Date(), in: db)
            }
        }
        #expect(try balance(replica, "bank-1") == 9_000)
        #expect(try balance(replica, manual) == 100)
        #expect(try replica.value("ledger_transaction", "bank-tx", "deleted_at")?.isNull == true)
        #expect(try replica.ownOps().count == ops)
    }

    @Test func aFailedWriteLeavesNoPartialBooking() throws {
        let replica = try Replica()
        let id = try makeAccount(replica, opening: 100)
        let ops = try replica.ownOps().count
        // An unknown category violates the foreign key after the booking row went in; the whole write rolls back.
        #expect(throws: (any Error).self) {
            try book(replica, id, "2026-11-02", -10, category: "no-such-category")
        }
        #expect(try balance(replica, id) == 100)
        #expect(try replica.count("ledger_transaction") == 0)
        #expect(try replica.ownOps().count == ops)
    }

    @Test func accountAndBookingsProduceSyncOpsAndReachOtherDevices() throws {
        let replica = try Replica()
        let id = try makeAccount(replica, opening: 2_000)
        let booking = try book(replica, id, "2026-11-04", -750)
        let gone = try book(replica, id, "2026-11-05", 100)
        try replica.database.write { try replica.writer.deleteManualBooking(id: gone, now: Date(), in: $0) }

        let ops = try replica.ownOps()
        #expect(ops.map(\.seq) == Array(1...Int64(ops.count)))
        let accountInsert = try #require(ops.first { $0.kind == .insert && $0.table == "account" && $0.rowID == id })
        let accountRow = try #require(accountInsert.row)
        #expect(accountRow["balance"] == .integer(2_000) && accountRow["name"] == .text("Wallet") && accountRow["kind"] == .text("wallet"))
        #expect(accountRow["bank_login_id"] == nil && accountRow["connector_account_id"] == nil)
        let bookingInsert = try #require(ops.first { $0.kind == .insert && $0.table == "ledger_transaction" && $0.rowID == booking })
        let bookingRow = try #require(bookingInsert.row)
        #expect(bookingRow["bank_ref_kind"] == .text("manual") && bookingRow["bank_ref"] == .text(booking))
        #expect(bookingRow["amount"] == .integer(-750) && bookingRow["account_id"] == .text(id))
        let balanceSets = ops.filter { $0.kind == .set && $0.table == "account" && $0.column == "balance" }
        #expect(balanceSets.map(\.value) == [.integer(1_250), .integer(1_350), .integer(1_250)])
        #expect(ops.contains { $0.kind == .delete && $0.table == "ledger_transaction" && $0.rowID == gone })

        // Field clocks exist for the editable columns, like for any other write.
        let clocked = try replica.database.read {
            try String.fetchAll($0, sql: "SELECT col FROM field_clock WHERE tbl = 'account' AND row_id = ? ORDER BY col", arguments: [id])
        }
        #expect(clocked.contains("balance") && clocked.contains("name") && clocked.contains("sort_order"))

        // Another device that applies the ops ends up with the same account, bookings and balance.
        let other = try Replica()
        try other.writer.applyRemote(ops)
        #expect(try other.value("account", id, "balance") == .integer(1_250))
        #expect(try other.value("account", id, "name") == .text("Wallet"))
        #expect(try other.value("ledger_transaction", booking, "bank_ref_kind") == .text("manual"))
        #expect(try other.value("ledger_transaction", gone, "deleted_at")?.isNull == false)
        let mirrored = try other.database.read { try AccountRecord.fetchOne($0, key: id) }
        #expect(mirrored?.isManual == true)
    }
}
