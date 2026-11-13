import Foundation

public enum VaultError: Error, Equatable, Sendable {
    case wrongPassword
    case weakKDFParameters
    case unsupportedFormat(Int)
    case notAVault
    case alreadyExists
    case io(String)
}

/// Decoded `vault.json`. Plaintext; every field that matters is bound into the AES-GCM AAD of its slot.
public struct VaultHeader: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    static let minimumMemoryKiB = 19_456
    static let minimumIterations = 2

    public var format: Int
    public var vaultID: UUID
    public var createdAt: Date
    public var slots: [Slot]

    public struct Slot: Codable, Equatable, Sendable {
        public var id: UUID
        public var type: String
        public var kdf: KDF
        public var wrap: Wrap
    }

    public struct KDF: Codable, Equatable, Sendable {
        public var algorithm: String
        public var version: Int
        public var memoryKiB: Int
        public var iterations: Int
        public var parallelism: Int
        public var salt: Data
        public var normalization: String

        init(memoryKiB: Int = 65_536, iterations: Int = 3, salt: Data) {
            self.algorithm = "argon2id"
            self.version = 19
            self.memoryKiB = memoryKiB
            self.iterations = iterations
            self.parallelism = 1
            self.salt = salt
            self.normalization = "NFC"
        }
    }

    public struct Wrap: Codable, Equatable, Sendable {
        public var algorithm: String
        public var nonce: Data
        public var ciphertext: Data
        public var tag: Data
    }

    /// Structural and strength checks applied to every header read from disk.
    func validate() throws {
        guard format == Self.currentFormat else { throw VaultError.unsupportedFormat(format) }
        guard !slots.isEmpty else { throw VaultError.notAVault }
        for slot in slots {
            let kdf = slot.kdf
            guard kdf.algorithm == "argon2id", kdf.version == 19, kdf.parallelism == 1,
                  kdf.normalization == "NFC", kdf.salt.count == VaultCrypto.saltLength,
                  slot.wrap.algorithm == "AES-256-GCM",
                  slot.wrap.nonce.count == VaultCrypto.nonceLength,
                  slot.wrap.ciphertext.count == VaultCrypto.dataKeyLength,
                  slot.wrap.tag.count == VaultCrypto.tagLength
            else { throw VaultError.notAVault }
            guard kdf.memoryKiB >= Self.minimumMemoryKiB, kdf.iterations >= Self.minimumIterations else {
                throw VaultError.weakKDFParameters
            }
        }
    }
}
