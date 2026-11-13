import CryptoKit
import Foundation
import Network
import Testing

@testable import IMMSyncCore

/// Stands in for the app: records what the agent relays and answers `received` as configured.
final class AgentFakeApp: AgentAppEndpoint, @unchecked Sendable {
    private let lock = NSLock()
    private var _pairingEvents: [AgentPairingEvent] = []
    private var _received: [(message: SyncMessage, peer: Data)] = []
    private var _connections: [(peer: Data, connected: Bool)] = []
    private var _handles = true

    var handles: Bool {
        get { lock.withLock { _handles } }
        set { lock.withLock { _handles = newValue } }
    }
    var pairingEvents: [AgentPairingEvent] { lock.withLock { _pairingEvents } }
    var received: [(message: SyncMessage, peer: Data)] { lock.withLock { _received } }
    var connections: [(peer: Data, connected: Bool)] { lock.withLock { _connections } }

    func pairingHandshakeCompleted(_ event: AgentPairingEvent) async { lock.withLock { _pairingEvents.append(event) } }
    func received(_ message: SyncMessage, from peer: Data) async -> Bool {
        lock.withLock {
            _received.append((message, peer))
            return _handles
        }
    }
    func peerConnectionChanged(peer: Data, connected: Bool) async { lock.withLock { _connections.append((peer, connected)) } }
    func statusChanged(_ status: AgentStatus) async {}
}

/// An agent server on loopback with a temporary group container and an owner key.
struct AgentRig {
    let directory: URL
    let storage: AgentStorage
    let owner = Curve25519.Signing.PrivateKey()
    let server: AgentServer
    let port: UInt16
    let groupKey = SyncGroupKey.generate()

    init(limits: MailboxStore.Limits = .init(), handshakeTimeout: Duration = .seconds(10), directory existing: URL? = nil) async throws {
        directory = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("agent-test-\(UUID().uuidString)")
        storage = AgentStorage(groupContainer: directory)
        try storage.writeOwnerPublicKey(owner.publicKey.rawRepresentation)
        server = try AgentServer(configuration: AgentConfiguration(
            storage: storage, binding: .loopback(port: 0), limits: limits, build: "test", handshakeTimeout: handshakeTimeout))
        try await server.start()
        port = try #require(await server.boundPort)
    }

    func cleanup() async {
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func connect() async throws -> NWConnectionStream {
        try await NWConnectionStream.connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
    }

    /// Publishes an allow-list with `peers` at `version`.
    @discardableResult
    func allow(_ peers: [Curve25519.KeyAgreement.PrivateKey], version: UInt64 = 1) async throws -> AgentCommandResult {
        let list = PeerAllowList(
            version: version, issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
            peers: peers.enumerated().map { .init(publicKey: $1.publicKey.rawRepresentation, name: "peer \($0)") })
        let signed = try SignedPeerAllowList.sign(list, with: owner)
        return await server.publishAllowList(try signed.encoded())
    }

    /// IK session of an allow-listed peer.
    func live(_ key: Curve25519.KeyAgreement.PrivateKey) async throws -> NoiseSession {
        try await NoiseSession.connect(over: try await connect(), localStatic: key, pinnedResponderStatic: server.staticPublicKey)
    }

    func envelope(device: UInt64 = 0xA1, from: Int64, to: Int64, size: Int = 200) throws -> SealedEnvelope {
        try SealedEnvelope.seal(
            payload: Data(repeating: 0x5A, count: size),
            header: .init(group: Data(repeating: 9, count: 16), device: device, seqFrom: from, seqTo: to), key: groupKey)
    }
}

func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

extension NoiseSession {
    /// Ping/pong barrier: everything the peer sent before answering the ping has arrived (messages are ordered).
    func drainUntilPong(token: UInt64 = 0xFEED) async throws -> [SyncMessage] {
        try await send(.ping(token: token))
        var seen: [SyncMessage] = []
        while true {
            let message = try await receive()
            if message == .pong(token: token) { return seen }
            seen.append(message)
        }
    }
}
