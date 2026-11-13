import Foundation

public enum NoiseError: Error, Equatable, Sendable {
    /// Protocol name or pattern not supported by this implementation (only `25519_ChaChaPoly_SHA256`,
    /// the fifteen fundamental patterns and `pskN` modifiers).
    case unsupportedProtocol(String)
    /// A key (static, remote static, PSK) the pattern needs was not provided, or a PSK has the wrong length.
    case missingKey(String)
    /// Message too short, too long (> 65 535 bytes) or malformed for the current step.
    case invalidMessage(String)
    /// AEAD authentication failed (wrong key, wrong PSK, tampered or replayed message).
    case decryptionFailed
    /// The cipher state used its 2^64 − 1 nonces (spec §5.1: the last value is reserved).
    case nonceExhausted
    /// A remote public key was low-order / invalid.
    case invalidPublicKey
    /// `writeMessage`/`readMessage` called out of turn, after completion, or after an earlier failure.
    case invalidState(String)
}
