import CryptoKit
import Foundation

/// The application endpoint as the agent sees it: implemented by the XPC bridge in the agent process and by test fakes.
public protocol AgentAppEndpoint: Sendable {
    /// The XXpsk3 handshake finished; the app shows the code and, after the user confirmed, forwards a `.pairingGrant`.
    func pairingHandshakeCompleted(_ event: AgentPairingEvent) async
    /// Live relay of a message from `peer`. Returning `false` (or not answering in time) makes the agent fall back to the
    /// mailbox: batches are stored for the next unlock, `hello` is answered from the outbox.
    func received(_ message: SyncMessage, from peer: Data) async -> Bool
    func peerConnectionChanged(peer: Data, connected: Bool) async
    func statusChanged(_ status: AgentStatus) async
}

/// Token of one `attach`; `detach` with a stale token is ignored.
public struct AgentAttachment: Hashable, Sendable {
    let id: UUID
}

public struct AgentConfiguration: Sendable {
    public enum Binding: Sendable {
        /// Production: the tailnet `utun` interface only; no listener without Tailscale.
        case tailnet(port: UInt16)
        /// Tests only: 127.0.0.1; `port` 0 picks a free port (see `AgentServer.boundPort`).
        case loopback(port: UInt16)
    }

    public var storage: AgentStorage
    public var binding: Binding
    public var limits: MailboxStore.Limits
    /// `CFBundleVersion` reported in `AgentStatus.build`.
    public var build: String
    public var clock: @Sendable () -> Date
    /// Replaces the `NWPathMonitor` based provider (tests).
    public var tailnet: (any TailnetProviding)?
    public var handshakeTimeout: Duration
    public var maxConcurrentHandshakes: Int
    /// Failed pairing handshakes after which the offer is withdrawn.
    public var maxPairingFailures: Int
    /// How long the agent waits for the app's answer to a live relay before it falls back to the mailbox.
    public var relayTimeout: Duration
    /// Diagnostics (listener state, connection counts, handshake outcome); never keys, payloads or peer identities.
    public var log: @Sendable (String) -> Void

    public init(
        storage: AgentStorage, binding: Binding, limits: MailboxStore.Limits = .init(), build: String = "0",
        clock: @escaping @Sendable () -> Date = { Date() }, tailnet: (any TailnetProviding)? = nil,
        handshakeTimeout: Duration = .seconds(10), maxConcurrentHandshakes: Int = 8, maxPairingFailures: Int = 5,
        relayTimeout: Duration = .seconds(5), log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.storage = storage
        self.binding = binding
        self.limits = limits
        self.build = build
        self.clock = clock
        self.tailnet = tailnet
        self.handshakeTimeout = handshakeTimeout
        self.maxConcurrentHandshakes = maxConcurrentHandshakes
        self.maxPairingFailures = maxPairingFailures
        self.relayTimeout = relayTimeout
        self.log = log
    }

    /// Port for the tailnet listener: `AgentConstants.defaultPort`, or in DEBUG builds the value of `IMMSyncPort` in the
    /// standard defaults / app-group defaults.
    public static func resolvedPort() -> UInt16 {
        #if DEBUG
        for defaults in [UserDefaults.standard, UserDefaults(suiteName: AgentConstants.appGroup)].compactMap({ $0 }) {
            let value = defaults.integer(forKey: AgentConstants.debugPortDefaultsKey)
            if value > 0, value <= Int(UInt16.max) { return UInt16(value) }
        }
        #endif
        return AgentConstants.defaultPort
    }
}

/// The agent's transport endpoint: terminates Noise sessions with the Mac's own static key, authenticates peers against the
/// signed allow-list, keeps the blind mailbox and routes messages between peers and the app.
///
/// - While an app is attached (unlocked, over XPC), `batch`/`ack`/`hello`/snapshot messages are relayed to it live and the
///   app's replies go out through `forward`.
/// - Without an app, inbound batches go to the inbox (acknowledged as "stored"), `hello` is answered with the outbox
///   batches newer than the peer's cursors, and the peer's `ack` frees outbox entries.
/// - `Noise_XXpsk3` is accepted only while an app-provided pairing offer is active (one use, limited failures); everything
///   else needs a `Noise_IK` handshake from an allow-listed static key. Peers get no byte before authentication.
public actor AgentServer {
    private struct PeerSession: Sendable {
        let id = UUID()
        let session: NoiseSession
        /// Joined through the pairing handshake; may talk to the app only until the allow-list contains the key.
        let viaPairing: Bool
    }

    /// Noise message 1 sizes (a test measures both): XXpsk3 = `e ‖ enc(commitment)` (32 + 32 + 16 tag: a PSK pattern mixes `e`
    /// into the key, so the payload is already encrypted), IK = `e ‖ enc(s) ‖ enc(empty)` (32 + 48 + 16).
    static let pairingMessage1Length = 80
    static let liveMessage1Length = 96

    public nonisolated let staticPublicKey: Data
    private let configuration: AgentConfiguration
    private let identity: Curve25519.KeyAgreement.PrivateKey
    private let inbox: MailboxStore
    private let outbox: MailboxStore
    private let tailnetProvider: (any TailnetProviding)?

    private var allowList: PeerAllowList?
    private var listener: AgentListener?
    private var listenerGeneration = 0
    private var listenerState: AgentListenerState = .cancelled
    private var tailnet: TailnetInterface?
    private var sessions: [Data: PeerSession] = [:]
    private var app: (token: AgentAttachment, endpoint: any AgentAppEndpoint)?
    private var offer: (secret: Data, expiry: Date)?
    private var pairingFailures = 0
    private var handshakesInFlight = 0
    private var started = false

    public init(configuration: AgentConfiguration) throws {
        self.configuration = configuration
        self.identity = try configuration.storage.loadOrCreateIdentity()
        self.staticPublicKey = identity.publicKey.rawRepresentation
        self.inbox = try MailboxStore(root: configuration.storage.inboxURL, limits: configuration.limits, clock: configuration.clock)
        self.outbox = try MailboxStore(root: configuration.storage.outboxURL, limits: configuration.limits, clock: configuration.clock)
        self.allowList = configuration.storage.loadAllowList()?.list
        switch configuration.binding {
        case .tailnet: self.tailnetProvider = configuration.tailnet ?? TailnetInterfaceMonitor()
        case .loopback: self.tailnetProvider = nil
        }
    }

    // MARK: Lifecycle

    /// Starts listening. Loopback mode returns once the listener is ready (or throws); tailnet mode returns at once and
    /// follows the tailnet interface from then on.
    public func start() async throws {
        guard !started else { return }
        started = true
        switch configuration.binding {
        case .loopback(let port):
            try buildListener(binding: .loopback, port: port)
            if case .failed(let reason) = await listener?.settledState() { throw AgentError.io("listener failed: \(reason)") }
        case .tailnet:
            tailnetProvider?.start { [weak self] interface in
                guard let self else { return }
                Task { await self.tailnetChanged(interface) }
            }
        }
    }

    public func stop() async {
        started = false
        tailnetProvider?.stop()
        listener?.cancel()
        listener = nil
        listenerState = .cancelled
        offer = nil
        let open = sessions.values
        sessions.removeAll()
        for entry in open { await entry.session.close() }
    }

    /// The port the listener is bound to once ready.
    public var boundPort: UInt16? {
        if case .ready(let port) = currentListenerState { return port }
        return nil
    }

    /// The live listener's own state (the server's copy lags behind by one actor hop).
    private var currentListenerState: AgentListenerState { listener?.state ?? listenerState }

    private func buildListener(binding: AgentListener.Binding, port: UInt16) throws {
        listener?.cancel()
        listenerGeneration += 1
        let generation = listenerGeneration
        let log = configuration.log
        let next = try AgentListener(
            binding: binding, port: port,
            onConnection: { [weak self] stream in
                guard let self else { Task { await stream.close() }; return }
                log("connection accepted")
                Task { await self.serve(stream) }
            },
            onState: { [weak self] state in
                guard let self else { return }
                Task { await self.listenerStateChanged(state, generation: generation) }
            })
        listener = next
        listenerState = .starting
        next.start()
    }

    private func tailnetChanged(_ interface: TailnetInterface?) async {
        guard started, case .tailnet(let port) = configuration.binding else { return }
        tailnet = interface
        if let interface {
            startTailnetListener(interface, port: port)
        } else {
            listener?.cancel()
            listener = nil
            listenerGeneration += 1
            listenerState = .cancelled
        }
        await notifyStatus()
    }

    private func startTailnetListener(_ interface: TailnetInterface, port: UInt16) {
        do {
            try buildListener(binding: .tailnet(interface), port: port)
        } catch {
            listener = nil
            listenerState = .failed("\(error)")
            scheduleRetry(interface, port: port)
        }
    }

    private func listenerStateChanged(_ state: AgentListenerState, generation: Int) async {
        guard generation == listenerGeneration else { return }
        listenerState = state
        configuration.log("listener \(state)")
        await notifyStatus()
        if case .failed = state, started, case .tailnet(let port) = configuration.binding, let interface = tailnet {
            scheduleRetry(interface, port: port)
        }
    }

    /// The path monitor does not fire for a bind failure (address not yet assigned, port still in use): retry the same
    /// interface after a pause. A newer interface or generation cancels the retry.
    private func scheduleRetry(_ interface: TailnetInterface, port: UInt16) {
        let generation = listenerGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.retryListener(interface, port: port, generation: generation)
        }
    }

    private func retryListener(_ interface: TailnetInterface, port: UInt16, generation: Int) async {
        guard started, generation == listenerGeneration, tailnet == interface else { return }
        startTailnetListener(interface, port: port)
        await notifyStatus()
    }

    // MARK: Sessions

    /// Runs one peer connection to its end: handshake, then the message loop. Public so tests (and in-memory transports)
    /// can feed streams directly.
    public func serve(_ stream: any ByteStream) async {
        guard handshakesInFlight < configuration.maxConcurrentHandshakes else {
            configuration.log("connection refused: too many handshakes in flight")
            await stream.close()
            return
        }
        handshakesInFlight += 1
        let peer = await handshake(stream)
        handshakesInFlight -= 1
        guard let peer else {
            configuration.log("handshake rejected")
            return
        }
        configuration.log("session established (\(peer.viaPairing ? "pairing" : "live"))")
        await run(peer)
    }

    private func handshake(_ stream: any ByteStream) async -> PeerSession? {
        let closer: @Sendable () async -> Void = { await stream.close() }
        do {
            return try await Self.withTimeout(configuration.handshakeTimeout, onTimeout: closer) {
                let first = try await stream.receive()
                let replay = ReplayFirstStream(stream, first: first)
                switch first.count {
                case Self.pairingMessage1Length: return try await self.pairingHandshake(replay)
                case Self.liveMessage1Length: return try await self.liveHandshake(replay)
                default:
                    await stream.close()
                    return nil
                }
            }
        } catch {
            await stream.close()
            return nil
        }
    }

    private func liveHandshake(_ stream: any ByteStream) async throws -> PeerSession {
        let session = try await NoiseSession.accept(over: stream, localStatic: identity, isAllowed: { key in
            await self.isAllowed(key)
        })
        return PeerSession(session: session, viaPairing: false)
    }

    private func pairingHandshake(_ stream: any ByteStream) async throws -> PeerSession? {
        guard let active = activeOffer() else {
            await stream.close()
            return nil
        }
        do {
            let session = try await NoiseSession.acceptPairing(
                over: stream, localStatic: identity, pairingSecret: active.secret,
                onCode: { _ in try await self.consumeOffer(secret: active.secret) })
            return PeerSession(session: session, viaPairing: true)
        } catch {
            pairingFailures += 1
            if pairingFailures >= configuration.maxPairingFailures {
                offer = nil
                pairingFailures = 0
                await notifyStatus()
            }
            throw error
        }
    }

    private func isAllowed(_ key: Data) -> Bool { allowList?.contains(staticKey: key) == true }

    private func activeOffer() -> (secret: Data, expiry: Date)? {
        guard let current = offer else { return nil }
        guard current.expiry > configuration.clock() else {
            offer = nil
            return nil
        }
        return current
    }

    private func consumeOffer(secret: Data) throws {
        guard app != nil, let current = activeOffer(), current.secret == secret else { throw AgentError.notAttached }
        offer = nil
        pairingFailures = 0
    }

    private func run(_ entry: PeerSession) async {
        let peer = entry.session.remoteStatic
        if entry.viaPairing, app == nil {
            await entry.session.close()
            return
        }
        if let old = sessions[peer] { await old.session.close() }
        sessions[peer] = entry
        if entry.viaPairing, let endpoint = app?.endpoint, let code = entry.session.pairingCode {
            await endpoint.pairingHandshakeCompleted(
                AgentPairingEvent(peer: peer, code: code.digits, handshakeHash: entry.session.handshakeHash))
        } else {
            await app?.endpoint.peerConnectionChanged(peer: peer, connected: true)
        }
        do {
            while true {
                let message = try await entry.session.receive()
                await route(message, from: entry)
            }
        } catch {
            // Closed, failed authentication or a framing violation: the session is over.
        }
        await entry.session.close()
        if sessions[peer]?.id == entry.id {
            sessions[peer] = nil
            await app?.endpoint.peerConnectionChanged(peer: peer, connected: false)
        }
    }

    // MARK: Routing

    private func route(_ message: SyncMessage, from entry: PeerSession) async {
        let peer = entry.session.remoteStatic
        guard isAllowed(peer) else {
            // A pairing session may reach the app (to confirm the code, to read the joiner's replies) but never the mailbox.
            if entry.viaPairing, let endpoint = app?.endpoint {
                _ = await endpoint.received(message, from: peer)
            } else {
                await entry.session.close()
            }
            return
        }
        switch message {
        case .ping(let token):
            try? await entry.session.send(.pong(token: token))
            return
        case .pong:
            return
        case .ack(let device, let seq):
            freeOutbox(peer: peer, sender: device, throughSeq: seq)
        default:
            break
        }
        if let endpoint = app?.endpoint, await endpoint.received(message, from: peer) { return }
        await mailboxFallback(message, entry)
    }

    private func mailboxFallback(_ message: SyncMessage, _ entry: PeerSession) async {
        let session = entry.session
        let peerID = MailboxPeerID(staticKey: session.remoteStatic)
        switch message {
        case .batch(let envelope):
            do {
                try inbox.put(envelope: envelope.encoded(), peer: peerID)
                try? await session.send(.ack(device: envelope.header.device, throughSeq: envelope.header.seqTo))
            } catch MailboxError.quotaExceeded {
                try? await session.send(.error(code: .quotaExceeded, message: "The mailbox for this device is full."))
            } catch {
                try? await session.send(.error(code: .malformed, message: "The batch was refused: \(error)"))
            }
        case .hello(let hello):
            await serveOutbox(for: hello, to: session)
        case .snapshotRequest:
            try? await session.send(.error(code: .appUnavailable, message: "IMM is locked or closed on the Mac."))
        default:
            break
        }
    }

    private func serveOutbox(for hello: SyncMessage.Hello, to session: NoiseSession) async {
        let peerID = MailboxPeerID(staticKey: session.remoteStatic)
        guard let entries = try? outbox.list(peer: peerID) else { return }
        var applied: [UInt64: Int64] = [:]
        for cursor in hello.cursors { applied[cursor.device] = max(applied[cursor.device] ?? 0, cursor.appliedSeq) }
        for entry in entries where entry.seqTo > (applied[entry.sender] ?? 0) {
            guard let bytes = try? outbox.fetch(entry), let envelope = try? SealedEnvelope(decoding: bytes) else { continue }
            do { try await session.send(.batch(envelope)) } catch { return }
        }
    }

    private func freeOutbox(peer: Data, sender: UInt64, throughSeq: Int64) {
        let peerID = MailboxPeerID(staticKey: peer)
        guard let entries = try? outbox.list(peer: peerID) else { return }
        for entry in entries where entry.sender == sender && entry.seqTo <= throughSeq { try? outbox.delete(entry) }
    }

    // MARK: App interface

    /// Registers the unlocked app; relays go to `endpoint` until `detach`. A second attach replaces the first.
    public func attach(_ endpoint: any AgentAppEndpoint) async -> AgentAttachment {
        let token = AgentAttachment(id: UUID())
        if app != nil { offer = nil }
        app = (token, endpoint)
        await notifyStatus()
        return token
    }

    /// The app locked or went away: the mailbox takes over and the pairing offer is withdrawn.
    public func detach(_ token: AgentAttachment) {
        guard app?.token == token else { return }
        app = nil
        offer = nil
    }

    /// `false` when no app is attached, the secret is not 32 bytes or the expiry has passed.
    public func setPairingOffer(secret: Data, expiry: Date) -> Bool {
        guard app != nil, secret.count == NoiseSession.pairingSecretLength, expiry > configuration.clock() else { return false }
        offer = (secret, expiry)
        pairingFailures = 0
        return true
    }

    public func clearPairingOffer() { offer = nil }

    /// Stores the app's owner Ed25519 public key (the key that signs allow-lists). Only the app can call this: the XPC
    /// connection is checked against the app's code-signing requirement. A different key invalidates the stored
    /// allow-list until the app publishes one signed with the new key.
    public func setOwnerPublicKey(_ key: Data) -> AgentCommandResult {
        guard key.count == 32 else { return .failure("invalidKey") }
        do { try configuration.storage.writeOwnerPublicKey(key) } catch { return .failure("io") }
        allowList = configuration.storage.loadAllowList()?.list
        return .success()
    }

    /// Verifies `signedData` (a `SignedPeerAllowList`) with the owner key from the group container and applies it.
    /// Peers that dropped off the list lose their sessions and mailboxes.
    public func publishAllowList(_ signedData: Data) async -> AgentCommandResult {
        guard let owner = configuration.storage.readOwnerPublicKey() else { return .failure("ownerKeyMissing") }
        let signed: SignedPeerAllowList
        let list: PeerAllowList
        do {
            signed = try SignedPeerAllowList(decoding: signedData)
            list = try signed.verify(ownerPublicKey: owner, minimumVersion: allowList?.version ?? 0)
        } catch let error as PeerAllowListError {
            switch error {
            case .invalidSignature: return .failure("invalidSignature")
            case .malformed: return .failure("malformed")
            case .invalidKey: return .failure("invalidKey")
            case .rolledBack: return .failure("rolledBack")
            }
        } catch {
            return .failure("malformed")
        }
        do { try configuration.storage.persistAllowList(signed) } catch { return .failure("io") }
        let previous = allowList
        allowList = list
        let allowed = Set(list.peers.map(\.publicKey))
        for removed in (previous?.peers ?? []).map(\.publicKey) where !allowed.contains(removed) {
            let id = MailboxPeerID(staticKey: removed)
            try? inbox.deleteAll(peer: id)
            try? outbox.deleteAll(peer: id)
            if let entry = sessions.removeValue(forKey: removed) { await entry.session.close() }
        }
        for (key, entry) in sessions where !allowed.contains(key) && !entry.viaPairing {
            sessions[key] = nil
            await entry.session.close()
        }
        await notifyStatus()
        return .success(Int(clamping: list.version))
    }

    /// Stores sealed batches the app produced for `peer`; the agent serves them while the app is locked or quit.
    public func publishOutbox(peer: Data, envelopes: [Data]) -> AgentCommandResult {
        let id = MailboxPeerID(staticKey: peer)
        var stored = 0
        for envelope in envelopes {
            do {
                try outbox.put(envelope: envelope, peer: id)
                stored += 1
            } catch MailboxError.quotaExceeded {
                return .failure("quotaExceeded", value: stored)
            } catch MailboxError.blobTooLarge {
                return .failure("blobTooLarge", value: stored)
            } catch MailboxError.invalidRange {
                return .failure("invalidRange", value: stored)
            } catch {
                return .failure("io", value: stored)
            }
        }
        return .success(stored)
    }

    /// Batches waiting for the app, oldest first per peer, up to `maxBytes` (at least one item).
    public func fetchInbox(peer: Data?, maxBytes: Int) -> [AgentInboxItem] {
        let ids: [MailboxPeerID]
        if let peer { ids = [MailboxPeerID(staticKey: peer)] } else { ids = (try? inbox.peers()) ?? [] }
        var items: [AgentInboxItem] = []
        var total = 0
        for id in ids {
            guard let key = Self.data(fromHex: id.rawValue), let entries = try? inbox.list(peer: id) else { continue }
            for entry in entries {
                if !items.isEmpty, total + entry.size > maxBytes { return items }
                guard let bytes = try? inbox.fetch(entry) else { continue }
                total += bytes.count
                items.append(AgentInboxItem(
                    peer: key, sender: entry.sender, seqFrom: entry.seqFrom, seqTo: entry.seqTo, storedAt: entry.storedAt,
                    envelope: bytes))
            }
        }
        return items
    }

    /// Deletes inbox entries the app applied; returns how many files were removed.
    public func deleteInbox(_ refs: [AgentInboxRef]) -> Int {
        var removed = 0
        for ref in refs {
            let entry = MailboxEntry(
                peer: MailboxPeerID(staticKey: ref.peer), sender: ref.sender, seqFrom: ref.seqFrom, seqTo: ref.seqTo, size: 0,
                storedAt: .distantPast)
            if (try? inbox.delete(entry)) != nil { removed += 1 }
        }
        return removed
    }

    /// Sends `message` on the session of `peer` (the app's live replies, pairing grant). `false` when the peer is not connected.
    public func forward(_ message: SyncMessage, to peer: Data) async -> Bool {
        guard let entry = sessions[peer] else { return false }
        do {
            try await entry.session.send(message)
            return true
        } catch {
            return false
        }
    }

    public func closeSession(peer: Data) async {
        if let entry = sessions.removeValue(forKey: peer) { await entry.session.close() }
    }

    /// Deletes every stored batch (Settings › "remove helper data"); the identity and allow-list stay.
    public func wipeMailbox() -> Int {
        var removed = 0
        for store in [inbox, outbox] {
            for id in (try? store.peers()) ?? [] {
                removed += ((try? store.list(peer: id)) ?? []).count
                try? store.deleteAll(peer: id)
            }
        }
        return removed
    }

    public func status() -> AgentStatus {
        var inboxCount = 0, inboxBytes = 0, outboxCount = 0, outboxBytes = 0
        for id in (try? inbox.peers()) ?? [] {
            let entries = (try? inbox.list(peer: id)) ?? []
            inboxCount += entries.count
            inboxBytes += entries.reduce(0) { $0 + $1.size }
        }
        for id in (try? outbox.peers()) ?? [] {
            let entries = (try? outbox.list(peer: id)) ?? []
            outboxCount += entries.count
            outboxBytes += entries.reduce(0) { $0 + $1.size }
        }
        var host: String?
        var port: UInt16?
        var problem: String?
        var listening = false
        switch currentListenerState {
        case .ready(let bound):
            listening = true
            port = bound
            switch configuration.binding {
            case .tailnet: host = tailnet?.address
            case .loopback: host = "127.0.0.1"
            }
        case .failed(let reason): problem = "failed: \(reason)"
        case .starting, .cancelled: break
        }
        return AgentStatus(
            protocolVersion: AgentConstants.xpcProtocolVersion, build: configuration.build, staticPublicKey: staticPublicKey,
            listening: listening, host: host, port: port, tailnetInterface: tailnet?.name, listenerError: problem,
            appAttached: app != nil, connectedPeers: sessions.keys.map { MailboxPeerID(staticKey: $0).rawValue }.sorted(),
            pairingActive: activeOffer() != nil, allowListVersion: allowList?.version ?? 0,
            ownerKeyPresent: configuration.storage.readOwnerPublicKey() != nil, inboxBatches: inboxCount, inboxBytes: inboxBytes,
            outboxBatches: outboxCount, outboxBytes: outboxBytes)
    }

    private func notifyStatus() async {
        guard let endpoint = app?.endpoint else { return }
        await endpoint.statusChanged(status())
    }

    // MARK: Helpers

    static func data(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Runs `body`; when `limit` passes first, `onTimeout` runs (it closes the stream so `body` fails).
    static func withTimeout<T: Sendable>(
        _ limit: Duration, onTimeout: @escaping @Sendable () async -> Void, _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let timer = Task {
            try await Task.sleep(for: limit)
            await onTimeout()
        }
        defer { timer.cancel() }
        return try await body()
    }
}

/// Hands out an already received first message, then reads from the underlying stream. Lets the server look at the first
/// handshake message to pick the pattern before `NoiseSession` reads it.
final class ReplayFirstStream: ByteStream, @unchecked Sendable {
    private let base: any ByteStream
    private let lock = NSLock()
    private var first: Data?

    init(_ base: any ByteStream, first: Data) {
        self.base = base
        self.first = first
    }

    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() async throws -> Data {
        let pending = lock.withLock { () -> Data? in
            defer { first = nil }
            return first
        }
        if let pending { return pending }
        return try await base.receive()
    }

    func close() async { await base.close() }
}
