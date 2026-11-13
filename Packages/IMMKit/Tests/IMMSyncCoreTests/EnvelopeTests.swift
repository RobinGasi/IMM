import CryptoKit
import Foundation
import Testing

@testable import IMMSyncCore

struct EnvelopeTests {
    let group = Data((0..<16).map { UInt8($0 + 1) })

    private func header(seqFrom: Int64 = 5, seqTo: Int64 = 9) -> SealedEnvelope.Header {
        SealedEnvelope.Header(group: group, device: 0x0102_0304_0506_0708, seqFrom: seqFrom, seqTo: seqTo)
    }

    // MARK: HKDF

    @Test func hkdfMatchesRFC5869Vectors() {
        // Test case 1.
        let okm1 = HKDFSHA256.derive(
            input: Data(repeating: 0x0b, count: 22), salt: Data(hex: "000102030405060708090a0b0c"),
            info: Data(hex: "f0f1f2f3f4f5f6f7f8f9"), outputCount: 42)
        #expect(okm1.hex == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        // Test case 3: empty salt and info.
        let okm3 = HKDFSHA256.derive(input: Data(repeating: 0x0b, count: 22), salt: Data(), info: Data(), outputCount: 42)
        #expect(okm3.hex == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
        // Multi-block output (> 32 bytes of T) agrees with CryptoKit.
        let ikm = Data((0..<40).map { UInt8($0) }), salt = Data("salt".utf8), info = Data("info".utf8)
        let ours = HKDFSHA256.derive(input: ikm, salt: salt, info: info, outputCount: 100)
        let reference = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: 100)
        #expect(ours == reference.withUnsafeBytes { Data($0) })
    }

    @Test func groupKeyDerivationUsesTheContractLabels() throws {
        let raw = Data((0..<32).map { UInt8($0) })
        let key = try SyncGroupKey(bytes: raw)
        #expect(key.rawBytes() == raw)
        #expect(SyncKeyLabel.seal.rawValue == "imm/v1/sync/seal")
        #expect(SyncKeyLabel.psk.rawValue == "imm/v1/sync/psk")
        #expect(SyncKeyLabel.agent.rawValue == "imm/v1/sync/agent")
        var seen = Set<Data>()
        for label in SyncKeyLabel.allCases {
            let derived = key.derive(label).rawBytes()
            let reference = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: raw), salt: Data(), info: Data(label.rawValue.utf8), outputByteCount: 32)
            #expect(derived == reference.withUnsafeBytes { Data($0) })
            #expect(derived != raw)
            seen.insert(derived)
        }
        #expect(seen.count == 3)
        #expect(key.derive(.seal, salt: Data([1])).rawBytes() != key.derive(.seal).rawBytes())
        #expect(throws: SyncKeyError.invalidLength(31)) { try SyncGroupKey(bytes: Data(count: 31)) }
        let a = SyncGroupKey.generate(), b = SyncGroupKey.generate()
        #expect(!a.isEqual(to: b))
        #expect(a.isEqual(to: try SyncGroupKey(bytes: a.rawBytes())))
    }

    // MARK: Envelope

    @Test func sealOpenRoundTrip() throws {
        let key = SyncGroupKey.generate()
        for size in [0, 1, 17, 1000, 100_000] {
            let payload = Data((0..<size).map { UInt8($0 & 0xff) })
            let envelope = try SealedEnvelope.seal(payload: payload, header: header(), key: key)
            #expect(envelope.ciphertext.count == size + 16)
            let decoded = try SealedEnvelope(decoding: envelope.encoded())
            #expect(decoded == envelope)
            #expect(try decoded.open(key: key) == payload)
        }
    }

    @Test func wireLayoutIsStable() throws {
        let envelope = try SealedEnvelope.seal(payload: Data("x".utf8), header: header(), key: SyncGroupKey.generate())
        let bytes = envelope.encoded()
        #expect(bytes.count == 41 + 24 + 1 + 16)
        #expect(bytes[0] == 1)
        #expect(Data(bytes[1..<17]) == group)
        #expect(Data(bytes[17..<25]) == Data(hex: "0102030405060708"))
        #expect(Data(bytes[25..<33]) == Data(hex: "0000000000000005"))
        #expect(Data(bytes[33..<41]) == Data(hex: "0000000000000009"))
        #expect(Data(bytes[41..<65]) == envelope.nonce)
        let peeked = try SealedEnvelope.peekHeader(bytes)
        #expect(peeked == header())
    }

    @Test func nonceIsFreshPerSeal() throws {
        let key = SyncGroupKey.generate()
        let a = try SealedEnvelope.seal(payload: Data("same".utf8), header: header(), key: key)
        let b = try SealedEnvelope.seal(payload: Data("same".utf8), header: header(), key: key)
        #expect(a.nonce != b.nonce)
        #expect(a.ciphertext != b.ciphertext)
    }

    @Test func everyBitFlipIsDetected() throws {
        let key = SyncGroupKey.generate()
        let envelope = try SealedEnvelope.seal(payload: Data("ledger ops".utf8), header: header(), key: key)
        let bytes = envelope.encoded()
        var detected = 0
        for index in 0..<bytes.count {
            for bit in [0, 3, 7] {
                var tampered = bytes
                tampered[index] ^= UInt8(1 << bit)
                do {
                    let parsed = try SealedEnvelope(decoding: tampered)
                    _ = try parsed.open(key: key)
                    Issue.record("flip at byte \(index) bit \(bit) was accepted")
                } catch {
                    detected += 1  // structural rejection (format byte, range) or authentication failure
                }
            }
        }
        #expect(detected == bytes.count * 3)
    }

    @Test func headerAndCiphertextTamperingFailAuthentication() throws {
        let key = SyncGroupKey.generate()
        let envelope = try SealedEnvelope.seal(payload: Data("payload".utf8), header: header(), key: key)
        // Header field changes keep the structure valid, so only the AAD protects them.
        for changed in [
            SealedEnvelope.Header(group: group, device: 9, seqFrom: 5, seqTo: 9),
            SealedEnvelope.Header(group: group, device: 0x0102_0304_0506_0708, seqFrom: 6, seqTo: 9),
            SealedEnvelope.Header(group: group, device: 0x0102_0304_0506_0708, seqFrom: 5, seqTo: 10),
            SealedEnvelope.Header(group: Data(repeating: 0, count: 16), device: 0x0102_0304_0506_0708, seqFrom: 5, seqTo: 9),
        ] {
            var bytes = envelope.encoded()
            bytes.replaceSubrange(0..<41, with: changed.bytes)
            #expect(throws: SealedEnvelopeError.authenticationFailed) { try SealedEnvelope(decoding: bytes).open(key: key) }
        }
        var ciphertext = envelope.encoded()
        ciphertext[ciphertext.count - 1] ^= 0x80
        #expect(throws: SealedEnvelopeError.authenticationFailed) { try SealedEnvelope(decoding: ciphertext).open(key: key) }
        var nonce = envelope.encoded()
        nonce[41] ^= 1
        #expect(throws: SealedEnvelopeError.authenticationFailed) { try SealedEnvelope(decoding: nonce).open(key: key) }
    }

    @Test func wrongKeyAndWrongGroupFail() throws {
        let key = SyncGroupKey.generate()
        let envelope = try SealedEnvelope.seal(payload: Data("payload".utf8), header: header(), key: key)
        #expect(throws: SealedEnvelopeError.authenticationFailed) { try envelope.open(key: SyncGroupKey.generate()) }
        // Same key, group id claimed differently: the authenticated header no longer matches.
        let wrongGroup = SealedEnvelope.Header(group: Data(repeating: 0xff, count: 16), device: header().device, seqFrom: 5, seqTo: 9)
        var bytes = envelope.encoded()
        bytes.replaceSubrange(0..<41, with: wrongGroup.bytes)
        #expect(throws: SealedEnvelopeError.authenticationFailed) { try SealedEnvelope(decoding: bytes).open(key: key) }
        // Key of another group (rotation): a different key never opens the old batch.
        let rotated = SyncGroupKey.generate()
        let resealed = try SealedEnvelope.seal(payload: Data("payload".utf8), header: wrongGroup, key: rotated)
        #expect(try resealed.open(key: rotated) == Data("payload".utf8))
        #expect(throws: SealedEnvelopeError.authenticationFailed) { try resealed.open(key: key) }
    }

    @Test func invalidInputs() throws {
        let key = SyncGroupKey.generate()
        #expect(throws: SealedEnvelopeError.invalidHeader) {
            try SealedEnvelope.seal(payload: Data(), header: SealedEnvelope.Header(group: Data(count: 15), device: 1, seqFrom: 1, seqTo: 1), key: key)
        }
        #expect(throws: SealedEnvelopeError.invalidHeader) {
            try SealedEnvelope.seal(payload: Data(), header: SealedEnvelope.Header(group: group, device: 1, seqFrom: 3, seqTo: 2), key: key)
        }
        #expect(throws: SealedEnvelopeError.invalidHeader) {
            try SealedEnvelope.seal(payload: Data(), header: SealedEnvelope.Header(group: group, device: 1, seqFrom: -1, seqTo: 2), key: key)
        }
        #expect(throws: SealedEnvelopeError.unsupportedFormat(2)) {
            try SealedEnvelope.seal(payload: Data(), header: SealedEnvelope.Header(group: group, device: 1, seqFrom: 1, seqTo: 1, format: 2), key: key)
        }
        #expect(throws: SealedEnvelopeError.malformed) { try SealedEnvelope(decoding: Data(count: 10)) }
        #expect(throws: SealedEnvelopeError.self) { try SealedEnvelope(decoding: Data(count: 200)) }  // format 0
        let tooBig = Data(count: SealedEnvelope.maxPayloadSize + 1)
        #expect(throws: SealedEnvelopeError.self) { try SealedEnvelope.seal(payload: tooBig, header: header(), key: key) }
        let largest = try SealedEnvelope.seal(payload: Data(count: SealedEnvelope.maxPayloadSize), header: header(), key: key)
        #expect(largest.encoded().count == Frame.maxPayload)
        #expect(try largest.open(key: key).count == SealedEnvelope.maxPayloadSize)
    }
}
