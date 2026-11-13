import Foundation
import GRDB
import Testing
@testable import IMMLedger

@Suite struct SchemaTests {
    @Test func migrationCreatesAllTablesOnEncryptedDatabase() throws {
        let ledger = try TestLedger()
        let names = try ledger.database.read { db throws in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'")
        }
        #expect(Set(names) == Set(LedgerSchema.tableNames))

        // The file is encrypted.
        let head = try Data(contentsOf: ledger.directory.appendingPathComponent("data.sqlite")).prefix(16)
        #expect(head != Data("SQLite format 3\0".utf8))

        // Wrong key cannot read it.
        var wrong = Configuration()
        wrong.prepareDatabase { db in try db.usePassphrase("other") }
        #expect(throws: (any Error).self) {
            let pool = try DatabasePool(path: ledger.directory.appendingPathComponent("data.sqlite").path, configuration: wrong)
            _ = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master") }
        }
    }

    @Test func everyTableIsStrictWithCommonColumns() throws {
        let ledger = try TestLedger()
        try ledger.database.read { db throws in
            for table in LedgerSchema.entityTables {
                let columns = try Row.fetchAll(db, sql: "SELECT name, pk FROM pragma_table_info(?)", arguments: [table])
                let names = columns.map { $0["name"] as String }
                for required in ["id", "created_at", "updated_at", "deleted_at"] {
                    #expect(names.contains(required), "\(table) lacks \(required)")
                }
                #expect(!names.contains("ck_system_fields"), "\(table) still has ck_system_fields")
            }
            for table in LedgerSchema.tableNames {
                let strict = try Int.fetchOne(db, sql: "SELECT strict FROM pragma_table_list(?) WHERE schema = 'main'", arguments: [table])
                #expect(strict == 1, "\(table) is not STRICT")
            }
        }
    }

    @Test func migrationIsIdempotent() throws {
        let ledger = try TestLedger()
        try LedgerSchema.migrate(ledger.database)
        _ = try LedgerStore(database: ledger.database)
    }

    @Test func checkConstraintsRejectUnknownEnumValues() throws {
        let ledger = try TestLedger()
        #expect(throws: DatabaseError.self) {
            try ledger.seed { db in
                try db.execute(sql: """
                    INSERT INTO category (id, name, color_token, kind, sort_order, created_at, updated_at)
                    VALUES ('x', 'X', 'chart-1', 'bogus', 'V', '2026-01-01', '2026-01-01')
                    """)
            }
        }
    }

    @Test func bankReferencesAreAttributesNotKeys() throws {
        // Bookings are identified by their derived id; two rows may carry the same bank reference.
        let ledger = try TestLedger()
        try ledger.seed { db in
            try AccountRecord(id: "a", kind: .giro, name: "Giro", balance: 0).insert(db)
            try TransactionRecord.fixture("t1", account: "a", "2026-11-01", -100).insert(db)
            var twin = TransactionRecord.fixture("t2", account: "a", "2026-11-02", -200)
            twin.bankRef = "t1"
            try twin.insert(db)
        }
        let count = try ledger.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ledger_transaction WHERE bank_ref = 't1'") }
        #expect(count == 2)
    }

    @Test func recordsRoundTrip() throws {
        let ledger = try TestLedger()
        let original = TransactionRecord(
            id: "t", accountId: "a", bookingDate: d("2026-11-11"), valueDate: d("2026-11-12"), bookedTime: "18:42", bookingSeq: 3,
            amount: -6348, counterpartyName: "REWE Markt GmbH", shortName: "REWE", counterpartyIban: "DE02120300000000202051",
            bookingText: "Kartenzahlung", purpose: "REWE SAGT DANKE", creditorId: nil, kind: .cardPayment, categoryId: "c",
            isOwnTransfer: false, isNew: true, note: "n", bankRefKind: "bank", bankRef: "ref-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_100.5)
        )
        try ledger.seed { db in
            try AccountRecord(id: "a", kind: .creditCard, name: "Visa", balance: -38412, syncStatus: .failed).insert(db)
            try CategoryRecord(id: "c", name: "Groceries", colorToken: "chart-5").insert(db)
            try original.insert(db)
        }
        let fetched = try ledger.database.read { db in try TransactionRecord.fetchOne(db, key: "t") }
        let account = try ledger.database.read { db in try AccountRecord.fetchOne(db, key: "a") }
        #expect(fetched == original)
        #expect(account?.kind == .creditCard)
        #expect(account?.syncStatus == .failed)

        // Stored as snake_case columns and ISO date text.
        let raw = try ledger.database.read { db throws in
            try Row.fetchOne(db, sql: "SELECT booking_date, is_new, kind, category_id FROM ledger_transaction WHERE id = 't'")
        }
        let row = try #require(raw)
        let bookingDate: String = row["booking_date"]
        let isNew: Int = row["is_new"]
        let kind: String = row["kind"]
        let categoryID: String = row["category_id"]
        #expect(bookingDate == "2026-11-11")
        #expect(isNew == 1)
        #expect(kind == "card_payment")
        #expect(categoryID == "c")
    }
}
