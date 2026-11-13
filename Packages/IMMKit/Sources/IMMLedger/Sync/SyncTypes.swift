import Foundation
import GRDB

/// One SQLite value of a synced column.
public enum SyncValue: Hashable, Sendable, Codable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: String?) { self = value.map(SyncValue.text) ?? .null }
    public init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    /// A timestamp in GRDB's `Date` text format (what `DatabaseValueConvertible` writes).
    public init(_ value: Date?) { self = value.map { SyncValue(databaseValue: $0.databaseValue) } ?? .null }
    public init(_ value: LocalDate?) { self = value.map { .text($0.iso) } ?? .null }

    public init(databaseValue: DatabaseValue) {
        switch databaseValue.storage {
        case .null: self = .null
        case .int64(let v): self = .integer(v)
        case .double(let v): self = .real(v)
        case .string(let v): self = .text(v)
        case .blob(let v): self = .blob(v)
        }
    }

    public var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .integer(let v): return v.databaseValue
        case .real(let v): return v.databaseValue
        case .text(let v): return v.databaseValue
        case .blob(let v): return v.databaseValue
        }
    }

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var text: String? { if case .text(let v) = self { return v }; return nil }
    public var integer: Int64? { if case .integer(let v) = self { return v }; return nil }

    // Compact JSON: {"t":"n"} | {"t":"i","v":5} | {"t":"r","v":1.5} | {"t":"s","v":"x"} | {"t":"b","v":"<base64>"}.
    private enum CodingKeys: String, CodingKey { case t, v }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "n": self = .null
        case "i": self = .integer(try c.decode(Int64.self, forKey: .v))
        case "r": self = .real(try c.decode(Double.self, forKey: .v))
        case "s": self = .text(try c.decode(String.self, forKey: .v))
        case "b": self = .blob(try c.decode(Data.self, forKey: .v))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown SyncValue type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: try c.encode("n", forKey: .t)
        case .integer(let v): try c.encode("i", forKey: .t); try c.encode(v, forKey: .v)
        case .real(let v): try c.encode("r", forKey: .t); try c.encode(v, forKey: .v)
        case .text(let v): try c.encode("s", forKey: .t); try c.encode(v, forKey: .v)
        case .blob(let v): try c.encode("b", forKey: .t); try c.encode(v, forKey: .v)
        }
    }
}

/// One entry of the op log. Ops are idempotent and commute: applying any multiset of them in any order
/// and with any duplicates gives the same ledger.
public struct SyncOp: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// Sets one column (`column`, `value`).
        case set
        /// Creates a row (`row` holds every written synced column, `id` included). Immutable columns are
        /// written once; the other columns take part in per-field last-writer-wins with the op's clock.
        case insert
        /// Sets the row's `deleted_at` register (tombstone). `column` and `value` are nil.
        case delete
    }

    public var device: DeviceNodeID
    /// Gap-free per device, starts at 1.
    public var seq: Int64
    public var hlc: HLC
    public var kind: Kind
    public var table: String
    public var rowID: String
    public var column: String?
    public var value: SyncValue?
    public var row: [String: SyncValue]?

    public init(
        device: DeviceNodeID, seq: Int64, hlc: HLC, kind: Kind, table: String, rowID: String,
        column: String? = nil, value: SyncValue? = nil, row: [String: SyncValue]? = nil
    ) {
        self.device = device
        self.seq = seq
        self.hlc = hlc
        self.kind = kind
        self.table = table
        self.rowID = rowID
        self.column = column
        self.value = value
        self.row = row
    }
}

/// How far this ledger has applied the ops of one device: the highest `seq` such that every op from 1 to it is present.
public struct SyncCursor: Hashable, Sendable, Codable {
    public var device: DeviceNodeID
    public var appliedSeq: Int64

    public init(device: DeviceNodeID, appliedSeq: Int64) {
        self.device = device
        self.appliedSeq = appliedSeq
    }
}

public struct ApplyResult: Sendable, Equatable {
    /// Ops that changed the ledger (a row, a value or a clock).
    public var applied: Int
    /// Duplicates and ops that lost to a newer write.
    public var ignored: Int
    /// Ops parked in `sync_quarantine` by this call.
    public var quarantined: Int

    public init(applied: Int = 0, ignored: Int = 0, quarantined: Int = 0) {
        self.applied = applied
        self.ignored = ignored
        self.quarantined = quarantined
    }
}

/// Why an op waits in `sync_quarantine`.
public enum QuarantineReason: String, Sendable, Codable, CaseIterable {
    /// The table, column or row class is not in `SyncSchema` (a newer app version wrote it).
    case unknownSchema
    /// The row or a parent row it references has not arrived yet. Retried after every later apply.
    case orphan
    /// The op's clock is more than five minutes ahead of this device's wall clock. Retried when time catches up.
    case drift
    /// The op is malformed or violates a constraint. Kept for inspection, never retried.
    case invalid
}

public struct QuarantinedOp: Sendable, Equatable {
    public var op: SyncOp
    public var reason: QuarantineReason
}

/// All synced rows with their field clocks and the cursors they correspond to.
public struct LedgerSnapshot: Sendable, Codable, Equatable {
    public struct Row: Sendable, Codable, Hashable {
        public var id: String
        /// Every synced column that is not NULL, plus `deleted_at` when the row is a tombstone.
        public var values: [String: SyncValue]
        public init(id: String, values: [String: SyncValue]) {
            self.id = id
            self.values = values
        }
    }

    public struct FieldClock: Sendable, Codable, Hashable {
        public var table: String
        public var rowID: String
        public var column: String
        public var hlc: HLC
        public init(table: String, rowID: String, column: String, hlc: HLC) {
            self.table = table
            self.rowID = rowID
            self.column = column
            self.hlc = hlc
        }
    }

    public var schemaVersion: Int
    /// Rows per table, ordered by id.
    public var tables: [String: [Row]]
    /// Ordered by table, row id, column.
    public var fieldClocks: [FieldClock]
    public var cursors: [SyncCursor]
    /// The newest clock this ledger has issued or seen.
    public var hlc: HLC

    public init(schemaVersion: Int, tables: [String: [Row]], fieldClocks: [FieldClock], cursors: [SyncCursor], hlc: HLC) {
        self.schemaVersion = schemaVersion
        self.tables = tables
        self.fieldClocks = fieldClocks
        self.cursors = cursors
        self.hlc = hlc
    }

    /// The part that must be identical on every converged replica (rows and field clocks).
    public var converged: LedgerSnapshot {
        LedgerSnapshot(schemaVersion: schemaVersion, tables: tables, fieldClocks: fieldClocks, cursors: [], hlc: .zero)
    }
}

public enum LedgerWriterError: Error, Equatable, Sendable {
    case unknownTable(String)
    case unknownColumn(table: String, column: String)
    /// The column is written once at insert (bank-immutable) and cannot be set.
    case immutableColumn(table: String, column: String)
    case noSuchRow(table: String, id: String)
    case missingID
    /// `setting` rows only sync for shared keys.
    case notShared(String)
    /// `applySnapshot` needs a ledger without local edits.
    case ledgerHasLocalEdits
    case snapshotSchemaMismatch(Int)
    case drift(HLCError)
}
