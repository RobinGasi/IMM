import Foundation

public enum SyncMessageError: Error, Equatable, Sendable {
    case truncated
    /// First byte is not a version this build understands.
    case unsupportedVersion(UInt8)
    /// Known version, unknown type byte (from a newer peer): the receiver ignores it and replies with `.error`.
    case unknownType(UInt8)
    case malformed(String)
}

/// Machine-readable reason in `SyncMessage.error`. Unknown values round-trip, so newer peers can add codes.
public struct SyncErrorCode: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let unknownMessageType = SyncErrorCode(rawValue: 1)
    public static let unsupportedVersion = SyncErrorCode(rawValue: 2)
    public static let malformed = SyncErrorCode(rawValue: 3)
    public static let notAllowed = SyncErrorCode(rawValue: 4)
    public static let quotaExceeded = SyncErrorCode(rawValue: 5)
    public static let `internal` = SyncErrorCode(rawValue: 6)
    public static let pairingRejected = SyncErrorCode(rawValue: 7)
}

/// Application messages carried over a `NoiseSession`.
///
/// Wire format (stable): `version (1 byte, = 1) ‖ type (1 byte) ‖ body`. Integers are big-endian, byte strings and
/// strings carry a `UInt32` length. Decoders ignore trailing bytes after the fields they know, so a later version can
/// append fields to a message without breaking older peers. New message types get new type bytes; an older peer
/// answers them with `.error(.unknownMessageType, …)` and keeps the session open.
public enum SyncMessage: Equatable, Sendable {
    public static let version: UInt8 = 1

    public struct Cursor: Equatable, Sendable {
        public var device: UInt64
        /// Highest op sequence of `device` the sender has applied.
        public var appliedSeq: Int64
        public init(device: UInt64, appliedSeq: Int64) {
            self.device = device
            self.appliedSeq = appliedSeq
        }
    }

    public struct Hello: Equatable, Sendable {
        public var device: UInt64
        public var group: Data
        public var cursors: [Cursor]
        public init(device: UInt64, group: Data, cursors: [Cursor]) {
            self.device = device
            self.group = group
            self.cursors = cursors
        }
    }

    public struct SnapshotChunk: Equatable, Sendable {
        public var requestID: UInt64
        public var index: UInt32
        public var isFinal: Bool
        /// Opaque (sealed by the caller).
        public var data: Data
        public init(requestID: UInt64, index: UInt32, isFinal: Bool, data: Data) {
            self.requestID = requestID
            self.index = index
            self.isFinal = isFinal
            self.data = data
        }
    }

    case hello(Hello)
    case batch(SealedEnvelope)
    /// "I applied `device`'s ops through `throughSeq`."
    case ack(device: UInt64, throughSeq: Int64)
    case snapshotRequest(requestID: UInt64)
    case snapshotChunk(SnapshotChunk)
    case ping(token: UInt64)
    case pong(token: UInt64)
    case error(code: SyncErrorCode, message: String)
    /// Pairing hand-over (group key, signed roster entry …); the bytes are defined by the pairing layer above.
    case pairingGrant(Data)

    enum TypeByte: UInt8 {
        case hello = 1, batch, ack, snapshotRequest, snapshotChunk, ping, pong, error, pairingGrant
    }

    // MARK: Encoding

    public func encoded() -> Data {
        var out = ByteWriter()
        out.u8(Self.version)
        switch self {
        case .hello(let hello):
            out.u8(TypeByte.hello.rawValue)
            out.u64(hello.device)
            out.bytes(hello.group)
            out.u32(UInt32(hello.cursors.count))
            for cursor in hello.cursors {
                out.u64(cursor.device)
                out.u64(UInt64(bitPattern: cursor.appliedSeq))
            }
        case .batch(let envelope):
            out.u8(TypeByte.batch.rawValue)
            out.bytes(envelope.encoded())
        case .ack(let device, let seq):
            out.u8(TypeByte.ack.rawValue)
            out.u64(device)
            out.u64(UInt64(bitPattern: seq))
        case .snapshotRequest(let id):
            out.u8(TypeByte.snapshotRequest.rawValue)
            out.u64(id)
        case .snapshotChunk(let chunk):
            out.u8(TypeByte.snapshotChunk.rawValue)
            out.u64(chunk.requestID)
            out.u32(chunk.index)
            out.u8(chunk.isFinal ? 1 : 0)
            out.bytes(chunk.data)
        case .ping(let token):
            out.u8(TypeByte.ping.rawValue)
            out.u64(token)
        case .pong(let token):
            out.u8(TypeByte.pong.rawValue)
            out.u64(token)
        case .error(let code, let message):
            out.u8(TypeByte.error.rawValue)
            out.u16(code.rawValue)
            out.bytes(Data(message.utf8))
        case .pairingGrant(let blob):
            out.u8(TypeByte.pairingGrant.rawValue)
            out.bytes(blob)
        }
        return out.data
    }

    // MARK: Decoding

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let version = try reader.u8()
        guard version == Self.version else { throw SyncMessageError.unsupportedVersion(version) }
        let typeValue = try reader.u8()
        guard let type = TypeByte(rawValue: typeValue) else { throw SyncMessageError.unknownType(typeValue) }
        switch type {
        case .hello:
            let device = try reader.u64()
            let group = try reader.bytes()
            let count = Int(try reader.u32())
            guard count <= reader.remaining / 16 else { throw SyncMessageError.malformed("cursor count exceeds message") }
            var cursors: [Cursor] = []
            cursors.reserveCapacity(count)
            for _ in 0..<count {
                cursors.append(Cursor(device: try reader.u64(), appliedSeq: Int64(bitPattern: try reader.u64())))
            }
            self = .hello(Hello(device: device, group: group, cursors: cursors))
        case .batch:
            do {
                self = .batch(try SealedEnvelope(decoding: try reader.bytes()))
            } catch let error as SyncMessageError {
                throw error
            } catch {
                throw SyncMessageError.malformed("batch envelope: \(error)")
            }
        case .ack:
            self = .ack(device: try reader.u64(), throughSeq: Int64(bitPattern: try reader.u64()))
        case .snapshotRequest:
            self = .snapshotRequest(requestID: try reader.u64())
        case .snapshotChunk:
            let id = try reader.u64()
            let index = try reader.u32()
            let final = try reader.u8() != 0
            self = .snapshotChunk(SnapshotChunk(requestID: id, index: index, isFinal: final, data: try reader.bytes()))
        case .ping:
            self = .ping(token: try reader.u64())
        case .pong:
            self = .pong(token: try reader.u64())
        case .error:
            let code = SyncErrorCode(rawValue: try reader.u16())
            let text = try reader.bytes()
            self = .error(code: code, message: String(decoding: text, as: UTF8.self))
        case .pairingGrant:
            self = .pairingGrant(try reader.bytes())
        }
    }
}

// MARK: - Byte helpers

struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)]) }
    mutating func u32(_ value: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((value >> UInt32(shift)) & 0xff)) } }
    mutating func u64(_ value: UInt64) { for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((value >> UInt64(shift)) & 0xff)) } }
    mutating func bytes(_ value: Data) {
        u32(UInt32(value.count))
        data.append(value)
    }
}

struct ByteReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data.rebased() }

    var remaining: Int { data.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw SyncMessageError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw SyncMessageError.truncated }
        defer { offset += 2 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw SyncMessageError.truncated }
        defer { offset += 4 }
        return data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw SyncMessageError.truncated }
        defer { offset += 8 }
        return data[offset..<offset + 8].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func bytes() throws -> Data {
        let length = Int(try u32())
        guard remaining >= length else { throw SyncMessageError.truncated }
        defer { offset += length }
        return Data(data[offset..<offset + length])
    }
}
