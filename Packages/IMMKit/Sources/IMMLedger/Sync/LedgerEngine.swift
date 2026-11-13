import Foundation
import GRDB

/// The stateless core of `LedgerWriter`: every function runs inside a write transaction the caller owns.
/// All state (clock, sequence numbers, field clocks) lives in the database, so it commits or rolls back with
/// the write it stamps.
struct LedgerEngine: Sendable {
    var now: @Sendable () -> Date

    static let system = LedgerEngine(now: { Date() })

    var nowMillis: UInt64 { UInt64(max(0, (now().timeIntervalSince1970 * 1000).rounded(.down))) }

    // MARK: Clock and sequence state

    struct State {
        var clock: HLCClock
        var nextSeq: Int64
    }

    static func nodeBits(_ node: DeviceNodeID) -> Int64 { Int64(bitPattern: node) }
    static func node(_ bits: Int64) -> DeviceNodeID { UInt64(bitPattern: bits) }

    /// The local device row, created on first use with a random node id.
    func localNode(_ db: Database) throws -> DeviceNodeID {
        if let bits = try Int64.fetchOne(db, sql: "SELECT node_id FROM sync_device WHERE is_local = 1") {
            return Self.node(bits)
        }
        return try Self.createLocalDevice(db, nowMillis: nowMillis)
    }

    /// Inserts the local `sync_device` row and the initial `hlc_state`. Used by migration v2 and as a fallback.
    @discardableResult
    static func createLocalDevice(_ db: Database, nowMillis: UInt64) throws -> DeviceNodeID {
        var node = UInt64.random(in: 1...UInt64.max)
        while try Int.fetchOne(db, sql: "SELECT 1 FROM sync_device WHERE node_id = ?", arguments: [nodeBits(node)]) != nil {
            node = UInt64.random(in: 1...UInt64.max)
        }
        try db.execute(
            sql: "INSERT INTO sync_device (id, node_id, name, is_local, created_at) VALUES (?, ?, NULL, 1, ?)",
            arguments: [UUID().uuidString, nodeBits(node), Date(timeIntervalSince1970: Double(nowMillis) / 1000)])
        try db.execute(
            sql: "INSERT OR IGNORE INTO hlc_state (id, hlc, op_seq) VALUES (1, ?, 1)",
            arguments: [HLC(millis: min(nowMillis, HLC.maxMillis), counter: 0, node: node).bytes])
        return node
    }

    /// The clock state. The stored clock carries the local node id, so no second lookup is needed.
    func loadState(_ db: Database) throws -> State {
        let statement = try db.cachedStatement(sql: "SELECT hlc, op_seq FROM hlc_state WHERE id = 1")
        if let row = try Row.fetchOne(statement), let hlc = HLC(bytes: row["hlc"] as Data) {
            return State(clock: HLCClock(last: hlc), nextSeq: row["op_seq"])
        }
        let node = try localNode(db)
        try db.execute(
            sql: "INSERT OR IGNORE INTO hlc_state (id, hlc, op_seq) VALUES (1, ?, 1)",
            arguments: [HLC(millis: min(nowMillis, HLC.maxMillis), counter: 0, node: node).bytes])
        return State(clock: HLCClock(node: node, now: nowMillis), nextSeq: 1)
    }

    func storeState(_ db: Database, _ state: State) throws {
        let statement = try db.cachedStatement(sql: "UPDATE hlc_state SET hlc = ?, op_seq = ? WHERE id = 1")
        try statement.execute(arguments: [state.clock.last.bytes, state.nextSeq])
    }

    /// Stamps one local write: advances the clock and appends the op.
    private func stamp(
        _ db: Database, _ state: inout State, kind: SyncOp.Kind, table: String, rowID: String, column: String?, payload: Data?
    ) throws -> HLC {
        let hlc: HLC
        do { hlc = try state.clock.send(now: nowMillis) } catch let error as HLCError { throw LedgerWriterError.drift(error) }
        let statement = try db.cachedStatement(sql: """
            INSERT INTO sync_op (device_id, seq, hlc, tbl, row_id, col, value, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        try statement.execute(arguments: [
            Self.nodeBits(hlc.node), state.nextSeq, hlc.bytes, table, rowID, column, payload, kind.rawValue,
        ])
        state.nextSeq += 1
        return hlc
    }

    // MARK: Row access

    private func columnValue(_ db: Database, table: String, rowID: String, column: String) throws -> SyncValue? {
        let statement = try db.cachedStatement(sql: "SELECT \"\(column)\" FROM \"\(table)\" WHERE id = ?")
        guard let row = try Row.fetchOne(statement, arguments: [rowID]) else { return nil }
        return SyncValue(databaseValue: row[0])
    }

    private func rowExists(_ db: Database, table: String, rowID: String) throws -> Bool {
        let statement = try db.cachedStatement(sql: "SELECT 1 FROM \"\(table)\" WHERE id = ?")
        return try Int.fetchOne(statement, arguments: [rowID]) != nil
    }

    private func clock(_ db: Database, table: String, rowID: String, column: String) throws -> HLC? {
        let statement = try db.cachedStatement(sql: "SELECT hlc FROM field_clock WHERE tbl = ? AND row_id = ? AND col = ?")
        guard let data = try Data.fetchOne(statement, arguments: [table, rowID, column]) else { return nil }
        return HLC(bytes: data)
    }

    private func putClock(_ db: Database, table: String, rowID: String, column: String, _ hlc: HLC) throws {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO field_clock (tbl, row_id, col, hlc) VALUES (?, ?, ?, ?)
            ON CONFLICT (tbl, row_id, col) DO UPDATE SET hlc = excluded.hlc
            """)
        try statement.execute(arguments: [table, rowID, column, hlc.bytes])
    }

    /// Stamps several fields of one row with the same clock in one statement.
    private func putClocks(_ db: Database, table: String, rowID: String, columns: [String], _ hlc: HLC) throws {
        guard !columns.isEmpty else { return }
        let marks = columns.map { _ in "(?, ?, ?, ?)" }.joined(separator: ", ")
        let statement = try db.cachedStatement(sql: """
            INSERT INTO field_clock (tbl, row_id, col, hlc) VALUES \(marks)
            ON CONFLICT (tbl, row_id, col) DO UPDATE SET hlc = excluded.hlc
            """)
        var arguments: [DatabaseValueConvertible] = []
        arguments.reserveCapacity(columns.count * 4)
        for column in columns { arguments += [table, rowID, column, hlc.bytes] }
        try statement.execute(arguments: StatementArguments(arguments))
    }

    private func updateColumn(_ db: Database, table: String, rowID: String, column: String, value: SyncValue, at date: Date) throws {
        let statement = try db.cachedStatement(sql: "UPDATE \"\(table)\" SET \"\(column)\" = ?, updated_at = ? WHERE id = ?")
        try statement.execute(arguments: [value.databaseValue, date, rowID])
    }

    private func validatedTable(_ name: String) throws -> SyncTable {
        guard let table = SyncSchema.table(name) else { throw LedgerWriterError.unknownTable(name) }
        return table
    }

    private func validateSettingRow(_ table: String, id: String) throws {
        if table == "setting", !SyncSchema.sharedSettingKeys.contains(id) { throw LedgerWriterError.notShared(id) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }

    // MARK: Local writes

    func set(_ db: Database, table tableName: String, rowID: String, column: String, to value: SyncValue) throws {
        let table = try validatedTable(tableName)
        guard let columnClass = table.columnClass(column) else {
            throw LedgerWriterError.unknownColumn(table: tableName, column: column)
        }
        guard columnClass != .immutable else { throw LedgerWriterError.immutableColumn(table: tableName, column: column) }
        try validateSettingRow(tableName, id: rowID)
        try WriteGuard.enter(db)
        defer { WriteGuard.exit(db) }

        guard let current = try columnValue(db, table: tableName, rowID: rowID, column: column) else {
            throw LedgerWriterError.noSuchRow(table: tableName, id: rowID)
        }
        let newValue = columnClass == .monotone ? Self.monotoneMerge(current, value) : value
        if newValue == current, try clock(db, table: tableName, rowID: rowID, column: column) != nil { return }

        var state = try loadState(db)
        let hlc = try stamp(db, &state, kind: .set, table: tableName, rowID: rowID, column: column, payload: try Self.encode(newValue))
        try updateColumn(db, table: tableName, rowID: rowID, column: column, value: newValue, at: hlc.date)
        try putClock(db, table: tableName, rowID: rowID, column: column, hlc)
        try storeState(db, state)
    }

    /// Creates a row. Returns false when the id exists (also as a tombstone).
    func insert(_ db: Database, table tableName: String, row: [String: SyncValue]) throws -> Bool {
        let table = try validatedTable(tableName)
        guard case .text(let id)? = row["id"] else { throw LedgerWriterError.missingID }
        try validateSettingRow(tableName, id: id)
        var written: [(name: String, value: SyncValue)] = []
        for (name, value) in row.sorted(by: { $0.key < $1.key }) where name != "id" {
            guard table.columnClass(name) != nil else { throw LedgerWriterError.unknownColumn(table: tableName, column: name) }
            if !value.isNull { written.append((name, value)) }
        }
        try WriteGuard.enter(db)
        defer { WriteGuard.exit(db) }
        if try rowExists(db, table: tableName, rowID: id) { return false }

        var state = try loadState(db)
        var logged: [String: SyncValue] = ["id": .text(id)]
        for (name, value) in written { logged[name] = value }
        let hlc = try stamp(db, &state, kind: .insert, table: tableName, rowID: id, column: nil, payload: try Self.encode(logged))
        try insertRow(db, table: table, id: id, values: written, at: hlc.date)
        try putClocks(db, table: tableName, rowID: id, columns: written.map(\.name).filter { table.columnClass($0) != .immutable }, hlc)
        try storeState(db, state)
        return true
    }

    func delete(_ db: Database, table tableName: String, rowID: String) throws {
        _ = try validatedTable(tableName)
        try validateSettingRow(tableName, id: rowID)
        try WriteGuard.enter(db)
        defer { WriteGuard.exit(db) }
        guard let current = try columnValue(db, table: tableName, rowID: rowID, column: SyncSchema.deletedAt) else {
            throw LedgerWriterError.noSuchRow(table: tableName, id: rowID)
        }
        if !current.isNull { return }
        var state = try loadState(db)
        let hlc = try stamp(db, &state, kind: .delete, table: tableName, rowID: rowID, column: nil, payload: nil)
        try updateColumn(db, table: tableName, rowID: rowID, column: SyncSchema.deletedAt, value: Self.tombstone(hlc), at: hlc.date)
        try putClock(db, table: tableName, rowID: rowID, column: SyncSchema.deletedAt, hlc)
        try storeState(db, state)
    }

    private func insertRow(_ db: Database, table: SyncTable, id: String, values: [(name: String, value: SyncValue)], at date: Date) throws {
        var columns = ["id"] + values.map(\.name) + ["created_at", "updated_at"]
        var arguments: [DatabaseValueConvertible?] = [id] + values.map { $0.value.databaseValue } + [date, date]
        if table.name == "setting" {
            columns.append("scope")
            arguments.append(SettingScope.shared)
        }
        let names = columns.map { "\"\($0)\"" }.joined(separator: ", ")
        let marks = columns.map { _ in "?" }.joined(separator: ", ")
        let statement = try db.cachedStatement(sql: "INSERT INTO \"\(table.name)\" (\(names)) VALUES (\(marks))")
        try statement.execute(arguments: StatementArguments(arguments))
    }

    func setSharedSetting(_ db: Database, _ key: SettingKey, _ value: String?) throws {
        guard key.scope == .shared else { throw LedgerWriterError.notShared(key.rawValue) }
        if try rowExists(db, table: "setting", rowID: key.rawValue) {
            try set(db, table: "setting", rowID: key.rawValue, column: "value", to: SyncValue(value))
        } else {
            _ = try insert(db, table: "setting", row: ["id": .text(key.rawValue), "key": .text(key.rawValue), "value": SyncValue(value)])
        }
    }

    /// The value of a `deleted_at` register written at `hlc`: the clock's wall time, so every replica stores the same text.
    static func tombstone(_ hlc: HLC) -> SyncValue { SyncValue(hlc.date) }

    /// "Read wins": `is_new` can only fall (1 → 0). NULL yields to any value.
    static func monotoneMerge(_ current: SyncValue, _ incoming: SyncValue) -> SyncValue {
        switch (current, incoming) {
        case (.integer(let a), .integer(let b)): return .integer(min(a, b))
        case (.null, _): return incoming
        default: return current
        }
    }

    // MARK: Remote writes

    enum Outcome: Equatable {
        case applied
        case ignored
        case quarantine(QuarantineReason)
    }

    private func missingParent(_ db: Database, table: SyncTable, values: [String: SyncValue]) throws -> Bool {
        for (column, parent) in table.foreignKeys {
            guard case .text(let id)? = values[column] else { continue }
            if try !rowExists(db, table: parent, rowID: id) { return true }
        }
        return false
    }

    /// Per-field merge of one incoming value. Returns true when the stored value or clock changed.
    @discardableResult
    func applyField(
        _ db: Database, table: String, rowID: String, column: String, value: SyncValue, hlc: HLC,
        columnClass: SyncColumnClass
    ) throws -> Bool {
        let current = try columnValue(db, table: table, rowID: rowID, column: column) ?? .null
        let known = try clock(db, table: table, rowID: rowID, column: column)

        if columnClass == .monotone {
            let merged = Self.monotoneMerge(current, value)
            var changed = false
            if merged != current {
                try updateColumn(db, table: table, rowID: rowID, column: column, value: merged, at: hlc.date)
                changed = true
            }
            if known == nil || hlc > known! {
                try putClock(db, table: table, rowID: rowID, column: column, hlc)
                changed = true
            }
            return changed
        }

        if let known, hlc <= known {
            // Lost (or duplicate). Remember what the loser wanted unless it is what we already hold.
            if hlc < known, value != current {
                try recordHistory(db, table: table, rowID: rowID, column: column, hlc: hlc, value: value)
            }
            return false
        }
        if let known, value != current {
            try recordHistory(db, table: table, rowID: rowID, column: column, hlc: known, value: current)
        }
        if value != current {
            try updateColumn(db, table: table, rowID: rowID, column: column, value: value, at: hlc.date)
        }
        try putClock(db, table: table, rowID: rowID, column: column, hlc)
        return true
    }

    private func recordHistory(_ db: Database, table: String, rowID: String, column: String, hlc: HLC, value: SyncValue) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO field_history (tbl, row_id, col, hlc, value) VALUES (?, ?, ?, ?, ?)",
            arguments: [table, rowID, column, hlc.bytes, try Self.encode(value)])
        try db.execute(
            sql: """
                DELETE FROM field_history WHERE tbl = ? AND row_id = ? AND col = ? AND hlc NOT IN (
                    SELECT hlc FROM field_history WHERE tbl = ? AND row_id = ? AND col = ? ORDER BY hlc DESC LIMIT 5)
                """,
            arguments: [table, rowID, column, table, rowID, column])
    }

    /// Applies one remote op (no logging, no cursor handling). Anything that cannot be applied yet or ever is
    /// reported as a quarantine reason; nothing is written in that case.
    func apply(_ db: Database, _ op: SyncOp, nowMillis: UInt64) throws -> Outcome {
        if op.hlc.millis > nowMillis, op.hlc.millis - nowMillis > HLCClock.maxDrift { return .quarantine(.drift) }
        guard let table = SyncSchema.table(op.table) else { return .quarantine(.unknownSchema) }
        if table.name == "setting", !SyncSchema.sharedSettingKeys.contains(op.rowID) { return .quarantine(.unknownSchema) }

        do {
            var outcome = Outcome.ignored
            try db.inSavepoint {
                outcome = try applyChecked(db, op, table: table)
                return .commit
            }
            return outcome
        } catch is DatabaseError {
            return .quarantine(.invalid)
        }
    }

    private func applyChecked(_ db: Database, _ op: SyncOp, table: SyncTable) throws -> Outcome {
        switch op.kind {
        case .set:
            guard let column = op.column, let value = op.value else { return .quarantine(.invalid) }
            guard let columnClass = table.columnClass(column), columnClass != .immutable else { return .quarantine(.unknownSchema) }
            guard try rowExists(db, table: table.name, rowID: op.rowID) else { return .quarantine(.orphan) }
            if try missingParent(db, table: table, values: [column: value]) { return .quarantine(.orphan) }
            let changed = try applyField(db, table: table.name, rowID: op.rowID, column: column, value: value, hlc: op.hlc, columnClass: columnClass)
            if changed { try bumpUpdatedAt(db, table: table.name, rowID: op.rowID, at: op.hlc.date) }
            return changed ? .applied : .ignored

        case .delete:
            guard try rowExists(db, table: table.name, rowID: op.rowID) else { return .quarantine(.orphan) }
            let changed = try applyField(
                db, table: table.name, rowID: op.rowID, column: SyncSchema.deletedAt, value: Self.tombstone(op.hlc),
                hlc: op.hlc, columnClass: .userEdit)
            return changed ? .applied : .ignored

        case .insert:
            guard var row = op.row, case .text(let id)? = row["id"], id == op.rowID else { return .quarantine(.invalid) }
            row["id"] = nil
            for name in row.keys where table.columnClass(name) == nil { return .quarantine(.unknownSchema) }
            if try missingParent(db, table: table, values: row) { return .quarantine(.orphan) }
            let present = row.filter { !$0.value.isNull }.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }

            if try !rowExists(db, table: table.name, rowID: id) {
                try insertRow(db, table: table, id: id, values: present, at: op.hlc.date)
                try putClocks(db, table: table.name, rowID: id, columns: present.map(\.name).filter { table.columnClass($0) != .immutable }, op.hlc)
                return .applied
            }
            var changed = false
            for (name, value) in present {
                guard let columnClass = table.columnClass(name), columnClass != .immutable else { continue }
                if try applyField(db, table: table.name, rowID: id, column: name, value: value, hlc: op.hlc, columnClass: columnClass) {
                    changed = true
                }
            }
            return changed ? .applied : .ignored
        }
    }

    private func bumpUpdatedAt(_ db: Database, table: String, rowID: String, at date: Date) throws {
        let statement = try db.cachedStatement(sql: "UPDATE \"\(table)\" SET updated_at = ? WHERE id = ?")
        try statement.execute(arguments: [date, rowID])
    }

    // MARK: Op log

    func storeOp(_ db: Database, _ op: SyncOp) throws -> Bool {
        let payload: Data?
        switch op.kind {
        case .set: payload = try Self.encode(op.value ?? .null)
        case .insert: payload = try Self.encode(op.row ?? [:])
        case .delete: payload = nil
        }
        let statement = try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO sync_op (device_id, seq, hlc, tbl, row_id, col, value, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        try statement.execute(arguments: [
            Self.nodeBits(op.device), op.seq, op.hlc.bytes, op.table, op.rowID, op.column, payload, op.kind.rawValue,
        ])
        return db.changesCount > 0
    }

    static func decodeOp(_ row: Row) throws -> SyncOp {
        let decoder = JSONDecoder()
        let kind = SyncOp.Kind(rawValue: row["kind"]) ?? .set
        let payload: Data? = row["value"]
        var op = SyncOp(
            device: node(row["device_id"]), seq: row["seq"], hlc: HLC(bytes: row["hlc"] as Data) ?? .zero, kind: kind,
            table: row["tbl"], rowID: row["row_id"], column: row["col"])
        switch kind {
        case .set: op.value = try payload.map { try decoder.decode(SyncValue.self, from: $0) } ?? .null
        case .insert: op.row = try payload.map { try decoder.decode([String: SyncValue].self, from: $0) } ?? [:]
        case .delete: break
        }
        return op
    }

    func ops(_ db: Database, from device: DeviceNodeID, after seq: Int64, limit: Int) throws -> [SyncOp] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT * FROM sync_op WHERE device_id = ? AND seq > ? ORDER BY seq LIMIT ?",
            arguments: [Self.nodeBits(device), seq, limit])
        return try rows.map(Self.decodeOp)
    }

    /// Moves the contiguous-prefix cursor of `device` over every op already in the log.
    func advanceCursor(_ db: Database, device: DeviceNodeID) throws {
        let bits = Self.nodeBits(device)
        var applied = try Int64.fetchOne(db, sql: "SELECT applied_seq FROM sync_cursor WHERE device_id = ?", arguments: [bits]) ?? 0
        let seqs = try Int64.fetchAll(
            db, sql: "SELECT seq FROM sync_op WHERE device_id = ? AND seq > ? ORDER BY seq", arguments: [bits, applied])
        for seq in seqs {
            if seq == applied + 1 { applied = seq } else { break }
        }
        try db.execute(
            sql: """
                INSERT INTO sync_cursor (device_id, applied_seq) VALUES (?, ?)
                ON CONFLICT (device_id) DO UPDATE SET applied_seq = excluded.applied_seq
                """,
            arguments: [bits, applied])
    }

    func cursors(_ db: Database) throws -> [SyncCursor] {
        let local = try localNode(db)
        var result: [DeviceNodeID: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT device_id, applied_seq FROM sync_cursor") {
            result[Self.node(row["device_id"])] = row["applied_seq"]
        }
        result[local] = try Int64.fetchOne(db, sql: "SELECT op_seq - 1 FROM hlc_state WHERE id = 1") ?? 0
        return result.map { SyncCursor(device: $0.key, appliedSeq: $0.value) }.sorted { $0.device < $1.device }
    }

    // MARK: Quarantine

    func quarantine(_ db: Database, _ op: SyncOp, reason: QuarantineReason) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_quarantine (device_id, seq, reason, op, quarantined_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (device_id, seq) DO UPDATE SET reason = excluded.reason
                """,
            arguments: [Self.nodeBits(op.device), op.seq, reason.rawValue, try Self.encode(op), now()])
    }

    func quarantined(_ db: Database) throws -> [QuarantinedOp] {
        let decoder = JSONDecoder()
        return try Row.fetchAll(db, sql: "SELECT reason, op FROM sync_quarantine ORDER BY device_id, seq").compactMap { row in
            guard let reason = QuarantineReason(rawValue: row["reason"]),
                  let op = try? decoder.decode(SyncOp.self, from: row["op"] as Data) else { return nil }
            return QuarantinedOp(op: op, reason: reason)
        }
    }

    /// Re-applies parked ops until no more of them can be applied. Returns the ops that left quarantine.
    func retryQuarantine(_ db: Database) throws -> [(device: DeviceNodeID, seq: Int64, applied: Bool)] {
        var resolved: [(device: DeviceNodeID, seq: Int64, applied: Bool)] = []
        let decoder = JSONDecoder()
        var progress = true
        while progress {
            progress = false
            let rows = try Row.fetchAll(
                db, sql: "SELECT device_id, seq, reason, op FROM sync_quarantine WHERE reason != 'invalid' ORDER BY device_id, seq")
            for row in rows {
                guard let op = try? decoder.decode(SyncOp.self, from: row["op"] as Data) else { continue }
                let outcome = try apply(db, op, nowMillis: nowMillis)
                switch outcome {
                case .applied, .ignored:
                    try db.execute(
                        sql: "DELETE FROM sync_quarantine WHERE device_id = ? AND seq = ?",
                        arguments: [row["device_id"] as Int64, row["seq"] as Int64])
                    resolved.append((op.device, op.seq, outcome == .applied))
                    progress = true
                case .quarantine(let reason):
                    if reason.rawValue != row["reason"] as String { try quarantine(db, op, reason: reason) }
                }
            }
        }
        return resolved
    }

    /// Applies a batch: logs each new op, applies it, parks what cannot be applied, retries parked ops, advances
    /// cursors and the local clock.
    func applyRemote(_ db: Database, _ ops: [SyncOp]) throws -> ApplyResult {
        try WriteGuard.enter(db)
        defer { WriteGuard.exit(db) }
        let local = try localNode(db)
        let nowMillis = self.nowMillis
        var result = ApplyResult()
        var devices = Set<DeviceNodeID>()
        var parked = Set<String>()
        var newest: HLC?

        for op in ops {
            // Our own ops coming back through a relay carry nothing new.
            if op.seq < 1 || op.device == local { result.ignored += 1; continue }
            guard try storeOp(db, op) else { result.ignored += 1; continue }
            devices.insert(op.device)
            let outcome = try apply(db, op, nowMillis: nowMillis)
            switch outcome {
            case .applied: result.applied += 1
            case .ignored: result.ignored += 1
            case .quarantine(let reason):
                try quarantine(db, op, reason: reason)
                result.quarantined += 1
                parked.insert("\(op.device):\(op.seq)")
            }
            if outcome != .quarantine(.drift), newest.map({ op.hlc > $0 }) ?? true { newest = op.hlc }
        }

        for resolved in try retryQuarantine(db) {
            if resolved.applied { result.applied += 1 } else { result.ignored += 1 }
            if parked.contains("\(resolved.device):\(resolved.seq)") { result.quarantined -= 1 }
        }
        for device in devices { try advanceCursor(db, device: device) }
        if let newest { try absorb(db, newest) }
        return result
    }

    /// Moves the local clock past `remote` (Kulkarni receive) and stores it.
    func absorb(_ db: Database, _ remote: HLC) throws {
        var state = try loadState(db)
        do { try state.clock.receive(remote, now: nowMillis) } catch let error as HLCError { throw LedgerWriterError.drift(error) }
        try storeState(db, state)
    }
}
