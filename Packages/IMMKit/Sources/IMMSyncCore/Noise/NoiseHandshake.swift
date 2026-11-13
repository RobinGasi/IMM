import CryptoKit
import Foundation

public enum NoiseRole: Sendable, Equatable {
    case initiator, responder
}

/// Noise `HandshakeState` (spec §5.3), `Noise_*_25519_ChaChaPoly_SHA256`, revision 34.
///
/// Drive it with alternating `writeMessage` / `readMessage` calls (initiator writes first); once `isComplete`
/// call `split()`. Any thrown error leaves the state unusable (`invalidState`): abandon the connection.
public struct NoiseHandshake: Sendable {
    public let pattern: NoisePattern
    public let role: NoiseRole

    private var symmetric: NoiseSymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey?
    private var localEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteStaticKey: Curve25519.KeyAgreement.PublicKey?
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private var psks: [Data]
    private var messageIndex = 0
    private var failed = false
    /// Test hook: fixed ephemeral key (the vectors fix both ephemerals). Production code always generates one.
    private let fixedEphemeral: Curve25519.KeyAgreement.PrivateKey?

    /// - Parameters:
    ///   - localStatic: required when the pattern sends or pre-shares the local static key.
    ///   - remoteStatic: the peer's 32-byte static public key when the pattern pre-shares it (`IK`: initiator).
    ///   - psks: 32-byte pre-shared keys in order of appearance in the pattern.
    public init(
        pattern: NoisePattern, role: NoiseRole, prologue: Data = Data(),
        localStatic: Curve25519.KeyAgreement.PrivateKey? = nil, remoteStatic: Data? = nil, psks: [Data] = []
    ) throws {
        try self.init(
            pattern: pattern, role: role, prologue: prologue, localStatic: localStatic, remoteStatic: remoteStatic,
            psks: psks, ephemeral: nil)
    }

    init(
        pattern: NoisePattern, role: NoiseRole, prologue: Data, localStatic: Curve25519.KeyAgreement.PrivateKey?,
        remoteStatic: Data?, psks: [Data], ephemeral: Curve25519.KeyAgreement.PrivateKey?
    ) throws {
        guard psks.count == pattern.pskCount else {
            throw NoiseError.missingKey("pattern \(pattern.name) needs \(pattern.pskCount) PSK(s), got \(psks.count)")
        }
        guard psks.allSatisfy({ $0.count == noiseKeyLength }) else {
            throw NoiseError.missingKey("a PSK must be 32 bytes")
        }
        self.pattern = pattern
        self.role = role
        self.localStatic = localStatic
        self.psks = psks
        self.fixedEphemeral = ephemeral
        if let remoteStatic {
            do {
                self.remoteStaticKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStatic)
            } catch {
                throw NoiseError.invalidPublicKey
            }
        }
        symmetric = NoiseSymmetricState(protocolName: pattern.protocolName)
        symmetric.mixHash(prologue)

        // Pre-messages: initiator's first, then responder's (spec §5.3 Initialize).
        let ownIsInitiator = role == .initiator
        for token in pattern.initiatorPreMessage {
            precondition(token == .s)
            try mixPreMessageStatic(own: ownIsInitiator)
        }
        for token in pattern.responderPreMessage {
            precondition(token == .s)
            try mixPreMessageStatic(own: !ownIsInitiator)
        }
    }

    private mutating func mixPreMessageStatic(own: Bool) throws {
        if own {
            guard let localStatic else { throw NoiseError.missingKey("local static key") }
            symmetric.mixHash(localStatic.publicKey.rawRepresentation)
        } else {
            guard let remoteStaticKey else { throw NoiseError.missingKey("remote static key") }
            symmetric.mixHash(remoteStaticKey.rawRepresentation)
        }
    }

    // MARK: State

    public var isComplete: Bool { messageIndex >= pattern.messages.count }

    /// True when the next call must be `writeMessage` (never true once complete).
    public var isMyTurnToWrite: Bool {
        guard !isComplete else { return false }
        return (messageIndex % 2 == 0) == (role == .initiator)
    }

    /// `h`, the handshake hash (channel binding). Final once `isComplete`.
    public var handshakeHash: Data { symmetric.hash }

    /// The peer's static public key, once received (or pre-shared).
    public var remoteStatic: Data? { remoteStaticKey?.rawRepresentation }

    public var localStaticPublic: Data? { localStatic?.publicKey.rawRepresentation }

    // MARK: Messages

    public mutating func writeMessage(payload: Data = Data()) throws -> Data {
        guard !failed, isMyTurnToWrite else { throw NoiseError.invalidState("not this side's turn to write") }
        do {
            let message = try write(payload: payload)
            return message
        } catch {
            failed = true
            throw error
        }
    }

    public mutating func readMessage(_ message: Data) throws -> Data {
        guard !failed, !isComplete, !isMyTurnToWrite else { throw NoiseError.invalidState("not this side's turn to read") }
        do {
            return try read(message)
        } catch {
            failed = true
            throw error
        }
    }

    private var pskMode: Bool { pattern.usesPSK }

    private mutating func write(payload: Data) throws -> Data {
        var out = Data()
        for token in pattern.messages[messageIndex] {
            switch token {
            case .e:
                let key = fixedEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
                localEphemeral = key
                let pub = key.publicKey.rawRepresentation
                out += pub
                symmetric.mixHash(pub)
                if pskMode { symmetric.mixKey(pub) }
            case .s:
                guard let localStatic else { throw NoiseError.missingKey("local static key") }
                out += try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation)
            case .ee, .es, .se, .ss, .psk:
                try mix(token)
            }
        }
        out += try symmetric.encryptAndHash(payload)
        guard out.count <= noiseMaxMessageLength else { throw NoiseError.invalidMessage("message exceeds 65535 bytes") }
        messageIndex += 1
        return out
    }

    private mutating func read(_ message: Data) throws -> Data {
        guard message.count <= noiseMaxMessageLength else { throw NoiseError.invalidMessage("message exceeds 65535 bytes") }
        var rest = message[...]
        func take(_ count: Int) throws -> Data {
            guard rest.count >= count else { throw NoiseError.invalidMessage("message too short") }
            let chunk = rest.prefix(count).rebased()
            rest = rest.dropFirst(count)
            return chunk
        }
        for token in pattern.messages[messageIndex] {
            switch token {
            case .e:
                guard remoteEphemeral == nil else { throw NoiseError.invalidState("remote ephemeral already set") }
                let raw = try take(noiseKeyLength)
                remoteEphemeral = try Self.publicKey(raw)
                symmetric.mixHash(raw)
                if pskMode { symmetric.mixKey(raw) }
            case .s:
                guard remoteStaticKey == nil else { throw NoiseError.invalidState("remote static already set") }
                let raw = try take(noiseKeyLength + (symmetric.cipher.hasKey ? noiseTagLength : 0))
                let plain = try symmetric.decryptAndHash(raw)
                remoteStaticKey = try Self.publicKey(plain)
            case .ee, .es, .se, .ss, .psk:
                try mix(token)
            }
        }
        let payload = try symmetric.decryptAndHash(rest.rebased())
        messageIndex += 1
        return payload
    }

    private static func publicKey(_ raw: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do { return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) } catch { throw NoiseError.invalidPublicKey }
    }

    private mutating func mix(_ token: NoiseToken) throws {
        let initiator = role == .initiator
        switch token {
        case .ee: try mixDH(localEphemeral, remoteEphemeral, "ephemeral")
        case .ss: try mixDH(localStatic, remoteStaticKey, "static")
        // es: initiator DH(e, rs), responder DH(s, re); se: initiator DH(s, re), responder DH(e, rs).
        case .es:
            if initiator { try mixDH(localEphemeral, remoteStaticKey, "es") } else { try mixDH(localStatic, remoteEphemeral, "es") }
        case .se:
            if initiator { try mixDH(localStatic, remoteEphemeral, "se") } else { try mixDH(localEphemeral, remoteStaticKey, "se") }
        case .psk:
            guard !psks.isEmpty else { throw NoiseError.missingKey("PSK") }
            symmetric.mixKeyAndHash(psks.removeFirst())
        case .e, .s: preconditionFailure("handled by caller")
        }
    }

    private mutating func mixDH(_ privateKey: Curve25519.KeyAgreement.PrivateKey?, _ publicKey: Curve25519.KeyAgreement.PublicKey?, _ what: String) throws {
        guard let privateKey, let publicKey else { throw NoiseError.missingKey("DH inputs for \(what)") }
        let secret: SharedSecret
        do {
            secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        } catch {
            throw NoiseError.invalidPublicKey  // low-order point: CryptoKit rejects the all-zero output
        }
        symmetric.mixKey(secret.withUnsafeBytes { Data($0) })
    }

    // MARK: Split

    /// Final step (spec §5.3 Split). Throws unless the handshake is complete.
    public func split() throws -> NoiseTransport {
        guard !failed, isComplete else { throw NoiseError.invalidState("handshake not complete") }
        let (c1, c2) = symmetric.split()
        return role == .initiator
            ? NoiseTransport(send: c1, receive: c2, handshakeHash: symmetric.hash)
            : NoiseTransport(send: c2, receive: c1, handshakeHash: symmetric.hash)
    }
}

/// The two transport cipher states after a completed handshake.
public struct NoiseTransport: Sendable {
    var sendCipher: NoiseCipherState
    var receiveCipher: NoiseCipherState
    public let handshakeHash: Data

    init(send: NoiseCipherState, receive: NoiseCipherState, handshakeHash: Data) {
        self.sendCipher = send
        self.receiveCipher = receive
        self.handshakeHash = handshakeHash
    }

    /// Largest plaintext one Noise message can carry.
    public static let maxPlaintextLength = noiseMaxMessageLength - noiseTagLength

    public mutating func encrypt(_ plaintext: Data, ad: Data = Data()) throws -> Data {
        guard plaintext.count <= Self.maxPlaintextLength else { throw NoiseError.invalidMessage("message exceeds 65535 bytes") }
        return try sendCipher.encrypt(ad: ad, plaintext: plaintext)
    }

    public mutating func decrypt(_ ciphertext: Data, ad: Data = Data()) throws -> Data {
        guard ciphertext.count <= noiseMaxMessageLength else { throw NoiseError.invalidMessage("message exceeds 65535 bytes") }
        return try receiveCipher.decrypt(ad: ad, ciphertext: ciphertext)
    }
}
