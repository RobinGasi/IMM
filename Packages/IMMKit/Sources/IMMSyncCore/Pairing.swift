import CryptoKit
import Foundation

/// Commit-reveal 6-digit pairing code.
///
/// ```
/// Noise_XXpsk3_25519_ChaChaPoly_SHA256, prologue "imm/v1/pair", psk = secret from the QR
/// msg1  I → R: e                    payload: commit = SHA256("imm/v1/pair-commit" ‖ nI ‖ sI.pub)
/// msg2  R → I: e, ee, s, es         payload: nR (16 B)      initiator pins rs against the QR here
/// msg3  I → R: s, se, psk           payload: nI (16 B)      responder checks the commitment with sI.pub = decrypted s
/// h2  = handshake hash after message 2 (both sides)
/// SAS = HKDF-SHA256(ikm = nI ‖ nR ‖ sI.pub, salt = h2, info = "imm/v1/pair-sas", 8 B) as UInt64 BE mod 10^6
/// ```
/// The initiator must fix `nI` and its static key before it learns `nR`; whoever sends the last Noise message could
/// otherwise grind a chosen code (measured: median 13 s for 6 digits).
public enum PairingCommitment {
    public static let nonceLength = 16
    public static let commitmentLength = 32
    static let commitLabel = Data("imm/v1/pair-commit".utf8)

    public static func makeNonce() -> Data { Sodium.randomBytes(nonceLength) }

    /// `SHA256("imm/v1/pair-commit" ‖ nI ‖ sI.pub)`.
    public static func commitment(initiatorNonce: Data, initiatorStatic: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: commitLabel)
        hasher.update(data: initiatorNonce)
        hasher.update(data: initiatorStatic)
        return Data(hasher.finalize())
    }

    /// Constant-time check of the revealed opening against the commitment received in message 1.
    public static func verify(commitment: Data, initiatorNonce: Data, initiatorStatic: Data) -> Bool {
        guard initiatorNonce.count == nonceLength, commitment.count == commitmentLength else { return false }
        return Sodium.constantTimeEqual(
            commitment, Self.commitment(initiatorNonce: initiatorNonce, initiatorStatic: initiatorStatic))
    }
}

/// A 6-digit decimal code both devices display; the user confirms that they match.
public struct ShortAuthCode: Hashable, Sendable, CustomStringConvertible {
    public static let digitCount = 6
    static let info = Data("imm/v1/pair-sas".utf8)

    /// 0 ..< 1 000 000.
    public let value: UInt32

    public init?(value: UInt32) {
        guard value < 1_000_000 else { return nil }
        self.value = value
    }

    /// Parses `"123456"` or `"123 456"`.
    public init?(_ text: String) {
        let digits = text.filter { !$0.isWhitespace }
        guard digits.count == Self.digitCount, digits.allSatisfy(\.isASCII), let number = UInt32(digits) else { return nil }
        self.value = number
    }

    /// `"012345"`.
    public var digits: String { String(format: "%06d", value) }
    /// `"012 345"` as shown to the user.
    public var formatted: String { "\(digits.prefix(3)) \(digits.suffix(3))" }
    public var description: String { formatted }

    /// Derives the code from the revealed values and the handshake hash after message 2.
    public static func derive(initiatorNonce: Data, responderNonce: Data, initiatorStatic: Data, handshakeHashAfterMessage2: Data) -> ShortAuthCode {
        let okm = HKDFSHA256.derive(
            input: initiatorNonce + responderNonce + initiatorStatic, salt: handshakeHashAfterMessage2, info: info, outputCount: 8)
        let number = okm.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return ShortAuthCode(value: UInt32(number % 1_000_000))!
    }

    /// Constant-time comparison of what the user typed/confirmed against the derived code.
    public func matches(_ other: ShortAuthCode) -> Bool { value == other.value }
}
