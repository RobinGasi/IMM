import CryptoKit
import Foundation
import Testing

@testable import IMMSyncCore

struct PairingTests {
    @Test func commitmentVerifiesOnlyTheCommittedOpening() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let nonce = PairingCommitment.makeNonce()
        let commitment = PairingCommitment.commitment(initiatorNonce: nonce, initiatorStatic: key)
        #expect(commitment.count == 32)
        #expect(PairingCommitment.verify(commitment: commitment, initiatorNonce: nonce, initiatorStatic: key))

        // A different nonce (the attacker tries another reveal after seeing nR) is detected.
        var otherNonce = nonce
        otherNonce[0] ^= 1
        #expect(!PairingCommitment.verify(commitment: commitment, initiatorNonce: otherNonce, initiatorStatic: key))
        // A different static key (a ground message-3 key) is detected.
        let otherKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        #expect(!PairingCommitment.verify(commitment: commitment, initiatorNonce: nonce, initiatorStatic: otherKey))
        // Malformed inputs.
        #expect(!PairingCommitment.verify(commitment: commitment.dropLast(), initiatorNonce: nonce, initiatorStatic: key))
        #expect(!PairingCommitment.verify(commitment: commitment, initiatorNonce: nonce.dropLast(), initiatorStatic: key))
    }

    @Test func commitmentIsDomainSeparated() {
        let nonce = Data(repeating: 1, count: 16), key = Data(repeating: 2, count: 32)
        let plain = Data(SHA256.hash(data: nonce + key))
        #expect(PairingCommitment.commitment(initiatorNonce: nonce, initiatorStatic: key) != plain)
        #expect(PairingCommitment.commitment(initiatorNonce: nonce, initiatorStatic: key)
            == Data(SHA256.hash(data: Data("imm/v1/pair-commit".utf8) + nonce + key)))
    }

    @Test func codeIsDeterministicAndDependsOnEveryInput() {
        let nI = Data(repeating: 1, count: 16), nR = Data(repeating: 2, count: 16)
        let s = Data(repeating: 3, count: 32), h = Data(repeating: 4, count: 32)
        let code = ShortAuthCode.derive(initiatorNonce: nI, responderNonce: nR, initiatorStatic: s, handshakeHashAfterMessage2: h)
        #expect(code == ShortAuthCode.derive(initiatorNonce: nI, responderNonce: nR, initiatorStatic: s, handshakeHashAfterMessage2: h))
        // Regression vector for the derivation (HKDF-SHA256, ikm = nI‖nR‖sI, salt = h2, info "imm/v1/pair-sas", 8 B mod 10^6).
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: nI + nR + s), salt: h, info: Data("imm/v1/pair-sas".utf8), outputByteCount: 8)
        let expected = okm.withUnsafeBytes { $0.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } } % 1_000_000
        #expect(UInt64(code.value) == expected)

        var changed = Set<UInt32>([code.value])
        for variant in 0..<4 {
            var a = nI, b = nR, c = s, d = h
            switch variant {
            case 0: a[0] ^= 1
            case 1: b[0] ^= 1
            case 2: c[0] ^= 1
            default: d[0] ^= 1
            }
            changed.insert(ShortAuthCode.derive(initiatorNonce: a, responderNonce: b, initiatorStatic: c, handshakeHashAfterMessage2: d).value)
        }
        #expect(changed.count == 5)  // 10^-24 chance of an accidental collision
    }

    @Test func codeFormattingAndParsing() throws {
        let code = try #require(ShortAuthCode(value: 12_345))
        #expect(code.digits == "012345")
        #expect(code.formatted == "012 345")
        #expect("\(code)" == "012 345")
        #expect(ShortAuthCode("012 345") == code)
        #expect(ShortAuthCode("012345") == code)
        #expect(ShortAuthCode(" 0123 45 ") == code)
        #expect(ShortAuthCode("12345") == nil)
        #expect(ShortAuthCode("1234567") == nil)
        #expect(ShortAuthCode("12345a") == nil)
        #expect(ShortAuthCode("٠١٢٣٤٥") == nil)  // non-ASCII digits
        #expect(ShortAuthCode(value: 1_000_000) == nil)
        #expect(ShortAuthCode(value: 999_999)?.digits == "999999")
    }

    @Test func codesAreRoughlyUniform() {
        // 6 digits = 10^6 outcomes; sanity-check there is no gross bias in the leading digit over 5000 random inputs.
        var counts = [Int](repeating: 0, count: 10)
        for _ in 0..<5000 {
            let code = ShortAuthCode.derive(
                initiatorNonce: PairingCommitment.makeNonce(), responderNonce: PairingCommitment.makeNonce(),
                initiatorStatic: Data(count: 32), handshakeHashAfterMessage2: Data(count: 32))
            counts[Int(code.digits.first!.wholeNumberValue!)] += 1
        }
        #expect(counts.allSatisfy { $0 > 300 && $0 < 700 }, "\(counts)")
    }
}
