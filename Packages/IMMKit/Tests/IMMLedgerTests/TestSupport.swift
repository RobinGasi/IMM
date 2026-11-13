import Foundation
import GRDB
@testable import IMMLedger

/// An encrypted, migrated ledger in a temporary directory.
final class TestLedger: Sendable {
    let directory: URL
    let store: LedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("imm-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase("x'" + String(repeating: "ab", count: 32) + "'")
        }
        let pool = try DatabasePool(path: directory.appendingPathComponent("data.sqlite").path, configuration: configuration)
        store = try LedgerStore(database: pool)
    }

    var database: DatabasePool { store.database }

    /// Seeds synced tables directly (fixtures), with the debug write guard lifted.
    @discardableResult
    func seed<T>(_ body: (Database) throws -> T) throws -> T {
        try database.write { db in try LedgerStore.unguarded(db) { try body(db) } }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

func d(_ iso: String) -> LocalDate {
    guard let date = LocalDate(iso: iso) else { fatalError("bad test date \(iso)") }
    return date
}

extension TransactionRecord {
    /// Compact fixture builder.
    static func fixture(
        _ id: String, account: String, _ date: String, _ amount: Int,
        category: String? = nil, time: String? = nil, seq: Int = 0,
        kind: TransactionKind = .cardPayment, own: Bool = false, new: Bool = false
    ) -> TransactionRecord {
        TransactionRecord(
            id: id, accountId: account, bookingDate: d(date), bookedTime: time, bookingSeq: seq,
            amount: amount, counterpartyName: id, kind: kind, categoryId: category,
            isOwnTransfer: own, isNew: new, bankRefKind: "bank", bankRef: id
        )
    }
}


/// A manually advanced wall clock.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var millis: UInt64

    init(millis: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) { self.millis = millis }

    var date: Date { lock.withLock { Date(timeIntervalSince1970: Double(millis) / 1000) } }
    var now: UInt64 { lock.withLock { millis } }
    func advance(by ms: UInt64) { lock.withLock { millis += ms } }
    /// Never lets the clock lag behind real time (a new ledger's clock state starts at the real time of its migration).
    func catchUpWithRealTime() {
        lock.withLock { millis = max(millis, UInt64(Date().timeIntervalSince1970 * 1000) + 1) }
    }
}

/// One device: its own encrypted ledger and a writer on a controllable clock.
final class Replica: Sendable {
    let ledger: TestLedger
    let clock: TestClock
    let writer: LedgerWriter

    init(clock: TestClock = TestClock()) throws {
        self.clock = clock
        ledger = try TestLedger()
        let source = clock
        source.catchUpWithRealTime()
        writer = LedgerWriter(store: ledger.store, now: { source.date })
    }

    var node: DeviceNodeID { writer.localNode }
    var database: DatabasePool { ledger.database }

    /// Every op this device authored.
    func ownOps() throws -> [SyncOp] { try writer.ops(from: node, after: 0, limit: .max) }

    func value(_ table: String, _ id: String, _ column: String) throws -> SyncValue? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT \"\(column)\" FROM \"\(table)\" WHERE id = ?", arguments: [id]).map { SyncValue(databaseValue: $0[0]) }
        }
    }

    func count(_ table: String, where clause: String = "1") throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \"\(table)\" WHERE \(clause)") ?? 0 }
    }
}

// MARK: Row builders

func categoryRow(_ id: String, name: String = "Category", sort: String = "V") -> [String: SyncValue] {
    ["id": .text(id), "name": .text(name), "color_token": .text("chart-1"), "kind": .text("expense"), "sort_order": .text(sort)]
}

func accountRow(_ id: String, name: String = "Giro", balance: Int = 0) -> [String: SyncValue] {
    ["id": .text(id), "kind": .text("giro"), "name": .text(name), "bank_name": .text("Bank"), "balance": SyncValue(balance),
     "currency": .text("EUR")]
}

func transactionRow(
    _ id: String, account: String, day: String = "2026-11-01", amount: Int = -100, category: String? = nil, isNew: Bool = false,
    shortName: String? = nil
) -> [String: SyncValue] {
    var row: [String: SyncValue] = [
        "id": .text(id), "account_id": .text(account), "booking_date": .text(day), "amount": SyncValue(amount), "currency": .text("EUR"),
        "counterparty_name": .text("Someone"), "kind": .text("card_payment"), "is_new": SyncValue(isNew),
    ]
    if let category { row["category_id"] = .text(category) }
    if let shortName { row["short_name"] = .text(shortName) }
    return row
}
