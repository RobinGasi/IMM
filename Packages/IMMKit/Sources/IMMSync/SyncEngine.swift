import CryptoKit
import Foundation
import IMMLedger
import IMMSyncCore

/// A remote device as one session sees it.
public struct SyncPeer: Sendable, Hashable {
    /// Authenticated Noise static key of the session.
    public var staticKey: Data
    /// The peer's node id when it is on the roster.
    public var node: DeviceNodeID?

    public init(staticKey: Data, node: DeviceNodeID? = nil) {
        self.staticKey = staticKey
        self.node = node
    }
}

public enum SyncEvent: Sendable, Equatable {
    /// The snapshot was applied: this ledger now holds the group's data.
    case bootstrapped
    /// A pairing grant was adopted (joining side).
    case paired(hub: DeviceNodeID)
    /// The group key rotated.
    case rekeyed
    case acked(device: DeviceNodeID, through: Int64)
    /// A joiner asked to be added (Mac side): who it claims to be.
    case joinRequested(SyncRosterEntry)
    case rejectedByHub
    case remoteError(code: SyncErrorCode, message: String)
    /// A batch could not be applied (wrong key after a rotation, tampering, malformed).
    case batchRejected(String)
}

/// Result of handling one message.
public struct SyncHandling: Sendable {
    public var replies: [SyncMessage] = []
    /// Ops that changed or entered the ledger (for logging and UI).
    public var appliedOps: [SyncOp] = []
    public var applyResult: ApplyResult?
    public var events: [SyncEvent] = []
    public init() {}
}

/// The transport-independent sync logic of one device: identity, group, roster, batches in and out, snapshots, pairing
/// hand-over messages. The Mac's `SyncService` drives it from XPC callbacks, `SyncClient` from a Noise session.
///
/// Per-peer bookkeeping lives in `sync_secret`: `sent.<peer>.<device>` is the highest sequence of a device already handed to a
/// peer (outbox or live), so a commit publishes only what is new. A `hello` carries the peer's real cursors and always wins:
/// it re-sends whatever the peer lacks, whatever the marker says.
public actor SyncEngine {
    /// Sequence numbers from here on in a batch header are control envelopes (rekey), never ledger ops.
    public static let controlSequenceBase: Int64 = 1 << 62

    public nonisolated let ledger: LedgerStore
    public nonisolated let secrets: SyncSecretStore
    public private(set) var identity: DeviceIdentity
    public private(set) var group: SyncGroup?
    private let publisher: BatchPublisher
    private let applier: BatchApplier
    private var assemblies: [UInt64: SnapshotAssembly] = [:]
    private var nextRequestID = UInt64.random(in: 1...UInt64.max >> 1)

    private struct SnapshotAssembly {
        var chunks: [Int64: Data] = [:]
        var expected: Int64 = 0
    }

    public init(ledger: LedgerStore, deviceName: String, payloadBudget: Int = SealedEnvelope.maxPayloadSize) throws {
        self.ledger = ledger
        let secrets = SyncSecretStore(ledger: ledger)
        self.secrets = secrets
        self.identity = try secrets.loadIdentity(defaultName: deviceName)
        self.group = try secrets.loadGroup()
        self.publisher = BatchPublisher(ledger: ledger, payloadBudget: payloadBudget)
        self.applier = BatchApplier(ledger: ledger)
    }

    public var isPaired: Bool { group != nil }

    /// The group, created on first use: the device that enables sync first founds the group.
    @discardableResult
    public func ensureGroup() throws -> SyncGroup {
        if let group { return group }
        let created = try secrets.loadOrCreateGroup()
        group = created
        return created
    }

    // MARK: Hello and cursors

    public func hello() throws -> SyncMessage {
        let cursors = try ledger.writer.cursors().map { SyncMessage.Cursor(device: $0.device, appliedSeq: $0.appliedSeq) }
        return .hello(.init(device: identity.nodeID, group: group?.id ?? Data(), cursors: cursors))
    }

    // MARK: Outgoing batches

    /// What `peer` lacks. `cursors` (from its `hello`) wins over the stored markers.
    /// - Parameter ownOnly: send only this device's own ops (a joined device talking to its hub); the hub relays all devices.
    public func batches(for peer: SyncPeer, cursors: [SyncMessage.Cursor]? = nil, ownOnly: Bool = false) throws -> [SealedEnvelope] {
        guard let group else { return [] }
        var known: [UInt64: Int64] = [:]
        if let cursors { for cursor in cursors { known[cursor.device] = max(known[cursor.device] ?? 0, cursor.appliedSeq) } }
        let secrets = secrets
        return try publisher.envelopes(
            group: group,
            known: { device in
                if cursors != nil { return known[device] ?? 0 }
                return (try? secrets.readInt(SyncSecretName.sent(peer: peer.staticKey, device: device))) ?? 0
            },
            excluding: peer.node, only: ownOnly ? identity.nodeID : nil)
    }

    /// Records that `envelopes` were handed to `peer` (outbox written or acknowledged).
    public func markSent(_ envelopes: [SealedEnvelope], to peer: SyncPeer) throws {
        for envelope in envelopes where envelope.header.seqTo < Self.controlSequenceBase {
            try raiseMarker(peer: peer, device: envelope.header.device, to: envelope.header.seqTo)
        }
    }

    private func raiseMarker(peer: SyncPeer, device: DeviceNodeID, to seq: Int64) throws {
        let name = SyncSecretName.sent(peer: peer.staticKey, device: device)
        if (try secrets.readInt(name) ?? 0) < seq { try secrets.writeInt(name, seq) }
    }

    public func isBootstrapped(peer: Data) throws -> Bool {
        try secrets.read(SyncSecretName.bootstrapped(peer: peer)) != nil
    }

    // MARK: Incoming

    /// Handles one message from `peer`.
    /// - Parameter fromHub: the session is the pinned connection to the device we sync through (joining side); only then are
    ///   grants and rekeys accepted.
    public func handle(_ message: SyncMessage, from peer: SyncPeer, fromHub: Bool = false) throws -> SyncHandling {
        var out = SyncHandling()
        switch message {
        case .hello(let hello):
            guard let group else { break }
            if let node = peer.node { try? secrets.touch(node: node) }
            if !hello.group.isEmpty, hello.group != group.id, peer.node != nil, !fromHub {
                out.replies.append(.pairingGrant(PairingWire.rekey(group: group.id, key: group.key.rawBytes()).encoded()))
            }
            let envelopes = try batches(for: peer, cursors: hello.cursors, ownOnly: fromHub)
            out.replies += envelopes.map { .batch($0) }
            try markSent(envelopes, to: peer)

        case .batch(let envelope):
            guard let group else {
                out.replies.append(.error(code: .notAllowed, message: "This device is not paired."))
                break
            }
            let applied = try applier.apply(envelope, group: group)
            out.appliedOps = applied.ops
            switch applied.outcome {
            case .applied(let device, let cursor, let result):
                out.applyResult = result
                out.replies.append(.ack(device: device, throughSeq: cursor))
            case .duplicate(let device, let cursor):
                out.replies.append(.ack(device: device, throughSeq: cursor))
            case .gap(let device, let cursor, _, let result):
                out.applyResult = result
                out.replies.append(.ack(device: device, throughSeq: cursor))
                out.replies.append(try hello())   // "I am at `cursor`": the sender re-sends from there
            case .rekey(let newID, let key):
                if fromHub, let event = try adopt(group: newID, key: key) { out.events.append(event); out.replies.append(try hello()) }
                out.replies.append(.ack(device: envelope.header.device, throughSeq: envelope.header.seqTo))
            case .staleGroup(let id):
                out.events.append(.batchRejected("sealed for another group (\(id.hex.prefix(8)))"))
                out.replies.append(try hello())   // lets the hub notice our stale group and send a rekey
            case .rejected(let reason):
                out.events.append(.batchRejected(reason))
            }
            if let node = peer.node { try? secrets.touch(node: node) }

        case .ack(let device, let through):
            if through < Self.controlSequenceBase, through > 0 { try raiseMarker(peer: peer, device: device, to: through) }
            if let node = peer.node { try? secrets.touch(node: node, acked: through < Self.controlSequenceBase) }
            out.events.append(.acked(device: device, through: through))

        case .snapshotRequest(let id):
            guard group != nil else {
                out.replies.append(.error(code: .notAllowed, message: "This device is not paired."))
                break
            }
            out.replies += try snapshotMessages(requestID: id, for: peer)

        case .snapshotChunk(let chunk):
            if let event = try receive(chunk: chunk) {
                out.events.append(event)
                out.replies.append(try hello())
            }

        case .pairingGrant(let blob):
            switch try PairingWire(decoding: blob) {
            case .join(let entry):
                out.events.append(.joinRequested(entry))
            case .grant(let grant):
                guard fromHub else { throw SyncError.protocolViolation("grant from a device that is not the hub") }
                if let group {
                    // A repeated grant (a double confirmation on the Mac) for the group we already hold changes nothing.
                    guard group.id == grant.group else { throw SyncError.protocolViolation("unexpected grant") }
                } else {
                    out.events.append(try adopt(grant: grant))
                }
            case .rekey(let id, let key):
                guard fromHub else { throw SyncError.protocolViolation("rekey from a device that is not the hub") }
                if let event = try adopt(group: id, key: key) {
                    out.events.append(event)
                    out.replies.append(try hello())
                }
            case .reject:
                out.events.append(.rejectedByHub)
            }

        case .ping(let token):
            out.replies.append(.pong(token: token))
        case .pong:
            break
        case .error(let code, let text):
            out.events.append(.remoteError(code: code, message: text))
        }
        return out
    }

    // MARK: Group changes

    private func adopt(group id: Data, key: Data) throws -> SyncEvent? {
        guard id.count == SealedEnvelope.groupLength, let groupKey = try? SyncGroupKey(bytes: key), id != group?.id else { return nil }
        let adopted = SyncGroup(id: id, key: groupKey)
        try secrets.store(adopted)
        group = adopted
        return .rekeyed
    }

    private func adopt(grant: PairingWire.Grant) throws -> SyncEvent {
        guard let signingKey = try? Curve25519.Signing.PublicKey(rawRepresentation: grant.hub.ed25519),
              signingKey.isValidSignature(grant.signature, for: PairingWire.rosterSignatureInput(hub: grant.hub, roster: grant.roster))
        else { throw SyncError.protocolViolation("the roster in the pairing grant is not signed by the device that sent it") }
        guard grant.group.count == SealedEnvelope.groupLength, let key = try? SyncGroupKey(bytes: grant.key) else {
            throw SyncError.protocolViolation("malformed group key")
        }
        try secrets.upsert(grant.hub)
        for entry in grant.roster where entry.node != identity.nodeID { try secrets.upsert(entry) }
        try secrets.write(SyncSecretName.ownerPublic, grant.hub.ed25519)
        try secrets.writeInt(SyncSecretName.hubNode, Int64(bitPattern: grant.hub.node))
        let adopted = SyncGroup(id: grant.group, key: key)
        try secrets.store(adopted)
        group = adopted
        return .paired(hub: grant.hub.node)
    }

    /// Mac side: adds the joiner to the roster and builds the grant for it.
    public func makeGrant(for joiner: SyncRosterEntry) throws -> SyncMessage {
        let group = try ensureGroup()
        try secrets.upsert(joiner)
        let hub = identity.rosterEntry
        let roster = try secrets.devices().filter { !$0.isLocal && $0.nodeID != joiner.node }.compactMap { record -> SyncRosterEntry? in
            guard let x = record.x25519Public, let e = record.ed25519Public else { return nil }
            return SyncRosterEntry(node: record.nodeID, deviceID: record.deviceUUID, name: record.name ?? "Device", x25519: x, ed25519: e)
        }
        let signature = try identity.signing.signature(for: PairingWire.rosterSignatureInput(hub: hub, roster: roster))
        let grant = PairingWire.Grant(group: group.id, key: group.key.rawBytes(), hub: hub, roster: roster, signature: signature)
        return .pairingGrant(PairingWire.grant(grant).encoded())
    }

    public static func rejectMessage() -> SyncMessage { .pairingGrant(PairingWire.reject.encoded()) }

    public static func joinMessage(_ entry: SyncRosterEntry) -> SyncMessage { .pairingGrant(PairingWire.join(entry).encoded()) }

    /// Rotates the group key and id (after a device was removed). Returns the envelope that tells remaining devices about it,
    /// sealed under the previous key so only current members open it.
    public func rotateGroup() throws -> (old: SyncGroup, new: SyncGroup, notice: SealedEnvelope) {
        let old = try ensureGroup()
        let new = SyncGroup.generate()
        let counter = (try secrets.readInt("rekey.counter") ?? 0) + 1
        try secrets.writeInt("rekey.counter", counter)
        let payload = PairingWire.rekey(group: new.id, key: new.key.rawBytes()).encoded()
        let header = SealedEnvelope.Header(
            group: old.id, device: identity.nodeID, seqFrom: Self.controlSequenceBase + counter, seqTo: Self.controlSequenceBase + counter)
        let notice = try SealedEnvelope.seal(payload: payload, header: header, key: old.key)
        try secrets.store(new)
        group = new
        return (old, new, notice)
    }

    public func rekeyMessage() throws -> SyncMessage {
        guard let group else { throw SyncError.noGroup }
        return .pairingGrant(PairingWire.rekey(group: group.id, key: group.key.rawBytes()).encoded())
    }

    // MARK: Snapshots

    /// Splits a sealed snapshot into chunks of at most 1 MiB. Marks `peer` as bootstrapped and its markers at the snapshot's
    /// cursors, so later publishes send only what came after.
    public func snapshotMessages(requestID: UInt64, for peer: SyncPeer) throws -> [SyncMessage] {
        guard let group else { throw SyncError.noGroup }
        let snapshot = try ledger.writer.snapshot()
        let json = try JSONEncoder().encode(snapshot)
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data
        let size = SealedEnvelope.maxPayloadSize
        let count = max(1, (compressed.count + size - 1) / size)
        var messages: [SyncMessage] = []
        for index in 0..<count {
            let piece = compressed.subdata(in: index * size..<min(compressed.count, (index + 1) * size))
            let header = SealedEnvelope.Header(group: group.id, device: identity.nodeID, seqFrom: Int64(index), seqTo: Int64(count - 1))
            let sealed = try SealedEnvelope.seal(payload: piece, header: header, key: group.key)
            messages.append(.snapshotChunk(.init(requestID: requestID, index: UInt32(index), isFinal: index == count - 1, data: sealed.encoded())))
        }
        for cursor in snapshot.cursors where cursor.device != peer.node {
            try raiseMarker(peer: peer, device: cursor.device, to: cursor.appliedSeq)
        }
        try secrets.write(SyncSecretName.bootstrapped(peer: peer.staticKey), Data([1]))
        return messages
    }

    /// Joining side: the message that asks the hub for the snapshot.
    public func snapshotRequest() -> SyncMessage {
        nextRequestID &+= 1
        return .snapshotRequest(requestID: nextRequestID)
    }

    public var needsBootstrap: Bool {
        get throws { try group != nil && secrets.read(SyncSecretName.bootstrapDone) == nil }
    }

    private func receive(chunk: SyncMessage.SnapshotChunk) throws -> SyncEvent? {
        guard let group else { throw SyncError.noGroup }
        guard let envelope = try? SealedEnvelope(decoding: chunk.data), envelope.header.group == group.id,
              let piece = try? envelope.open(key: group.key)
        else { throw SyncError.snapshotFailed("a snapshot chunk does not authenticate") }
        var assembly = assemblies[chunk.requestID] ?? SnapshotAssembly()
        assembly.expected = envelope.header.seqTo + 1
        assembly.chunks[envelope.header.seqFrom] = piece
        assemblies[chunk.requestID] = assembly
        guard Int64(assembly.chunks.count) == assembly.expected else { return nil }
        assemblies[chunk.requestID] = nil
        var compressed = Data()
        for index in 0..<assembly.expected {
            guard let piece = assembly.chunks[index] else { throw SyncError.snapshotFailed("snapshot chunk \(index) is missing") }
            compressed += piece
        }
        guard let json = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let snapshot = try? JSONDecoder().decode(LedgerSnapshot.self, from: json)
        else { throw SyncError.snapshotFailed("the snapshot does not decode") }
        try ledger.writer.applySnapshot(snapshot)
        try secrets.write(SyncSecretName.bootstrapDone, Data([1]))
        return .bootstrapped
    }
}
