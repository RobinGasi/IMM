import Foundation
import GRDB

/// Whether a setting syncs between devices.
extension SettingKey {
    /// `shared` keys go through `LedgerWriter` and sync; `local` keys stay on this device.
    public var scope: SettingScope {
        SyncSchema.sharedSettingKeys.contains(rawValue) ? .shared : .local
    }
}

/// Keys of the `setting` table.
public enum SettingKey: String, Sendable, CaseIterable {
    case rolloverEnabled = "rollover_enabled"
    case autoLockMinutes = "auto_lock_minutes"
    case lockOnSleep = "lock_on_sleep"
    case demoOnly = "demo_only"
    case ledgerToday = "ledger_today"
}

/// Entry point to the ledger: owns the migrated database, the writer and the settings accessors.
public final class LedgerStore: Sendable {
    public let database: DatabasePool
    /// The only mutator of synced tables.
    public let writer: LedgerWriter

    /// Runs the schema migrator on `database` and arms the debug write guard.
    public init(database: DatabasePool) throws {
        try LedgerSchema.migrate(database)
        try database.write { try WriteGuard.install($0) }
        self.database = database
        self.writer = LedgerWriter(database: database)
    }

    /// Runs `body` with the debug write guard lifted (test fixtures that seed synced tables directly; never
    /// use it in app code). A no-op in release builds.
    public static func unguarded<T>(_ db: Database, _ body: () throws -> T) throws -> T {
        try WriteGuard.enter(db)
        defer { WriteGuard.exit(db) }
        return try body()
    }

    /// "Today" for the ledger: `ledger_today` while the database holds only demo data, else the system date.
    public func today() throws -> LocalDate {
        try database.read { try LedgerClock.today($0) }
    }

    public func setting(_ key: SettingKey) throws -> String? {
        try database.read { try Self.setting(key, in: $0) }
    }

    /// Sets a setting; `nil` removes it. Shared keys go through the writer (and sync), local keys stay here.
    public func setSetting(_ key: SettingKey, _ value: String?) throws {
        try database.write { try Self.setSetting(key, value, in: $0) }
    }

    /// Reads a setting inside an existing transaction.
    public static func setting(_ key: SettingKey, in db: Database) throws -> String? {
        let row = try Row.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ? AND deleted_at IS NULL", arguments: [key.rawValue])
        guard let row else { return nil }
        let value: String? = row["value"]
        return value
    }

    /// Writes a setting inside an existing write transaction; `nil` removes it. Local keys are written
    /// directly (device-local rows never reach the op log); shared keys are routed through the ledger writer.
    public static func setSetting(_ key: SettingKey, _ value: String?, in db: Database) throws {
        if key.scope == .shared {
            try LedgerEngine.system.setSharedSetting(db, key, value)
            return
        }
        guard let value else {
            try db.execute(sql: "DELETE FROM setting WHERE id = ? AND scope = 'local'", arguments: [key.rawValue])
            return
        }
        let now = Date()
        try db.execute(
            sql: """
                INSERT INTO setting (id, key, scope, value, created_at, updated_at) VALUES (?, ?, 'local', ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at, deleted_at = NULL
                """,
            arguments: [key.rawValue, key.rawValue, value, now, now])
    }
}

/// The ledger's notion of "today".
public enum LedgerClock {
    /// `ledger_today` when the setting `demo_only` is `"1"` (and `ledger_today` parses), otherwise the
    /// calendar day of `now` in `timeZone`.
    public static func today(_ db: Database, now: Date = Date(), timeZone: TimeZone = .current) throws -> LocalDate {
        if try LedgerStore.setting(.demoOnly, in: db) == "1",
           let iso = try LedgerStore.setting(.ledgerToday, in: db),
           let date = LocalDate(iso: iso) {
            return date
        }
        return LocalDate(now, timeZone: timeZone)
    }
}
