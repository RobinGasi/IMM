import Foundation

/// How one synced column merges.
public enum SyncColumnClass: String, Sendable, Codable {
    /// Written once with the row (identity inputs); later writes are ignored.
    case immutable
    /// Latest write from the bank wins (per-field last-writer-wins, stamped by the fetch's clock).
    case bankLatest
    /// Latest user edit wins (per-field last-writer-wins).
    case userEdit
    /// Only ever moves towards its terminal value (`is_new`: 1 → 0, "read wins"), whatever the clocks say.
    case monotone
}

/// How a whole table behaves (documentation and insert semantics).
public enum SyncTableClass: String, Sendable, Codable {
    /// Insert-only rows with deterministic ids; a second insert of the same id changes nothing.
    case bankImmutable
    /// Rows the bank rewrites on every fetch.
    case bankLatest
    /// Rows the user edits.
    case userEdit
    /// Mixed: the columns carry their own classes (`ledger_transaction`, `account`, `setting`).
    case mixed
}

public struct SyncTable: Sendable {
    public let name: String
    public let tableClass: SyncTableClass
    /// Synced columns (never `id`, `created_at`, `updated_at`, `deleted_at`) in declaration order.
    public let columns: [(name: String, columnClass: SyncColumnClass)]
    /// Column → parent table for every synced foreign key.
    public let foreignKeys: [String: String]

    public func columnClass(_ column: String) -> SyncColumnClass? {
        columns.first { $0.name == column }?.columnClass
    }

    public var columnNames: [String] { columns.map(\.name) }
}

/// The registry of what syncs. `LedgerWriter.applyRemote` quarantines ops on tables or columns that are not
/// listed here (`unknownSchema`).
///
/// Table classes (see `LedgerSchema` for the schema):
/// - bank-immutable: `security`, `depot_value_history`, and the identity columns of `ledger_transaction`.
/// - bank-latest: `account` balance and status fields, `standing_order`, `holding`, `savings_plan`, `savings_plan_item`,
///   and the non-identity bank attributes of `ledger_transaction`.
/// - user-edit: `category`, `rule`, `budget`, `contract`, `account` display fields, `ledger_transaction.category_id` / `.note`
///   / `.is_own_transfer`, `setting` rows with scope `shared`.
/// - monotone: `ledger_transaction.is_new`.
/// - device-local (not listed): `bank_login`, `account.bank_login_id` / `.connector_account_id`, `insight`, `sync_state`,
///   `pending_transaction`, `setting` rows with scope `local`, and every `sync_*`, `hlc_state`, `field_*` table.
///
/// `deleted_at` of every synced table is its own register (see `LedgerWriter.delete`).
public enum SyncSchema {
    /// Version of the snapshot and op format.
    public static let version = 1

    /// Keys of `setting` that sync; every other key stays on the device.
    public static let sharedSettingKeys: Set<String> = [SettingKey.rolloverEnabled.rawValue]

    private typealias Column = (name: String, columnClass: SyncColumnClass)

    private static func table(
        _ name: String, _ tableClass: SyncTableClass, foreignKeys: [String: String] = [:],
        immutable: [String] = [], bankLatest: [String] = [], userEdit: [String] = [], monotone: [String] = []
    ) -> SyncTable {
        var columns: [Column] = []
        columns += immutable.map { ($0, .immutable) }
        columns += bankLatest.map { ($0, .bankLatest) }
        columns += userEdit.map { ($0, .userEdit) }
        columns += monotone.map { ($0, .monotone) }
        return SyncTable(name: name, tableClass: tableClass, columns: columns, foreignKeys: foreignKeys)
    }

    /// Parents before children, so snapshots and bootstraps can insert in order.
    public static let tables: [SyncTable] = [
        table("category", .userEdit, userEdit: ["name", "color_token", "kind", "sort_order"]),
        table("security", .bankImmutable, immutable: ["name", "isin", "wkn", "kind", "region"]),
        table("account", .mixed,
              bankLatest: ["kind", "bank_name", "iban", "balance", "currency", "overdraft_limit", "statement_note",
                           "last_synced_at", "sync_status", "sync_status_text"],
              userEdit: ["name", "subtitle", "sort_order"]),
        table("ledger_transaction", .mixed,
              foreignKeys: ["account_id": "account", "category_id": "category"],
              immutable: ["account_id", "booking_date", "amount", "currency"],
              bankLatest: ["value_date", "booked_time", "booking_seq", "counterparty_name", "short_name", "counterparty_iban",
                           "booking_text", "purpose", "creditor_id", "kind", "bank_ref_kind", "bank_ref"],
              userEdit: ["category_id", "note", "is_own_transfer"],
              monotone: ["is_new"]),
        table("rule", .userEdit, foreignKeys: ["category_id": "category"],
              userEdit: ["pattern", "category_id", "origin", "enabled"]),
        table("budget", .userEdit, foreignKeys: ["category_id": "category"],
              userEdit: ["category_id", "monthly_limit", "currency"]),
        table("setting", .mixed, immutable: ["key"], userEdit: ["value"]),
        table("standing_order", .bankLatest, foreignKeys: ["account_id": "account", "category_id": "category"],
              immutable: ["account_id"],
              bankLatest: ["recipient", "iban", "purpose", "amount", "currency", "rhythm", "day_of_month", "next_execution", "status"],
              userEdit: ["category_id"]),
        table("contract", .userEdit, foreignKeys: ["account_id": "account", "category_id": "category"],
              userEdit: ["provider", "account_id", "group_name", "category_id", "rhythm", "monthly_amount", "currency",
                         "next_debit", "notice_text", "notice_deadline", "renewal_date", "renewal_amount",
                         "price_change_amount", "price_change_start", "kind", "sort_order"]),
        table("holding", .bankLatest, foreignKeys: ["account_id": "account", "security_id": "security"],
              immutable: ["account_id", "security_id", "isin"],
              bankLatest: ["name", "quantity_micro", "price", "price_at", "cost_basis", "currency", "sort_order"]),
        table("depot_value_history", .bankImmutable, foreignKeys: ["account_id": "account"],
              immutable: ["account_id", "date", "value", "currency"]),
        table("savings_plan", .bankLatest, foreignKeys: ["account_id": "account", "source_account_id": "account"],
              immutable: ["account_id"],
              bankLatest: ["source_account_id", "amount", "currency", "day_of_month", "next_execution"]),
        table("savings_plan_item", .bankLatest, foreignKeys: ["plan_id": "savings_plan", "security_id": "security"],
              immutable: ["plan_id", "security_id"],
              bankLatest: ["amount", "sort_order"]),
    ]

    private static let byName: [String: SyncTable] = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })

    public static func table(_ name: String) -> SyncTable? { byName[name] }

    /// `id` is always allowed in an insert row; these names are the register and the bookkeeping columns.
    static let deletedAt = "deleted_at"
}
