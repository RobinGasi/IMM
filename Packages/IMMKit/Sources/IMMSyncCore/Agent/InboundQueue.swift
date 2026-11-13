import Foundation

/// Messages that arrived on a stream and the one task waiting for the next; shared by the TCP `ByteStream`s.
/// After `fail`, queued messages stay readable, then `pop` throws.
final class InboundQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var failure: Error?

    var currentFailure: Error? { lock.withLock { failure } }

    func push(_ payloads: [Data]) {
        guard !payloads.isEmpty else { return }
        var resume: (CheckedContinuation<Data, Error>, Data)?
        lock.withLock {
            for payload in payloads {
                if resume == nil, messages.isEmpty, let waiting = waiter {
                    waiter = nil
                    resume = (waiting, payload)
                } else {
                    messages.append(payload)
                }
            }
        }
        resume.map { $0.0.resume(returning: $0.1) }
    }

    func fail(_ error: Error) {
        let waiting = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            if failure == nil { failure = error }
            defer { waiter = nil }
            return messages.isEmpty ? waiter : nil
        }
        waiting?.resume(throwing: error)
    }

    func pop() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let outcome: Result<Data, Error>? = lock.withLock {
                if !messages.isEmpty { return .success(messages.removeFirst()) }
                if let failure { return .failure(failure) }
                precondition(waiter == nil, "one receiver at a time")
                waiter = continuation
                return nil
            }
            switch outcome {
            case .success(let data): continuation.resume(returning: data)
            case .failure(let error): continuation.resume(throwing: error)
            case nil: break
            }
        }
    }
}
