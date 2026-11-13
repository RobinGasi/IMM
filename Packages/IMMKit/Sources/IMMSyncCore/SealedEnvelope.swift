import Clibsodium
import Foundation

public enum SealedEnvelopeError: Error, Equatable, Sendable {
    /// Bytes do not form an envelope (too short, bad lengths).
    case malformed
    case unsupportedFormat(UInt8)
    /// Header violates its invariants (group not 16 bytes, negative or inverted sequence range).
    case invalidHeader
    /// Authentication failed: wrong key, wrong group, or a modified header or ciphertext.
    case authenticationFailed
    /// The encoded envelope would exceed `SealedEnvelope.maxEncodedSize`.
    case tooLarge(Int)
}

/// A sealed batch or snapshot: `{format, group, device, seqFrom, seqTo}` header in the clear (the keyless agent
/// reads it to file and deduplicate blobs), payload under XChaCha20-Poly1305 with a random 192-bit nonce,
/// header bytes as AAD. Key = `HKDF(group key, "imm/v1/sync/seal")`.
///
/// ```
/// offset  0  format      UInt8 (= 1)
///         1  group       16 bytes
///        17  device      UInt64 BE
///        25  seqFrom     Int64 BE
///        33  seqTo       Int64 BE
///        41  nonce       24 bytes (random per seal, so a restored backup that reuses a sequence number is safe)
///        65  ciphertext  payload ‖ 16-byte Poly1305 tag
/// ```
public struct SealedEnvelope: Equatable, Sendable {
    public static let currentFormat: UInt8 = 1
    public static let groupLength = 16
    public static let headerLength = 41
    public static let nonceLength = 24
    public static let tagLength = 16
    /// "Max 1 MB per batch": the encoded envelope fits one `Frame`.
    public static let maxEncodedSize = Frame.maxPayload
    public static let maxPayloadSize = maxEncodedSize - headerLength - nonceLength - tagLength

    public struct Header: Equatable, Sendable {
        public var format: UInt8
        /// 16-byte sync group id (changes when the group key rotates).
        public var group: Data
        public var device: UInt64
        public var seqFrom: Int64
        public var seqTo: Int64

        public init(group: Data, device: UInt64, seqFrom: Int64, seqTo: Int64, format: UInt8 = SealedEnvelope.currentFormat) {
            self.format = format
            self.group = group
            self.device = device
            self.seqFrom = seqFrom
            self.seqTo = seqTo
        }

        func validate() throws {
            guard group.count == SealedEnvelope.groupLength, seqFrom >= 0, seqFrom <= seqTo else {
                throw SealedEnvelopeError.invalidHeader
            }
        }

        /// The 41 header bytes, also the AAD.
        public var bytes: Data {
            var out = Data([format])
            out += group
            out += Self.be(device)
            out += Self.be(UInt64(bitPattern: seqFrom))
            out += Self.be(UInt64(bitPattern: seqTo))
            return out
        }

        private static func be(_ value: UInt64) -> Data {
            var big = value.bigEndian
            return Data(bytes: &big, count: 8)
        }
    }

    public let header: Header
    public let nonce: Data
    /// Payload ciphertext ‖ tag.
    public let ciphertext: Data

    /// Seals `payload`. Throws `.tooLarge` when the encoded envelope would exceed 1 MiB.
    public static func seal(payload: Data, header: Header, key: SyncGroupKey) throws -> SealedEnvelope {
        try header.validate()
        guard header.format == currentFormat else { throw SealedEnvelopeError.unsupportedFormat(header.format) }
        guard payload.count <= maxPayloadSize else {
            throw SealedEnvelopeError.tooLarge(headerLength + nonceLength + payload.count + tagLength)
        }
        Sodium.ensure()
        let nonce = Sodium.randomBytes(nonceLength)
        let sealKey = key.derive(.seal)
        var ciphertext = Data(count: payload.count + tagLength)
        let aad = header.bytes
        let status: Int32 = ciphertext.withUnsafeMutableBytes { out in
            withBytes(payload) { message in
                withBytes(aad) { ad in
                    withBytes(nonce) { npub in
                        sealKey.memory.withUnsafeBytes { k in
                            crypto_aead_xchacha20poly1305_ietf_encrypt(
                                out.baseAddress!.assumingMemoryBound(to: UInt8.self), nil, message, UInt64(payload.count),
                                ad, UInt64(aad.count), nil, npub, k.baseAddress!.assumingMemoryBound(to: UInt8.self))
                        }
                    }
                }
            }
        }
        precondition(status == 0, "crypto_aead_xchacha20poly1305_ietf_encrypt failed")
        return SealedEnvelope(header: header, nonce: nonce, ciphertext: ciphertext)
    }

    /// Verifies the header and the ciphertext and returns the payload.
    public func open(key: SyncGroupKey) throws -> Data {
        guard header.format == Self.currentFormat else { throw SealedEnvelopeError.unsupportedFormat(header.format) }
        try header.validate()
        guard nonce.count == Self.nonceLength, ciphertext.count >= Self.tagLength else { throw SealedEnvelopeError.malformed }
        Sodium.ensure()
        let sealKey = key.derive(.seal)
        let aad = header.bytes
        var plaintext = Data(count: ciphertext.count - Self.tagLength)
        let status: Int32 = plaintext.withUnsafeMutableBytes { out in
            withBytes(ciphertext) { c in
                withBytes(aad) { ad in
                    withBytes(nonce) { npub in
                        sealKey.memory.withUnsafeBytes { k in
                            crypto_aead_xchacha20poly1305_ietf_decrypt(
                                out.baseAddress?.assumingMemoryBound(to: UInt8.self), nil, nil, c, UInt64(ciphertext.count),
                                ad, UInt64(aad.count), npub, k.baseAddress!.assumingMemoryBound(to: UInt8.self))
                        }
                    }
                }
            }
        }
        guard status == 0 else { throw SealedEnvelopeError.authenticationFailed }
        return plaintext
    }

    // MARK: Wire format

    private init(header: Header, nonce: Data, ciphertext: Data) {
        self.header = header
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    public func encoded() -> Data { header.bytes + nonce + ciphertext }

    /// Parses an envelope (structure only; authentication happens in `open`).
    public init(decoding data: Data) throws {
        let (header, rest) = try Self.parseHeader(data)
        guard rest.count >= Self.nonceLength + Self.tagLength else { throw SealedEnvelopeError.malformed }
        self.init(
            header: header, nonce: rest.prefix(Self.nonceLength).rebased(), ciphertext: rest.dropFirst(Self.nonceLength).rebased())
    }

    /// Reads only the (unauthenticated) header, as the keyless agent does when filing a blob.
    public static func peekHeader(_ data: Data) throws -> Header { try parseHeader(data).0 }

    private static func parseHeader(_ data: Data) throws -> (Header, Data) {
        guard data.count >= headerLength + nonceLength + tagLength else { throw SealedEnvelopeError.malformed }
        guard data.count <= maxEncodedSize else { throw SealedEnvelopeError.tooLarge(data.count) }
        let bytes = data.rebased()
        guard bytes[0] == currentFormat else { throw SealedEnvelopeError.unsupportedFormat(bytes[0]) }
        func word(_ offset: Int) -> UInt64 { bytes[offset..<offset + 8].reduce(0) { ($0 << 8) | UInt64($1) } }
        let header = Header(
            group: bytes[1..<17].rebased(), device: word(17), seqFrom: Int64(bitPattern: word(25)), seqTo: Int64(bitPattern: word(33)),
            format: bytes[0])
        try header.validate()
        return (header, bytes.dropFirst(headerLength).rebased())
    }
}

/// Pointer to `data`'s bytes; a one-byte dummy stands in for empty data (libsodium never reads it).
private func withBytes<R>(_ data: Data, _ body: (UnsafePointer<UInt8>) -> R) -> R {
    if data.isEmpty {
        var dummy: UInt8 = 0
        return withUnsafePointer(to: &dummy) { body($0) }
    }
    return data.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
}
