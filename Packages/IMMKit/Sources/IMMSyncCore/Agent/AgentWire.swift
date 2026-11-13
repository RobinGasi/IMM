import Foundation

/// Payloads of the XPC interface. Everything crosses XPC as one `Data` (JSON for records, `AgentWire.list` for byte-string
/// lists), so the @objc protocols need no secure-coding class lists and can grow fields without breaking an older peer.

public struct AgentStatus: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// `CFBundleVersion` of the agent bundle (the app re-registers the agent when it differs from its own embedded build).
    public var build: String
    /// The Mac's transport identity: peers pin this key (it goes into the pairing QR payload).
    public var staticPublicKey: Data
    public var listening: Bool
    /// Address the listener is bound to (`100.x` tailnet address, `127.0.0.1` in loopback test mode); nil without Tailscale.
    public var host: String?
    public var port: UInt16?
    public var tailnetInterface: String?
    /// Human-readable listener problem (`waiting(...)`, `failed(...)`), nil when fine or when simply no Tailscale.
    public var listenerError: String?
    /// An app is attached over XPC (unlocked): the agent relays live.
    public var appAttached: Bool
    /// Static keys (hex) of peers with an open session.
    public var connectedPeers: [String]
    public var pairingActive: Bool
    public var allowListVersion: UInt64
    public var ownerKeyPresent: Bool
    public var inboxBatches: Int
    public var inboxBytes: Int
    public var outboxBatches: Int
    public var outboxBytes: Int
}

/// "The XXpsk3 handshake finished": the app shows `code`, asks the user to confirm and then forwards a `.pairingGrant`.
public struct AgentPairingEvent: Codable, Equatable, Sendable {
    /// The joining device's authenticated static public key.
    public var peer: Data
    /// Six decimal digits (`ShortAuthCode.digits`).
    public var code: String
    /// Noise handshake hash (channel binding), for the app's own bookkeeping.
    public var handshakeHash: Data
}

/// One sealed batch of the inbox.
public struct AgentInboxItem: Codable, Equatable, Sendable {
    public var peer: Data
    public var sender: UInt64
    public var seqFrom: Int64
    public var seqTo: Int64
    public var storedAt: Date
    /// The encoded `SealedEnvelope`.
    public var envelope: Data
}

/// Reference to an inbox entry, for `deleteInbox`.
public struct AgentInboxRef: Codable, Equatable, Hashable, Sendable {
    public var peer: Data
    public var sender: UInt64
    public var seqFrom: Int64
    public var seqTo: Int64
    public init(peer: Data, sender: UInt64, seqFrom: Int64, seqTo: Int64) {
        self.peer = peer
        self.sender = sender
        self.seqFrom = seqFrom
        self.seqTo = seqTo
    }
}

/// Reply of commands that can fail for a reason the app must see.
public struct AgentCommandResult: Codable, Equatable, Sendable {
    public var ok: Bool
    /// Machine-readable: `ownerKeyMissing`, `invalidSignature`, `malformed`, `invalidKey`, `rolledBack`, `quotaExceeded`,
    /// `blobTooLarge`, `invalidRange`, `io`.
    public var error: String?
    /// Command-specific count or version (allow-list version, stored envelopes, deleted entries).
    public var value: Int
    public static func success(_ value: Int = 0) -> AgentCommandResult { .init(ok: true, error: nil, value: value) }
    public static func failure(_ error: String, value: Int = 0) -> AgentCommandResult { .init(ok: false, error: error, value: value) }
}

public enum AgentWire {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    /// `UInt32 count ‖ (UInt32 length ‖ bytes)*`.
    public static func encodeList(_ items: [Data]) -> Data {
        var writer = ByteWriter()
        writer.u32(UInt32(items.count))
        for item in items { writer.bytes(item) }
        return writer.data
    }

    public static func decodeList(_ data: Data) throws -> [Data] {
        var reader = ByteReader(data)
        let count = Int(try reader.u32())
        guard count <= reader.remaining / 4 else { throw SyncMessageError.malformed("list count exceeds data") }
        var items: [Data] = []
        items.reserveCapacity(count)
        for _ in 0..<count { items.append(try reader.bytes()) }
        return items
    }

    public static func decodeStatus(_ data: Data) throws -> AgentStatus { try decode(AgentStatus.self, from: data) }
    public static func decodeResult(_ data: Data) throws -> AgentCommandResult { try decode(AgentCommandResult.self, from: data) }
    public static func decodeInbox(_ data: Data) throws -> [AgentInboxItem] { try decode([AgentInboxItem].self, from: data) }
    public static func encodeRefs(_ refs: [AgentInboxRef]) -> Data { encode(refs) }
}

public extension SyncErrorCode {
    /// The agent cannot relay this message because no unlocked app is attached.
    static let appUnavailable = SyncErrorCode(rawValue: 8)
}
