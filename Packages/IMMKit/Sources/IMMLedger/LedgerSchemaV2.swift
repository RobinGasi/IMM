import Foundation
import GRDB

/// Migration `v2`: the sync schema.
///
/// - Adds the bookkeeping tables (`sync_device`, `hlc_state`, `field_clock`, `sync_op`, `sync_cursor`,
///   `sync_quarantine`, `field_history`, `sync_secret`) and the device-local `pending_transaction`.
/// - Rebuilds `ledger_transaction` (no `UNIQUE (account_id, bank_reference)`; `bank_reference` becomes the nullable
///   attributes `bank_ref_kind` / `bank_ref`), `category` (`sort_order` is a fractional index), `setting`
///   (`scope`, no `UNIQUE (key)`) and `depot_value_history` (no `UNIQUE (account_id, date)`).
/// - Drops `ck_system_fields` everywhere and adds `account.connector_account_id` (the connector's id for the account).
/// - Re-identifies accounts, bookings, securities, holdings, depot values, budgets, savings plans and plan items
///   deterministically (`StableID`) and rewrites every foreign key.
/// - Stamps every synced value with one migration clock `(millis 1, counter 0, this device's node)`. A real edit
///   anywhere therefore beats a migrated value, and two independently migrated vaults still tie-break
///   deterministically by node id.
enum LedgerSchemaV2 {
    static let migrationMillis: UInt64 = 1

    static func migrate(_ db: Database) throws {
        let ids = try IDMap.build(db)
        try createSyncTables(db)
        let node = try LedgerEngine.createLocalDevice(db, nowMillis: UInt64(max(0, Date().timeIntervalSince1970 * 1000)))

        try db.execute(sql: "CREATE TEMP TABLE id_map (tbl TEXT NOT NULL, old TEXT NOT NULL, new TEXT NOT NULL, PRIMARY KEY (tbl, old)) WITHOUT ROWID")
        let insert = try db.makeStatement(sql: "INSERT INTO id_map (tbl, old, new) VALUES (?, ?, ?)")
        for (table, map) in ids.all {
            for (old, new) in map { try insert.execute(arguments: [table, old, new]) }
        }
        defer { try? db.execute(sql: "DROP TABLE IF EXISTS temp.id_map") }

        try rebuildCategory(db)
        try rebuildLedgerTransaction(db)
        try rebuildSetting(db)
        try rebuildDepotValueHistory(db)
        try remapInPlace(db)
        for table in ["bank_login", "rule", "standing_order", "contract", "insight", "sync_state"] {
            try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN ck_system_fields")
        }
        try stamp(db, hlc: HLC(millis: migrationMillis, counter: 0, node: node))
    }

    // MARK: Identity mapping

    private struct IDMap {
        var account: [String: String] = [:]
        var transaction: [String: String] = [:]
        var security: [String: String] = [:]
        var holding: [String: String] = [:]
        var depotValue: [String: String] = [:]
        var budget: [String: String] = [:]
        var savingsPlan: [String: String] = [:]
        var savingsPlanItem: [String: String] = [:]

        var all: [(String, [String: String])] {
            [("account", account), ("ledger_transaction", transaction), ("security", security), ("holding", holding),
             ("depot_value_history", depotValue), ("budget", budget), ("savings_plan", savingsPlan),
             ("savings_plan_item", savingsPlanItem)]
        }

        /// Computes every new id from the v1 data. Colliding derived ids keep the old id (never merge rows).
        static func build(_ db: Database) throws -> IDMap {
            var map = IDMap()
            var taken = Set<String>()
            func derive(_ old: String, _ new: String) -> String {
                let chosen = taken.insert(new).inserted ? new : old
                if chosen == old { taken.insert(old) }
                return chosen
            }

            // Accounts: key = IBAN (or card/depot number) with the login's bank code; the old id as last resort.
            for row in try Row.fetchAll(db, sql: """
                SELECT a.id, a.iban, COALESCE(l.bank_code, '') AS bank_code FROM account a
                LEFT JOIN bank_login l ON l.id = a.bank_login_id ORDER BY a.rowid
                """) {
                let old: String = row["id"]
                let number: String = (row["iban"] as String?) ?? old
                map.account[old] = derive(old, StableID.accountID(bankCode: row["bank_code"], accountNumber: number))
            }

            // Bookings: content tuple + occurrence index per account.
            var byAccount: [String: [(old: String, content: StableID.BookingContent, reference: String?)]] = [:]
            var accountOrder: [String] = []
            for row in try Row.fetchAll(db, sql: """
                SELECT id, account_id, booking_date, amount, currency, counterparty_iban, counterparty_name, purpose, bank_reference
                FROM ledger_transaction ORDER BY rowid
                """) {
                let account: String = row["account_id"]
                let day = LocalDate(iso: row["booking_date"]) ?? LocalDate(year: 1970, month: 1, day: 1)
                let content = StableID.BookingContent(
                    day: day, amount: row["amount"], currency: row["currency"], reversal: false,
                    counterpartyKey: StableID.counterpartyKey(iban: row["counterparty_iban"], name: row["counterparty_name"]),
                    purposeKey: StableID.purposeKey(row["purpose"]))
                if byAccount[account] == nil { accountOrder.append(account) }
                byAccount[account, default: []].append((row["id"], content, row["bank_reference"]))
            }
            for account in accountOrder {
                let entries = byAccount[account] ?? []
                let newAccount = map.account[account] ?? account
                let ids = StableID.bookingIDs(accountID: newAccount, entries: entries.map { ($0.content, $0.reference) })
                for (entry, id) in zip(entries, ids) { map.transaction[entry.old] = derive(entry.old, id) }
            }

            for row in try Row.fetchAll(db, sql: "SELECT id, isin FROM security ORDER BY rowid") {
                let old: String = row["id"]
                map.security[old] = derive(old, StableID.securityID(isin: row["isin"]))
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, account_id, isin FROM holding ORDER BY rowid") {
                let old: String = row["id"]
                let account: String = row["account_id"]
                map.holding[old] = derive(old, StableID.holdingID(accountID: map.account[account] ?? account, isin: row["isin"]))
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, account_id, date FROM depot_value_history ORDER BY rowid") {
                let old: String = row["id"]
                let account: String = row["account_id"]
                let date = LocalDate(iso: row["date"]) ?? LocalDate(year: 1970, month: 1, day: 1)
                map.depotValue[old] = derive(old, StableID.depotValueID(accountID: map.account[account] ?? account, date: date))
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, category_id FROM budget ORDER BY rowid") {
                let old: String = row["id"]
                map.budget[old] = derive(old, StableID.budgetID(categoryID: row["category_id"]))
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, account_id FROM savings_plan ORDER BY rowid") {
                let old: String = row["id"]
                let account: String = row["account_id"]
                map.savingsPlan[old] = derive(old, StableID.savingsPlanID(accountID: map.account[account] ?? account))
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, plan_id, security_id FROM savings_plan_item ORDER BY rowid") {
                let old: String = row["id"]
                let plan: String = row["plan_id"]
                let security: String = row["security_id"]
                map.savingsPlanItem[old] = derive(old, StableID.savingsPlanItemID(
                    planID: map.savingsPlan[plan] ?? plan, securityID: map.security[security] ?? security))
            }
            return map
        }
    }

    /// SQL expression: the new id of `column` (old id) in `tbl`, or the column itself when unmapped.
    private static func mapped(_ tbl: String, _ column: String) -> String {
        "COALESCE((SELECT new FROM id_map WHERE tbl = '\(tbl)' AND old = \(column)), \(column))"
    }

    // MARK: Tables

    private static let common = """
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT
    """

    private static func createSyncTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE sync_device (
                id TEXT NOT NULL PRIMARY KEY,
                node_id INTEGER NOT NULL UNIQUE,
                name TEXT,
                is_local INTEGER NOT NULL DEFAULT 0 CHECK (is_local IN (0, 1)),
                x25519_public BLOB,
                ed25519_public BLOB,
                created_at TEXT NOT NULL,
                revoked_at TEXT,
                last_seen_hlc BLOB,
                last_acked_hlc BLOB,
                transport_host TEXT,
                transport_port INTEGER
            ) STRICT
            """)
        try db.execute(sql: "CREATE UNIQUE INDEX sync_device_local ON sync_device (is_local) WHERE is_local = 1")
        try db.execute(sql: """
            CREATE TABLE hlc_state (
                id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
                hlc BLOB NOT NULL,
                op_seq INTEGER NOT NULL
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE field_clock (
                tbl TEXT NOT NULL,
                row_id TEXT NOT NULL,
                col TEXT NOT NULL,
                hlc BLOB NOT NULL,
                PRIMARY KEY (tbl, row_id, col)
            ) STRICT, WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE sync_op (
                device_id INTEGER NOT NULL,
                seq INTEGER NOT NULL,
                hlc BLOB NOT NULL,
                tbl TEXT NOT NULL,
                row_id TEXT NOT NULL,
                col TEXT,
                value BLOB,
                kind TEXT NOT NULL CHECK (kind IN ('set', 'insert', 'delete')),
                PRIMARY KEY (device_id, seq)
            ) STRICT, WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE sync_cursor (
                device_id INTEGER NOT NULL PRIMARY KEY,
                applied_seq INTEGER NOT NULL,
                acked_hlc BLOB
            ) STRICT
            """)
        let reasons = QuarantineReason.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        try db.execute(sql: """
            CREATE TABLE sync_quarantine (
                device_id INTEGER NOT NULL,
                seq INTEGER NOT NULL,
                reason TEXT NOT NULL CHECK (reason IN (\(reasons))),
                op BLOB NOT NULL,
                quarantined_at TEXT NOT NULL,
                PRIMARY KEY (device_id, seq)
            ) STRICT, WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE field_history (
                tbl TEXT NOT NULL,
                row_id TEXT NOT NULL,
                col TEXT NOT NULL,
                hlc BLOB NOT NULL,
                value BLOB NOT NULL,
                PRIMARY KEY (tbl, row_id, col, hlc)
            ) STRICT, WITHOUT ROWID
            """)
        try db.execute(sql: """
            CREATE TABLE sync_secret (
                name TEXT NOT NULL PRIMARY KEY,
                value BLOB NOT NULL,
                updated_at TEXT NOT NULL
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE TABLE pending_transaction (
                id TEXT NOT NULL PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES account(id),
                position INTEGER NOT NULL,
                booking_date TEXT,
                value_date TEXT,
                amount INTEGER NOT NULL,
                currency TEXT NOT NULL,
                counterparty_name TEXT NOT NULL,
                counterparty_iban TEXT,
                booking_text TEXT,
                purpose TEXT,
                kind TEXT NOT NULL \(LedgerSchema.check("kind", TransactionKind.self)),
                fetched_at TEXT NOT NULL
            ) STRICT
            """)
        try db.execute(sql: "CREATE INDEX pending_transaction_account ON pending_transaction (account_id, position)")
    }

    private static func rebuildCategory(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE category_v2 (
                id TEXT NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                color_token TEXT NOT NULL,
                kind TEXT NOT NULL \(LedgerSchema.check("kind", CategoryKind.self)),
                sort_order TEXT NOT NULL,
                \(common)
            ) STRICT
            """)
        let rows = try Row.fetchAll(db, sql: "SELECT id, name, color_token, kind, created_at, updated_at, deleted_at FROM category ORDER BY sort_order, rowid")
        let keys = FractionalIndex.keys(count: rows.count)
        for (row, key) in zip(rows, keys) {
            try db.execute(
                sql: "INSERT INTO category_v2 (id, name, color_token, kind, sort_order, created_at, updated_at, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [row["id"] as String, row["name"] as String, row["color_token"] as String, row["kind"] as String, key,
                            row["created_at"] as String, row["updated_at"] as String, row["deleted_at"] as String?])
        }
        try db.execute(sql: "DROP TABLE category")
        try db.execute(sql: "ALTER TABLE category_v2 RENAME TO category")
    }

    private static func rebuildLedgerTransaction(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE ledger_transaction_v2 (
                id TEXT NOT NULL PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES account(id),
                booking_date TEXT NOT NULL,
                value_date TEXT,
                booked_time TEXT,
                booking_seq INTEGER NOT NULL DEFAULT 0,
                amount INTEGER NOT NULL,
                currency TEXT NOT NULL,
                counterparty_name TEXT NOT NULL,
                short_name TEXT,
                counterparty_iban TEXT,
                booking_text TEXT,
                purpose TEXT,
                creditor_id TEXT,
                kind TEXT NOT NULL \(LedgerSchema.check("kind", TransactionKind.self)),
                category_id TEXT REFERENCES category(id),
                is_own_transfer INTEGER NOT NULL DEFAULT 0 CHECK (is_own_transfer IN (0, 1)),
                is_new INTEGER NOT NULL DEFAULT 0 CHECK (is_new IN (0, 1)),
                note TEXT,
                bank_ref_kind TEXT,
                bank_ref TEXT,
                \(common)
            ) STRICT
            """)
        try db.execute(sql: """
            INSERT INTO ledger_transaction_v2 (
                id, account_id, booking_date, value_date, booked_time, booking_seq, amount, currency, counterparty_name,
                short_name, counterparty_iban, booking_text, purpose, creditor_id, kind, category_id, is_own_transfer,
                is_new, note, bank_ref_kind, bank_ref, created_at, updated_at, deleted_at)
            SELECT
                \(mapped("ledger_transaction", "id")), \(mapped("account", "account_id")), booking_date, value_date, booked_time,
                booking_seq, amount, currency, counterparty_name, short_name, counterparty_iban, booking_text, purpose,
                creditor_id, kind, category_id, is_own_transfer, is_new, note, 'legacy', bank_reference,
                created_at, updated_at, deleted_at
            FROM ledger_transaction
            """)
        try db.execute(sql: "DROP TABLE ledger_transaction")
        try db.execute(sql: "ALTER TABLE ledger_transaction_v2 RENAME TO ledger_transaction")
        try db.execute(sql: "CREATE INDEX ledger_transaction_account_date ON ledger_transaction (account_id, booking_date)")
        try db.execute(sql: "CREATE INDEX ledger_transaction_category ON ledger_transaction (category_id)")
        try db.execute(sql: "CREATE INDEX ledger_transaction_date ON ledger_transaction (booking_date)")
        try db.execute(sql: "CREATE INDEX ledger_transaction_bank_ref ON ledger_transaction (bank_ref)")
    }

    private static func rebuildSetting(_ db: Database) throws {
        let shared = SyncSchema.sharedSettingKeys.sorted().map { "'\($0)'" }.joined(separator: ", ")
        try db.execute(sql: """
            CREATE TABLE setting_v2 (
                id TEXT NOT NULL PRIMARY KEY,
                key TEXT NOT NULL,
                scope TEXT NOT NULL DEFAULT 'local' \(LedgerSchema.check("scope", SettingScope.self)),
                value TEXT,
                \(common)
            ) STRICT
            """)
        try db.execute(sql: """
            INSERT INTO setting_v2 (id, key, scope, value, created_at, updated_at, deleted_at)
            SELECT id, key, CASE WHEN key IN (\(shared)) THEN 'shared' ELSE 'local' END, value, created_at, updated_at, deleted_at
            FROM setting
            """)
        try db.execute(sql: "DROP TABLE setting")
        try db.execute(sql: "ALTER TABLE setting_v2 RENAME TO setting")
    }

    private static func rebuildDepotValueHistory(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE depot_value_history_v2 (
                id TEXT NOT NULL PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES account(id),
                date TEXT NOT NULL,
                value INTEGER NOT NULL,
                currency TEXT NOT NULL,
                \(common)
            ) STRICT
            """)
        try db.execute(sql: """
            INSERT INTO depot_value_history_v2 (id, account_id, date, value, currency, created_at, updated_at, deleted_at)
            SELECT \(mapped("depot_value_history", "id")), \(mapped("account", "account_id")), date, value, currency,
                   created_at, updated_at, deleted_at
            FROM depot_value_history
            """)
        try db.execute(sql: "DROP TABLE depot_value_history")
        try db.execute(sql: "ALTER TABLE depot_value_history_v2 RENAME TO depot_value_history")
        try db.execute(sql: "CREATE INDEX depot_value_history_account_date ON depot_value_history (account_id, date)")
    }

    /// Tables that keep their shape: new ids and foreign keys are written in place (foreign keys are off during migrations).
    private static func remapInPlace(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE account ADD COLUMN connector_account_id TEXT")
        try db.execute(sql: "UPDATE account SET connector_account_id = id")
        try db.execute(sql: "ALTER TABLE account DROP COLUMN ck_system_fields")
        try db.execute(sql: "UPDATE account SET id = \(mapped("account", "id"))")

        try db.execute(sql: "UPDATE security SET id = \(mapped("security", "id"))")
        try db.execute(sql: "ALTER TABLE security DROP COLUMN ck_system_fields")

        try db.execute(sql: """
            UPDATE holding SET id = \(mapped("holding", "id")), account_id = \(mapped("account", "account_id")),
                security_id = \(mapped("security", "security_id"))
            """)
        try db.execute(sql: "ALTER TABLE holding DROP COLUMN ck_system_fields")

        try db.execute(sql: "UPDATE budget SET id = \(mapped("budget", "id"))")
        try db.execute(sql: "ALTER TABLE budget DROP COLUMN ck_system_fields")

        try db.execute(sql: """
            UPDATE savings_plan SET id = \(mapped("savings_plan", "id")), account_id = \(mapped("account", "account_id")),
                source_account_id = \(mapped("account", "source_account_id"))
            """)
        try db.execute(sql: "ALTER TABLE savings_plan DROP COLUMN ck_system_fields")

        try db.execute(sql: """
            UPDATE savings_plan_item SET id = \(mapped("savings_plan_item", "id")), plan_id = \(mapped("savings_plan", "plan_id")),
                security_id = \(mapped("security", "security_id"))
            """)
        try db.execute(sql: "ALTER TABLE savings_plan_item DROP COLUMN ck_system_fields")

        try db.execute(sql: "UPDATE standing_order SET account_id = \(mapped("account", "account_id"))")
        try db.execute(sql: "UPDATE contract SET account_id = \(mapped("account", "account_id"))")
        try db.execute(sql: "UPDATE insight SET transaction_id = \(mapped("ledger_transaction", "transaction_id"))")
        // The dropped `account.bank_login_id` link stays: it is device-local but keeps its foreign key.
    }

    /// Gives every current synced value (non-NULL; tombstones for `deleted_at`) the migration clock.
    private static func stamp(_ db: Database, hlc: HLC) throws {
        for table in SyncSchema.tables {
            let filter = table.name == "setting" ? " AND scope = 'shared'" : ""
            for column in table.columns where column.columnClass != .immutable {
                try db.execute(
                    sql: """
                        INSERT INTO field_clock (tbl, row_id, col, hlc)
                        SELECT ?, id, ?, ? FROM "\(table.name)" WHERE "\(column.name)" IS NOT NULL\(filter)
                        """,
                    arguments: [table.name, column.name, hlc.bytes])
            }
            try db.execute(
                sql: """
                    INSERT INTO field_clock (tbl, row_id, col, hlc)
                    SELECT ?, id, ?, ? FROM "\(table.name)" WHERE deleted_at IS NOT NULL\(filter)
                    """,
                arguments: [table.name, SyncSchema.deletedAt, hlc.bytes])
        }
    }
}
