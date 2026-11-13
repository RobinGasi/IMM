import Foundation
import GRDB
import Testing
import IMMLedger
@testable import IMMBanking

/// Migration `v2` on a vault built with the pre-sync importer (`Fixtures/DemoV1.sqlite`: the demo ledger imported by
/// the code at commit 90163c5, migration `v1` only; keyed with the raw key `cd…cd`, so tests skip the passphrase KDF).
@Suite struct MigrationTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/DemoV1.sqlite")

    private final class Opened: Sendable {
        let directory: URL
        let pool: DatabasePool
        init(prefix: String = "imm-mig") throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("data.sqlite")
            try FileManager.default.copyItem(at: MigrationTests.fixture, to: target)
            var configuration = Configuration()
            configuration.prepareDatabase { db in try db.usePassphrase("x'" + String(repeating: "cd", count: 32) + "'") }
            pool = try DatabasePool(path: target.path, configuration: configuration)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private final class Fresh: Sendable {
        let directory: URL
        let store: LedgerStore
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("imm-mig-fresh-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.prepareDatabase { db in try db.usePassphrase("x'" + String(repeating: "ef", count: 32) + "'") }
            store = try LedgerStore(database: try DatabasePool(path: directory.appendingPathComponent("data.sqlite").path, configuration: configuration))
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Before {
        var counts: [String: Int] = [:]
        var categoryOrder: [String] = []
        var accounts: [String: String] = [:]       // old id → name
        var sumsByAccount: [String: Int] = [:]     // account name → sum of booking amounts
        var settings: [String: String] = [:]
    }

    private func before(_ pool: DatabasePool) throws -> Before {
        try pool.read { db in
            var result = Before()
            for table in LedgerSchema.entityTables { result.counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") }
            result.categoryOrder = try String.fetchAll(db, sql: "SELECT name FROM category ORDER BY sort_order, rowid")
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM account") { result.accounts[row["id"]] = row["name"] }
            for row in try Row.fetchAll(db, sql: "SELECT a.name AS name, SUM(t.amount) AS total FROM ledger_transaction t JOIN account a ON a.id = t.account_id GROUP BY a.name") {
                result.sumsByAccount[row["name"]] = row["total"]
            }
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM setting") { result.settings[row["key"]] = row["value"] }
            return result
        }
    }

    @Test func theFixtureIsAVersionOneVault() throws {
        let opened = try Opened()
        let applied = try opened.pool.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        #expect(applied == ["v1"])
        let columns = try opened.pool.read { try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('account')") }
        #expect(columns.contains("ck_system_fields"))
    }

    @Test func v1DemoVaultMigratesAndKeepsItsFigures() throws {
        let opened = try Opened()
        let was = try before(opened.pool)
        #expect(was.counts["account"] == 5 && (was.counts["ledger_transaction"] ?? 0) > 148)

        let store = try LedgerStore(database: opened.pool)        // runs v2
        let applied = try store.database.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        #expect(applied == ["v1", "v2"])

        try store.database.read { db in
            // Same rows, same order of categories, same sums.
            for table in LedgerSchema.entityTables {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
                #expect(count == was.counts[table], Comment(rawValue: "\(table) count"))
            }
            #expect(try String.fetchAll(db, sql: "SELECT name FROM category ORDER BY sort_order") == was.categoryOrder)
            let keys = try String.fetchAll(db, sql: "SELECT sort_order FROM category ORDER BY sort_order")
            #expect(Set(keys).count == keys.count && !keys.contains { $0.hasSuffix("0") })
            let sums = try Row.fetchAll(db, sql: "SELECT a.name AS name, SUM(t.amount) AS total FROM ledger_transaction t JOIN account a ON a.id = t.account_id GROUP BY a.name")
            #expect(Dictionary(uniqueKeysWithValues: sums.map { ($0["name"] as String, $0["total"] as Int) }) == was.sumsByAccount)

            // Schema: no ck_system_fields, STRICT everywhere, no UNIQUE except primary keys on synced tables.
            for table in LedgerSchema.tableNames {
                let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)", arguments: [table])
                #expect(!columns.contains("ck_system_fields"), "\(table)")
                #expect(try Int.fetchOne(db, sql: "SELECT strict FROM pragma_table_list(?) WHERE schema = 'main'", arguments: [table]) == 1, "\(table) strict")
            }
            for table in SyncSchema.tables.map(\.name) {
                let uniques = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_index_list(?) WHERE \"unique\" = 1 AND origin != 'pk'", arguments: [table])
                #expect(uniques == 0, "\(table) has a UNIQUE constraint")
            }
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)

            // Settings keep their keys; none of today's keys syncs.
            let settings = try Row.fetchAll(db, sql: "SELECT key, scope, value FROM setting")
            #expect(Dictionary(uniqueKeysWithValues: settings.map { ($0["key"] as String, $0["value"] as String) }) == was.settings)
            #expect(settings.allSatisfy { ($0["scope"] as String) == "local" } == !was.settings.keys.contains(SettingKey.rolloverEnabled.rawValue))

            // Anchors of the demo ledger still hold through the ledger definitions.
            #expect(MoneyFormatter.string(try LedgerDefinitions.netWorth(db)) == "63.058,54\u{00A0}€")
            #expect(try LedgerDefinitions.newCount(db) == 14)
            #expect(try LedgerDefinitions.uncategorisedCount(db) == 6)
            let dangling = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight WHERE transaction_id IS NOT NULL AND transaction_id NOT IN (SELECT id FROM ledger_transaction)")
            #expect(dangling == 0)
        }
    }

    @Test func idsAreRederivedExactlyAsAFreshImportDerivesThem() throws {
        let opened = try Opened()
        let migrated = try LedgerStore(database: opened.pool)
        let fresh = try Fresh()
        let bank = try DemoDataset.load()
        try LedgerImporter.importSnapshot(bank.snapshot, profile: bank.profile, into: fresh.store)

        func ids(_ store: LedgerStore, _ table: String) throws -> Set<String> {
            try store.database.read { Set(try String.fetchAll($0, sql: "SELECT id FROM \(table)")) }
        }
        for table in ["account", "ledger_transaction", "security", "holding", "depot_value_history", "savings_plan", "savings_plan_item"] {
            let migratedIDs = try ids(migrated, table)
            let freshIDs = try ids(fresh.store, table)
            #expect(!migratedIDs.isEmpty, Comment(rawValue: table))
            #expect(migratedIDs == freshIDs, Comment(rawValue: "\(table) ids differ from a fresh import"))
        }
        // Budgets are keyed by their category (whose id is random per vault).
        try migrated.database.read { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, category_id FROM budget") {
                #expect(row["id"] as String == StableID.budgetID(categoryID: row["category_id"]))
            }
        }
        // Every id is a version-8 UUID; none of the v1 string ids survives in a derived table.
        let accounts = try migrated.database.read { try Row.fetchAll($0, sql: "SELECT id, connector_account_id FROM account") }
        for row in accounts {
            let id: String = row["id"]
            #expect(UUID(uuidString: id) != nil && id.dropFirst(14).first == "8")
            #expect(DemoAccountID.all.contains(row["connector_account_id"] as String))
        }
        // Standing orders, contracts and logins keep their ids and point at the new account ids.
        try migrated.database.read { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standing_order WHERE account_id NOT IN (SELECT id FROM account)") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM contract WHERE account_id NOT IN (SELECT id FROM account)") == 0)
            #expect(try String.fetchAll(db, sql: "SELECT id FROM bank_login ORDER BY id") == ["dkb", "ing", "paypal", "sparkasse"])
        }
    }

    @Test func everySyncedValueIsStampedWithTheMigrationClock() throws {
        let opened = try Opened()
        let store = try LedgerStore(database: opened.pool)
        let node = store.writer.localNode
        try store.database.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_op") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_device WHERE is_local = 1") == 1)
            let stamps = try Set(Data.fetchAll(db, sql: "SELECT DISTINCT hlc FROM field_clock"))
            #expect(stamps == [HLC(millis: 1, counter: 0, node: node).bytes])
            // A clock per non-NULL field of the LWW classes; nothing for immutable columns.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ledger_transaction t WHERE NOT EXISTS (SELECT 1 FROM field_clock c WHERE c.tbl = 'ledger_transaction' AND c.row_id = t.id AND c.col = 'kind')") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM field_clock WHERE tbl = 'ledger_transaction' AND col = 'amount'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM field_clock WHERE tbl = 'account' AND col = 'balance'") == 5)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM field_clock WHERE tbl = 'bank_login'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM field_clock WHERE tbl = 'insight'") == 0)
        }
        // Any real edit beats a migrated value.
        let writer = store.writer
        let category = try store.database.read { try #require(try String.fetchOne($0, sql: "SELECT id FROM category ORDER BY sort_order LIMIT 1")) }
        let stale = SyncOp(
            device: 4242, seq: 1, hlc: HLC(millis: 2, counter: 0, node: 4242), kind: .set, table: "category", rowID: category, column: "name",
            value: .text("remote"))
        #expect(try writer.applyRemote([stale]).applied == 1)
        #expect(try store.database.read { try String.fetchOne($0, sql: "SELECT name FROM category WHERE id = ?", arguments: [category]) } == "remote")
    }

    @Test func importingAgainAfterMigrationFindsEveryRow() throws {
        let opened = try Opened()
        let store = try LedgerStore(database: opened.pool)
        let was = try before(opened.pool)
        let bank = try DemoDataset.load()
        try LedgerImporter.importSnapshot(bank.snapshot, profile: bank.profile, into: store)
        try store.database.read { (db: Database) throws in
            for table in LedgerSchema.entityTables {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == was.counts[table], "\(table) changed by re-import")
            }
            // No booking was rewritten: the identity matched the migration's.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_op WHERE tbl = 'ledger_transaction'") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_op WHERE tbl IN ('security', 'depot_value_history', 'budget', 'category', 'rule')") == 0)
        }
    }

    @Test func aMigratedVaultBootstrapsAnotherDevice() throws {
        let opened = try Opened()
        let store = try LedgerStore(database: opened.pool)
        let fresh = try Fresh()
        try fresh.store.writer.applySnapshot(try store.writer.snapshot())
        let freshSnapshot = try fresh.store.writer.snapshot().converged
        let sourceSnapshot = try store.writer.snapshot().converged
        #expect(freshSnapshot == sourceSnapshot)
        #expect(freshSnapshot.tables["ledger_transaction"]?.isEmpty == false)
        // Local-only data does not travel.
        let insights = try fresh.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM insight") }
        let logins = try fresh.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bank_login") }
        #expect(insights == 0 && logins == 0)
    }
}
