import Foundation
import Network

public enum NWConnectionStreamError: Error, Equatable, Sendable {
    case connectFailed(String)
    case timedOut
}

/// `ByteStream` over a TCP `NWConnection`: every message is one `Frame` (UInt32 big-endian length, ≤ 1 MiB).
/// Used by the agent for accepted connections and by clients (the tests, later `SyncClient`) for outgoing ones.
public final class NWConnectionStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let inbound = InboundQueue()
    private let decoderLock = NSLock()
    private var decoder = FrameDecoder()

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// The remote endpoint of the connection (for logging).
    public var remoteDescription: String { connection.endpoint.debugDescription }

    /// Starts an accepted connection and waits until it is ready.
    public static func accept(_ connection: NWConnection, queue: DispatchQueue = .global(qos: .userInitiated)) async throws -> NWConnectionStream {
        let stream = NWConnectionStream(connection: connection)
        try await stream.start(queue: queue)
        return stream
    }

    /// Dials `host:port` and waits until the connection is ready. `timeout` bounds the wait (NWConnection otherwise
    /// waits for a usable path indefinitely); it counts awake time, so a sleep of the Mac mid-connect does not use it up.
    public static func connect(
        host: String, port: UInt16, timeout: Duration = .seconds(10), queue: DispatchQueue = .global(qos: .userInitiated)
    ) async throws -> NWConnectionStream {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWConnectionStreamError.connectFailed("bad port") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        let stream = NWConnectionStream(connection: connection)
        let timer = Task {
            try await AwakeClock.sleep(for: timeout)
            stream.fail(NWConnectionStreamError.timedOut)
            connection.cancel()
        }
        defer { timer.cancel() }
        try await stream.start(queue: queue)
        return stream
    }

    private func start(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case .failed(let error):
                    self?.fail(NWConnectionStreamError.connectFailed("\(error)"))
                    once.resume(throwing: NWConnectionStreamError.connectFailed("\(error)"))
                case .cancelled:
                    self?.fail(ByteStreamError.closed)
                    once.resume(throwing: self?.currentFailure ?? ByteStreamError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let (payloads, decodeError) = self.decoderLock.withLock { () -> ([Data], Error?) in
                    self.decoder.append(data)
                    var ready: [Data] = []
                    do {
                        while let payload = try self.decoder.next() { ready.append(payload) }
                    } catch {
                        return (ready, error)
                    }
                    return (ready, nil)
                }
                self.inbound.push(payloads)
                if let decodeError {
                    self.fail(decodeError)
                    self.connection.cancel()
                    return
                }
            }
            if error != nil || isComplete {
                self.fail(ByteStreamError.closed)
                self.connection.cancel()
                return
            }
            self.receiveLoop()
        }
    }

    /// Ends the stream: queued messages stay readable, then `receive` throws.
    private func fail(_ error: Error) { inbound.fail(error) }

    private var currentFailure: Error? { inbound.currentFailure }

    public func send(_ data: Data) async throws {
        if let failure = currentFailure { throw failure }
        let framed = try Frame.encode(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: NWConnectionStreamError.connectFailed("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> Data { try await inbound.pop() }

    public func close() async {
        fail(ByteStreamError.closed)
        connection.cancel()
    }
}

/// Resumes a checked continuation at most once.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}
