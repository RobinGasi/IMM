import CryptoKit
import Foundation

public enum NoiseSessionError: Error, Equatable, Sendable {
    /// The Noise layer failed: wrong PSK, wrong pinned key, tampered or replayed message, nonce exhaustion …
    case noise(NoiseError)
    /// The responder's static key is not the one pinned (from the QR code / the paired-device record).
    case pinMismatch
    /// The initiator's revealed nonce and static key do not match its message-1 commitment.
    case pairingCommitmentMismatch
    /// The initiator's static key is not on the allow-list.
    case peerNotAllowed
    /// A handshake payload had the wrong shape.
    case malformedHandshake(String)
    /// A logical message exceeds `NoiseSession.maxMessageSize`.
    case messageTooLarge
    /// A decrypted transport message is not valid framing/encoding.
    case malformedMessage(String)
    /// The session was closed locally or after an earlier failure.
    case closed
}

/// Serialises async critical sections (one logical message must not interleave its Noise chunks with another).
final class AsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if held {
                waiters.append(continuation)
                lock.unlock()
            } else {
                held = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            held = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// An authenticated, encrypted session over any `ByteStream`: Noise handshake, then `SyncMessage`s.
///
/// Each Noise message travels as one `ByteStream` message (the transport frames it with `Frame`). A `SyncMessage`
/// encoding larger than one Noise message is split into chunks: every Noise plaintext is `flag ‖ bytes` with flag 0 on
/// the last chunk and 1 otherwise. The transport nonce is the implicit message counter, so a replayed, dropped,
/// reordered or modified message fails authentication; the session then closes itself and every later call throws
/// `.closed`.
///
/// Entry points:
/// - `initiatePairing` / `acceptPairing`: `Noise_XXpsk3` with the QR secret as PSK, prologue `imm/v1/pair`, commit-reveal
///   `ShortAuthCode`; the initiator pins the responder's static key before it sends message 3.
/// - `connect` / `accept`: `Noise_IK` with pinned static keys, prologue `imm/v1/live`.
public actor NoiseSession {
    public static let pairingPrologue = Data("imm/v1/pair".utf8)
    public static let livePrologue = Data("imm/v1/live".utf8)
    public static let pairingSecretLength = 32
    /// Upper bound for one logical message after reassembly (a sealed 1 MiB batch plus framing fits).
    public static let maxMessageSize = 2 << 20
    private static let chunkSize = NoiseTransport.maxPlaintextLength - 1

    public nonisolated let role: NoiseRole
    /// The authenticated static public key of the peer.
    public nonisolated let remoteStatic: Data
    /// Channel binding value of the handshake.
    public nonisolated let handshakeHash: Data
    /// Set for pairing sessions, on both sides.
    public nonisolated let pairingCode: ShortAuthCode?

    private let stream: any ByteStream
    private var transport: NoiseTransport
    private var closed = false
    private let sendGate = AsyncMutex()
    private let receiveGate = AsyncMutex()

    private init(
        stream: any ByteStream, transport: NoiseTransport, role: NoiseRole, remoteStatic: Data, pairingCode: ShortAuthCode?
    ) {
        self.stream = stream
        self.transport = transport
        self.role = role
        self.remoteStatic = remoteStatic
        self.handshakeHash = transport.handshakeHash
        self.pairingCode = pairingCode
    }

    // MARK: Handshakes

    private static func noise<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as NoiseError { throw NoiseSessionError.noise(error) }
    }

    /// Phone side of pairing. Sends message 1 (with the commitment), reads message 2, checks that the responder's static
    /// key equals `expectedResponderStatic` (from the QR; nil when pairing by typed code alone) and only then reveals itself
    /// in message 3.
    /// - Parameter onCode: called with the code after message 2 and the pin check, before message 3 is sent, so the UI can
    ///   show it; throwing aborts the pairing.
    /// - Throws: `.pinMismatch` before anything identifying was sent. A wrong `pairingSecret` is invisible here: the
    ///   responder rejects message 3 and closes, so the next `receive` fails with `ByteStreamError.closed`.
    public static func initiatePairing(
        over stream: any ByteStream, localStatic: Curve25519.KeyAgreement.PrivateKey, pairingSecret: Data,
        expectedResponderStatic: Data?, onCode: @Sendable (ShortAuthCode) async throws -> Void = { _ in }
    ) async throws -> NoiseSession {
        do {
            var handshake = try noise {
                try NoiseHandshake(
                    pattern: .xxPSK3, role: .initiator, prologue: pairingPrologue, localStatic: localStatic, psks: [pairingSecret])
            }
            let nonce = PairingCommitment.makeNonce()
            let localPublic = localStatic.publicKey.rawRepresentation
            let commitment = PairingCommitment.commitment(initiatorNonce: nonce, initiatorStatic: localPublic)
            try await stream.send(try noise { try handshake.writeMessage(payload: commitment) })

            let message2 = try await stream.receive()
            let responderNonce = try noise { try handshake.readMessage(message2) }
            guard responderNonce.count == PairingCommitment.nonceLength else {
                throw NoiseSessionError.malformedHandshake("message 2 payload must be a 16-byte nonce")
            }
            // Pin before message 3: plain XX does not authenticate the responder against anything the user saw.
            // `expectedResponderStatic == nil`: the user typed the code without scanning the QR, so there is no key to pin.
            // The responder still proves it knows the PSK (nothing decrypts in message 3 otherwise), and the code check
            // on both screens covers a man in the middle.
            guard let remote = handshake.remoteStatic,
                  expectedResponderStatic.map({ Sodium.constantTimeEqual(remote, $0) }) ?? true else {
                throw NoiseSessionError.pinMismatch
            }
            let code = ShortAuthCode.derive(
                initiatorNonce: nonce, responderNonce: responderNonce, initiatorStatic: localPublic,
                handshakeHashAfterMessage2: handshake.handshakeHash)
            try await onCode(code)

            try await stream.send(try noise { try handshake.writeMessage(payload: nonce) })
            let transport = try noise { try handshake.split() }
            return NoiseSession(stream: stream, transport: transport, role: .initiator, remoteStatic: remote, pairingCode: code)
        } catch {
            await stream.close()
            throw error
        }
    }

    /// Mac side of pairing. Reads message 1 (commitment), answers with message 2 (its nonce), reads message 3 and checks
    /// the opening against the commitment with the static key that message 3 carried.
    /// - Parameter onCode: called with the code once message 3 verified; the session is returned right after. The caller
    ///   must not send anything (group key, roster entry) before the user confirmed the code.
    /// - Throws: `.noise(.decryptionFailed)` for a wrong PSK, `.pairingCommitmentMismatch` for a forged reveal.
    public static func acceptPairing(
        over stream: any ByteStream, localStatic: Curve25519.KeyAgreement.PrivateKey, pairingSecret: Data,
        onCode: @Sendable (ShortAuthCode) async throws -> Void = { _ in }
    ) async throws -> NoiseSession {
        do {
            var handshake = try noise {
                try NoiseHandshake(
                    pattern: .xxPSK3, role: .responder, prologue: pairingPrologue, localStatic: localStatic, psks: [pairingSecret])
            }
            let message1 = try await stream.receive()
            let commitment = try noise { try handshake.readMessage(message1) }
            guard commitment.count == PairingCommitment.commitmentLength else {
                throw NoiseSessionError.malformedHandshake("message 1 payload must be a 32-byte commitment")
            }
            let nonce = PairingCommitment.makeNonce()
            try await stream.send(try noise { try handshake.writeMessage(payload: nonce) })
            let handshakeHashAfterMessage2 = handshake.handshakeHash

            let message3 = try await stream.receive()
            let initiatorNonce = try noise { try handshake.readMessage(message3) }
            guard let remote = handshake.remoteStatic else { throw NoiseSessionError.malformedHandshake("no initiator static key") }
            guard PairingCommitment.verify(commitment: commitment, initiatorNonce: initiatorNonce, initiatorStatic: remote) else {
                throw NoiseSessionError.pairingCommitmentMismatch
            }
            let code = ShortAuthCode.derive(
                initiatorNonce: initiatorNonce, responderNonce: nonce, initiatorStatic: remote,
                handshakeHashAfterMessage2: handshakeHashAfterMessage2)
            try await onCode(code)
            let transport = try noise { try handshake.split() }
            return NoiseSession(stream: stream, transport: transport, role: .responder, remoteStatic: remote, pairingCode: code)
        } catch {
            await stream.close()
            throw error
        }
    }

    /// Reconnect with `Noise_IK`: the initiator knows the responder's static key (`pinnedResponderStatic`), the responder
    /// learns the initiator's from message 1. A wrong pinned key makes the responder's decryption of message 1 fail.
    public static func connect(
        over stream: any ByteStream, localStatic: Curve25519.KeyAgreement.PrivateKey, pinnedResponderStatic: Data
    ) async throws -> NoiseSession {
        do {
            var handshake = try noise {
                try NoiseHandshake(
                    pattern: .ik, role: .initiator, prologue: livePrologue, localStatic: localStatic,
                    remoteStatic: pinnedResponderStatic)
            }
            try await stream.send(try noise { try handshake.writeMessage() })
            let message2 = try await stream.receive()
            let payload = try noise { try handshake.readMessage(message2) }
            guard payload.isEmpty else { throw NoiseSessionError.malformedHandshake("unexpected message 2 payload") }
            let transport = try noise { try handshake.split() }
            return NoiseSession(
                stream: stream, transport: transport, role: .initiator, remoteStatic: pinnedResponderStatic, pairingCode: nil)
        } catch {
            await stream.close()
            throw error
        }
    }

    /// Responder side of `Noise_IK`. `isAllowed` is asked with the initiator's authenticated static key before any reply
    /// is written; a rejected peer gets nothing but a closed stream.
    public static func accept(
        over stream: any ByteStream, localStatic: Curve25519.KeyAgreement.PrivateKey,
        isAllowed: @Sendable (Data) async -> Bool
    ) async throws -> NoiseSession {
        do {
            var handshake = try noise {
                try NoiseHandshake(pattern: .ik, role: .responder, prologue: livePrologue, localStatic: localStatic)
            }
            let message1 = try await stream.receive()
            let payload = try noise { try handshake.readMessage(message1) }
            guard payload.isEmpty else { throw NoiseSessionError.malformedHandshake("unexpected message 1 payload") }
            guard let remote = handshake.remoteStatic else { throw NoiseSessionError.malformedHandshake("no initiator static key") }
            guard await isAllowed(remote) else { throw NoiseSessionError.peerNotAllowed }
            try await stream.send(try noise { try handshake.writeMessage() })
            let transport = try noise { try handshake.split() }
            return NoiseSession(stream: stream, transport: transport, role: .responder, remoteStatic: remote, pairingCode: nil)
        } catch {
            await stream.close()
            throw error
        }
    }

    // MARK: Messages

    public var isClosed: Bool { closed }

    /// Encrypts and sends one message (chunked when larger than one Noise message).
    public func send(_ message: SyncMessage) async throws {
        try await sendEncoded(message.encoded())
    }

    /// Chunks, encrypts and sends an already encoded message (tests use it to send types this build does not know).
    func sendEncoded(_ plain: Data) async throws {
        guard plain.count <= Self.maxMessageSize else { throw NoiseSessionError.messageTooLarge }
        await sendGate.acquire()
        defer { sendGate.release() }
        guard !closed else { throw NoiseSessionError.closed }
        var offset = 0
        repeat {
            let end = min(plain.count, offset + Self.chunkSize)
            let chunk = Data([end == plain.count ? 0 : 1]) + plain[offset..<end]
            let sealed: Data
            do {
                sealed = try transport.encrypt(chunk)
            } catch let error as NoiseError {
                await fail()
                throw NoiseSessionError.noise(error)
            }
            do {
                try await stream.send(sealed)
            } catch {
                await fail()
                throw error
            }
            offset = end
        } while offset < plain.count
    }

    /// Receives the next message. Messages of an unknown type are ignored after answering with `.error(.unknownMessageType)`.
    /// Any authentication or framing failure (tampering, replay, reordering) closes the session and throws.
    public func receive() async throws -> SyncMessage {
        await receiveGate.acquire()
        defer { receiveGate.release() }
        var assembled = Data()
        while true {
            guard !closed else { throw NoiseSessionError.closed }
            let raw: Data
            do {
                raw = try await stream.receive()
            } catch {
                await fail()
                throw error
            }
            guard !closed else { throw NoiseSessionError.closed }
            let plain: Data
            do {
                plain = try transport.decrypt(raw)
            } catch let error as NoiseError {
                await fail()
                throw NoiseSessionError.noise(error)
            }
            guard let flag = plain.first, flag <= 1 else {
                await fail()
                throw NoiseSessionError.malformedMessage("bad chunk flag")
            }
            assembled += plain.dropFirst()
            guard assembled.count <= Self.maxMessageSize else {
                await fail()
                throw NoiseSessionError.messageTooLarge
            }
            guard flag == 0 else { continue }
            do {
                return try SyncMessage(decoding: assembled)
            } catch SyncMessageError.unknownType(let type) {
                assembled = Data()
                try await send(.error(code: .unknownMessageType, message: "unknown message type \(type)"))
            } catch SyncMessageError.unsupportedVersion(let version) {
                try? await send(.error(code: .unsupportedVersion, message: "unsupported version \(version)"))
                await fail()
                throw NoiseSessionError.malformedMessage("unsupported version \(version)")
            } catch let error as SyncMessageError {
                await fail()
                throw NoiseSessionError.malformedMessage("\(error)")
            }
        }
    }

    /// Closes the stream; later `send`/`receive` calls throw `.closed`.
    public func close() async { await fail() }

    private func fail() async {
        guard !closed else { return }
        closed = true
        await stream.close()
    }
}
