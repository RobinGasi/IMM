import CoreImage
import CryptoKit
import Foundation
import IMMLedger
import IMMSyncCore

/// Base32 with the RFC 4648 alphabet (A–Z, 2–7: no 0, 1, 8, 9), shown in groups of four: `K7QM-4TZP-X2WD-6HNA`.
public enum PairingCodeFormat {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// 10 bytes → 16 symbols (80 bits) in four dash-separated groups.
    public static func encode(_ secret: Data) -> String {
        precondition(secret.count == PairingSecret.length)
        var out: [Character] = []
        var buffer: UInt64 = 0
        var bits = 0
        for byte in secret {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt64(bits - 5)) & 31)])
                bits -= 5
            }
        }
        return stride(from: 0, to: out.count, by: 4).map { String(out[$0..<min($0 + 4, out.count)]) }.joined(separator: "-")
    }

    /// Accepts any case and ignores dashes and spaces; nil for a wrong length or a symbol outside the alphabet.
    public static func decode(_ text: String) -> Data? {
        let symbols = text.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard symbols.count == PairingSecret.length * 8 / 5 else { return nil }
        var buffer: UInt64 = 0
        var bits = 0
        var out = Data()
        for symbol in symbols {
            guard let value = alphabet.firstIndex(of: symbol) else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> UInt64(bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out.count == PairingSecret.length ? out : nil
    }
}

/// The pairing secret: 80 random bits, shown as the code and carried in the QR payload. 80 bits are enough because an offer
/// lives 120 seconds, is single-use and the agent withdraws it after five failed handshakes; the PSK fed to Noise is
/// `HKDF-SHA256(secret, info = "imm/v1/pair-psk", 32)`.
public struct PairingSecret: Sendable, Equatable {
    public static let length = 10
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.length else { return nil }
        self.bytes = bytes
    }

    public static func generate() -> PairingSecret {
        PairingSecret(bytes: Data((0..<length).map { _ in UInt8.random(in: 0...255) }))!
    }

    public var code: String { PairingCodeFormat.encode(bytes) }

    /// The 32-byte pre-shared key for `Noise_XXpsk3`.
    public var psk: Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bytes), salt: Data(), info: Data("imm/v1/pair-psk".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}

/// What the Mac shows while a device pairs: QR payload and copyable code.
public struct PairingOffer: Sendable, Equatable {
    /// Compact JSON, version 1: `{"v":1,"device":"<node hex>","agent":"<base64 agent static key>","secret":"<code>","expiry":<unix s>,"host":"…","port":47380}`.
    public let qrPayload: String
    /// `K7QM-4TZP-X2WD-6HNA`.
    public let code: String
    public let expiry: Date
    public let host: String
    public let port: UInt16
    /// The agent's static key (also inside the QR payload), for pairing by code alone on another Mac.
    public let agentKey: Data

    /// A QR code rendering of `qrPayload` (error correction M), scaled by an integer factor to about `size` points.
    public func qrImage(size: Int = 280) -> CGImage? { QRCode.image(for: qrPayload, size: size) }
}

public enum PairingPayload {
    struct Wire: Codable {
        var v: Int
        var device: String
        var agent: Data
        var secret: String
        var expiry: Double
        var host: String
        var port: Int
    }

    static func make(node: DeviceNodeID, agentKey: Data, secret: PairingSecret, expiry: Date, host: String, port: UInt16) -> String {
        let wire = Wire(
            v: 1, device: String(node, radix: 16), agent: agentKey, secret: secret.code, expiry: expiry.timeIntervalSince1970,
            host: host, port: Int(port))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(wire)) ?? Data(), as: UTF8.self)
    }
}

/// A parsed invitation as the joining device sees it: from the QR JSON, or from a typed code (host, port and optionally
/// the agent key then come from the command line).
public struct PairingInvite: Sendable, Equatable {
    public var secret: PairingSecret
    public var agentKey: Data?
    public var host: String?
    public var port: UInt16?
    public var expiry: Date?
    public var hubNode: DeviceNodeID?

    public init(secret: PairingSecret, agentKey: Data? = nil, host: String? = nil, port: UInt16? = nil, expiry: Date? = nil, hubNode: DeviceNodeID? = nil) {
        self.secret = secret
        self.agentKey = agentKey
        self.host = host
        self.port = port
        self.expiry = expiry
        self.hubNode = hubNode
    }

    /// Parses the QR JSON (`{"v":1,…}`) or a bare code (`K7QM-4TZP-X2WD-6HNA`).
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            guard let wire = try? JSONDecoder().decode(PairingPayload.Wire.self, from: Data(trimmed.utf8)), wire.v == 1 else {
                throw SyncError.invalidInvite("unreadable pairing QR payload")
            }
            guard let bytes = PairingCodeFormat.decode(wire.secret), let secret = PairingSecret(bytes: bytes), wire.agent.count == 32 else {
                throw SyncError.invalidInvite("bad secret or agent key")
            }
            self.init(
                secret: secret, agentKey: wire.agent, host: wire.host, port: UInt16(clamping: wire.port),
                expiry: Date(timeIntervalSince1970: wire.expiry), hubNode: UInt64(wire.device, radix: 16))
        } else {
            guard let bytes = PairingCodeFormat.decode(trimmed), let secret = PairingSecret(bytes: bytes) else {
                throw SyncError.invalidInvite("the pairing code is 16 letters and digits (A–Z, 2–7), for example K7QM-4TZP-X2WD-6HNA")
            }
            self.init(secret: secret)
        }
    }
}

enum QRCode {
    static func image(for text: String, size: Int) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, CGFloat(size) / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

// MARK: - Hand-over messages (`SyncMessage.pairingGrant` payloads)

/// JSON bodies of `SyncMessage.pairingGrant`, tagged by `kind`.
enum PairingWire: Codable, Sendable, Equatable {
    /// Joiner → Mac, right after the handshake: who is asking.
    case join(SyncRosterEntry)
    /// Mac → joiner after the user confirmed the code.
    case grant(Grant)
    /// Mac → a device that is already paired: the group key rotated.
    case rekey(group: Data, key: Data)
    /// Mac → joiner: the user said the codes do not match.
    case reject

    struct Grant: Codable, Sendable, Equatable {
        var group: Data
        var key: Data
        var hub: SyncRosterEntry
        /// The other devices already in the group (the joiner connects to the Mac only, but keeps the roster).
        var roster: [SyncRosterEntry]
        /// Ed25519 signature of the Mac over `"imm/v1/roster" ‖ canonical JSON of (hub, roster)`.
        var signature: Data
    }

    private enum CodingKeys: String, CodingKey { case kind, entry, grant, group, key }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "join": self = .join(try container.decode(SyncRosterEntry.self, forKey: .entry))
        case "grant": self = .grant(try container.decode(Grant.self, forKey: .grant))
        case "rekey": self = .rekey(group: try container.decode(Data.self, forKey: .group), key: try container.decode(Data.self, forKey: .key))
        case "reject": self = .reject
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .join(let entry):
            try container.encode("join", forKey: .kind)
            try container.encode(entry, forKey: .entry)
        case .grant(let grant):
            try container.encode("grant", forKey: .kind)
            try container.encode(grant, forKey: .grant)
        case .rekey(let group, let key):
            try container.encode("rekey", forKey: .kind)
            try container.encode(group, forKey: .group)
            try container.encode(key, forKey: .key)
        case .reject:
            try container.encode("reject", forKey: .kind)
        }
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    init(decoding data: Data) throws {
        guard let decoded = try? JSONDecoder().decode(PairingWire.self, from: data) else {
            throw SyncError.protocolViolation("unreadable pairing message")
        }
        self = decoded
    }

    static func rosterSignatureInput(hub: SyncRosterEntry, roster: [SyncRosterEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Body: Codable { var hub: SyncRosterEntry; var roster: [SyncRosterEntry] }
        return Data("imm/v1/roster".utf8) + ((try? encoder.encode(Body(hub: hub, roster: roster))) ?? Data())
    }
}
