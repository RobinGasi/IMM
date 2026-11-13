import Foundation

public enum SyncKeyError: Error, Equatable, Sendable {
    case invalidLength(Int)
}

/// HKDF info labels for keys derived from the group key. One purpose each.
public enum SyncKeyLabel: String, Sendable, CaseIterable {
    /// AEAD key for sealed batches and snapshots (`SealedEnvelope`).
    case seal = "imm/v1/sync/seal"
    /// Pre-shared key material for group-scoped Noise handshakes.
    case psk = "imm/v1/sync/psk"
    /// Key shared with the (keyless) agent, e.g. for authenticating its allow-list updates or mailbox metadata.
    case agent = "imm/v1/sync/agent"
}

/// A 32-byte key derived from the group key, in `sodium_malloc` memory, zeroed on release.
public final class SyncDerivedKey: @unchecked Sendable {
    public static let length = 32
    let memory: SecretMemory

    init(memory: SecretMemory) { self.memory = memory }

    /// Copies the key out (the copy is not wiped; use for test vectors and hand-off only).
    public func rawBytes() -> Data { memory.withUnsafeBytes { Data($0) } }

    public func isEqual(to other: SyncDerivedKey) -> Bool { memory.isEqual(to: other.memory) }
}

/// The 32-byte symmetric key shared by all devices of one ledger. Lives in `sodium_malloc` memory and is zeroed when
/// the last reference goes away. It never leaves the vault database except through `rawBytes()`.
public final class SyncGroupKey: @unchecked Sendable {
    public static let length = 32
    private let memory: SecretMemory

    public init(bytes: Data) throws {
        guard bytes.count == Self.length else { throw SyncKeyError.invalidLength(bytes.count) }
        memory = SecretMemory(copying: bytes)
    }

    private init(memory: SecretMemory) { self.memory = memory }

    /// Fresh random key (created by the first device, or on rotation after a device removal).
    public static func generate() -> SyncGroupKey { SyncGroupKey(memory: .random(count: length)) }

    /// Copies the key out for storage in the (encrypted) vault database. The caller owns the copy.
    public func rawBytes() -> Data { memory.withUnsafeBytes { Data($0) } }

    public func isEqual(to other: SyncGroupKey) -> Bool { memory.isEqual(to: other.memory) }

    /// `HKDF-SHA256(ikm = group key, salt, info = label, 32 bytes)`.
    public func derive(_ label: SyncKeyLabel, salt: Data = Data()) -> SyncDerivedKey {
        SyncDerivedKey(
            memory: HKDFSHA256.derive(input: memory, salt: salt, info: Data(label.rawValue.utf8), outputCount: SyncDerivedKey.length))
    }
}
