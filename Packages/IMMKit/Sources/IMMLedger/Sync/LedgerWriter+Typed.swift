import Foundation
import GRDB

/// Typed edits on top of the generic writer. The UI and the importer use these; the generic API is for sync.
extension LedgerWriter {
    // MARK: Records

    /// The synced columns of `record` as an insert row (`id` included; NULL columns are left out by the writer).
    public func syncRow<R: LedgerRecord>(_ record: R) throws -> [String: SyncValue] {
        guard let table = SyncSchema.table(R.databaseTableName) else { throw LedgerWriterError.unknownTable(R.databaseTableName) }
        let dictionary = try record.databaseDictionary
        var row: [String: SyncValue] = ["id": .text(record.id)]
        for column in table.columnNames {
            if let value = dictionary[column] { row[column] = SyncValue(databaseValue: value) }
        }
        return row
    }

    /// Inserts `record` unless its id exists (also as a tombstone). Returns whether it was inserted.
    @discardableResult
    public func insert<R: LedgerRecord>(_ record: R, in db: Database) throws -> Bool {
        try insertImmutable(table: R.databaseTableName, row: try syncRow(record), in: db)
    }

    /// Inserts `record`; when the id exists, brings the listed columns up to the record's values (changed ones only).
    public func upsert<R: LedgerRecord>(_ record: R, refreshing columns: [String], in db: Database) throws {
        let row = try syncRow(record)
        let list = columns.map { "\"\($0)\"" }.joined(separator: ", ")
        let current = try Row.fetchOne(
            db, sql: "SELECT \(list) FROM \"\(R.databaseTableName)\" WHERE id = ?", arguments: [record.id])
        guard let current else {
            try insertImmutable(table: R.databaseTableName, row: row, in: db)
            return
        }
        var changes: [String: SyncValue] = [:]
        for column in columns {
            let incoming = row[column] ?? .null
            if SyncValue(databaseValue: current[column] as DatabaseValue) != incoming { changes[column] = incoming }
        }
        if !changes.isEmpty { try set(table: R.databaseTableName, rowID: record.id, values: changes, in: db) }
    }

    // MARK: Transactions

    public func setCategory(transactionID: String, categoryID: String?) throws {
        try set(table: "ledger_transaction", rowID: transactionID, column: "category_id", to: SyncValue(categoryID))
    }

    /// Files several bookings under one category in a single transaction (Suggestions "Accept sure").
    public func setCategory(transactionIDs: [String], categoryID: String?) throws {
        try database.write { db in
            for id in transactionIDs {
                try engine.set(db, table: "ledger_transaction", rowID: id, column: "category_id", to: SyncValue(categoryID))
            }
        }
    }

    public func setNote(transactionID: String, note: String?) throws {
        let trimmed = note?.isEmpty == true ? nil : note
        try set(table: "ledger_transaction", rowID: transactionID, column: "note", to: SyncValue(trimmed))
    }

    /// Clears `is_new` ("read wins": a device that reads a booking ends its "new" state everywhere).
    public func markSeen(transactionID: String) throws {
        try set(table: "ledger_transaction", rowID: transactionID, column: "is_new", to: .integer(0))
    }

    public func markSeen(transactionIDs: [String]) throws {
        try database.write { db in
            for id in transactionIDs {
                try engine.set(db, table: "ledger_transaction", rowID: id, column: "is_new", to: .integer(0))
            }
        }
    }

    // MARK: Rules

    /// "Always file X under Y". An existing live rule with the same pattern and category is re-enabled
    /// instead of duplicated. Returns the rule's id.
    @discardableResult
    public func addRule(pattern: String, categoryID: String, origin: RuleOrigin = .manual) throws -> String {
        try database.write { try addRule(pattern: pattern, categoryID: categoryID, origin: origin, in: $0) }
    }

    @discardableResult
    public func addRule(pattern: String, categoryID: String, origin: RuleOrigin = .manual, in db: Database) throws -> String {
        if let existing = try Row.fetchOne(
            db, sql: "SELECT id, enabled FROM rule WHERE pattern = ? AND category_id = ? AND deleted_at IS NULL ORDER BY id LIMIT 1",
            arguments: [pattern, categoryID]) {
            let id: String = existing["id"]
            if existing["enabled"] as Int == 0 { try set(table: "rule", rowID: id, column: "enabled", to: .integer(1), in: db) }
            return id
        }
        let id = UUID().uuidString
        try insertImmutable(table: "rule", row: [
            "id": .text(id), "pattern": .text(pattern), "category_id": .text(categoryID),
            "origin": .text(origin.rawValue), "enabled": .integer(1),
        ], in: db)
        return id
    }

    /// Changes the given fields of a rule.
    public func setRule(id: String, pattern: String? = nil, categoryID: String? = nil, enabled: Bool? = nil) throws {
        var values: [String: SyncValue] = [:]
        if let pattern { values["pattern"] = .text(pattern) }
        if let categoryID { values["category_id"] = .text(categoryID) }
        if let enabled { values["enabled"] = SyncValue(enabled) }
        try set(table: "rule", rowID: id, values: values)
    }

    public func deleteRule(id: String) throws {
        try delete(table: "rule", rowID: id)
    }

    // MARK: Settings

    /// Sets a shared setting (syncs). `nil` stores NULL, which readers treat as unset. Device-local keys go
    /// through `LedgerStore.setSetting` and never reach the op log.
    public func setSetting(_ key: SettingKey, _ value: String?) throws {
        try database.write { try setSetting(key, value, in: $0) }
    }

    public func setSetting(_ key: SettingKey, _ value: String?, in db: Database) throws {
        try engine.setSharedSetting(db, key, value)
    }

    // MARK: Account sync status (bank-latest fields)

    /// Marks live accounts as synced at `date`: all of them, or only those of one bank login.
    public func markAccountsSynced(loginID: String? = nil, at date: Date) throws {
        try database.write { try markAccountsSynced(loginID: loginID, at: date, in: $0) }
    }

    public func markAccountsSynced(loginID: String? = nil, at date: Date, in db: Database) throws {
        let ids: [String]
        if let loginID {
            ids = try String.fetchAll(db, sql: "SELECT id FROM account WHERE bank_login_id = ? AND deleted_at IS NULL ORDER BY id", arguments: [loginID])
        } else {
            ids = try String.fetchAll(db, sql: "SELECT id FROM account WHERE deleted_at IS NULL ORDER BY id")
        }
        for id in ids {
            try set(table: "account", rowID: id, values: [
                "last_synced_at": SyncValue(date), "sync_status": .text(AccountSyncStatus.ok.rawValue), "sync_status_text": .null,
            ], in: db)
        }
    }

    public func markAccountSyncFailed(accountID: String, text: String) throws {
        try set(table: "account", rowID: accountID, values: [
            "sync_status": .text(AccountSyncStatus.failed.rawValue), "sync_status_text": .text(text),
        ])
    }
}
