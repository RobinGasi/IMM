import AppKit
import Foundation
import GRDB
import IMMLedger
import IMMSyncCore

/// What the coordinator reports to the main-actor `SyncService`.
enum SyncUpdate: Sendable {
    case agent(AgentStatus)
    case pairing(SyncPairingPhase)
    case devices
    case remoteApplied([SyncOp])
    case relay(RelayStatus)
    case failure(String)
}

/// Everything the Mac app does with the agent while it is unlocked, off the main actor: XPC link, allow-list, inbox, outbox,
/// live relay, pairing, removal. One instance per unlocked vault.
actor SyncCoordinator: AgentAppEndpoint {
    let engine: SyncEngine
    private let makeClient: @Sendable (any AgentAppEndpoint) -> AgentXPCClient
    private let resolveHost: @Sendable (String) async -> String
    private let report: @Sendable (SyncUpdate) -> Void
    private let publishDelay: Duration
    private let relayProvider: any RelayProviding
    /// The relay's durable state lives in the vault; closed by `requestStop()` so late CloudKit callbacks cannot touch a closed pool.
    private nonisolated let relayPersistence: LedgerRelayPersistence

    private var client: AgentXPCClient?
    private var agentStatus: AgentStatus?
    private var connected: Set<Data> = []
    private var pairingEvent: AgentPairingEvent?
    private var joins: [Data: SyncRosterEntry] = [:]
    private var offer: PairingOffer?
    private var offerTimer: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var queue: AsyncStream<Incoming>.Continuation?
    private var reconnecting = false
    private var relay: RelayLane?
    private var relayTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?
    /// How the last batch from a device arrived ("Tailscale" or "iCloud").
    private var routes: [DeviceNodeID: String] = [:]
    private var confirming = false
    /// Set synchronously by `requestStop()` (from any thread), before the actor gets to run `stop()`: every step that touches
    /// the ledger or the agent checks it, so nothing starts once the app began to lock.
    private nonisolated let stopRequested = StopFlag()
    private var stopped: Bool { stopRequested.isSet }

    private enum Incoming: Sendable {
        case message(SyncMessage, Data)
    }

    init(
        engine: SyncEngine, publishDelay: Duration = .milliseconds(300),
        makeClient: @escaping @Sendable (any AgentAppEndpoint) -> AgentXPCClient,
        resolveHost: @escaping @Sendable (String) async -> String, relayProvider: any RelayProviding = NoRelayProvider(),
        report: @escaping @Sendable (SyncUpdate) -> Void
    ) {
        self.engine = engine
        self.relayProvider = relayProvider
        relayPersistence = LedgerRelayPersistence(ledger: engine.ledger)
        self.publishDelay = publishDelay
        self.makeClient = makeClient
        self.resolveHost = resolveHost
        self.report = report
    }

    // MARK: Lifecycle

    /// Connects to the agent, hands over the owner key and the signed allow-list, attaches, applies the inbox, publishes the outbox.
    func start() async throws {
        try ensureRunning()
        try await engine.ensureGroup()
        let (stream, continuation) = AsyncStream<Incoming>.makeStream()
        queue = continuation
        worker = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                await self.process(item)
            }
        }
        startRelay()
        try await connect()
        try ensureRunning()
        startObservation()
    }

    // MARK: Relay (iCloud lane)

    /// Starts the async lane in the background: entitlement and account check, store, first pull and publish. The live lane
    /// never waits for it and never depends on it.
    private func startRelay() {
        guard relayTask == nil else { return }
        let provider = relayProvider
        let persistence = relayPersistence
        relayTask = Task { [weak self] in
            guard let self else { return }
            let node = await self.engine.identity.nodeID
            let setup = await provider.makeStore(device: node, persistence: persistence)
            await self.relayReady(setup)
        }
    }

    private func relayReady(_ setup: RelaySetup) async {
        switch setup {
        case .unavailable(let reason):
            report(.relay(.unavailable(reason)))
        case .ready(let store):
            guard !stopped else {
                await store.stop()
                return
            }
            let flag = stopRequested
            let lane = RelayLane(
                engine: engine, store: store, isStopped: { flag.isSet },
                report: { [weak self] update in Task { await self?.relayUpdate(update) } })
            relay = lane
            await lane.start()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in Task { await self?.relaySync() } }
            await lane.sync()
        }
    }

    private func relayUpdate(_ update: RelayLane.Update) {
        guard !stopped else { return }
        switch update {
        case .status(let status):
            report(.relay(status))
        case .applied(let ops):
            for device in Set(ops.map(\.device)) { routes[device] = "iCloud" }
            report(.remoteApplied(ops))
        case .failure(let text):
            report(.failure(text))
        }
    }

    /// Fetch and publish through the relay (wake, "Sync now").
    func relaySync() async {
        guard !stopped else { return }
        await relay?.sync()
    }

    private func ensureRunning() throws {
        if stopped { throw CancellationError() }
    }

    private func connect() async throws {
        try ensureRunning()
        let client = makeClient(self)
        client.setInvalidationHandler { [weak self] in
            Task { await self?.agentLost() }
        }
        self.client = client
        var status: AgentStatus?
        var lastError = "the sync helper does not answer"
        for _ in 0..<24 {
            do {
                status = try await client.status()
                break
            } catch {
                lastError = "\(error)"
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        try ensureRunning()
        guard let status else { throw SyncError.agentUnavailable(lastError) }
        guard status.protocolVersion == AgentConstants.xpcProtocolVersion else {
            throw SyncError.agentUnavailable("The sync helper is a different version (\(status.build)). Restart IMM.")
        }
        let identity = await engine.identity
        let owner = try await client.setOwnerPublicKey(identity.signingPublic)
        guard owner.ok else { throw SyncError.agentUnavailable("owner key refused: \(owner.error ?? "?")") }
        try ensureRunning()
        try await publishAllowList()
        try ensureRunning()
        let attached = try await client.attach()
        await agentStatusChanged(attached)
        await drainInbox()
        await publishAll(hello: true)
    }

    /// First step of shutdown, callable from any thread and without waiting: from now on no step of this coordinator starts
    /// work on the ledger. `quiesce()` then waits for the steps already running.
    nonisolated func requestStop() {
        stopRequested.set()
        relayPersistence.close()
    }

    /// Cancels the coordinator's tasks and waits until none of them can touch the ledger any more (bounded: a step that waits for
    /// a hung agent must not keep the vault open; it sees `stopped` when it resumes and does nothing). After this the vault may close.
    func quiesce(limit: Duration = .seconds(2)) async {
        requestStop()
        var tasks = [observation, debounce, worker, offerTimer, relayTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        relayTask = nil
        if let lane = relay { tasks.append(Task { await lane.shutdown() }) }
        relay = nil
        queue?.finish()
        observation = nil
        debounce = nil
        offerTimer = nil
        queue = nil
        worker = nil
        connected = []
        await waitForTasks(tasks, limit: limit)
        // Whatever this coordinator already asked of the engine actor has run when this returns.
        _ = await engine.identity
    }

    /// Tells the agent that the app is gone (it then serves the mailbox on its own). Needs no ledger.
    func detach() async {
        if let client {
            try? await client.clearPairingOffer()
            try? await client.detach()
            client.invalidate()
        }
        client = nil
    }

    func stop() async {
        await quiesce()
        await detach()
    }

    /// The XPC connection broke (the agent exited or was restarted by launchd): reconnect with a pause until it works.
    private func agentLost() async {
        guard !stopped, !reconnecting else { return }
        reconnecting = true
        defer { reconnecting = false }
        connected = []
        client?.invalidate()
        client = nil
        for attempt in 0..<30 where !stopped {
            try? await Task.sleep(for: .seconds(min(1 + attempt, 5)))
            guard !stopped else { return }
            do {
                try await connect()
                report(.devices)
                return
            } catch {
                report(.failure("\(error)"))
            }
        }
    }

    // MARK: Agent callbacks

    func pairingHandshakeCompleted(_ event: AgentPairingEvent) async {
        guard offer != nil else {
            try? await client?.closeSession(peer: event.peer)
            return
        }
        pairingEvent = event
        publishPairingPhase()
    }

    func received(_ message: SyncMessage, from peer: Data) async -> Bool {
        queue?.yield(.message(message, peer))
        return queue != nil
    }

    func peerConnectionChanged(peer: Data, connected isConnected: Bool) async {
        if isConnected { connected.insert(peer) } else { connected.remove(peer) }
        if isConnected, let record = try? engine.secrets.device(staticKey: peer) {
            try? engine.secrets.touch(node: record.nodeID)
            if let hello = try? await engine.hello() { _ = try? await client?.forward(hello, to: peer) }
        }
        report(.devices)
    }

    func statusChanged(_ status: AgentStatus) async {
        await agentStatusChanged(status)
    }

    private func agentStatusChanged(_ status: AgentStatus) async {
        agentStatus = status
        report(.agent(status))
    }

    var isListening: Bool { agentStatus?.listening == true }

    /// Handles queued peer messages one at a time, so a snapshot or a long batch never reorders what follows.
    private func process(_ item: Incoming) async {
        guard !stopped, case .message(let message, let peerKey) = item else { return }
        let record = try? engine.secrets.device(staticKey: peerKey)
        guard let record else {
            // Not on the roster: only a pairing candidate may talk, and only to say who it is.
            if case .pairingGrant(let blob) = message, let wire = try? PairingWire(decoding: blob), case .join(let entry) = wire,
               entry.x25519 == peerKey {
                joins[peerKey] = entry
                publishPairingPhase()
            }
            return
        }
        do {
            let handling = try await engine.handle(message, from: SyncPeer(staticKey: peerKey, node: record.nodeID))
            // `handle` has already moved this peer's markers past the batches it answers with (a `hello` re-sends what the peer
            // lacks). Live delivery is best effort: the peer may close its session right after the `hello`, and a batch written to
            // a closed session would never reach its outbox, so the marker would claim it was sent. Every answered batch therefore
            // also goes to the outbox, as `publishAll` does; the peer's ack frees it.
            let answered = handling.replies.compactMap { reply -> SealedEnvelope? in
                if case .batch(let envelope) = reply { return envelope } else { return nil }
            }
            if !answered.isEmpty {
                let stored = try await client?.publishOutbox(peer: peerKey, envelopes: answered)
                if stored?.ok != true { report(.failure("outbox for \(record.name ?? "device"): \(stored?.error ?? "not connected")")) }
            }
            for reply in handling.replies { _ = try await client?.forward(reply, to: peerKey) }
            if case .batch = message, handling.applyResult != nil || !handling.appliedOps.isEmpty { routes[record.nodeID] = "Tailscale" }
            if !handling.appliedOps.isEmpty { report(.remoteApplied(handling.appliedOps)) }
            for case .batchRejected(let reason) in handling.events { report(.failure("batch refused: \(reason)")) }
            if case .ack = message { report(.devices) }
        } catch {
            report(.failure("\(error)"))
        }
    }

    // MARK: Allow-list

    func publishAllowList() async throws {
        guard let client else { throw SyncError.agentUnavailable("not connected") }
        let identity = await engine.identity
        let peers = try engine.secrets.devices().filter { !$0.isLocal }.compactMap { record -> PeerAllowList.Peer? in
            guard let key = record.x25519Public else { return nil }
            return .init(publicKey: key, name: record.name ?? "Device")
        }
        let agentVersion = Int64(try await client.status().allowListVersion)
        let version = max(try engine.secrets.readInt(SyncSecretName.allowListVersion) ?? 0, agentVersion) + 1
        let signed = try SignedPeerAllowList.sign(
            PeerAllowList(version: UInt64(version), issuedAt: Date(), peers: peers), with: identity.signing)
        let result = try await client.publishAllowList(signed)
        guard result.ok else { throw SyncError.agentUnavailable("allow-list refused: \(result.error ?? "?")") }
        try engine.secrets.writeInt(SyncSecretName.allowListVersion, version)
    }

    // MARK: Inbox and outbox

    /// Applies the batches that arrived while the app was locked.
    func drainInbox() async {
        guard let client else { return }
        for _ in 0..<50 {
            guard !stopped else { return }
            guard let items = try? await client.fetchInbox(), !items.isEmpty else { return }
            var refs: [AgentInboxRef] = []
            var applied: [SyncOp] = []
            for item in items.sorted(by: { ($0.peer.hex, $0.sender, $0.seqFrom) < ($1.peer.hex, $1.sender, $1.seqFrom) }) {
                if stopped { break }   // what was applied so far is deleted below; the rest stays for the next unlock
                let ref = AgentInboxRef(peer: item.peer, sender: item.sender, seqFrom: item.seqFrom, seqTo: item.seqTo)
                guard let envelope = try? SealedEnvelope(decoding: item.envelope),
                      let record = try? engine.secrets.device(staticKey: item.peer)
                else {
                    refs.append(ref)   // not a batch, or from a device that was removed
                    continue
                }
                do {
                    let handling = try await engine.handle(.batch(envelope), from: SyncPeer(staticKey: item.peer, node: record.nodeID))
                    applied += handling.appliedOps
                    if !handling.appliedOps.isEmpty { routes[record.nodeID] = "Tailscale" }
                    refs.append(ref)
                } catch {
                    report(.failure("inbox batch not applied: \(error)"))   // keep it for the next unlock
                }
            }
            if !applied.isEmpty { report(.remoteApplied(applied)) }
            guard !refs.isEmpty else { return }
            _ = try? await client.deleteInbox(refs)
            report(.devices)
        }
    }

    /// Hands every bootstrapped device what it lacks: into the agent's outbox (served while the app is locked) and, when the
    /// device is connected, live. Optionally greets connected devices with `hello` (their cursors then correct our markers).
    func publishAll(hello: Bool = false) async {
        guard !stopped else { return }
        await relay?.publish()   // the async lane first: it must see markers as they were before the live lane raises them
        guard !stopped, let client else { return }
        let devices = (try? engine.secrets.devices().filter { !$0.isLocal && $0.x25519Public != nil }) ?? []
        for record in devices {
            guard !stopped else { return }
            guard let key = record.x25519Public, (try? await engine.isBootstrapped(peer: key)) == true else { continue }
            let peer = SyncPeer(staticKey: key, node: record.nodeID)
            do {
                let envelopes = try await engine.batches(for: peer)
                if !envelopes.isEmpty {
                    let result = try await client.publishOutbox(peer: key, envelopes: envelopes)
                    guard !stopped else { return }
                    if result.ok {
                        try await engine.markSent(envelopes, to: peer)
                    } else {
                        report(.failure("outbox for \(record.name ?? "device"): \(result.error ?? "?")"))
                    }
                    if connected.contains(key) {
                        for envelope in envelopes { _ = try await client.forward(.batch(envelope), to: key) }
                    }
                }
                if hello, connected.contains(key) { _ = try await client.forward(try await engine.hello(), to: key) }
            } catch {
                report(.failure("publish: \(error)"))
            }
        }
        report(.devices)
    }

    private func startObservation() {
        observation?.cancel()
        let database = engine.ledger.database
        observation = Task { [weak self] in
            // Moves with every local commit and with every op applied from a peer (the hub relays those to the others).
            let tracking = ValueObservation.tracking { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE((SELECT op_seq FROM hlc_state WHERE id = 1), 0) + COALESCE((SELECT SUM(applied_seq) FROM sync_cursor), 0)"
                ) ?? 0
            }.removeDuplicates()
            do {
                for try await _ in tracking.values(in: database) {
                    await self?.schedulePublish()
                }
            } catch {}
        }
    }

    private func schedulePublish() {
        guard !stopped else { return }
        debounce?.cancel()
        let delay = publishDelay
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.publishAll()
        }
    }

    /// Publishes now, without waiting for the debounce (tests, "Sync now").
    func publishNow() async {
        debounce?.cancel()
        await publishAll(hello: true)
        await relay?.pull()
    }

    // MARK: Pairing

    func beginPairing(now: Date = Date()) async throws -> PairingOffer {
        guard let client else { throw SyncError.agentUnavailable("not connected") }
        guard let status = agentStatus, status.listening, let host = status.host, let port = status.port else { throw SyncError.noTailscale }
        let secret = PairingSecret.generate()
        let expiry = now.addingTimeInterval(120)
        guard try await client.setPairingOffer(secret: secret.psk, expiry: expiry) else {
            throw SyncError.agentUnavailable("the helper refused the pairing offer")
        }
        let identity = await engine.identity
        let display = await resolveHost(host)
        let offer = PairingOffer(
            qrPayload: PairingPayload.make(
                node: identity.nodeID, agentKey: status.staticPublicKey, secret: secret, expiry: expiry, host: display, port: port),
            code: secret.code, expiry: expiry, host: display, port: port, agentKey: status.staticPublicKey)
        self.offer = offer
        pairingEvent = nil
        joins = [:]
        offerTimer?.cancel()
        offerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.offerExpired()
        }
        publishPairingPhase()
        return offer
    }

    private func offerExpired() {
        guard pairingEvent == nil else { return }   // a handshake is waiting for the user: keep the confirmation
        offer = nil
        report(.pairing(.idle))
    }

    private func publishPairingPhase() {
        if let event = pairingEvent, let code = ShortAuthCode(event.code) {
            report(.pairing(.confirming(deviceName: joins[event.peer]?.name, code: code)))
        } else if let offer {
            report(.pairing(.offering(offer)))
        } else {
            report(.pairing(.idle))
        }
    }

    func confirmPairing(_ typed: String?) async throws {
        try ensureRunning()
        guard let client, let event = pairingEvent, !confirming else { throw SyncError.pairingNotActive }
        confirming = true
        defer { confirming = false }
        if let typed {
            guard let entered = ShortAuthCode(typed), let expected = ShortAuthCode(event.code), entered.matches(expected) else {
                throw SyncError.pairingCodeMismatch
            }
        }
        var join = joins[event.peer]
        for _ in 0..<40 where join == nil {   // the joiner's "who am I" message may trail the handshake notice
            try await Task.sleep(for: .milliseconds(50))
            join = joins[event.peer]
        }
        guard let join else { throw SyncError.protocolViolation("the new device did not say who it is") }
        guard join.x25519 == event.peer else { throw SyncError.protocolViolation("the device identity does not match the session key") }
        let grant = try await engine.makeGrant(for: join)
        try await publishAllowList()
        guard try await client.forward(grant, to: event.peer) else { throw SyncError.agentUnavailable("the new device disconnected") }
        try? await client.clearPairingOffer()
        finishPairing()
        report(.devices)
    }

    func rejectPairing() async {
        if let event = pairingEvent {
            _ = try? await client?.forward(SyncEngine.rejectMessage(), to: event.peer)
            try? await client?.closeSession(peer: event.peer)
        }
        try? await client?.clearPairingOffer()
        finishPairing()
    }

    private func finishPairing() {
        offerTimer?.cancel()
        offer = nil
        pairingEvent = nil
        joins = [:]
        report(.pairing(.idle))
    }

    // MARK: Removal

    /// Revokes `node`: allow-list without it (the agent drops its session and mailboxes), new group key and id, the remaining
    /// devices told about it (live, and through their outbox sealed under the old key), then everything published again.
    func remove(node: DeviceNodeID) async throws {
        try ensureRunning()
        guard let client else { throw SyncError.agentUnavailable("not connected") }
        guard let record = try engine.secrets.device(node: node), !record.isLocal else { throw SyncError.unknownDevice }
        try engine.secrets.revoke(node: node)
        try await publishAllowList()
        let rotation = try await engine.rotateGroup()
        let rekey = try await engine.rekeyMessage()
        for remaining in try engine.secrets.devices().filter({ !$0.isLocal }) {
            guard let key = remaining.x25519Public else { continue }
            _ = try? await client.publishOutbox(peer: key, envelopes: [rotation.notice])
            if connected.contains(key) { _ = try? await client.forward(rekey, to: key) }
        }
        if let key = record.x25519Public { connected.remove(key) }
        await publishAll(hello: true)
    }

    // MARK: Snapshot for the UI

    func deviceInfos() -> [SyncDeviceInfo] {
        let records = (try? engine.secrets.devices().filter { !$0.isLocal }) ?? []
        let online = Set(agentStatus?.connectedPeers ?? [])
        return records.map { record in
            let key = record.x25519Public
            let isConnected = key.map { connected.contains($0) || online.contains(MailboxPeerID(staticKey: $0).rawValue) } ?? false
            return SyncDeviceInfo(
                id: record.nodeID, name: record.name ?? "Device", lastSeen: isConnected ? Date() : record.lastSeen,
                lastSync: record.lastAcked ?? record.lastSeen, route: routes[record.nodeID] ?? "Tailscale", isConnected: isConnected)
        }
    }
}

/// A flag that one thread sets and any thread reads.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Waits until every task has finished or `limit` of awake time has passed, whichever comes first. Unlike a task group this
/// does not wait for the tasks once the limit is up: awaiting a task's value cannot be cancelled.
func waitForTasks(_ tasks: [Task<Void, Never>], limit: Duration) async {
    guard !tasks.isEmpty else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let once = OnceVoid(continuation)
        Task {
            for task in tasks { await task.value }
            once.resume()
        }
        Task {
            try? await AwakeClock.sleep(for: limit)
            once.resume()
        }
    }
}

private final class OnceVoid: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() {
        let taken = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume()
    }
}
