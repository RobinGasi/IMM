import Foundation
import IMMLedger
import IMMSyncCore

/// The async lane: publishes this device's sealed batches to a `RelayStore` and feeds what other devices left there into the
/// same `SyncEngine.handle(.batch)` the live lane uses. The engine applies idempotently per sender cursor, so a batch that
/// arrives over both lanes, or twice, changes nothing the second time.
///
/// - Only this device's own ops are published (`ownOnly`): every device that has the relay publishes its own, so the lanes
///   form a full mesh. The marker `published` is the highest own sequence handed to the relay. It starts at the lowest
///   sequence a bootstrapped peer is known to hold (the snapshot cursor), so a new relay does not re-upload history.
/// - Only batches sealed with the current group key are applied. Pairing, grants and rekeys stay on the live lane; an
///   envelope for another group is acknowledged and ignored (it is deleted when it is old, or when we sealed it ourselves).
/// - Acks: after applying, a device publishes one small sealed envelope with its cursors (`SealedEnvelope` with a sequence
///   at or above `ackBase`). A batch is deleted from the relay once every other roster device acknowledged a cursor past
///   it, or after `retention` (90 days). Acks are superseded by the same device's next ack.
actor RelayLane {
    /// Sequence numbers from here on in an envelope header are relay acks (control envelopes start at `controlSequenceBase`).
    static let ackBase: Int64 = SyncEngine.controlSequenceBase + (1 << 40)
    static let stateName = "relay.state"
    static let defaultRetention: TimeInterval = 90 * 24 * 3600

    enum Update: Sendable {
        case status(RelayStatus)
        case applied([SyncOp])
        case failure(String)
    }

    struct State: Codable {
        struct Entry: Codable, Equatable {
            enum Kind: String, Codable { case batch, ack }
            var id: String
            var kind: Kind
            var device: UInt64
            var seqTo: Int64
            var group: Data
            var at: Date
        }

        /// Highest own sequence handed to the relay; nil until the first publish decides where to start.
        var published: Int64?
        var group: Data?
        var index: [Entry] = []
        /// What other devices acknowledged: sender node (hex) → device (hex) → sequence.
        var peerCursors: [String: [String: Int64]] = [:]
        /// The cursors in our last ack: device (hex) → sequence.
        var lastAck: [String: Int64] = [:]
        /// Sequence of our newest ack envelope: each ack is numbered above the previous one even when the clock stalls.
        var lastAckSeq: Int64?
    }

    struct AckPayload: Codable {
        var relayAck: Int = 1
        var cursors: [String: Int64]
    }

    let engine: SyncEngine
    let store: any RelayStore
    private let retention: TimeInterval
    private let now: @Sendable () -> Date
    private let isStopped: @Sendable () -> Bool
    private let report: @Sendable (Update) -> Void
    private var suspended = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var eventTask: Task<Void, Never>?
    private var closed = false

    init(
        engine: SyncEngine, store: any RelayStore, retention: TimeInterval = RelayLane.defaultRetention,
        now: @escaping @Sendable () -> Date = { Date() }, isStopped: @escaping @Sendable () -> Bool = { false },
        report: @escaping @Sendable (Update) -> Void
    ) {
        self.engine = engine
        self.store = store
        self.retention = retention
        self.now = now
        self.isStopped = isStopped
        self.report = report
    }

    var isSuspended: Bool { suspended }
    private var usable: Bool { !suspended && !closed && !isStopped() }

    // MARK: Lifecycle

    /// Starts listening to the store's events (push, account changes, resets).
    func start() {
        guard eventTask == nil else { return }
        let events = store.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        report(.status(.ready))
    }

    /// Stops the event loop and the store and waits for the step that is running.
    func shutdown() async {
        closed = true
        eventTask?.cancel()
        eventTask = nil
        await store.stop()
        await gated {}
    }

    private func handle(_ event: RelayStoreEvent) async {
        guard !closed else { return }
        switch event {
        case .remoteChange:
            await pull()
        case .accountLost(let reason):
            suspended = true
            report(.status(.unavailable(reason)))
        case .accountAvailable:
            suspended = false
            report(.status(.ready))
            await sync()
        case .reset:
            await gated {
                guard var state = try? loadState() else { return }
                state.published = try? await republishPoint(state)
                state.index = []
                state.lastAck = [:]
                try? saveState(state)
            }
            await sync()
        case .failure(let text):
            report(.status(.error(text)))
            report(.failure(text))
        }
    }

    /// Pull, publish, clean up: launch, unlock, wake, "Sync now".
    func sync() async {
        await pull()
        await publish()
    }

    // MARK: Gate

    /// One step at a time: publish, pull and cleanup share the state record and must not interleave across their awaits.
    private func gated(_ body: () async -> Void) async {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        await body()
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    // MARK: State

    private var secrets: SyncSecretStore { engine.secrets }

    private func loadState() throws -> State {
        guard let data = try secrets.read(Self.stateName) else { return State() }
        return try JSONDecoder().decode(State.self, from: data)
    }

    private func saveState(_ state: State) throws {
        try secrets.write(Self.stateName, try JSONEncoder().encode(state))
    }

    private static func hex(_ node: UInt64) -> String { String(node, radix: 16) }

    // MARK: Publish

    func publish() async {
        await gated { await publishLocked() }
    }

    private func publishLocked() async {
        guard usable else { return }
        do {
            guard let group = await engine.group else { return }
            let own = await engine.identity.nodeID
            var state = try loadState()
            if state.group != group.id {
                state.group = group.id
                state.published = nil
            }
            guard try hasBootstrappedPeer(own: own) else { try saveState(state); return }
            let marker: Int64
            if let published = state.published {
                marker = published
            } else {
                marker = try initialMarker(own: own)
            }
            let envelopes = try await engine.batches(
                for: SyncPeer(staticKey: Data(), node: nil), cursors: [.init(device: own, appliedSeq: marker)], ownOnly: true)
            guard !envelopes.isEmpty else {
                state.published = marker
                try saveState(state)
                return
            }
            report(.status(.syncing))
            let ids = try await store.upload(envelopes, from: own)
            guard !isStopped() else { return }
            let at = now()
            for (id, envelope) in zip(ids, envelopes) {
                state.index.append(.init(id: id, kind: .batch, device: own, seqTo: envelope.header.seqTo, group: group.id, at: at))
            }
            state.published = envelopes.map(\.header.seqTo).max() ?? marker
            try saveState(state)
            report(.status(.ready))
        } catch {
            failed(error)
        }
    }

    /// Peers we have given a snapshot (or that bootstrapped us): without one, nobody could use what we publish.
    private func rosterPeers() throws -> [SyncDeviceRecord] {
        try secrets.devices().filter { !$0.isLocal }
    }

    private func hasBootstrappedPeer(own: DeviceNodeID) throws -> Bool {
        // A joined device got a snapshot from its hub (`bootstrapDone`); a hub marks every device it handed a snapshot to.
        if try secrets.read(SyncSecretName.bootstrapDone) != nil { return !(try rosterPeers().isEmpty) }
        return try rosterPeers().contains { record in
            guard let key = record.x25519Public else { return false }
            return try secrets.read(SyncSecretName.bootstrapped(peer: key)) != nil
        }
    }

    /// Where to start when the relay has never been used: the lowest own sequence a bootstrapped peer already holds.
    private func initialMarker(own: DeviceNodeID) throws -> Int64 {
        // A joined device's own history starts at the pairing: everything it wrote is news to the group.
        if try secrets.read(SyncSecretName.bootstrapDone) != nil { return 0 }
        var lowest: Int64?
        for record in try rosterPeers() {
            guard let key = record.x25519Public, try secrets.read(SyncSecretName.bootstrapped(peer: key)) != nil else { continue }
            let held = try secrets.readInt(SyncSecretName.sent(peer: key, device: own)) ?? 0
            lowest = min(lowest ?? held, held)
        }
        return lowest ?? 0
    }

    /// After the relay lost its content: the lowest own sequence a peer may still lack (what it acknowledged through the relay
    /// or what we handed to it live), so recent batches go up again. nil lets `initialMarker` decide.
    private func republishPoint(_ state: State) async throws -> Int64? {
        let own = await engine.identity.nodeID
        var lowest: Int64?
        for record in try rosterPeers() {
            guard let key = record.x25519Public, try secrets.read(SyncSecretName.bootstrapped(peer: key)) != nil else { continue }
            let acked = state.peerCursors[Self.hex(record.nodeID)]?[Self.hex(own)] ?? 0
            let sent = try secrets.readInt(SyncSecretName.sent(peer: key, device: own)) ?? 0
            lowest = min(lowest ?? max(acked, sent), max(acked, sent))
        }
        return lowest
    }

    // MARK: Pull

    func pull() async {
        await gated { await pullLocked() }
    }

    private func pullLocked() async {
        guard usable else { return }
        do {
            report(.status(.syncing))
            let items = try await store.fetchNew()
            guard let group = await engine.group else {
                try await store.acknowledge(items)   // not paired: nothing here is ours to read
                report(.status(.ready))
                return
            }
            let own = await engine.identity.nodeID
            var state = try loadState()
            var acknowledged: [RelayItem] = []
            var applied: [SyncOp] = []
            for item in items.sorted(by: { ($0.sender, $0.envelope.header.seqFrom) < ($1.sender, $1.envelope.header.seqFrom) }) {
                guard !isStopped() else { break }
                let header = item.envelope.header
                if !state.index.contains(where: { $0.id == item.recordID }) {
                    state.index.append(
                        .init(
                            id: item.recordID, kind: header.seqFrom >= Self.ackBase ? .ack : .batch, device: header.device,
                            seqTo: header.seqTo, group: header.group, at: item.uploadedAt))
                }
                if header.device == own || header.group != group.id || header.seqFrom >= SyncEngine.controlSequenceBase {
                    // Our own echo, another group, or a control envelope: only acks are read here.
                    if header.device != own, header.group == group.id, header.seqFrom >= Self.ackBase { readAck(item, group: group, into: &state) }
                    acknowledged.append(item)
                    continue
                }
                do {
                    let handling = try await engine.handle(.batch(item.envelope), from: SyncPeer(staticKey: Data(), node: header.device))
                    applied += handling.appliedOps
                    for case .batchRejected(let reason) in handling.events { report(.failure("relay batch refused: \(reason)")) }
                    acknowledged.append(item)
                } catch {
                    report(.failure("relay batch not applied: \(error)"))   // stays in the inbox for the next round
                }
            }
            try saveState(state)
            guard !isStopped() else { return }
            if !acknowledged.isEmpty { try await store.acknowledge(acknowledged) }
            if !applied.isEmpty { report(.applied(applied)) }
            try await publishAckIfNeeded(own: own, group: group)
            try await cleanup(own: own, group: group)
            report(.status(.ready))
        } catch {
            failed(error)
        }
    }

    private func readAck(_ item: RelayItem, group: SyncGroup, into state: inout State) {
        guard let payload = try? item.envelope.open(key: group.key), let ack = try? JSONDecoder().decode(AckPayload.self, from: payload)
        else { return }
        let sender = Self.hex(item.sender)
        var merged = state.peerCursors[sender] ?? [:]
        for (device, seq) in ack.cursors { merged[device] = max(merged[device] ?? 0, seq) }
        state.peerCursors[sender] = merged
    }

    // MARK: Acks and cleanup

    private func publishAckIfNeeded(own: DeviceNodeID, group: SyncGroup) async throws {
        guard !(try rosterPeers().isEmpty) else { return }
        var cursors: [String: Int64] = [:]
        for cursor in try engine.ledger.writer.cursors() where cursor.appliedSeq > 0 { cursors[Self.hex(cursor.device)] = cursor.appliedSeq }
        var state = try loadState()
        guard cursors != state.lastAck, !cursors.isEmpty else { return }
        let seq = max(Self.ackBase + Int64(now().timeIntervalSince1970 * 1000), (state.lastAckSeq ?? 0) + 1)
        let payload = try JSONEncoder().encode(AckPayload(cursors: cursors))
        let envelope = try SealedEnvelope.seal(
            payload: payload, header: .init(group: group.id, device: own, seqFrom: seq, seqTo: seq), key: group.key)
        let ids = try await store.upload([envelope], from: own)
        guard let id = ids.first else { return }
        state.index.append(.init(id: id, kind: .ack, device: own, seqTo: seq, group: group.id, at: now()))
        state.lastAck = cursors
        state.lastAckSeq = seq
        try saveState(state)
    }

    /// Deletes what nobody needs any more.
    func cleanup() async {
        await gated {
            guard usable, let group = await engine.group else { return }
            let own = await engine.identity.nodeID
            do { try await cleanup(own: own, group: group) } catch { failed(error) }
        }
    }

    private func cleanup(own: DeviceNodeID, group: SyncGroup) async throws {
        var state = try loadState()
        let roster = try rosterPeers()
        let cursors = Dictionary(uniqueKeysWithValues: try engine.ledger.writer.cursors().map { ($0.device, $0.appliedSeq) })
        let current = now()
        var doomed: [String] = []
        let newestAck = Dictionary(
            state.index.filter { $0.kind == .ack }.map { (Self.hex($0.device), $0.seqTo) }, uniquingKeysWith: max)
        for entry in state.index {
            let expired = current.timeIntervalSince(entry.at) > retention
            if expired { doomed.append(entry.id); continue }
            if entry.group != group.id {
                if entry.device == own { doomed.append(entry.id) }   // sealed by us for a group that no longer exists
                continue
            }
            switch entry.kind {
            case .ack:
                if entry.seqTo < (newestAck[Self.hex(entry.device)] ?? entry.seqTo) { doomed.append(entry.id) }
            case .batch:
                guard (cursors[entry.device] ?? 0) >= entry.seqTo || entry.device == own else { continue }
                let others = roster.filter { $0.nodeID != entry.device }
                let everyoneHasIt = others.allSatisfy { (state.peerCursors[Self.hex($0.nodeID)]?[Self.hex(entry.device)] ?? 0) >= entry.seqTo }
                if everyoneHasIt, !(others.isEmpty && entry.device == own) { doomed.append(entry.id) }
            }
        }
        guard !doomed.isEmpty else { return }
        try await store.delete(recordIDs: doomed)
        state.index.removeAll { doomed.contains($0.id) }
        // Cursors of devices that left the roster are of no use any more.
        let known = Set(roster.map { Self.hex($0.nodeID) })
        state.peerCursors = state.peerCursors.filter { known.contains($0.key) }
        try saveState(state)
    }

    // MARK: Errors

    private func failed(_ error: Error) {
        if let relay = error as? RelayError, case .unavailable(let reason) = relay {
            suspended = true
            report(.status(.unavailable(reason)))
            return
        }
        report(.status(.error("\(error)")))
        report(.failure("iCloud relay: \(error)"))
    }
}
