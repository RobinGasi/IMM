import Foundation
import GRDB
import Testing
@testable import IMMLedger

@Suite struct WriterTests {
    private func seeded() throws -> Replica {
        let replica = try Replica()
        let writer = replica.writer
        try writer.insertImmutable(table: "category", row: categoryRow("c1", name: "Groceries"))
        try writer.insertImmutable(table: "account", row: accountRow("a1"))
        try writer.insertImmutable(table: "ledger_transaction", row: transactionRow("t1", account: "a1", isNew: true))
        return replica
    }

    @Test func localSetWritesRowClockAndOpTogether() throws {
        let replica = try seeded()
        replica.clock.advance(by: 10)
        try replica.writer.set(table: "category", rowID: "c1", column: "name", to: .text("Food"))

        #expect(try replica.value("category", "c1", "name") == .text("Food"))
        let ops = try replica.ownOps()
        #expect(ops.map(\.seq) == [1, 2, 3, 4])                       // gap-free from 1
        let set = try #require(ops.last)
        #expect(set.kind == .set && set.table == "category" && set.rowID == "c1" && set.column == "name" && set.value == .text("Food"))
        #expect(ops == ops.sorted { $0.hlc < $1.hlc })                 // clocks climb with seq
        #expect(Set(ops.map(\.hlc)).count == ops.count)

        let clock = try replica.database.read {
            try Data.fetchOne($0, sql: "SELECT hlc FROM field_clock WHERE tbl = 'category' AND row_id = 'c1' AND col = 'name'")
        }
        #expect(HLC(bytes: try #require(clock)) == set.hlc)
        // The stored clock state is at least the last op.
        let state = try replica.database.read { try Data.fetchOne($0, sql: "SELECT hlc FROM hlc_state") }
        #expect(HLC(bytes: try #require(state))! >= set.hlc)
        #expect(set.hlc.node == replica.node)
    }

    @Test func settingTheSameValueWritesNothing() throws {
        let replica = try seeded()
        let before = try replica.ownOps().count
        try replica.writer.set(table: "category", rowID: "c1", column: "name", to: .text("Groceries"))
        #expect(try replica.ownOps().count == before)
    }

    @Test func severalColumnsTickTheClockOncePerColumn() throws {
        let replica = try seeded()
        try replica.writer.set(table: "category", rowID: "c1", values: ["name": .text("Food"), "color_token": .text("chart-2")])
        let ops = try replica.ownOps().suffix(2)
        #expect(Set(ops.map { $0.column ?? "" }) == ["name", "color_token"])
        #expect(Set(ops.map(\.hlc)).count == 2)
    }

    @Test func registryIsEnforcedOnLocalWrites() throws {
        let replica = try seeded()
        let writer = replica.writer
        #expect(throws: LedgerWriterError.unknownTable("bank_login")) {
            try writer.set(table: "bank_login", rowID: "x", column: "bank_name", to: .text("x"))
        }
        #expect(throws: LedgerWriterError.unknownColumn(table: "category", column: "bogus")) {
            try writer.set(table: "category", rowID: "c1", column: "bogus", to: .text("x"))
        }
        #expect(throws: LedgerWriterError.immutableColumn(table: "ledger_transaction", column: "amount")) {
            try writer.set(table: "ledger_transaction", rowID: "t1", column: "amount", to: .integer(1))
        }
        #expect(throws: LedgerWriterError.noSuchRow(table: "category", id: "nope")) {
            try writer.set(table: "category", rowID: "nope", column: "name", to: .text("x"))
        }
        #expect(throws: LedgerWriterError.notShared("auto_lock_minutes")) {
            try writer.setSetting(.autoLockMinutes, "5")
        }
        // deleted_at is the register of `delete`, not a settable column.
        #expect(throws: LedgerWriterError.unknownColumn(table: "category", column: "deleted_at")) {
            try writer.set(table: "category", rowID: "c1", column: "deleted_at", to: .null)
        }
    }

    @Test func aFailedTransactionLeavesNoTrace() throws {
        let replica = try seeded()
        let opsBefore = try replica.ownOps().count
        let stateBefore = try replica.database.read { try Data.fetchOne($0, sql: "SELECT hlc FROM hlc_state") }
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try replica.database.write { db in
                try replica.writer.set(table: "category", rowID: "c1", column: "name", to: .text("Lost"), in: db)
                try replica.writer.insertImmutable(table: "category", row: categoryRow("c2"), in: db)
                throw Boom()
            }
        }
        #expect(try replica.value("category", "c1", "name") == .text("Groceries"))
        #expect(try replica.count("category") == 1)
        #expect(try replica.ownOps().count == opsBefore)
        #expect(try replica.database.read { try Data.fetchOne($0, sql: "SELECT hlc FROM hlc_state") } == stateBefore)
        #expect(try replica.count("field_clock", where: "row_id = 'c2'") == 0)
    }

    @Test func insertImmutableIgnoresDuplicatesIncludingTombstones() throws {
        let replica = try seeded()
        let ops = try replica.ownOps().count
        #expect(try replica.writer.insertImmutable(table: "category", row: categoryRow("c1", name: "Other")) == false)
        try replica.writer.delete(table: "category", rowID: "c1")
        #expect(try replica.writer.insertImmutable(table: "category", row: categoryRow("c1", name: "Reborn")) == false)
        #expect(try replica.value("category", "c1", "name") == .text("Groceries"))
        #expect(try replica.ownOps().count == ops + 1)    // only the delete
    }

    @Test func nullColumnsAreLeftOutOfInsertOps() throws {
        let replica = try seeded()
        let insert = try #require(try replica.ownOps().first { $0.rowID == "t1" })
        #expect(insert.kind == .insert)
        let row = try #require(insert.row)
        #expect(row["category_id"] == nil && row["note"] == nil)
        #expect(row["id"] == .text("t1") && row["amount"] == .integer(-100))
        // Only the LWW columns get clocks; identity columns do not.
        let clocked = try replica.database.read {
            try String.fetchAll($0, sql: "SELECT col FROM field_clock WHERE tbl = 'ledger_transaction' AND row_id = 't1' ORDER BY col")
        }
        #expect(clocked == ["counterparty_name", "is_new", "kind"])
    }

    @Test func deleteIsAnIdempotentRegister() throws {
        let replica = try seeded()
        try replica.writer.delete(table: "ledger_transaction", rowID: "t1")
        let first = try replica.value("ledger_transaction", "t1", "deleted_at")
        #expect(first?.isNull == false)
        let ops = try replica.ownOps().count
        try replica.writer.delete(table: "ledger_transaction", rowID: "t1")
        #expect(try replica.ownOps().count == ops)
        #expect(try replica.value("ledger_transaction", "t1", "deleted_at") == first)
        let op = try #require(try replica.ownOps().last)
        #expect(op.kind == .delete && op.column == nil && op.value == nil)
        // The tombstone text is the clock's wall time, identical on every replica.
        #expect(first == SyncValue(op.hlc.date))
        #expect(throws: LedgerWriterError.noSuchRow(table: "ledger_transaction", id: "zz")) {
            try replica.writer.delete(table: "ledger_transaction", rowID: "zz")
        }
    }

    @Test func opsAreServedInSequenceWithLimit() throws {
        let replica = try seeded()
        for i in 0..<5 { try replica.writer.set(table: "category", rowID: "c1", column: "name", to: .text("n\(i)")) }
        let all = try replica.ownOps()
        #expect(all.count == 8)
        let page = try replica.writer.ops(from: replica.node, after: 3, limit: 2)
        #expect(page.map(\.seq) == [4, 5])
        #expect(try replica.writer.ops(from: replica.node, after: 8, limit: 10).isEmpty)
        #expect(try replica.writer.ops(from: 12345, after: 0, limit: 10).isEmpty)
        #expect(try replica.writer.cursors() == [SyncCursor(device: replica.node, appliedSeq: 8)])
    }

    // MARK: Typed helpers

    @Test func typedTransactionEdits() throws {
        let replica = try seeded()
        let writer = replica.writer
        try writer.setCategory(transactionID: "t1", categoryID: "c1")
        #expect(try replica.value("ledger_transaction", "t1", "category_id") == .text("c1"))
        try writer.setNote(transactionID: "t1", note: "dinner")
        #expect(try replica.value("ledger_transaction", "t1", "note") == .text("dinner"))
        try writer.setNote(transactionID: "t1", note: "")
        #expect(try replica.value("ledger_transaction", "t1", "note") == .null)
        try writer.setCategory(transactionID: "t1", categoryID: nil)
        #expect(try replica.value("ledger_transaction", "t1", "category_id") == .null)

        try writer.markSeen(transactionID: "t1")
        #expect(try replica.value("ledger_transaction", "t1", "is_new") == .integer(0))
        let ops = try replica.ownOps().count
        try writer.markSeen(transactionID: "t1")
        #expect(try replica.ownOps().count == ops)
        // `is_new` cannot be raised again.
        try writer.set(table: "ledger_transaction", rowID: "t1", column: "is_new", to: .integer(1))
        #expect(try replica.value("ledger_transaction", "t1", "is_new") == .integer(0))
        #expect(try replica.ownOps().count == ops)
    }

    @Test func batchCategoryEditIsOneTransaction() throws {
        let replica = try seeded()
        try replica.writer.insertImmutable(table: "ledger_transaction", row: transactionRow("t2", account: "a1", day: "2026-11-02"))
        try replica.writer.setCategory(transactionIDs: ["t1", "t2"], categoryID: "c1")
        #expect(try replica.value("ledger_transaction", "t1", "category_id") == .text("c1"))
        #expect(try replica.value("ledger_transaction", "t2", "category_id") == .text("c1"))
        struct Boom: Error {}
        #expect(throws: (any Error).self) {
            try replica.writer.setCategory(transactionIDs: ["t1", "missing"], categoryID: nil)
        }
        // The failed batch rolled back as a whole.
        #expect(try replica.value("ledger_transaction", "t1", "category_id") == .text("c1"))
    }

    @Test func rulesAreAddedOnceAndEdited() throws {
        let replica = try seeded()
        let writer = replica.writer
        let id = try writer.addRule(pattern: "REWE", categoryID: "c1")
        #expect(try writer.addRule(pattern: "REWE", categoryID: "c1") == id)
        #expect(try replica.count("rule") == 1)
        try writer.setRule(id: id, enabled: false)
        #expect(try replica.value("rule", id, "enabled") == .integer(0))
        #expect(try writer.addRule(pattern: "REWE", categoryID: "c1") == id)    // re-enables
        #expect(try replica.value("rule", id, "enabled") == .integer(1))
        try writer.setRule(id: id, pattern: "REWE Markt")
        #expect(try replica.value("rule", id, "pattern") == .text("REWE Markt"))
        try writer.deleteRule(id: id)
        #expect(try replica.value("rule", id, "deleted_at")?.isNull == false)
    }

    @Test func sharedSettingsSyncAndLocalOnesDoNot() throws {
        let replica = try seeded()
        let ops = try replica.ownOps().count
        try replica.ledger.store.setSetting(.autoLockMinutes, "15")
        try replica.ledger.store.setSetting(.demoOnly, "1")
        #expect(try replica.ownOps().count == ops)
        #expect(try replica.ledger.store.setting(.autoLockMinutes) == "15")

        // Shared keys go through the writer and into the op log.
        try replica.ledger.store.setSetting(.rolloverEnabled, "0")
        #expect(try replica.ownOps().contains { $0.table == "setting" && $0.rowID == "rollover_enabled" })
        #expect(try replica.ledger.store.setting(.rolloverEnabled) == "0")
        try replica.ledger.store.setSetting(.rolloverEnabled, "1")
        #expect(try replica.ledger.store.setting(.rolloverEnabled) == "1")
        try replica.ledger.store.setSetting(.rolloverEnabled, nil)
        #expect(try replica.ledger.store.setting(.rolloverEnabled) == nil)
        #expect(try replica.count("setting", where: "scope = 'shared'") == 1)
    }

    // MARK: Guard

    #if DEBUG
    @Test func directWritesToSyncedTablesAreRefusedInDebug() throws {
        let replica = try seeded()
        func refused(_ sql: String) -> Bool {
            do {
                try replica.database.write { try $0.execute(sql: sql) }
                return false
            } catch let error as DatabaseError {
                return error.message?.contains("LedgerWriter") == true
            } catch { return false }
        }
        #expect(refused("UPDATE category SET name = 'x' WHERE id = 'c1'"))
        #expect(refused("UPDATE ledger_transaction SET deleted_at = '2026-01-01' WHERE id = 't1'"))
        #expect(refused("DELETE FROM category WHERE id = 'c1'"))
        #expect(refused("INSERT INTO category (id, name, color_token, kind, sort_order, created_at, updated_at) VALUES ('z', 'Z', 'chart-1', 'expense', 'V', 'x', 'x')"))
        #expect(refused("INSERT INTO setting (id, key, scope, value, created_at, updated_at) VALUES ('rollover_enabled', 'rollover_enabled', 'shared', '1', 'x', 'x')"))
        #expect(try replica.value("category", "c1", "name") == .text("Groceries"))

        // Local columns, bookkeeping and local settings are not synced and stay writable.
        try replica.database.write { db in
            try db.execute(sql: "UPDATE account SET connector_account_id = 'x', updated_at = 'now' WHERE id = 'a1'")
            try db.execute(sql: "INSERT INTO setting (id, key, scope, value, created_at, updated_at) VALUES ('auto_lock_minutes', 'auto_lock_minutes', 'local', '5', 'x', 'x')")
        }
        // The guard is lifted inside the writer's own transaction and for explicit fixtures.
        try replica.writer.set(table: "category", rowID: "c1", column: "name", to: .text("ok"))
        try replica.ledger.seed { try $0.execute(sql: "UPDATE category SET name = 'fixture' WHERE id = 'c1'") }
        #expect(try replica.value("category", "c1", "name") == .text("fixture"))
        // And it is armed again afterwards.
        #expect(refused("UPDATE category SET name = 'x' WHERE id = 'c1'"))
    }
    #endif
}
