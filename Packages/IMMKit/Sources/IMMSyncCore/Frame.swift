import Foundation

public enum FrameError: Error, Equatable, Sendable {
    /// The declared or supplied payload exceeds `Frame.maxPayload`.
    case tooLarge(Int)
}

/// Stream framing: UInt32 big-endian length, then that many payload bytes (≤ 1 MiB).
/// Each frame carries one Noise message (≤ 65 535 B); larger logical messages are chunked above the Noise layer.
public enum Frame {
    public static let headerLength = 4
    public static let maxPayload = 1 << 20

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxPayload else { throw FrameError.tooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }
}

/// Incremental decoder for a byte stream: `append` received bytes, then drain `next()`.
/// A header declaring more than `Frame.maxPayload` throws before any payload is buffered.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedCount: Int { buffer.count }

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// The next complete payload, or `nil` when more bytes are needed.
    public mutating func next() throws -> Data? {
        guard buffer.count >= Frame.headerLength else { return nil }
        let base = buffer.startIndex
        let length = buffer[base..<base + 4].reduce(0) { ($0 << 8) | Int($1) }
        guard length <= Frame.maxPayload else { throw FrameError.tooLarge(length) }
        guard buffer.count >= Frame.headerLength + length else { return nil }
        let payload = buffer[(base + 4)..<(base + 4 + length)].rebased()
        buffer = buffer.dropFirst(Frame.headerLength + length).rebased()
        return payload
    }
}
