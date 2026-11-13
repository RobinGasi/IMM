import Foundation
import GRDB

/// Debug-only enforcement of "`LedgerWriter` is the only mutator of synced tables".
///
/// `LedgerStore` installs, on its writer connection, a temp table `imm_write_guard(depth)` and temp
/// triggers on every synced table. Each trigger aborts an INSERT, DELETE or UPDATE of a synced column
/// (and of shared `setting` rows) while `depth` is 0. `LedgerWriter` raises `depth` for the length of its
/// own write transaction; `LedgerStore.unguarded(_:)` does the same for test fixtures. Temp objects live
/// and die with the connection, so nothing is persisted and release builds carry none of it.
enum WriteGuard {
    #if DEBUG
    static let enabled = true

    static func install(_ db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM sqlite_temp_master WHERE name = 'imm_write_guard'") == nil else { return }
        try db.execute(sql: "CREATE TEMP TABLE imm_write_guard (depth INTEGER NOT NULL)")
        try db.execute(sql: "INSERT INTO imm_write_guard VALUES (0)")
        let message = "synced tables change only through LedgerWriter"
        for table in SyncSchema.tables {
            // Shared `setting` rows are the only synced ones of that table; every other table syncs whole.
            func condition(_ row: String) -> String {
                var condition = "(SELECT depth FROM temp.imm_write_guard) = 0"
                if table.name == "setting" { condition += " AND \(row).scope = 'shared'" }
                return condition
            }
            try db.execute(sql: """
                CREATE TEMP TRIGGER imm_guard_insert_\(table.name) BEFORE INSERT ON main."\(table.name)"
                WHEN \(condition("NEW")) BEGIN SELECT RAISE(ABORT, '\(message): insert into \(table.name)'); END
                """)
            try db.execute(sql: """
                CREATE TEMP TRIGGER imm_guard_delete_\(table.name) BEFORE DELETE ON main."\(table.name)"
                WHEN \(condition("OLD")) BEGIN SELECT RAISE(ABORT, '\(message): delete from \(table.name)'); END
                """)
            let columns = (table.columnNames + [SyncSchema.deletedAt]).map { "\"\($0)\"" }.joined(separator: ", ")
            try db.execute(sql: """
                CREATE TEMP TRIGGER imm_guard_update_\(table.name) BEFORE UPDATE OF \(columns) ON main."\(table.name)"
                WHEN \(condition("NEW")) BEGIN SELECT RAISE(ABORT, '\(message): update of \(table.name)'); END
                """)
        }
    }

    static func enter(_ db: Database) throws {
        try db.execute(sql: "UPDATE temp.imm_write_guard SET depth = depth + 1")
    }

    static func exit(_ db: Database) {
        try? db.execute(sql: "UPDATE temp.imm_write_guard SET depth = depth - 1")
    }
    #else
    static let enabled = false
    static func install(_ db: Database) throws {}
    static func enter(_ db: Database) throws {}
    static func exit(_ db: Database) {}
    #endif
}
