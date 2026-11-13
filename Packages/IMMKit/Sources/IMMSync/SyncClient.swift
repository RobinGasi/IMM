import CryptoKit
import Foundation
import IMMLedger
import IMMSyncCore

/// Something that happened during a client run (the peer tool prints it; tests record it).
public enum SyncClientEvent: Sendable {
    case connected(host: String, port: UInt16)
    case code(ShortAuthCode)
    case paired(hub: DeviceNodeID)
    case bootstrapped
    case sent(batches: Int, ops: Int)
    case applied(ops: [SyncOp], at: Date)
    case rekeyed
    case hubUnavailable(String)
}

public struct SyncReport: Sendable, Equatable {
    public var bootstrapped = false
    public var batchesSent = 0
    public var opsSent = 0
    public var opsApplied = 0
    public var hubLocked = false
    public var duration: Duration = .zero
}

/// Dials the Mac's agent and syncs one ledger with it: pairing (`Noise_XXpsk3`, agent key pinned from the QR) or a normal
/// session (`Noise_IK`, agent key pinned at pairing), `hello` / cursors, own batches up, the hub's outbox down, snapshot on first
/// contact. The iPhone app and the `imm-sync-peer` tool use it.
public actor SyncClient {
    public let engine: SyncEngine
    private let log: @Sendable (SyncClientEvent) -> Void

    public init(engine: SyncEngine, log: @escaping @Sendable (SyncClientEvent) -> Void = { _ in }) {
        self.engine = engine
        self.log = log
    }

    public struct Options: Sendable {
        /// A one-shot run ends after this long without traffic once everything pushed is acknowledged.
        public var idle: Duration = .milliseconds(600)
        /// Keep the session open this long, pushing local commits and applying what arrives (nil: one-shot).
        public var watch: Duration?
        /// Hard limit of a run (pairing waits for the user's confirmation on the Mac). Counts awake time (`AwakeClock`): a sleep of
        /// this device or a frozen process during the run does not use it up.
        public var timeout: Duration = .seconds(20)
        public init(idle: Duration = .milliseconds(600), watch: Duration? = nil, timeout: Duration = .seconds(20)) {
            self.idle = idle
            self.watch = watch
            self.timeout = timeout
        }
    }

    // MARK: Pairing

    /// Pairs with the Mac. `onCode` shows the 6-digit code; the Mac's user confirms there (or rejects) and the grant arrives;
    /// then the snapshot is fetched and applied. Throws `SyncError.pairingRejected` when the user rejected.
    public func pair(
        invite: PairingInvite, host: String, port: UInt16, options: Options = .init(timeout: .seconds(150)),
        onCode: @escaping @Sendable (ShortAuthCode) async throws -> Void = { _ in }
    ) async throws -> SyncReport {
        let identity = await engine.identity
        let stream = try await NWConnectionStream.connect(host: host, port: port, timeout: .seconds(10))
        log(.connected(host: host, port: port))
        let log = log
        let session = try await NoiseSession.initiatePairing(
            over: stream, localStatic: identity.x25519, pairingSecret: invite.secret.psk, expectedResponderStatic: invite.agentKey,
            onCode: { code in
                log(.code(code))
                try await onCode(code)
            })
        try await session.send(SyncEngine.joinMessage(identity.rosterEntry))
        return try await run(session: session, awaitGrant: true, options: options)
    }

    // MARK: Sessions

    /// One sync session with the paired Mac.
    public func sync(host: String, port: UInt16, options: Options = .init()) async throws -> SyncReport {
        let secrets = engine.secrets
        guard await engine.isPaired, let agent = try secrets.read(SyncSecretName.agentStatic) else { throw SyncError.notPaired }
        let identity = await engine.identity
        let stream = try await NWConnectionStream.connect(host: host, port: port, timeout: .seconds(10))
        log(.connected(host: host, port: port))
        let session = try await NoiseSession.connect(over: stream, localStatic: identity.x25519, pinnedResponderStatic: agent)
        return try await run(session: session, awaitGrant: false, options: options)
    }

    // MARK: Session loop

    private enum Item: Sendable {
        case message(SyncMessage)
        case closed
        /// Stamped by the timer task, so a slow consumer does not distort the awake time.
        case tick(ContinuousClock.Instant)
    }

    private final class Pump: @unchecked Sendable {
        let stream: AsyncStream<Item>
        private let reader: Task<Void, Never>
        private let timer: Task<Void, Never>

        init(session: NoiseSession) {
            let (stream, continuation) = AsyncStream<Item>.makeStream()
            self.stream = stream
            reader = Task {
                do {
                    while true { continuation.yield(.message(try await session.receive())) }
                } catch {
                    continuation.yield(.closed)
                    continuation.finish()
                }
            }
            timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    continuation.yield(.tick(.now))
                }
            }
        }

        func stop() {
            timer.cancel()
            reader.cancel()
        }
    }

    private final class RunState {
        var report = SyncReport()
        var hub: SyncPeer
        var awaiting: [UInt64: Int64] = [:]
        var granted: Bool
        var bootstrapPending = false
        /// Awake time of the last traffic.
        var lastActivity: Duration
        var lastPushedSeq: Int64 = -1
        /// Highest sequence per device already sent in this session (the hub's hello may still show an older cursor).
        var sentThrough: [UInt64: Int64] = [:]

        init(hub: SyncPeer, granted: Bool, now: Duration) {
            self.hub = hub
            self.granted = granted
            self.lastActivity = now
        }
    }

    private func push(_ state: RunState, session: NoiseSession, awake: AwakeClock) async throws {
        let batches = try await engine.batches(for: state.hub, ownOnly: true)
        var ops = 0
        for envelope in batches {
            try await session.send(.batch(envelope))
            state.awaiting[envelope.header.device] = max(state.awaiting[envelope.header.device] ?? 0, envelope.header.seqTo)
            state.sentThrough[envelope.header.device] = max(state.sentThrough[envelope.header.device] ?? 0, envelope.header.seqTo)
            ops += Int(envelope.header.seqTo - envelope.header.seqFrom + 1)
        }
        if !batches.isEmpty {
            state.report.batchesSent += batches.count
            state.report.opsSent += ops
            log(.sent(batches: batches.count, ops: ops))
            state.lastActivity = awake.elapsed
        }
        state.lastPushedSeq = try await localSeq()
    }

    private func run(session: NoiseSession, awaitGrant: Bool, options: Options) async throws -> SyncReport {
        let awake = AwakeClock()
        let pump = Pump(session: session)
        defer { pump.stop() }

        let secrets = engine.secrets
        let hubNode = try secrets.readInt(SyncSecretName.hubNode).map { UInt64(bitPattern: $0) }
        let state = RunState(hub: SyncPeer(staticKey: session.remoteStatic, node: hubNode), granted: !awaitGrant, now: .zero)
        let log = log

        if state.granted {
            try await session.send(try await engine.hello())
            try await push(state, session: session, awake: awake)
            if try await engine.needsBootstrap {
                try await session.send(await engine.snapshotRequest())
                state.bootstrapPending = true
            }
        }

        for await item in pump.stream {
            if case .tick(let stamp) = item { awake.observe(at: stamp) }
            let now = awake.elapsed
            switch item {
            case .tick:
                if now > options.timeout { throw SyncError.timedOut }
                if let watch = options.watch {
                    if now > watch {
                        state.report.duration = now
                        await session.close()
                        return state.report
                    }
                    if state.granted, !state.bootstrapPending, try await localSeq() != state.lastPushedSeq {
                        try await push(state, session: session, awake: awake)
                    }
                } else if state.granted, !state.bootstrapPending, state.awaiting.isEmpty, now - state.lastActivity > options.idle {
                    state.report.duration = now
                    await session.close()
                    return state.report
                }

            case .closed:
                if options.watch == nil, state.granted, !state.bootstrapPending {
                    state.report.duration = now
                    return state.report
                }
                if !state.granted { throw SyncError.protocolViolation("the Mac closed the connection before the pairing finished") }
                throw ByteStreamError.closed

            case .message(let message):
                state.lastActivity = now
                let handling = try await engine.handle(message, from: state.hub, fromHub: true)
                for event in handling.events {
                    switch event {
                    case .paired(let node):
                        state.granted = true
                        state.hub.node = node
                        try secrets.write(SyncSecretName.agentStatic, session.remoteStatic)
                        try secrets.remove(SyncSecretName.bootstrapDone)
                        log(.paired(hub: node))
                        try await session.send(await engine.snapshotRequest())
                        state.bootstrapPending = true
                    case .bootstrapped:
                        state.bootstrapPending = false
                        state.report.bootstrapped = true
                        log(.bootstrapped)
                    case .rejectedByHub:
                        throw SyncError.pairingRejected
                    case .acked(let device, let through):
                        if let want = state.awaiting[device], through >= want { state.awaiting[device] = nil }
                    case .rekeyed:
                        log(.rekeyed)
                    case .remoteError(let code, let text):
                        if code == .appUnavailable {
                            state.report.hubLocked = true
                            log(.hubUnavailable(text))
                            if state.bootstrapPending { throw SyncError.snapshotFailed("IMM is locked on the Mac; unlock it and try again") }
                        } else if code == .pairingRejected {
                            throw SyncError.pairingRejected
                        }
                    case .joinRequested, .batchRejected:
                        break
                    }
                }
                for reply in handling.replies {
                    if case .batch(let envelope) = reply {
                        // Already on the wire in this session (the hub's hello was written before our batch reached it).
                        if envelope.header.seqTo <= (state.sentThrough[envelope.header.device] ?? 0) { continue }
                        state.sentThrough[envelope.header.device] = envelope.header.seqTo
                        state.awaiting[envelope.header.device] = max(state.awaiting[envelope.header.device] ?? 0, envelope.header.seqTo)
                        state.report.batchesSent += 1
                        state.report.opsSent += Int(envelope.header.seqTo - envelope.header.seqFrom + 1)
                    }
                    try await session.send(reply)
                }
                if !handling.appliedOps.isEmpty {
                    state.report.opsApplied += handling.appliedOps.count
                    log(.applied(ops: handling.appliedOps, at: Date()))
                }
            }
        }
        // The consuming task was cancelled (the caller ended a watch early): close the session instead of leaking it.
        await session.close()
        if Task.isCancelled { throw CancellationError() }
        throw ByteStreamError.closed
    }

    private func localSeq() async throws -> Int64 {
        let local = await engine.identity.nodeID
        return try engine.ledger.writer.cursors().first { $0.device == local }?.appliedSeq ?? 0
    }
}
