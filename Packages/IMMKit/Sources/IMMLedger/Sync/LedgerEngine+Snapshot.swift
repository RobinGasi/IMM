import Foundation
import GRDB

extension LedgerEngine {
    func snapshot(_ db: Database) throws -> LedgerSnapshot {
        var tables: [String: [LedgerSnapshot.Row]] = [:]
        for table in SyncSchema.tables {
            let columns = table.columnNames
            let list = (["id"] + columns + [SyncSchema.deletedAt]).map { "\"\($0)\"" }.joined(separator: ", ")
            let filter = table.name == "setting" ? " WHERE scope = 'shared'" : ""
            var rows: [LedgerSnapshot.Row] = []
            for row in try Row.fetchAll(db, sql: "SELECT \(list) FROM \"\(table.name)\"\(filter) ORDER BY id") {
                var values: [String: SyncValue] = [:]
                for column in columns + [SyncSchema.deletedAt] {
                    let value = SyncValue(databaseValue: row[column] as DatabaseValue)
                    if !value.isNull { values[column] = value }
                }
                rows.append(.init(id: row["id"], values: values))
            }
            tables[table.name] = rows
        }
        let registered = Set(SyncSchema.tables.map(\.name))
        let clocks = try Row.fetchAll(db, sql: "SELECT tbl, row_id, col, hlc FROM field_clock ORDER BY tbl, row_id, col").compactMap { row -> LedgerSnapshot.FieldClock? in
            let table: String = row["tbl"]
            guard registered.contains(table), let hlc = HLC(bytes: row["hlc"] as Data) else { return nil }
            return .init(table: table, rowID: row["row_id"], column: row["col"], hlc: hlc)
        }
        let state = try loadState(db)
        return LedgerSnapshot(
            schemaVersion: SyncSchema.version, tables: tables, fieldClocks: clocks, cursors: try cursors(db), hlc: state.clock.last)
    }

    /// Merges `snapshot` into this ledger (per-field last-writer-wins, as for ops) and adopts its cursors.
    /// Needs a ledger without local edits; migration-stamped values (clock millis 1) lose to the snapshot's.
    func applySnapshot(_ db: Database, _ snapshot: LedgerSnapshot) throws {
        guard snapshot.schemaVersion == SyncSchema.version else { throw LedgerWriterError.snapshotSchemaMismatch(snapshot.schemaVersion) }
        let local = try localNode(db)
        if try Int.fetchOne(db, sql: "SELECT 1 FROM sync_op WHERE device_id = ? LIMIT 1", arguments: [Self.nodeBits(local)]) != nil {
            throw LedgerWriterError.ledgerHasLocalEdits
        }
        try WriteGuard.enter(db)
        defer { WriteGuard.exit(db) }
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

        var clocks: [String: [String: HLC]] = [:]   // "table\0row" → column → clock
        for clock in snapshot.fieldClocks {
            clocks[clock.table + "\u{0}" + clock.rowID, default: [:]][clock.column] = clock.hlc
        }
        for table in SyncSchema.tables {
            for row in snapshot.tables[table.name] ?? [] {
                let rowClocks = clocks[table.name + "\u{0}" + row.id] ?? [:]
                let stamp = rowClocks.values.max() ?? snapshot.hlc
                let columns = table.columnNames + [SyncSchema.deletedAt]
                if try Int.fetchOne(db, sql: "SELECT 1 FROM \"\(table.name)\" WHERE id = ?", arguments: [row.id]) == nil {
                    var names = ["id"], arguments: [DatabaseValueConvertible?] = [row.id]
                    for column in columns { if let value = row.values[column] { names.append(column); arguments.append(value.databaseValue) } }
                    names += ["created_at", "updated_at"]
                    arguments += [stamp.date, stamp.date]
                    if table.name == "setting" { names.append("scope"); arguments.append(SettingScope.shared) }
                    let quoted = names.map { "\"\($0)\"" }.joined(separator: ", ")
                    let marks = names.map { _ in "?" }.joined(separator: ", ")
                    try db.execute(sql: "INSERT INTO \"\(table.name)\" (\(quoted)) VALUES (\(marks))", arguments: StatementArguments(arguments))
                    for (column, hlc) in rowClocks {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO field_clock (tbl, row_id, col, hlc) VALUES (?, ?, ?, ?)",
                            arguments: [table.name, row.id, column, hlc.bytes])
                    }
                } else {
                    for (column, hlc) in rowClocks {
                        let columnClass = column == SyncSchema.deletedAt ? SyncColumnClass.userEdit : table.columnClass(column)
                        guard let columnClass, columnClass != .immutable else { continue }
                        try applyField(
                            db, table: table.name, rowID: row.id, column: column, value: row.values[column] ?? .null, hlc: hlc,
                            columnClass: columnClass)
                    }
                }
            }
        }
        for cursor in snapshot.cursors where cursor.device != local {
            try db.execute(
                sql: """
                    INSERT INTO sync_cursor (device_id, applied_seq) VALUES (?, ?)
                    ON CONFLICT (device_id) DO UPDATE SET applied_seq = MAX(applied_seq, excluded.applied_seq)
                    """,
                arguments: [Self.nodeBits(cursor.device), cursor.appliedSeq])
        }
        try absorb(db, snapshot.hlc)
    }
}
