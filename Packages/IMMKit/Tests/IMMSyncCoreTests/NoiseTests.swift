import CryptoKit
import Foundation
import Testing

@testable import IMMSyncCore

struct NoiseTests {
    private func pair(pattern: NoisePattern = .xx, prologue: Data = Data("p".utf8), psks: [Data] = []) throws -> (NoiseHandshake, NoiseHandshake, Curve25519.KeyAgreement.PrivateKey, Curve25519.KeyAgreement.PrivateKey) {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let initiator = try NoiseHandshake(pattern: pattern, role: .initiator, prologue: prologue, localStatic: a, remoteStatic: pattern == .ik ? b.publicKey.rawRepresentation : nil, psks: psks)
        let responder = try NoiseHandshake(pattern: pattern, role: .responder, prologue: prologue, localStatic: b, psks: psks)
        return (initiator, responder, a, b)
    }

    private func run(_ initiator: inout NoiseHandshake, _ responder: inout NoiseHandshake) throws {
        while !initiator.isComplete {
            if initiator.isMyTurnToWrite {
                let m = try initiator.writeMessage()
                _ = try responder.readMessage(m)
            } else {
                let m = try responder.writeMessage()
                _ = try initiator.readMessage(m)
            }
        }
    }

    @Test func xxPSK3AndIKRoundTripWithRandomKeys() throws {
        let psk = Data(repeating: 7, count: 32)
        for (pattern, psks) in [(NoisePattern.xxPSK3, [psk]), (NoisePattern.ik, [])] {
            var (i, r, a, b) = try pair(pattern: pattern, psks: psks)
            try run(&i, &r)
            #expect(i.handshakeHash == r.handshakeHash)
            #expect(i.remoteStatic == b.publicKey.rawRepresentation)
            #expect(r.remoteStatic == a.publicKey.rawRepresentation)
            var ti = try i.split(), tr = try r.split()
            let c = try ti.encrypt(Data("hello".utf8))
            #expect(try tr.decrypt(c) == Data("hello".utf8))
            let d = try tr.encrypt(Data("back".utf8))
            #expect(try ti.decrypt(d) == Data("back".utf8))
        }
    }

    @Test func patternNamesParse() throws {
        #expect(NoisePattern.xxPSK3.protocolName == "Noise_XXpsk3_25519_ChaChaPoly_SHA256")
        #expect(NoisePattern.xxPSK3.pskCount == 1)
        #expect(NoisePattern.ik.pskCount == 0)
        #expect(try NoisePattern(name: "XXpsk0+psk3").pskCount == 2)
        #expect(try NoisePattern(protocolName: "Noise_N_25519_ChaChaPoly_SHA256").isOneWay)
        for bad in ["Noise_XX_448_ChaChaPoly_SHA256", "Noise_XX_25519_AESGCM_SHA256", "Noise_XX_25519_ChaChaPoly_BLAKE2b", "Noise_NK1_25519_ChaChaPoly_SHA256", "Noise_XXfallback_25519_ChaChaPoly_SHA256", "XX", "Noise_XXpsk9_25519_ChaChaPoly_SHA256"] {
            #expect(throws: NoiseError.self) { try NoisePattern(protocolName: bad) }
        }
    }

    @Test func prologueMismatchFailsTheHandshake() throws {
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        var i = try NoiseHandshake(pattern: .ik, role: .initiator, prologue: Data("one".utf8), localStatic: a, remoteStatic: b.publicKey.rawRepresentation)
        var r = try NoiseHandshake(pattern: .ik, role: .responder, prologue: Data("two".utf8), localStatic: b)
        let m1 = try i.writeMessage()
        #expect(throws: NoiseError.decryptionFailed) { try r.readMessage(m1) }
    }

    @Test func wrongPSKIsDetectedByTheResponderAtMessage3() throws {
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        var i = try NoiseHandshake(pattern: .xxPSK3, role: .initiator, localStatic: a, psks: [Data(repeating: 1, count: 32)])
        var r = try NoiseHandshake(pattern: .xxPSK3, role: .responder, localStatic: b, psks: [Data(repeating: 2, count: 32)])
        _ = try r.readMessage(try i.writeMessage())
        _ = try i.readMessage(try r.writeMessage())
        #expect(throws: NoiseError.decryptionFailed) { try r.readMessage(try i.writeMessage()) }
    }

    @Test func missingOrBadKeysAreRejectedUpFront() throws {
        let k = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: NoiseError.self) { try NoiseHandshake(pattern: .xxPSK3, role: .initiator, localStatic: k) }  // no PSK
        #expect(throws: NoiseError.self) { try NoiseHandshake(pattern: .xxPSK3, role: .initiator, localStatic: k, psks: [Data(count: 31)]) }
        #expect(throws: NoiseError.self) { try NoiseHandshake(pattern: .ik, role: .initiator, localStatic: k) }  // no remote static
        #expect(throws: NoiseError.invalidPublicKey) { try NoiseHandshake(pattern: .ik, role: .initiator, localStatic: k, remoteStatic: Data(count: 31)) }
        var noStatic = try NoiseHandshake(pattern: .xx, role: .initiator)
        var responder = try NoiseHandshake(pattern: .xx, role: .responder, localStatic: k)
        _ = try responder.readMessage(try noStatic.writeMessage())
        _ = try noStatic.readMessage(try responder.writeMessage())
        #expect(throws: NoiseError.missingKey("local static key")) { try noStatic.writeMessage() }
    }

    @Test func outOfTurnCallsAndFailuresLockTheState() throws {
        var (i, r, _, _) = try pair()
        #expect(throws: NoiseError.self) { try r.writeMessage() }
        #expect(throws: NoiseError.self) { try i.readMessage(Data()) }
        #expect(throws: NoiseError.self) { try i.split() }
        let m1 = try i.writeMessage()
        #expect(throws: NoiseError.self) { try i.writeMessage() }
        #expect(throws: NoiseError.self) { try r.readMessage(m1.dropLast()) }  // truncated e
        #expect(throws: NoiseError.invalidState("not this side's turn to read")) { try r.readMessage(m1) }  // failed state
    }

    @Test func lowOrderEphemeralIsRejected() throws {
        // IK message 1 starts with `e, es`: the DH with an all-zero (low-order) ephemeral must fail.
        var (_, r, _, _) = try pair(pattern: .ik)
        #expect(throws: NoiseError.invalidPublicKey) { try r.readMessage(Data(count: 96)) }
    }

    @Test func tamperedAndReplayedTransportMessagesFail() throws {
        var (i, r, _, _) = try pair()
        try run(&i, &r)
        var ti = try i.split(), tr = try r.split()
        let c1 = try ti.encrypt(Data("one".utf8))
        let c2 = try ti.encrypt(Data("two".utf8))
        #expect(c1.startIndex == 0 && c2.startIndex == 0)  // CryptoKit results are rebased
        var flipped = c1
        flipped[0] ^= 1
        #expect(throws: NoiseError.decryptionFailed) { try tr.decrypt(flipped) }
        #expect(try tr.decrypt(c1) == Data("one".utf8))  // failed attempt did not advance the nonce
        #expect(throws: NoiseError.decryptionFailed) { try tr.decrypt(c1) }  // replay
        #expect(try tr.decrypt(c2) == Data("two".utf8))
        #expect(throws: NoiseError.decryptionFailed) { try tr.decrypt(Data(count: 8)) }  // shorter than a tag
    }

    @Test func transportMessageSizeLimit() throws {
        var (i, r, _, _) = try pair()
        try run(&i, &r)
        var ti = try i.split(), tr = try r.split()
        let max = Data(repeating: 9, count: NoiseTransport.maxPlaintextLength)
        let c = try ti.encrypt(max)
        #expect(c.count == noiseMaxMessageLength)
        #expect(try tr.decrypt(c) == max)
        #expect(throws: NoiseError.self) { try ti.encrypt(max + [0]) }
    }

    @Test func nonceExhaustionIsAnError() throws {
        var (i, r, _, _) = try pair()
        try run(&i, &r)
        var ti = try i.split(), tr = try r.split()
        // 2^64 − 1 is reserved: the last usable nonce is 2^64 − 2.
        ti.sendCipher.nonce = UInt64.max - 1
        tr.receiveCipher.nonce = UInt64.max - 1
        let last = try ti.encrypt(Data("last".utf8))
        #expect(try tr.decrypt(last) == Data("last".utf8))
        #expect(ti.sendCipher.nonce == UInt64.max)
        #expect(throws: NoiseError.nonceExhausted) { try ti.encrypt(Data("more".utf8)) }
        #expect(throws: NoiseError.nonceExhausted) { try tr.decrypt(last) }
    }

    @Test func hkdfMatchesNoiseDefinition() {
        // Noise HKDF(ck, ikm, 2) = HKDF-Extract(salt = ck, ikm) then Expand with empty info (spec §4.3).
        let ck = Data((0..<32).map { UInt8($0) }), ikm = Data(repeating: 0x42, count: 32)
        let out = noiseHKDF(chainingKey: ck, input: ikm, outputs: 3)
        let reference = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: ck, info: Data(), outputByteCount: 96)
        #expect(out.reduce(Data(), +) == reference.withUnsafeBytes { Data($0) })
    }
}
