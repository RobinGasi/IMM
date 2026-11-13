import Darwin
import Foundation

/// `ByteStream` over an accepted BSD socket: every message is one `Frame`.
///
/// Network.framework's `NWListener` is not used for the agent's inbound side: on this Mac a listener bound to the tailnet
/// `utun` accepts the SYN but then fails `NECP_CLIENT_ACTION_ADD_FLOW` with EPERM, so no tailnet peer ever connects (see
/// `AgentListener`). A plain socket bound to the tailnet address works.
///
/// One reader thread decodes frames; writes are non-blocking with a bounded wait, so a stalled peer cannot block the
/// agent. The descriptor is closed by the reader thread only, after `close()` shut the socket down.
public final class SocketStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let inbound = InboundQueue()
    private let lock = NSLock()
    private var fdClosed = false
    private let writeQueue = DispatchQueue(label: "dev.gasi.imm.sync-agent.socket-write")
    private let onClosed: @Sendable () -> Void
    /// How long a single `send` may wait for a peer that does not read.
    static let writeTimeout: TimeInterval = 15

    public let remoteDescription: String

    /// Takes ownership of `fd` (a connected TCP socket) and starts reading.
    init(fd: Int32, remoteDescription: String, onClosed: @escaping @Sendable () -> Void = {}) {
        self.fd = fd
        self.remoteDescription = remoteDescription
        self.onClosed = onClosed
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
        var idle: Int32 = 60
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
        let thread = Thread { [self] in readLoop() }
        thread.name = "dev.gasi.imm.sync-agent.socket-read"
        thread.start()
    }

    private func readLoop() {
        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var failure: Error = ByteStreamError.closed
        readLoop: while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            decoder.append(Data(buffer[0..<count]))
            var payloads: [Data] = []
            do {
                while let payload = try decoder.next() { payloads.append(payload) }
            } catch {
                inbound.push(payloads)
                failure = error
                break readLoop
            }
            inbound.push(payloads)
        }
        inbound.fail(failure)
        lock.withLock {
            fdClosed = true
            Darwin.close(fd)
        }
        onClosed()
    }

    public func send(_ data: Data) async throws {
        if let failure = inbound.currentFailure { throw failure }
        let framed = try Frame.encode(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    try self.writeAll(framed)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writeAll(_ data: Data) throws {
        let deadline = Date().addingTimeInterval(Self.writeTimeout)
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                let written: Int = lock.withLock {
                    fdClosed ? -2 : write(fd, raw.baseAddress! + offset, raw.count - offset)
                }
                if written >= 0 {
                    offset += written
                    continue
                }
                if written == -2 { throw ByteStreamError.closed }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == ENOBUFS else {
                    shutdownSocket()
                    throw ByteStreamError.closed
                }
                guard Date() < deadline else {
                    shutdownSocket()
                    throw NWConnectionStreamError.timedOut
                }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, 200)
            }
        }
    }

    private func shutdownSocket() {
        lock.withLock {
            if !fdClosed { Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    public func receive() async throws -> Data { try await inbound.pop() }

    public func close() async {
        inbound.fail(ByteStreamError.closed)
        shutdownSocket()
    }
}
