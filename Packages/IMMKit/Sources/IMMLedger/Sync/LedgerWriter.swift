import Foundation
import GRDB

/// The only mutator of synced tables.
///
/// A local write updates the row, its field clock, the hybrid logical clock and appends a `sync_op`, all in
/// one transaction. `applyRemote` merges ops from other devices per field (latest clock wins, `is_new` read
/// wins, `deleted_at` is its own register), records losing values in `field_history`, parks ops it cannot apply
/// yet in `sync_quarantine` and never re-logs what it applies. See `SyncSchema` for what syncs.
///
/// Methods taking `in db:` run inside the caller's write transaction (batch writers such as the importer);
/// the others open their own. In debug builds a temp trigger aborts any write to a synced table that does not
/// go through this type (see `WriteGuard`).
public final class LedgerWriter: Sendable {
    let database: DatabasePool
    let engine: LedgerEngine
    private let node: DeviceNodeID

    public convenience init(store: LedgerStore) {
        self.init(database: store.database)
    }

    /// `now` is the wall clock (tests inject a controllable one).
    public init(database: DatabasePool, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.engine = LedgerEngine(now: now)
        // The local device row exists after migration v2; the lookup only fails on a closed database.
        let engine = self.engine
        self.node = (try? database.write { try engine.localNode($0) }) ?? 0
    }

    public convenience init(store: LedgerStore, now: @escaping @Sendable () -> Date) {
        self.init(database: store.database, now: now)
    }

    /// This device's node id (from the local `sync_device` row).
    public var localNode: DeviceNodeID { node }

    // MARK: Local edits

    public func set(table: String, rowID: String, column: String, to value: SyncValue) throws {
        try database.write { try engine.set($0, table: table, rowID: rowID, column: column, to: value) }
    }

    public func set(table: String, rowID: String, column: String, to value: SyncValue, in db: Database) throws {
        try engine.set(db, table: table, rowID: rowID, column: column, to: value)
    }

    /// Several columns of one row, one clock tick each.
    public func set(table: String, rowID: String, values: [String: SyncValue]) throws {
        try database.write { try set(table: table, rowID: rowID, values: values, in: $0) }
    }

    public func set(table: String, rowID: String, values: [String: SyncValue], in db: Database) throws {
        for (column, value) in values.sorted(by: { $0.key < $1.key }) {
            try engine.set(db, table: table, rowID: rowID, column: column, to: value)
        }
    }

    /// Creates a row from `row` (`id` included; NULL columns are left out). Returns false, changing nothing,
    /// when the id already exists (also as a tombstone): bank-immutable rows are written once.
    @discardableResult
    public func insertImmutable(table: String, row: [String: SyncValue]) throws -> Bool {
        try database.write { try engine.insert($0, table: table, row: row) }
    }

    @discardableResult
    public func insertImmutable(table: String, row: [String: SyncValue], in db: Database) throws -> Bool {
        try engine.insert(db, table: table, row: row)
    }

    /// Tombstones a row (`deleted_at` register).
    public func delete(table: String, rowID: String) throws {
        try database.write { try engine.delete($0, table: table, rowID: rowID) }
    }

    public func delete(table: String, rowID: String, in db: Database) throws {
        try engine.delete(db, table: table, rowID: rowID)
    }

    // MARK: Sync surface

    /// Ops of `device` with `seq` greater than `after`, ascending (the local device's own and relayed ones).
    public func ops(from device: DeviceNodeID, after seq: Int64, limit: Int) throws -> [SyncOp] {
        try database.read { try engine.ops($0, from: device, after: seq, limit: limit) }
    }

    /// Highest contiguous applied sequence per device, the local device included.
    public func cursors() throws -> [SyncCursor] {
        try database.read { try engine.cursors($0) }
    }

    /// Applies a batch from other devices. Idempotent; any order, any duplicates.
    @discardableResult
    public func applyRemote(_ ops: [SyncOp]) throws -> ApplyResult {
        try database.write { try engine.applyRemote($0, ops) }
    }

    @discardableResult
    public func applyRemote(_ ops: [SyncOp], in db: Database) throws -> ApplyResult {
        try engine.applyRemote(db, ops)
    }

    /// Re-applies quarantined ops (call when time has passed or a schema upgrade may have made them applicable).
    @discardableResult
    public func retryQuarantine() throws -> ApplyResult {
        try database.write { db in
            try WriteGuard.enter(db)
            defer { WriteGuard.exit(db) }
            var result = ApplyResult()
            for resolved in try engine.retryQuarantine(db) {
                if resolved.applied { result.applied += 1 } else { result.ignored += 1 }
            }
            return result
        }
    }

    public func quarantinedOps() throws -> [QuarantinedOp] {
        try database.read { try engine.quarantined($0) }
    }

    public func snapshot() throws -> LedgerSnapshot {
        try database.read { try engine.snapshot($0) }
    }

    /// Bootstraps this ledger from another device's snapshot. Throws `ledgerHasLocalEdits` after local edits.
    public func applySnapshot(_ snapshot: LedgerSnapshot) throws {
        try database.write { try engine.applySnapshot($0, snapshot) }
    }

    /// The losing values recorded for one field, newest first (at most five).
    public func fieldHistory(table: String, rowID: String, column: String) throws -> [(hlc: HLC, value: SyncValue)] {
        try database.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(
                db, sql: "SELECT hlc, value FROM field_history WHERE tbl = ? AND row_id = ? AND col = ? ORDER BY hlc DESC",
                arguments: [table, rowID, column]
            ).compactMap { row in
                guard let hlc = HLC(bytes: row["hlc"] as Data),
                      let value = try? decoder.decode(SyncValue.self, from: row["value"] as Data) else { return nil }
                return (hlc, value)
            }
        }
    }
}
