import Clibsodium
import Foundation

extension Data {
    /// A copy whose indices start at 0 (slices and CryptoKit results keep the offset of their parent buffer).
    func rebased() -> Data { withUnsafeBytes { Data($0) } }
}

/// One-time libsodium initialisation.
enum Sodium {
    private static let ready: Bool = sodium_init() >= 0

    static func ensure() {
        precondition(ready, "libsodium failed to initialise")
    }

    /// Cryptographically secure random bytes (libsodium, `arc4random` on Apple platforms).
    static func randomBytes(_ count: Int) -> Data {
        ensure()
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress, count > 0 { randombytes_buf(base, count) }
        }
        return data
    }

    /// Constant-time equality for equal-length buffers; `false` when the lengths differ.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        ensure()
        return a.withUnsafeBytes { left in
            b.withUnsafeBytes { right in
                sodium_memcmp(left.baseAddress!, right.baseAddress!, a.count) == 0
            }
        }
    }
}

/// Fixed-size secret in `sodium_malloc` memory (guard pages, locked, zeroed and freed in `deinit`).
/// Reference type so a key can be shared between actors without copying the secret around.
final class SecretMemory: @unchecked Sendable {
    let count: Int
    private let base: UnsafeMutableRawPointer

    init(count: Int) {
        Sodium.ensure()
        precondition(count > 0)
        guard let pointer = sodium_malloc(count) else {
            fatalError("sodium_malloc failed for \(count) bytes")
        }
        sodium_memzero(pointer, count)
        self.base = pointer
        self.count = count
    }

    convenience init(copying data: Data) {
        self.init(count: data.count)
        let destination = base
        data.withUnsafeBytes { source in
            if let address = source.baseAddress { memcpy(destination, address, source.count) }
        }
    }

    static func random(count: Int) -> SecretMemory {
        let memory = SecretMemory(count: count)
        randombytes_buf(memory.base, count)
        return memory
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: count))
    }

    func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: base, count: count))
    }

    func isEqual(to other: SecretMemory) -> Bool {
        guard count == other.count else { return false }
        return other.withUnsafeBytes { sodium_memcmp(base, $0.baseAddress!, count) == 0 }
    }

    deinit { sodium_free(base) }
}

/// HKDF-SHA256 (RFC 5869) on libsodium's HMAC-SHA-256, so the input key never leaves `sodium_malloc` memory.
enum HKDFSHA256 {
    private static let hashLength = Int(crypto_auth_hmacsha256_BYTES)

    /// Derives `outputCount` (≤ 255 × 32) bytes into a fresh `SecretMemory`.
    static func derive(input: SecretMemory, salt: Data, info: Data, outputCount: Int) -> SecretMemory {
        precondition(outputCount > 0 && outputCount <= 255 * hashLength)
        let output = SecretMemory(count: outputCount)
        input.withUnsafeBytes { ikm in
            output.withUnsafeMutableBytes { out in
                expand(ikm: ikm, salt: salt, info: info, into: out)
            }
        }
        return output
    }

    /// Plain-data variant for non-secret inputs (pairing SAS, tests).
    static func derive(input: Data, salt: Data, info: Data, outputCount: Int) -> Data {
        precondition(outputCount > 0 && outputCount <= 255 * hashLength)
        var output = Data(count: outputCount)
        input.withUnsafeBytes { ikm in
            output.withUnsafeMutableBytes { out in
                expand(ikm: ikm, salt: salt, info: info, into: out)
            }
        }
        return output
    }

    private static func expand(ikm: UnsafeRawBufferPointer, salt: Data, info: Data, into out: UnsafeMutableRawBufferPointer) {
        Sodium.ensure()
        var prk = [UInt8](repeating: 0, count: hashLength)
        var block = [UInt8]()
        var message = [UInt8]()
        defer {
            wipe(&prk)
            wipe(&block)
            wipe(&message)
        }
        // Extract: PRK = HMAC(salt, ikm). RFC 5869: an empty salt is HashLen zero bytes.
        let saltBytes = salt.isEmpty ? [UInt8](repeating: 0, count: hashLength) : [UInt8](salt)
        saltBytes.withUnsafeBytes { hmac(key: $0, message: ikm, into: &prk) }
        // Expand: T(i) = HMAC(PRK, T(i-1) ‖ info ‖ i)
        var produced = 0
        var counter: UInt8 = 1
        while produced < out.count {
            message.removeAll(keepingCapacity: true)
            message.append(contentsOf: block)
            message.append(contentsOf: info)
            message.append(counter)
            var next = [UInt8](repeating: 0, count: hashLength)
            prk.withUnsafeBytes { key in
                message.withUnsafeBytes { hmac(key: key, message: $0, into: &next) }
            }
            wipe(&block)
            block = next
            let take = min(hashLength, out.count - produced)
            block.withUnsafeBytes { _ = memcpy(out.baseAddress! + produced, $0.baseAddress!, take) }
            produced += take
            counter &+= 1
        }
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { sodium_memzero(base, $0.count) } }
    }

    private static func hmac(key: UnsafeRawBufferPointer, message: UnsafeRawBufferPointer, into output: inout [UInt8]) {
        var state = crypto_auth_hmacsha256_state()
        crypto_auth_hmacsha256_init(&state, key.baseAddress?.assumingMemoryBound(to: UInt8.self), key.count)
        if message.count > 0 {
            crypto_auth_hmacsha256_update(&state, message.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt64(message.count))
        }
        crypto_auth_hmacsha256_final(&state, &output)
        sodium_memzero(&state, MemoryLayout<crypto_auth_hmacsha256_state>.size)
    }
}
