import Clibsodium
import Foundation
import Security

/// One-time libsodium initialisation.
enum SodiumRuntime {
    private static let ready: Bool = sodium_init() >= 0

    static func ensure() {
        precondition(ready, "libsodium failed to initialise")
    }
}

/// Key material in `sodium_malloc` memory (guard pages, `mlock`ed, zeroed and freed in `deinit`).
public struct SecureBytes: ~Copyable, @unchecked Sendable {
    public let count: Int
    private let base: UnsafeMutableRawPointer

    /// Zero-filled buffer of `count` bytes.
    public init(count: Int) {
        SodiumRuntime.ensure()
        precondition(count >= 0)
        let size = max(count, 1)
        guard let pointer = sodium_malloc(size) else {
            fatalError("sodium_malloc failed for \(size) bytes")
        }
        sodium_memzero(pointer, size)
        self.base = pointer
        self.count = count
    }

    public init(copying bytes: UnsafeRawBufferPointer) {
        self.init(count: bytes.count)
        if let source = bytes.baseAddress, bytes.count > 0 {
            memcpy(base, source, bytes.count)
        }
    }

    public init(copying data: Data) {
        self.init(count: data.count)
        let destination = base
        data.withUnsafeBytes { source in
            if let address = source.baseAddress, source.count > 0 {
                memcpy(destination, address, source.count)
            }
        }
    }

    /// Cryptographically secure random bytes (`SecRandomCopyBytes`).
    public static func random(count: Int) throws -> SecureBytes {
        let bytes = SecureBytes(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw VaultError.io("Random number generator failed (\(status)).")
        }
        return bytes
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: count))
    }

    func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: base, count: count))
    }

    /// Constant-time comparison.
    public func isEqual(to other: borrowing SecureBytes) -> Bool {
        guard count == other.count else { return false }
        if count == 0 { return true }
        return other.withUnsafeBytes { otherBytes in
            sodium_memcmp(base, otherBytes.baseAddress!, count) == 0
        }
    }

    deinit {
        sodium_free(base)
    }
}

/// Reference-counted key storage shared by `UnlockedVault` and the GRDB `prepareDatabase` closure.
/// Memory is `sodium_malloc`ed and wiped on `wipe()` / `deinit`.
final class KeyBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var base: UnsafeMutableRawPointer?
    let count: Int

    init(copying bytes: UnsafeRawBufferPointer) {
        SodiumRuntime.ensure()
        let size = max(bytes.count, 1)
        guard let pointer = sodium_malloc(size) else {
            fatalError("sodium_malloc failed for \(size) bytes")
        }
        sodium_memzero(pointer, size)
        if let source = bytes.baseAddress, bytes.count > 0 {
            memcpy(pointer, source, bytes.count)
        }
        self.base = pointer
        self.count = bytes.count
    }

    static func make(copying key: borrowing SecureBytes) -> KeyBuffer {
        key.withUnsafeBytes { KeyBuffer(copying: $0) }
    }

    var isWiped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return base == nil
    }

    func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        lock.lock()
        defer { lock.unlock() }
        guard let base else { throw VaultError.io("The vault is locked.") }
        return try body(UnsafeRawBufferPointer(start: base, count: count))
    }

    /// Copies the key into a fresh `SecureBytes`. Traps when wiped.
    func copyOut() -> SecureBytes {
        lock.lock()
        defer { lock.unlock() }
        guard let base else { preconditionFailure("Key buffer used after lock()") }
        return SecureBytes(copying: UnsafeRawBufferPointer(start: base, count: count))
    }

    func wipe() {
        lock.lock()
        defer { lock.unlock() }
        if let base {
            sodium_free(base)
            self.base = nil
        }
    }

    deinit {
        if let base { sodium_free(base) }
    }
}
