import CryptoKit
import Foundation
import GRDB
import IMMLedger
import IMMSyncCore

/// This device's identity inside the ledger's sync group.
///
/// - `nodeID` is the ledger's own node id (`LedgerWriter.localNode`, the 8 random bytes created with the local
///   `sync_device` row when migration v2 ran). It is the id every HLC, op, cursor and sealed-batch header carries, so it
///   cannot change afterwards. Deriving it as "first 8 bytes of SHA-256 over both public keys" would need a node id
///   that exists before the keys do, which the ledger cannot give. The keys are stored beside the node id in the local
///   `sync_device` row instead, and peers learn the mapping from the pairing hand-over (`SyncRosterEntry`).
/// - `x25519` is the Noise static key this device presents to *other* agents (the iPhone, the peer tool). The Mac's own
///   transport identity is the agent's key (`AgentStatus.staticPublicKey`), which peers pin.
/// - `signing` is the Ed25519 key that signs the allow-list this device hands to its own agent ("owner key") and the roster
///   in a pairing grant.
public struct DeviceIdentity: Sendable {
    public let nodeID: DeviceNodeID
    public let deviceUUID: UUID
    public let name: String
    public let x25519: Curve25519.KeyAgreement.PrivateKey
    public let signing: Curve25519.Signing.PrivateKey

    public var x25519Public: Data { x25519.publicKey.rawRepresentation }
    public var signingPublic: Data { signing.publicKey.rawRepresentation }
    public var rosterEntry: SyncRosterEntry {
        SyncRosterEntry(node: nodeID, deviceID: deviceUUID.uuidString, name: name, x25519: x25519Public, ed25519: signingPublic)
    }
}

/// The sync group of one ledger: a 16-byte id (new on every key rotation) and the 32-byte key.
public struct SyncGroup: Sendable {
    public let id: Data
    public let key: SyncGroupKey

    public init(id: Data, key: SyncGroupKey) {
        self.id = id
        self.key = key
    }

    public static func generate() -> SyncGroup {
        SyncGroup(id: Data((0..<16).map { _ in UInt8.random(in: 0...255) }), key: .generate())
    }
}

/// A device as the roster knows it (`sync_device`).
public struct SyncDeviceRecord: Sendable, Equatable, Identifiable {
    public var id: DeviceNodeID { nodeID }
    public var nodeID: DeviceNodeID
    public var deviceUUID: String
    public var name: String?
    public var isLocal: Bool
    public var x25519Public: Data?
    public var ed25519Public: Data?
    public var createdAt: Date
    public var revokedAt: Date?
    /// Last time a session with the device was seen / it acknowledged our ops (wall-clock milliseconds kept in the HLC columns).
    public var lastSeen: Date?
    public var lastAcked: Date?
}

/// What the roster needs to know about one device; travels in a pairing grant.
public struct SyncRosterEntry: Codable, Sendable, Equatable {
    public var node: UInt64
    public var deviceID: String
    public var name: String
    public var x25519: Data
    public var ed25519: Data

    public init(node: UInt64, deviceID: String, name: String, x25519: Data, ed25519: Data) {
        self.node = node
        self.deviceID = deviceID
        self.name = name
        self.x25519 = x25519
        self.ed25519 = ed25519
    }
}

public enum SyncSecretName {
    public static let x25519 = "x25519.private"
    public static let ed25519 = "ed25519.private"
    public static let groupKey = "group.key"
    public static let groupID = "group.id"
    /// Ed25519 key of the device whose agent we sync through (the Mac), learned from the pairing grant.
    public static let ownerPublic = "owner.public"
    /// Noise static key of the agent we pinned at pairing.
    public static let agentStatic = "agent.static"
    /// Node id of the device we sync through.
    public static let hubNode = "hub.node"
    public static let bootstrapDone = "bootstrap.done"
    public static let allowListVersion = "allowlist.version"
    static func sent(peer: Data, device: DeviceNodeID) -> String { "sent.\(peer.hex).\(String(device, radix: 16))" }
    static func bootstrapped(peer: Data) -> String { "peer-bootstrapped.\(peer.hex)" }
}

extension Data {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Keys, group and roster, kept in the vault database (`sync_secret`, `sync_device`; both device-local tables, encrypted
/// with the vault). Everything is created lazily on first use.
public final class SyncSecretStore: Sendable {
    public let ledger: LedgerStore
    private var database: DatabasePool { ledger.database }

    public init(ledger: LedgerStore) {
        self.ledger = ledger
    }

    // MARK: Key-value

    public func read(_ name: String) throws -> Data? {
        try database.read { try Self.read(name, db: $0) }
    }

    public func write(_ name: String, _ value: Data) throws {
        try database.write { try Self.write(name, value, db: $0) }
    }

    public func remove(_ name: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM sync_secret WHERE name = ?", arguments: [name]) }
    }

    static func read(_ name: String, db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT value FROM sync_secret WHERE name = ?", arguments: [name])
    }

    static func write(_ name: String, _ value: Data, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_secret (name, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT (name) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
            arguments: [name, value, Date()])
    }

    public func readInt(_ name: String) throws -> Int64? {
        guard let data = try read(name), data.count == 8 else { return nil }
        return Int64(bitPattern: data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }

    public func writeInt(_ name: String, _ value: Int64) throws {
        var big = UInt64(bitPattern: value).bigEndian
        try write(name, Data(bytes: &big, count: 8))
    }

    // MARK: Identity

    /// Loads (creating on first use) the device keys and fills the public half into the local `sync_device` row.
    public func loadIdentity(defaultName: String) throws -> DeviceIdentity {
        let node = ledger.writer.localNode
        return try database.write { db in
            let x25519 = try Self.loadKey(SyncSecretName.x25519, db: db) { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
                ?? Curve25519.KeyAgreement.PrivateKey()
            let signing = try Self.loadKey(SyncSecretName.ed25519, db: db) { try Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
                ?? Curve25519.Signing.PrivateKey()
            try Self.write(SyncSecretName.x25519, x25519.rawRepresentation, db: db)
            try Self.write(SyncSecretName.ed25519, signing.rawRepresentation, db: db)
            guard let row = try Row.fetchOne(db, sql: "SELECT id, name FROM sync_device WHERE is_local = 1") else {
                throw SyncError.ledgerNotReady
            }
            let uuid: String = row["id"]
            var name: String? = row["name"]
            if name == nil {
                name = defaultName
            }
            try db.execute(
                sql: "UPDATE sync_device SET x25519_public = ?, ed25519_public = ?, name = ? WHERE is_local = 1",
                arguments: [x25519.publicKey.rawRepresentation, signing.publicKey.rawRepresentation, name])
            return DeviceIdentity(
                nodeID: node, deviceUUID: UUID(uuidString: uuid) ?? UUID(), name: name ?? defaultName, x25519: x25519, signing: signing)
        }
    }

    private static func loadKey<K>(_ name: String, db: Database, make: (Data) throws -> K) throws -> K? {
        guard let data = try read(name, db: db) else { return nil }
        return try make(data)
    }

    // MARK: Group

    public func loadGroup() throws -> SyncGroup? {
        try database.read { db in
            guard let id = try Self.read(SyncSecretName.groupID, db: db), id.count == SealedEnvelope.groupLength,
                  let key = try Self.read(SyncSecretName.groupKey, db: db), let group = try? SyncGroupKey(bytes: key)
            else { return nil }
            return SyncGroup(id: id, key: group)
        }
    }

    /// The group, created by this device when none exists yet (this device is then the first device of the ledger).
    public func loadOrCreateGroup() throws -> SyncGroup {
        if let existing = try loadGroup() { return existing }
        let group = SyncGroup.generate()
        try store(group)
        return group
    }

    public func store(_ group: SyncGroup) throws {
        try database.write { db in
            try Self.write(SyncSecretName.groupKey, group.key.rawBytes(), db: db)
            try Self.write(SyncSecretName.groupID, group.id, db: db)
        }
    }

    // MARK: Roster

    public func devices(includeRevoked: Bool = false) throws -> [SyncDeviceRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sync_device ORDER BY is_local DESC, created_at, node_id")
                .map(Self.record)
                .filter { includeRevoked || $0.revokedAt == nil }
        }
    }

    public func device(node: DeviceNodeID) throws -> SyncDeviceRecord? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_device WHERE node_id = ?", arguments: [Int64(bitPattern: node)]).map(Self.record)
        }
    }

    public func device(staticKey: Data) throws -> SyncDeviceRecord? {
        try database.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM sync_device WHERE x25519_public = ? AND is_local = 0 AND revoked_at IS NULL", arguments: [staticKey]
            ).map(Self.record)
        }
    }

    private static func record(_ row: Row) -> SyncDeviceRecord {
        func date(_ column: String) -> Date? {
            guard let data: Data = row[column], let hlc = HLC(bytes: data) else { return nil }
            return Date(timeIntervalSince1970: Double(hlc.millis) / 1000)
        }
        return SyncDeviceRecord(
            nodeID: UInt64(bitPattern: row["node_id"] as Int64), deviceUUID: row["id"], name: row["name"], isLocal: (row["is_local"] as Int) == 1,
            x25519Public: row["x25519_public"], ed25519Public: row["ed25519_public"], createdAt: row["created_at"],
            revokedAt: row["revoked_at"], lastSeen: date("last_seen_hlc"), lastAcked: date("last_acked_hlc"))
    }

    /// Adds or refreshes a remote device. A node id already known under another static key is an error: ids never move.
    public func upsert(_ entry: SyncRosterEntry, at date: Date = Date()) throws {
        let bits = Int64(bitPattern: entry.node)
        try database.write { db in
            if let existing = try Row.fetchOne(db, sql: "SELECT x25519_public, is_local FROM sync_device WHERE node_id = ?", arguments: [bits]) {
                guard (existing["is_local"] as Int) == 0 else { throw SyncError.rosterConflict }
                let key: Data? = existing["x25519_public"]
                guard key == nil || key == entry.x25519 else { throw SyncError.rosterConflict }
                try db.execute(
                    sql: "UPDATE sync_device SET name = ?, x25519_public = ?, ed25519_public = ?, revoked_at = NULL WHERE node_id = ?",
                    arguments: [entry.name, entry.x25519, entry.ed25519, bits])
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO sync_device (id, node_id, name, is_local, x25519_public, ed25519_public, created_at)
                        VALUES (?, ?, ?, 0, ?, ?, ?)
                        """,
                    arguments: [entry.deviceID, bits, entry.name, entry.x25519, entry.ed25519, date])
            }
        }
    }

    public func revoke(node: DeviceNodeID, at date: Date = Date()) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE sync_device SET revoked_at = ? WHERE node_id = ? AND is_local = 0", arguments: [date, Int64(bitPattern: node)])
        }
    }

    public func setTransport(node: DeviceNodeID, host: String?, port: UInt16?) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE sync_device SET transport_host = ?, transport_port = ? WHERE node_id = ?",
                arguments: [host, port.map { Int($0) }, Int64(bitPattern: node)])
        }
    }

    public func touch(node: DeviceNodeID, seen: Bool = true, acked: Bool = false, at date: Date = Date()) throws {
        let millis = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
        let stamp = HLC(millis: min(millis, HLC.maxMillis), counter: 0, node: node).bytes
        try database.write { db in
            if seen { try db.execute(sql: "UPDATE sync_device SET last_seen_hlc = ? WHERE node_id = ?", arguments: [stamp, Int64(bitPattern: node)]) }
            if acked { try db.execute(sql: "UPDATE sync_device SET last_acked_hlc = ? WHERE node_id = ?", arguments: [stamp, Int64(bitPattern: node)]) }
        }
    }
}

public enum SyncError: Error, Equatable, Sendable {
    case ledgerNotReady
    case rosterConflict
    case noGroup
    case notPaired
    case noTailscale
    case pairingNotActive
    case pairingCodeMismatch
    case pairingRejected
    case invalidInvite(String)
    case agentUnavailable(String)
    case unknownDevice
    case protocolViolation(String)
    case snapshotFailed(String)
    case timedOut
}
