import CryptoKit
import Foundation

/// Maximum Noise message size (spec §3).
public let noiseMaxMessageLength = 65_535
let noiseTagLength = 16
let noiseKeyLength = 32

/// Noise `CipherState` for ChaCha20-Poly1305 (spec §5.1): 96-bit nonce = 32 zero bits ‖ 64-bit little-endian counter.
struct NoiseCipherState: Sendable {
    private(set) var key: SymmetricKey?
    var nonce: UInt64 = 0

    init(key: SymmetricKey? = nil, nonce: UInt64 = 0) {
        self.key = key
        self.nonce = nonce
    }

    var hasKey: Bool { key != nil }

    mutating func initializeKey(_ key: SymmetricKey?) {
        self.key = key
        nonce = 0
    }

    private func chachaNonce() throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 12)
        var counter = nonce.littleEndian
        withUnsafeBytes(of: &counter) { bytes.replaceSubrange(4..<12, with: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        // 2^64 − 1 is reserved for Rekey (spec §5.1); using it for encryption is an error.
        guard nonce != UInt64.max else { throw NoiseError.nonceExhausted }
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: chachaNonce(), authenticating: ad)
        nonce += 1
        return (sealed.ciphertext + sealed.tag).rebased()
    }

    mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce != UInt64.max else { throw NoiseError.nonceExhausted }
        guard ciphertext.count >= noiseTagLength else { throw NoiseError.decryptionFailed }
        let split = ciphertext.count - noiseTagLength
        let body = ciphertext.prefix(split)
        let tag = ciphertext.suffix(noiseTagLength)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: chachaNonce(), ciphertext: body, tag: tag)
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
            nonce += 1  // only after authentication succeeded (spec §5.1)
            return plaintext.rebased()
        } catch {
            throw NoiseError.decryptionFailed
        }
    }
}

/// Noise `HKDF(chaining_key, input_key_material, num_outputs)` (spec §4.3) on HMAC-SHA-256.
func noiseHKDF(chainingKey: Data, input: Data, outputs: Int) -> [Data] {
    precondition(outputs == 2 || outputs == 3)
    func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
    let temp = hmac(chainingKey, input)
    let out1 = hmac(temp, Data([0x01]))
    let out2 = hmac(temp, out1 + Data([0x02]))
    if outputs == 2 { return [out1, out2] }
    let out3 = hmac(temp, out2 + Data([0x03]))
    return [out1, out2, out3]
}

/// Noise `SymmetricState` (spec §5.2) with SHA-256.
struct NoiseSymmetricState: Sendable {
    private(set) var chainingKey: Data
    private(set) var hash: Data
    var cipher = NoiseCipherState()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        if name.count <= 32 {
            hash = name + Data(count: 32 - name.count)
        } else {
            hash = Data(SHA256.hash(data: name))
        }
        chainingKey = hash
    }

    mutating func mixHash(_ data: Data) {
        hash = Data(SHA256.hash(data: hash + data))
    }

    mutating func mixKey(_ input: Data) {
        let out = noiseHKDF(chainingKey: chainingKey, input: input, outputs: 2)
        chainingKey = out[0]
        cipher.initializeKey(SymmetricKey(data: out[1]))
    }

    mutating func mixKeyAndHash(_ input: Data) {
        let out = noiseHKDF(chainingKey: chainingKey, input: input, outputs: 3)
        chainingKey = out[0]
        mixHash(out[1])
        cipher.initializeKey(SymmetricKey(data: out[2]))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: hash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: hash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// Returns the two transport cipher states (initiator → responder first).
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let out = noiseHKDF(chainingKey: chainingKey, input: Data(), outputs: 2)
        return (NoiseCipherState(key: SymmetricKey(data: out[0])), NoiseCipherState(key: SymmetricKey(data: out[1])))
    }
}
