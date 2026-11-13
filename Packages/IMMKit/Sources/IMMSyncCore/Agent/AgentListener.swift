import Darwin
import Foundation

public enum AgentListenerState: Equatable, Sendable {
    case starting
    case ready(port: UInt16)
    case failed(String)
    case cancelled
}

/// A TCP listener on one local address: the Mac's tailnet address, or (tests only) loopback.
///
/// The listening socket is bound to the tailnet IPv4 address itself and scoped to the `utun` interface (`IP_BOUND_IF`), so
/// connections to the LAN address or to loopback are refused and nothing is reachable from Wi-Fi. The server cancels and
/// rebuilds the listener when `TailnetInterfaceMonitor` reports a change; without Tailscale there is no listener at all.
///
/// Why BSD sockets and not `NWListener(requiredInterface:)`: measured on macOS 27.0.1 with Tailscale's network
/// extension on a utun interface, an `NWListener` bound by `requiredInterface` to the utun — or any wildcard
/// `NWListener` — receives the peer's SYN ("received new flow") but then fails `nw_path_evaluator_create_flow_inner
/// NECP_CLIENT_ACTION_ADD_FLOW … [1: Operation not permitted]`, so a second tailnet device times out. A sandboxed BSD
/// socket bound to `100.x:47380` is reachable from that device and refused on the LAN address (Apple-signed daemons and
/// a Python listener behave the same way). An earlier experiment saw `NWListener` work; the difference is unexplained.
public final class AgentListener: @unchecked Sendable {
    public enum Binding: Sendable {
        case tailnet(TailnetInterface)
        /// Test mode: 127.0.0.1 only.
        case loopback
    }

    public let binding: Binding
    private let socketFD: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "dev.gasi.imm.sync-agent.listener")
    private let lock = NSLock()
    private var current: AgentListenerState = .starting
    private var waiters: [CheckedContinuation<AgentListenerState, Never>] = []
    private var open = 0
    private let onState: @Sendable (AgentListenerState) -> Void
    private let onConnection: @Sendable (SocketStream) -> Void
    /// Connections beyond this many open sockets are closed at once (unauthenticated flood).
    private let maxOpenConnections: Int

    /// Binds and listens immediately; throws when the address cannot be bound.
    /// - Parameters:
    ///   - port: TCP port; 0 picks a free one (loopback test mode).
    ///   - onConnection: called for each accepted connection.
    ///   - onState: called when the state changes (`ready` / `failed` / `cancelled`).
    public init(
        binding: Binding, port: UInt16, maxOpenConnections: Int = 32,
        onConnection: @escaping @Sendable (SocketStream) -> Void,
        onState: @escaping @Sendable (AgentListenerState) -> Void
    ) throws {
        self.binding = binding
        self.onState = onState
        self.onConnection = onConnection
        self.maxOpenConnections = maxOpenConnections

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError.io("socket: \(String(cString: strerror(errno)))") }
        func fail(_ what: String) -> AgentError {
            let message = "\(what): \(String(cString: strerror(errno)))"
            Darwin.close(fd)
            return .io(message)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let host: String
        switch binding {
        case .tailnet(let tailnet):
            host = tailnet.address
            var index = if_nametoindex(tailnet.name)
            guard index != 0 else { throw fail("if_nametoindex(\(tailnet.name))") }
            guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                throw fail("IP_BOUND_IF")
            }
        case .loopback:
            host = "127.0.0.1"
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw fail("inet_pton(\(host))") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw fail("bind(\(host):\(port))") }
        guard listen(fd, 16) == 0 else { throw fail("listen") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw fail("getsockname") }
        self.socketFD = fd
        self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        current = .ready(port: UInt16(bigEndian: actual.sin_port))
    }

    public var state: AgentListenerState { lock.withLock { current } }

    /// Starts accepting connections; reports `ready` through `onState`.
    public func start() {
        source.setEventHandler { [weak self] in self?.acceptPending() }
        let fd = socketFD
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        let ready = state
        onState(ready)
    }

    public func cancel() {
        let waitersToResume: [CheckedContinuation<AgentListenerState, Never>] = lock.withLock {
            guard current != .cancelled else { return [] }
            current = .cancelled
            defer { waiters = [] }
            return waiters
        }
        source.cancel()
        for waiter in waitersToResume { waiter.resume(returning: .cancelled) }
        onState(.cancelled)
    }

    /// The state once it is not `.starting` (immediately for this listener: it binds in `init`).
    public func settledState() async -> AgentListenerState { state }

    private func acceptPending() {
        while true {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(socketFD, $0, &length) }
            }
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                if errno != EAGAIN { reportFailure(String(cString: strerror(errno))) }
                return
            }
            let admitted = lock.withLock { () -> Bool in
                guard open < maxOpenConnections else { return false }
                open += 1
                return true
            }
            guard admitted else {
                Darwin.close(client)
                continue
            }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &peer.sin_addr, &text, socklen_t(text.count))
            let textBytes = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let remote = "\(String(decoding: textBytes, as: UTF8.self)):\(UInt16(bigEndian: peer.sin_port))"
            let stream = SocketStream(fd: client, remoteDescription: remote, onClosed: { [weak self] in
                self?.lock.withLock { self?.open -= 1 }
            })
            onConnection(stream)
        }
    }

    private func reportFailure(_ reason: String) {
        let changed = lock.withLock { () -> Bool in
            guard current != .cancelled else { return false }
            if case .failed = current { return false }
            current = .failed(reason)
            return true
        }
        if changed { onState(.failed(reason)) }
    }
}
