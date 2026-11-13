import CryptoKit
import Foundation
import Testing

@testable import IMMSyncCore

private actor Recorder<T: Sendable> {
    private(set) var values: [T] = []
    func add(_ value: T) { values.append(value) }
}

struct NoiseSessionTests {
    let phone = Curve25519.KeyAgreement.PrivateKey()
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let secret = Data((0..<32).map { UInt8($0 * 3) })

    private func pairingSessions() async throws -> (initiator: NoiseSession, responder: NoiseSession, phoneCode: ShortAuthCode, macCode: ShortAuthCode) {
        let (a, b) = InMemoryDuplexStream.makePair()
        let phoneCodes = Recorder<ShortAuthCode>(), macCodes = Recorder<ShortAuthCode>()
        async let initiator = NoiseSession.initiatePairing(
            over: a, localStatic: phone, pairingSecret: secret, expectedResponderStatic: mac.publicKey.rawRepresentation,
            onCode: { await phoneCodes.add($0) })
        async let responder = NoiseSession.acceptPairing(
            over: b, localStatic: mac, pairingSecret: secret, onCode: { await macCodes.add($0) })
        let (i, r) = try await (initiator, responder)
        let phoneValues = await phoneCodes.values, macValues = await macCodes.values
        return (i, r, try #require(phoneValues.first), try #require(macValues.first))
    }

    private func liveSessions() async throws -> (NoiseSession, NoiseSession, InMemoryDuplexStream, InMemoryDuplexStream) {
        let (a, b) = InMemoryDuplexStream.makePair()
        let phoneKey = phone.publicKey.rawRepresentation
        async let initiator = NoiseSession.connect(over: a, localStatic: phone, pinnedResponderStatic: mac.publicKey.rawRepresentation)
        async let responder = NoiseSession.accept(over: b, localStatic: mac, isAllowed: { $0 == phoneKey })
        return try await (initiator, responder, a, b)
    }

    // MARK: Pairing

    @Test func pairingShowsTheSameCodeOnBothSidesThenIKReconnects() async throws {
        let (i, r, phoneCode, macCode) = try await pairingSessions()
        #expect(phoneCode == macCode)
        #expect(i.pairingCode == phoneCode && r.pairingCode == macCode)
        #expect(i.remoteStatic == mac.publicKey.rawRepresentation)
        #expect(r.remoteStatic == phone.publicKey.rawRepresentation)
        #expect(i.handshakeHash == r.handshakeHash)
        #expect(i.role == .initiator && r.role == .responder)

        // After the user confirmed, the Mac hands over the group key.
        let grant = Data("group key + roster entry".utf8)
        try await r.send(.pairingGrant(grant))
        #expect(try await i.receive() == .pairingGrant(grant))
        try await i.send(.ping(token: 1))
        #expect(try await r.receive() == .ping(token: 1))

        // Later: IK with pinned keys.
        let (live1, live2, _, _) = try await liveSessions()
        #expect(live1.pairingCode == nil)
        #expect(live1.remoteStatic == mac.publicKey.rawRepresentation)
        #expect(live2.remoteStatic == phone.publicKey.rawRepresentation)
        try await live1.send(.hello(.init(device: 1, group: Data(repeating: 1, count: 16), cursors: [.init(device: 1, appliedSeq: 4)])))
        guard case .hello(let hello) = try await live2.receive() else { Issue.record("expected hello"); return }
        #expect(hello.cursors == [.init(device: 1, appliedSeq: 4)])
        try await live2.send(.pong(token: 9))
        #expect(try await live1.receive() == .pong(token: 9))
        // A different handshake gives different transcripts.
        #expect(live1.handshakeHash != i.handshakeHash)
    }

    @Test func pairingCodesDifferBetweenAttempts() async throws {
        var codes = Set<UInt32>()
        for _ in 0..<3 { codes.insert(try await pairingSessions().phoneCode.value) }
        #expect(codes.count >= 2)  // 10^-12 chance of three equal codes
    }

    @Test func wrongPSKFailsAtTheResponderAndTheInitiatorSeesAClosedStream() async throws {
        let (a, b) = InMemoryDuplexStream.makePair()
        let wrong = Data(repeating: 0xee, count: 32)
        async let initiator = NoiseSession.initiatePairing(
            over: a, localStatic: phone, pairingSecret: wrong, expectedResponderStatic: mac.publicKey.rawRepresentation)
        async let responder: Result<NoiseSession, Error> = {
            do { return .success(try await NoiseSession.acceptPairing(over: b, localStatic: mac, pairingSecret: secret)) } catch { return .failure(error) }
        }()
        // The initiator cannot tell: its handshake completes, then the connection is dead.
        let i = try await initiator
        switch await responder {
        case .success: Issue.record("responder accepted a wrong PSK")
        case .failure(let error): #expect(error as? NoiseSessionError == .noise(.decryptionFailed))
        }
        await #expect(throws: ByteStreamError.closed) { try await i.receive() }
        #expect(await i.isClosed)
    }

    @Test func pinMismatchAbortsBeforeMessage3() async throws {
        let (a, b) = InMemoryDuplexStream.makePair()
        let impostor = Curve25519.KeyAgreement.PrivateKey()  // knows the PSK (photographed QR) but is not the pinned Mac
        let codeShown = Recorder<ShortAuthCode>()
        async let initiator: Result<NoiseSession, Error> = {
            do {
                return .success(try await NoiseSession.initiatePairing(
                    over: a, localStatic: phone, pairingSecret: secret, expectedResponderStatic: mac.publicKey.rawRepresentation,
                    onCode: { await codeShown.add($0) }))
            } catch { return .failure(error) }
        }()
        async let responder: Result<NoiseSession, Error> = {
            do { return .success(try await NoiseSession.acceptPairing(over: b, localStatic: impostor, pairingSecret: secret)) } catch { return .failure(error) }
        }()
        switch await initiator {
        case .success: Issue.record("initiator accepted an unpinned responder")
        case .failure(let error): #expect(error as? NoiseSessionError == .pinMismatch)
        }
        if case .success = await responder { Issue.record("responder should not complete") }
        #expect(a.sentMessages.count == 1, "message 3 (which carries the phone's static key) must never be sent")
        #expect(await codeShown.values.isEmpty)
    }

    @Test func forgedRevealIsDetectedByTheResponder() async throws {
        // An initiator that commits to (nonce X, key S) and then reveals nonce Y after seeing nR.
        for forgeKey in [false, true] {
            let (a, b) = InMemoryDuplexStream.makePair()
            async let responder: Result<NoiseSession, Error> = {
                do { return .success(try await NoiseSession.acceptPairing(over: b, localStatic: mac, pairingSecret: secret)) } catch { return .failure(error) }
            }()
            let committedKey = Curve25519.KeyAgreement.PrivateKey()
            let sendingKey = forgeKey ? Curve25519.KeyAgreement.PrivateKey() : committedKey  // "ground" static key in message 3
            var hs = try NoiseHandshake(pattern: .xxPSK3, role: .initiator, prologue: NoiseSession.pairingPrologue, localStatic: sendingKey, psks: [secret])
            let committedNonce = PairingCommitment.makeNonce()
            let commitment = PairingCommitment.commitment(initiatorNonce: committedNonce, initiatorStatic: committedKey.publicKey.rawRepresentation)
            try await a.send(try hs.writeMessage(payload: commitment))
            _ = try hs.readMessage(try await a.receive())
            let revealed = forgeKey ? committedNonce : PairingCommitment.makeNonce()
            try await a.send(try hs.writeMessage(payload: revealed))
            switch await responder {
            case .success: Issue.record("forged reveal accepted (forgeKey: \(forgeKey))")
            case .failure(let error): #expect(error as? NoiseSessionError == .pairingCommitmentMismatch)
            }
        }
    }

    @Test func malformedPairingPayloadsAreRejected() async throws {
        let (a, b) = InMemoryDuplexStream.makePair()
        async let responder: Result<NoiseSession, Error> = {
            do { return .success(try await NoiseSession.acceptPairing(over: b, localStatic: mac, pairingSecret: secret)) } catch { return .failure(error) }
        }()
        var hs = try NoiseHandshake(pattern: .xxPSK3, role: .initiator, prologue: NoiseSession.pairingPrologue, localStatic: phone, psks: [secret])
        try await a.send(try hs.writeMessage(payload: Data("short".utf8)))  // not a 32-byte commitment
        if case .success = await responder { Issue.record("accepted a malformed commitment") }
    }

    // MARK: IK

    @Test func ikWithWrongPinnedKeyFails() async throws {
        let (a, b) = InMemoryDuplexStream.makePair()
        let phoneKey = phone.publicKey.rawRepresentation
        let wrongPin = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        async let initiator: Result<NoiseSession, Error> = {
            do { return .success(try await NoiseSession.connect(over: a, localStatic: phone, pinnedResponderStatic: wrongPin)) } catch { return .failure(error) }
        }()
        async let responder: Result<NoiseSession, Error> = {
            do { return .success(try await NoiseSession.accept(over: b, localStatic: mac, isAllowed: { $0 == phoneKey })) } catch { return .failure(error) }
        }()
        if case .success = await responder { Issue.record("responder accepted a message for another static key") }
        switch await initiator {
        case .success: Issue.record("initiator completed against the wrong key")
        case .failure(let error): #expect(error as? ByteStreamError == .closed)
        }
    }

    @Test func ikResponderRejectsUnknownPeersWithoutReplying() async throws {
        let (a, b) = InMemoryDuplexStream.makePair()
        async let initiator: Result<NoiseSession, Error> = {
            do { return .success(try await NoiseSession.connect(over: a, localStatic: phone, pinnedResponderStatic: mac.publicKey.rawRepresentation)) } catch { return .failure(error) }
        }()
        async let responder: Result<NoiseSession, Error> = {
            do { return .success(try await NoiseSession.accept(over: b, localStatic: mac, isAllowed: { _ in false })) } catch { return .failure(error) }
        }()
        switch await responder {
        case .success: Issue.record("unknown peer accepted")
        case .failure(let error): #expect(error as? NoiseSessionError == .peerNotAllowed)
        }
        if case .success = await initiator { Issue.record("initiator should not complete") }
        #expect(b.sentMessages.isEmpty, "a rejected peer gets no reply")
    }

    // MARK: Transport

    @Test func replayedTransportMessageIsRejectedAndClosesTheSession() async throws {
        let (i, r, a, _) = try await liveSessions()
        try await i.send(.ping(token: 1))
        #expect(try await r.receive() == .ping(token: 1))
        let captured = try #require(a.sentMessages.last)
        a.inject(captured)  // attacker re-delivers the same ciphertext
        await #expect(throws: NoiseSessionError.noise(.decryptionFailed)) { try await r.receive() }
        #expect(await r.isClosed)
        await #expect(throws: NoiseSessionError.closed) { try await r.receive() }
        await #expect(throws: NoiseSessionError.closed) { try await r.send(.ping(token: 2)) }
    }

    @Test func tamperedAndReorderedMessagesAreRejected() async throws {
        do {
            let (i, r, a, _) = try await liveSessions()
            a.dropNextSends(1)
            try await i.send(.ping(token: 1))
            var tampered = try #require(a.sentMessages.last)
            tampered[tampered.count / 2] ^= 0x01
            a.inject(tampered)
            await #expect(throws: NoiseSessionError.noise(.decryptionFailed)) { try await r.receive() }
        }
        do {
            let (i, r, a, _) = try await liveSessions()
            a.dropNextSends(1)
            try await i.send(.ping(token: 1))  // dropped: the receiver never sees nonce 0
            try await i.send(.ping(token: 2))
            await #expect(throws: NoiseSessionError.noise(.decryptionFailed)) { try await r.receive() }
        }
    }

    @Test func unknownMessageTypesAreIgnoredWithAnErrorReply() async throws {
        let (i, r, _, _) = try await liveSessions()
        try await i.sendEncoded(Data([SyncMessage.version, 200, 1, 2, 3]))  // a type from the future
        try await i.send(.ping(token: 77))
        #expect(try await r.receive() == .ping(token: 77))  // the unknown one was skipped
        guard case .error(let code, _) = try await i.receive() else { Issue.record("expected an error reply"); return }
        #expect(code == .unknownMessageType)
        #expect(!(await r.isClosed))
    }

    @Test func unsupportedVersionClosesTheSession() async throws {
        let (i, r, _, _) = try await liveSessions()
        try await i.sendEncoded(Data([9, 6, 0, 0, 0, 0, 0, 0, 0, 1]))
        await #expect(throws: NoiseSessionError.self) { try await r.receive() }
        #expect(await r.isClosed)
        guard case .error(let code, _) = try await i.receive() else { Issue.record("expected an error reply"); return }
        #expect(code == .unsupportedVersion)
    }

    @Test func largeMessagesAreChunkedAcrossNoiseMessages() async throws {
        let (i, r, a, _) = try await liveSessions()
        let key = SyncGroupKey.generate()
        let envelope = try SealedEnvelope.seal(
            payload: Data((0..<SealedEnvelope.maxPayloadSize).map { UInt8($0 & 0xff) }),
            header: SealedEnvelope.Header(group: Data(repeating: 1, count: 16), device: 1, seqFrom: 1, seqTo: 500), key: key)
        let before = a.sentMessages.count
        try await i.send(.batch(envelope))
        let chunks = a.sentMessages.count - before
        #expect(chunks >= 16)  // 1 MiB / 64 KiB
        #expect(a.sentMessages.suffix(chunks).allSatisfy { $0.count <= noiseMaxMessageLength })
        guard case .batch(let received) = try await r.receive() else { Issue.record("expected batch"); return }
        #expect(received == envelope)
        #expect(try received.open(key: key).count == SealedEnvelope.maxPayloadSize)

        // Exactly one Noise message worth, and the boundary ±1.
        for size in [NoiseTransport.maxPlaintextLength - 1 - 12 - 3, NoiseTransport.maxPlaintextLength - 1, NoiseTransport.maxPlaintextLength, 0] {
            let chunk = SyncMessage.snapshotChunk(.init(requestID: 1, index: 0, isFinal: false, data: Data(repeating: 3, count: size)))
            try await r.send(chunk)
            #expect(try await i.receive() == chunk)
        }
        await #expect(throws: NoiseSessionError.messageTooLarge) {
            try await i.send(.snapshotChunk(.init(requestID: 1, index: 0, isFinal: true, data: Data(count: NoiseSession.maxMessageSize))))
        }
    }

    @Test func concurrentSendsDoNotInterleaveChunks() async throws {
        let (i, r, _, _) = try await liveSessions()
        let messages = (0..<6).map { n in
            SyncMessage.snapshotChunk(.init(requestID: UInt64(n), index: 0, isFinal: true, data: Data(repeating: UInt8(n), count: 200_000)))
        }
        await withThrowingTaskGroup(of: Void.self) { group in
            for message in messages { group.addTask { try await i.send(message) } }
        }
        var received: [SyncMessage] = []
        for _ in messages { received.append(try await r.receive()) }
        #expect(Set(received.map { $0.encoded() }) == Set(messages.map { $0.encoded() }))
    }

    @Test func closeStopsBothSides() async throws {
        let (i, r, _, _) = try await liveSessions()
        await i.close()
        await #expect(throws: NoiseSessionError.closed) { try await i.send(.ping(token: 1)) }
        await #expect(throws: ByteStreamError.closed) { try await r.receive() }
    }
}
