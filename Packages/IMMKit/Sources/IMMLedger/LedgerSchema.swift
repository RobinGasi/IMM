import Foundation
import GRDB

/// The ledger schema. Migration `v1` creates every entity table as `STRICT`; `v2` is the sync schema
/// (see `LedgerSchemaV2` and `SyncSchema`).
///
/// Conventions
/// - `id TEXT PRIMARY KEY` is a UUID string: random for rows the user creates, name-based UUIDv8 (`StableID`) for
///   rows every device derives alike (accounts, bookings, securities, holdings, depot values, budgets, savings plans);
///   the `setting` table uses its key, `sync_state` uses `singleton`.
/// - `created_at`, `updated_at`, `deleted_at` (tombstone) are GRDB `Date` text. `deleted_at` of a synced row is a
///   register of its own. Timestamps are device-local metadata; clocks live in `field_clock`.
/// - Amounts are `INTEGER` minor units (cents) with an ISO 4217 `currency` column; signed (negative = outflow) unless noted.
/// - Dates are `TEXT` `YYYY-MM-DD` (`LocalDate`), so string comparison is date comparison.
/// - Holding quantities are `INTEGER` millionths of a unit (`quantity_micro`); prices are minor units per unit.
/// - Enum columns carry `CHECK` constraints generated from the Swift enums.
public enum LedgerSchema {
    /// Entity tables (all carry `id`, `created_at`, `updated_at`, `deleted_at`).
    public static let entityTables = [
        "bank_login", "account", "category", "ledger_transaction", "rule", "budget", "setting",
        "standing_order", "contract", "security", "holding", "depot_value_history",
        "savings_plan", "savings_plan_item", "insight", "sync_state",
    ]

    /// Bookkeeping tables added by `v2` (device-local).
    public static let syncTables = [
        "sync_device", "hlc_state", "field_clock", "sync_op", "sync_cursor", "sync_quarantine",
        "field_history", "sync_secret", "pending_transaction",
    ]

    /// All table names.
    public static let tableNames = entityTables + syncTables

    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try createV1(db)
        }
        migrator.registerMigration("v2") { db in
            try LedgerSchemaV2.migrate(db)
        }
        return migrator
    }

    /// Runs all pending migrations on `writer`.
    public static func migrate(_ writer: any DatabaseWriter) throws {
        try makeMigrator().migrate(writer)
    }

    static func check<E: RawRepresentable & CaseIterable>(_ column: String, _ type: E.Type) -> String where E.RawValue == String {
        "CHECK (\(column) IN (" + E.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ") + "))"
    }

    private static let common = """
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        ck_system_fields BLOB
    """

    private static func createV1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE bank_login (
                id TEXT NOT NULL PRIMARY KEY,
                connector_id TEXT NOT NULL,
                bank_name TEXT NOT NULL,
                bank_code TEXT NOT NULL,
                login_name TEXT NOT NULL,
                tan_method TEXT NOT NULL,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE account (
                id TEXT NOT NULL PRIMARY KEY,
                bank_login_id TEXT REFERENCES bank_login(id),
                kind TEXT NOT NULL \(check("kind", AccountKind.self)),
                name TEXT NOT NULL,
                bank_name TEXT NOT NULL,
                iban TEXT,
                subtitle TEXT,
                balance INTEGER NOT NULL,
                currency TEXT NOT NULL,
                overdraft_limit INTEGER NOT NULL DEFAULT 0,
                statement_note TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                last_synced_at TEXT,
                sync_status TEXT NOT NULL DEFAULT 'never' \(check("sync_status", AccountSyncStatus.self)),
                sync_status_text TEXT,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE category (
                id TEXT NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                color_token TEXT NOT NULL,
                kind TEXT NOT NULL \(check("kind", CategoryKind.self)),
                sort_order INTEGER NOT NULL DEFAULT 0,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE ledger_transaction (
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
                kind TEXT NOT NULL \(check("kind", TransactionKind.self)),
                category_id TEXT REFERENCES category(id),
                is_own_transfer INTEGER NOT NULL DEFAULT 0 CHECK (is_own_transfer IN (0, 1)),
                is_new INTEGER NOT NULL DEFAULT 0 CHECK (is_new IN (0, 1)),
                note TEXT,
                bank_reference TEXT NOT NULL,
                \(common),
                UNIQUE (account_id, bank_reference)
            ) STRICT
            """)
        try db.execute(sql: "CREATE INDEX ledger_transaction_account_date ON ledger_transaction (account_id, booking_date)")
        try db.execute(sql: "CREATE INDEX ledger_transaction_category ON ledger_transaction (category_id)")
        try db.execute(sql: "CREATE INDEX ledger_transaction_date ON ledger_transaction (booking_date)")

        try db.execute(sql: """
            CREATE TABLE rule (
                id TEXT NOT NULL PRIMARY KEY,
                pattern TEXT NOT NULL,
                category_id TEXT NOT NULL REFERENCES category(id),
                origin TEXT NOT NULL \(check("origin", RuleOrigin.self)),
                enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE budget (
                id TEXT NOT NULL PRIMARY KEY,
                category_id TEXT NOT NULL REFERENCES category(id),
                monthly_limit INTEGER NOT NULL,
                currency TEXT NOT NULL,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE setting (
                id TEXT NOT NULL PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,
                value TEXT,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE standing_order (
                id TEXT NOT NULL PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES account(id),
                recipient TEXT NOT NULL,
                iban TEXT NOT NULL,
                purpose TEXT,
                amount INTEGER NOT NULL,
                currency TEXT NOT NULL,
                rhythm TEXT NOT NULL \(check("rhythm", StandingOrderRhythm.self)),
                day_of_month INTEGER CHECK (day_of_month IS NULL OR day_of_month BETWEEN 1 AND 31),
                next_execution TEXT,
                status TEXT NOT NULL \(check("status", StandingOrderStatus.self)),
                category_id TEXT REFERENCES category(id),
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE contract (
                id TEXT NOT NULL PRIMARY KEY,
                provider TEXT NOT NULL,
                account_id TEXT REFERENCES account(id),
                group_name TEXT NOT NULL,
                category_id TEXT REFERENCES category(id),
                rhythm TEXT NOT NULL \(check("rhythm", ContractRhythm.self)),
                monthly_amount INTEGER NOT NULL,
                currency TEXT NOT NULL,
                next_debit TEXT,
                notice_text TEXT,
                notice_deadline TEXT,
                renewal_date TEXT,
                renewal_amount INTEGER,
                price_change_amount INTEGER,
                price_change_start TEXT,
                kind TEXT NOT NULL \(check("kind", ContractKind.self)),
                sort_order INTEGER NOT NULL DEFAULT 0,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE security (
                id TEXT NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                isin TEXT NOT NULL,
                wkn TEXT,
                kind TEXT NOT NULL \(check("kind", SecurityKind.self)),
                region TEXT,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE holding (
                id TEXT NOT NULL PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES account(id),
                security_id TEXT REFERENCES security(id),
                name TEXT NOT NULL,
                isin TEXT,
                quantity_micro INTEGER NOT NULL,
                price INTEGER NOT NULL,
                price_at TEXT,
                cost_basis INTEGER NOT NULL,
                currency TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                \(common)
            ) STRICT
            """)
        try db.execute(sql: "CREATE INDEX holding_account ON holding (account_id)")

        try db.execute(sql: """
            CREATE TABLE depot_value_history (
                id TEXT NOT NULL PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES account(id),
                date TEXT NOT NULL,
                value INTEGER NOT NULL,
                currency TEXT NOT NULL,
                \(common),
                UNIQUE (account_id, date)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE savings_plan (
                id TEXT NOT NULL PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES account(id),
                source_account_id TEXT REFERENCES account(id),
                amount INTEGER NOT NULL,
                currency TEXT NOT NULL,
                day_of_month INTEGER NOT NULL CHECK (day_of_month BETWEEN 1 AND 31),
                next_execution TEXT,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE savings_plan_item (
                id TEXT NOT NULL PRIMARY KEY,
                plan_id TEXT NOT NULL REFERENCES savings_plan(id),
                security_id TEXT NOT NULL REFERENCES security(id),
                amount INTEGER NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE insight (
                id TEXT NOT NULL PRIMARY KEY,
                kind TEXT NOT NULL \(check("kind", InsightKind.self)),
                transaction_id TEXT REFERENCES ledger_transaction(id),
                payload TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                \(common)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE sync_state (
                id TEXT NOT NULL PRIMARY KEY,
                state BLOB,
                \(common)
            ) STRICT
            """)
    }
}
