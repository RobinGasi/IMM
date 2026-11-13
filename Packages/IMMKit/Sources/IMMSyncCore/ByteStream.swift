import Foundation

public enum ByteStreamError: Error, Equatable, Sendable {
    case closed
}

/// A message-oriented, ordered, reliable pipe to one peer. Each `send` delivers exactly one message; `receive`
/// returns the next one. Real transports implement it over TCP with `Frame` (length-prefixed), tests with
/// `InMemoryDuplexStream`. Used for both the handshake messages and the encrypted transport messages.
public protocol ByteStream: Sendable {
    func send(_ data: Data) async throws
    /// Suspends until the next message arrives; throws when the stream ended.
    func receive() async throws -> Data
    /// Releases the underlying connection. Default: nothing to do.
    func close() async
}

extension ByteStream {
    public func close() async {}
}

/// One endpoint of an in-memory duplex pipe, for tests and in-process simulations. Records everything it sent and
/// lets a test inject or drop messages on the way to the peer.
public final class InMemoryDuplexStream: ByteStream, @unchecked Sendable {
    private final class Queue: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Data] = []
        private var waiter: CheckedContinuation<Data, Error>?
        private var closed = false

        func push(_ data: Data) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: data)
            } else {
                items.append(data)
                lock.unlock()
            }
        }

        func pop() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !items.isEmpty {
                    let item = items.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: item)
                } else if closed {
                    lock.unlock()
                    continuation.resume(throwing: ByteStreamError.closed)
                } else {
                    precondition(waiter == nil, "one receiver at a time")
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        func close() {
            lock.lock()
            closed = true
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(throwing: ByteStreamError.closed)
        }
    }

    private let inbox: Queue
    private let outbox: Queue
    private let lock = NSLock()
    private var log: [Data] = []
    private var dropNext = 0

    private init(inbox: Queue, outbox: Queue) {
        self.inbox = inbox
        self.outbox = outbox
    }

    /// Two connected endpoints.
    public static func makePair() -> (InMemoryDuplexStream, InMemoryDuplexStream) {
        let a = Queue(), b = Queue()
        return (InMemoryDuplexStream(inbox: a, outbox: b), InMemoryDuplexStream(inbox: b, outbox: a))
    }

    /// Every message this endpoint sent, in order (including dropped ones).
    public var sentMessages: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// Silently discards the next `count` messages this endpoint sends.
    public func dropNextSends(_ count: Int) {
        lock.lock()
        dropNext = count
        lock.unlock()
    }

    /// Delivers `data` to the peer as if this endpoint had sent it (replay / forgery in tests).
    public func inject(_ data: Data) { outbox.push(data) }

    private func record(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        log.append(data)
        guard dropNext > 0 else { return false }
        dropNext -= 1
        return true
    }

    public func send(_ data: Data) async throws {
        if !record(data) { outbox.push(data) }
    }

    public func receive() async throws -> Data { try await inbox.pop() }

    public func close() async {
        outbox.close()
        inbox.close()
    }
}
