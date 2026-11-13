import Foundation
import Security

// MARK: - Protocols

/// What the app (the application endpoint) may ask of the agent, over the Mach service `AgentConstants.machServiceName`.
/// Every payload is `Data` (see `AgentWire`); peers are identified by their 32-byte Noise static public key.
@objc public protocol AgentXPCProtocol {
    /// `AgentStatus` as JSON.
    func status(reply: @escaping @Sendable (Data) -> Void)
    /// The app is unlocked and wants live relay; the client interface of this connection becomes the relay target.
    /// Invalidating the connection (or `detach`) hands relaying back to the mailbox. Replies with `AgentStatus`.
    func attach(reply: @escaping @Sendable (Data) -> Void)
    func detach(reply: @escaping @Sendable () -> Void)
    /// Allow XXpsk3 pairing handshakes with `secret` (32 bytes) until `expiry`. `false` unless attached.
    func setPairingOffer(secret: Data, expiry: Date, reply: @escaping @Sendable (Bool) -> Void)
    func clearPairingOffer(reply: @escaping @Sendable () -> Void)
    /// The app's owner Ed25519 public key (32 bytes) that signs allow-lists; replies with `AgentCommandResult`.
    func setOwnerPublicKey(_ key: Data, reply: @escaping @Sendable (Data) -> Void)
    /// `SignedPeerAllowList.encoded()`; replies with `AgentCommandResult` (value = list version).
    func publishAllowList(_ signed: Data, reply: @escaping @Sendable (Data) -> Void)
    /// `envelopes` = `AgentWire.encodeList` of encoded `SealedEnvelope`s; replies with `AgentCommandResult` (value = stored).
    func publishOutbox(peer: Data, envelopes: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Replies with `[AgentInboxItem]` JSON, up to `maxBytes` of envelopes (at least one item).
    func fetchInbox(peer: Data?, maxBytes: Int, reply: @escaping @Sendable (Data) -> Void)
    /// `refs` = JSON `[AgentInboxRef]`; replies with `AgentCommandResult` (value = deleted).
    func deleteInbox(_ refs: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Sends the encoded `SyncMessage` on the open session of `peer`; `false` when `peer` is not connected.
    func forward(_ message: Data, to peer: Data, reply: @escaping @Sendable (Bool) -> Void)
    func closeSession(peer: Data, reply: @escaping @Sendable () -> Void)
    /// Deletes every stored batch; replies with `AgentCommandResult` (value = deleted batches).
    func wipeMailbox(reply: @escaping @Sendable (Data) -> Void)
}

/// What the agent calls on the app (exported by the app's connection).
@objc public protocol AgentXPCClientProtocol {
    /// `AgentPairingEvent` as JSON.
    func pairingHandshakeCompleted(_ event: Data)
    /// An encoded `SyncMessage` from `peer`. Reply `true` when handled; `false` (or no reply within the relay timeout)
    /// makes the agent store/serve through the mailbox instead.
    func received(_ message: Data, from peer: Data, reply: @escaping @Sendable (Bool) -> Void)
    func peerConnectionChanged(peer: Data, connected: Bool)
    /// `AgentStatus` as JSON.
    func statusChanged(_ status: Data)
}

public enum AgentXPCInterfaces {
    public static func agent() -> NSXPCInterface { NSXPCInterface(with: AgentXPCProtocol.self) }
    public static func client() -> NSXPCInterface { NSXPCInterface(with: AgentXPCClientProtocol.self) }
}

// MARK: - Code-signing requirements

/// `NSXPCConnection.setCodeSigningRequirement` strings for both directions.
///
/// - Signed builds (Debug with a development certificate, Release with Developer ID): the peer must be signed by an Apple
///   chain with leaf OU = the team of this process and carry the expected bundle identifier.
/// - Unsigned builds (`Debug-Unsigned`, ad-hoc signature, no team): a team check cannot be satisfied, so the requirement
///   relaxes to the bundle identifier alone. That is weaker (any ad-hoc binary with that identifier passes), acceptable only
///   for local development; `relaxed` tells the caller so it can log it. Release builds are always signed.
public enum AgentXPCRequirements {
    public struct Requirement: Equatable, Sendable {
        public var text: String
        public var relaxed: Bool
    }

    /// Pure formatter: `anchor apple generic and certificate leaf[subject.OU] = "<team>" and identifier "<id>"`.
    public static func strict(teamIdentifier: String, identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(identifier)\""
    }

    /// The Team ID of the running process' signature, nil for ad-hoc or unsigned code.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Requirement for the process on the other end of the connection. The agent passes the app's bundle id, the app the agent's.
    public static func requirement(forPeerIdentifier identifier: String, ownTeam: String? = ownTeamIdentifier()) -> Requirement {
        if let ownTeam { return Requirement(text: strict(teamIdentifier: ownTeam, identifier: identifier), relaxed: false) }
        return Requirement(text: "identifier \"\(identifier)\"", relaxed: true)
    }

    public static func forAgentToTrustApp() -> Requirement { requirement(forPeerIdentifier: AgentConstants.appBundleIdentifier) }
    public static func forAppToTrustAgent() -> Requirement { requirement(forPeerIdentifier: AgentConstants.agentBundleIdentifier) }
}

// MARK: - Agent side

private final class OnceBool: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
        let taken = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}

/// `AgentAppEndpoint` over the connection's remote object (the app's exported `AgentXPCClientProtocol`).
final class XPCAppEndpoint: AgentAppEndpoint, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let relayTimeout: Duration

    init(connection: NSXPCConnection, relayTimeout: Duration) {
        self.connection = connection
        self.relayTimeout = relayTimeout
    }

    private func proxy(onError: @escaping @Sendable () -> Void = {}) -> (any AgentXPCClientProtocol)? {
        connection.remoteObjectProxyWithErrorHandler { _ in onError() } as? any AgentXPCClientProtocol
    }

    func pairingHandshakeCompleted(_ event: AgentPairingEvent) async {
        proxy()?.pairingHandshakeCompleted(AgentWire.encode(event))
    }

    func received(_ message: SyncMessage, from peer: Data) async -> Bool {
        let encoded = message.encoded()
        let timeout = relayTimeout
        return await withCheckedContinuation { continuation in
            let once = OnceBool(continuation)
            let timer = Task {
                try await Task.sleep(for: timeout)
                once.resume(false)
            }
            guard let proxy = proxy(onError: {
                once.resume(false)
                timer.cancel()
            }) else {
                once.resume(false)
                timer.cancel()
                return
            }
            proxy.received(encoded, from: peer) { handled in
                once.resume(handled)
                timer.cancel()
            }
        }
    }

    func peerConnectionChanged(peer: Data, connected: Bool) async {
        proxy()?.peerConnectionChanged(peer: peer, connected: connected)
    }

    func statusChanged(_ status: AgentStatus) async {
        proxy()?.statusChanged(AgentWire.encode(status))
    }
}

/// One app connection: exports `AgentXPCProtocol` and forwards to the `AgentServer`.
final class AgentXPCHandler: NSObject, AgentXPCProtocol, @unchecked Sendable {
    private let server: AgentServer
    private let relayTimeout: Duration
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var attachment: AgentAttachment?

    init(server: AgentServer, connection: NSXPCConnection, relayTimeout: Duration) {
        self.server = server
        self.connection = connection
        self.relayTimeout = relayTimeout
    }

    func connectionInvalidated() {
        Task { await detachCurrent() }
    }

    private func detachCurrent() async {
        let token = lock.withLock { () -> AgentAttachment? in
            defer { attachment = nil }
            return attachment
        }
        if let token { await server.detach(token) }
    }

    func status(reply: @escaping @Sendable (Data) -> Void) {
        let server = server
        Task { reply(AgentWire.encode(await server.status())) }
    }

    func attach(reply: @escaping @Sendable (Data) -> Void) {
        guard let connection else { return reply(Data()) }
        let endpoint = XPCAppEndpoint(connection: connection, relayTimeout: relayTimeout)
        Task {
            await detachCurrent()
            let token = await server.attach(endpoint)
            lock.withLock { attachment = token }
            reply(AgentWire.encode(await server.status()))
        }
    }

    func detach(reply: @escaping @Sendable () -> Void) {
        Task {
            await detachCurrent()
            reply()
        }
    }

    func setPairingOffer(secret: Data, expiry: Date, reply: @escaping @Sendable (Bool) -> Void) {
        let server = server
        Task { reply(await server.setPairingOffer(secret: secret, expiry: expiry)) }
    }

    func clearPairingOffer(reply: @escaping @Sendable () -> Void) {
        let server = server
        Task {
            await server.clearPairingOffer()
            reply()
        }
    }

    func setOwnerPublicKey(_ key: Data, reply: @escaping @Sendable (Data) -> Void) {
        let server = server
        Task { reply(AgentWire.encode(await server.setOwnerPublicKey(key))) }
    }

    func publishAllowList(_ signed: Data, reply: @escaping @Sendable (Data) -> Void) {
        let server = server
        Task { reply(AgentWire.encode(await server.publishAllowList(signed))) }
    }

    func publishOutbox(peer: Data, envelopes: Data, reply: @escaping @Sendable (Data) -> Void) {
        let server = server
        Task {
            guard let list = try? AgentWire.decodeList(envelopes) else { return reply(AgentWire.encode(AgentCommandResult.failure("malformed"))) }
            reply(AgentWire.encode(await server.publishOutbox(peer: peer, envelopes: list)))
        }
    }

    func fetchInbox(peer: Data?, maxBytes: Int, reply: @escaping @Sendable (Data) -> Void) {
        let server = server
        Task { reply(AgentWire.encode(await server.fetchInbox(peer: peer, maxBytes: maxBytes))) }
    }

    func deleteInbox(_ refs: Data, reply: @escaping @Sendable (Data) -> Void) {
        let server = server
        Task {
            guard let decoded = try? AgentWire.decode([AgentInboxRef].self, from: refs) else {
                return reply(AgentWire.encode(AgentCommandResult.failure("malformed")))
            }
            reply(AgentWire.encode(AgentCommandResult.success(await server.deleteInbox(decoded))))
        }
    }

    func forward(_ message: Data, to peer: Data, reply: @escaping @Sendable (Bool) -> Void) {
        let server = server
        Task {
            guard let decoded = try? SyncMessage(decoding: message) else { return reply(false) }
            reply(await server.forward(decoded, to: peer))
        }
    }

    func closeSession(peer: Data, reply: @escaping @Sendable () -> Void) {
        let server = server
        Task {
            await server.closeSession(peer: peer)
            reply()
        }
    }

    func wipeMailbox(reply: @escaping @Sendable (Data) -> Void) {
        let server = server
        Task { reply(AgentWire.encode(AgentCommandResult.success(await server.wipeMailbox()))) }
    }
}

/// Accepts app connections on the agent's Mach service (or, in tests, an anonymous listener).
public final class AgentXPCService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let server: AgentServer
    private let listener: NSXPCListener
    private let relayTimeout: Duration

    /// - Parameters:
    ///   - requirement: code-signing requirement the app must satisfy; nil disables the check (tests only).
    public init(
        server: AgentServer, listener: NSXPCListener = NSXPCListener(machServiceName: AgentConstants.machServiceName),
        requirement: String?, relayTimeout: Duration = .seconds(5)
    ) {
        self.server = server
        self.listener = listener
        self.relayTimeout = relayTimeout
        super.init()
        if let requirement { listener.setConnectionCodeSigningRequirement(requirement) }
        listener.delegate = self
    }

    public var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    public func resume() { listener.resume() }

    public func invalidate() { listener.invalidate() }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let handler = AgentXPCHandler(server: server, connection: connection, relayTimeout: relayTimeout)
        connection.exportedInterface = AgentXPCInterfaces.agent()
        connection.exportedObject = handler
        connection.remoteObjectInterface = AgentXPCInterfaces.client()
        connection.invalidationHandler = { [weak handler] in handler?.connectionInvalidated() }
        connection.resume()
        return true
    }
}

// MARK: - App side

public enum AgentXPCError: Error, Equatable, Sendable {
    /// The agent is not running, was invalidated or rejected the connection (code-signing requirement).
    case unreachable(String)
    case malformedReply
}

/// Bridges the agent's `AgentXPCClientProtocol` calls to a Swift `AgentAppEndpoint` (the app side of the live relay).
final class XPCClientExport: NSObject, AgentXPCClientProtocol, @unchecked Sendable {
    private let endpoint: any AgentAppEndpoint
    init(endpoint: any AgentAppEndpoint) { self.endpoint = endpoint }

    func pairingHandshakeCompleted(_ event: Data) {
        guard let decoded = try? AgentWire.decode(AgentPairingEvent.self, from: event) else { return }
        let endpoint = endpoint
        Task { await endpoint.pairingHandshakeCompleted(decoded) }
    }

    func received(_ message: Data, from peer: Data, reply: @escaping @Sendable (Bool) -> Void) {
        guard let decoded = try? SyncMessage(decoding: message) else { return reply(false) }
        let endpoint = endpoint
        Task { reply(await endpoint.received(decoded, from: peer)) }
    }

    func peerConnectionChanged(peer: Data, connected: Bool) {
        let endpoint = endpoint
        Task { await endpoint.peerConnectionChanged(peer: peer, connected: connected) }
    }

    func statusChanged(_ status: Data) {
        guard let decoded = try? AgentWire.decodeStatus(status) else { return }
        let endpoint = endpoint
        Task { await endpoint.statusChanged(decoded) }
    }
}

/// The app's side of the XPC link: typed, async wrappers over `AgentXPCProtocol`.
///
/// ```swift
/// let client = AgentXPCClient(endpoint: myEndpoint)          // requirement defaults to AgentXPCRequirements.forAppToTrustAgent()
/// let status = try await client.attach()                       // unlocked: live relay on
/// ```
public final class AgentXPCClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let export: XPCClientExport
    private let lock = NSLock()
    private var invalidationHandler: (@Sendable () -> Void)?

    /// Connects to the agent's Mach service. `requirement` nil disables the check (tests only).
    public convenience init(
        machServiceName: String = AgentConstants.machServiceName, endpoint: any AgentAppEndpoint,
        requirement: String? = AgentXPCRequirements.forAppToTrustAgent().text
    ) {
        self.init(connection: NSXPCConnection(machServiceName: machServiceName, options: []), endpoint: endpoint, requirement: requirement)
    }

    /// Connects to an anonymous listener (tests).
    public convenience init(listenerEndpoint: NSXPCListenerEndpoint, endpoint: any AgentAppEndpoint, requirement: String? = nil) {
        self.init(connection: NSXPCConnection(listenerEndpoint: listenerEndpoint), endpoint: endpoint, requirement: requirement)
    }

    private init(connection: NSXPCConnection, endpoint: any AgentAppEndpoint, requirement: String?) {
        self.connection = connection
        self.export = XPCClientExport(endpoint: endpoint)
        connection.remoteObjectInterface = AgentXPCInterfaces.agent()
        connection.exportedInterface = AgentXPCInterfaces.client()
        connection.exportedObject = export
        if let requirement { connection.setCodeSigningRequirement(requirement) }
        connection.invalidationHandler = { [weak self] in self?.fireInvalidated() }
        connection.interruptionHandler = { [weak self] in self?.fireInvalidated() }
        connection.resume()
    }

    /// Called when the connection was interrupted (agent exited or restarted) or invalidated; the app must `attach` again
    /// on a new client after an invalidation.
    public func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { invalidationHandler = handler }
    }

    private func fireInvalidated() {
        let handler = lock.withLock { invalidationHandler }
        handler?()
    }

    public func invalidate() { connection.invalidate() }

    private func call<T: Sendable>(_ body: (any AgentXPCProtocol, @escaping @Sendable (T) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: AgentXPCError.unreachable("\(error)"))
            }
            guard let agent = proxy as? any AgentXPCProtocol else {
                continuation.resume(throwing: AgentXPCError.unreachable("no proxy"))
                return
            }
            body(agent) { continuation.resume(returning: $0) }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try AgentWire.decode(type, from: data) } catch { throw AgentXPCError.malformedReply }
    }

    public func status() async throws -> AgentStatus {
        let data: Data = try await call { agent, reply in agent.status(reply: reply) }
        return try decode(AgentStatus.self, data)
    }

    @discardableResult
    public func attach() async throws -> AgentStatus {
        let data: Data = try await call { agent, reply in agent.attach(reply: reply) }
        return try decode(AgentStatus.self, data)
    }

    public func detach() async throws {
        let _: Bool = try await call { agent, reply in agent.detach { reply(true) } }
    }

    public func setPairingOffer(secret: Data, expiry: Date) async throws -> Bool {
        try await call { agent, reply in agent.setPairingOffer(secret: secret, expiry: expiry, reply: reply) }
    }

    public func clearPairingOffer() async throws {
        let _: Bool = try await call { agent, reply in agent.clearPairingOffer { reply(true) } }
    }

    public func setOwnerPublicKey(_ key: Data) async throws -> AgentCommandResult {
        let data: Data = try await call { agent, reply in agent.setOwnerPublicKey(key, reply: reply) }
        return try decode(AgentCommandResult.self, data)
    }

    public func publishAllowList(_ signed: SignedPeerAllowList) async throws -> AgentCommandResult {
        let encoded = try signed.encoded()
        let data: Data = try await call { agent, reply in agent.publishAllowList(encoded, reply: reply) }
        return try decode(AgentCommandResult.self, data)
    }

    public func publishOutbox(peer: Data, envelopes: [SealedEnvelope]) async throws -> AgentCommandResult {
        let payload = AgentWire.encodeList(envelopes.map { $0.encoded() })
        let data: Data = try await call { agent, reply in agent.publishOutbox(peer: peer, envelopes: payload, reply: reply) }
        return try decode(AgentCommandResult.self, data)
    }

    public func fetchInbox(peer: Data? = nil, maxBytes: Int = 8 << 20) async throws -> [AgentInboxItem] {
        let data: Data = try await call { agent, reply in agent.fetchInbox(peer: peer, maxBytes: maxBytes, reply: reply) }
        return try decode([AgentInboxItem].self, data)
    }

    @discardableResult
    public func deleteInbox(_ refs: [AgentInboxRef]) async throws -> Int {
        let payload = AgentWire.encodeRefs(refs)
        let data: Data = try await call { agent, reply in agent.deleteInbox(payload, reply: reply) }
        return try decode(AgentCommandResult.self, data).value
    }

    public func forward(_ message: SyncMessage, to peer: Data) async throws -> Bool {
        let encoded = message.encoded()
        return try await call { agent, reply in agent.forward(encoded, to: peer, reply: reply) }
    }

    public func closeSession(peer: Data) async throws {
        let _: Bool = try await call { agent, reply in agent.closeSession(peer: peer) { reply(true) } }
    }

    @discardableResult
    public func wipeMailbox() async throws -> Int {
        let data: Data = try await call { agent, reply in agent.wipeMailbox(reply: reply) }
        return try decode(AgentCommandResult.self, data).value
    }
}
