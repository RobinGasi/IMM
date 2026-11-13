import Clibsodium
import CryptoKit
import Foundation
import GRDB
import Security

/// Key hierarchy: password -> Argon2id KEK -> AES-GCM unwraps the 32-byte data key -> HKDF database key.
enum VaultCrypto {
    static let dataKeyLength = 32
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16
    static let slotType = "password"

    // MARK: Random

    static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw VaultError.io("Random number generator failed (\(status)).") }
        return data
    }

    // MARK: Argon2id

    /// Key-encryption key from the NFC-normalised UTF-8 password (libsodium `crypto_pwhash`, Argon2id 1.3).
    static func deriveKEK(password: String, salt: Data, memoryKiB: Int, iterations: Int) throws -> SecureBytes {
        SodiumRuntime.ensure()
        var passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        let passwordLength = passwordBytes.count
        if passwordBytes.isEmpty { passwordBytes.append(0) }  // keeps a valid pointer for an empty password
        defer {
            passwordBytes.withUnsafeMutableBytes { buffer in
                if let address = buffer.baseAddress, buffer.count > 0 { sodium_memzero(address, buffer.count) }
            }
        }
        let kek = SecureBytes(count: dataKeyLength)
        let status: Int32 = passwordBytes.withUnsafeBufferPointer { password in
            salt.withUnsafeBytes { saltBytes in
                kek.withUnsafeMutableBytes { output in
                    crypto_pwhash(
                        output.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        UInt64(output.count),
                        UnsafeRawPointer(password.baseAddress!).assumingMemoryBound(to: CChar.self),
                        UInt64(passwordLength),
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        UInt64(iterations),
                        memoryKiB * 1024,
                        crypto_pwhash_alg_argon2id13()
                    )
                }
            }
        }
        guard status == 0 else { throw VaultError.io("Key derivation failed.") }
        return kek
    }

    // MARK: AES-256-GCM wrap

    static func aad(vaultID: UUID, slotID: UUID, kdf: VaultHeader.KDF) -> Data {
        let text = "imm-vault-v1|\(vaultID.uuidString)|\(slotID.uuidString)|\(kdf.algorithm)|\(kdf.version)|\(kdf.memoryKiB)|\(kdf.iterations)|\(kdf.parallelism)|\(kdf.salt.base64EncodedString())"
        return Data(text.utf8)
    }

    static func symmetricKey(_ key: borrowing SecureBytes) -> SymmetricKey {
        key.withUnsafeBytes { SymmetricKey(data: $0) }
    }

    /// Builds a password slot that wraps `dataKey` under a KEK derived from `password` and `kdf`.
    static func makeSlot(
        id: UUID, vaultID: UUID, password: String, kdf: VaultHeader.KDF, dataKey: borrowing SecureBytes
    ) throws -> VaultHeader.Slot {
        let kek = try deriveKEK(password: password, salt: kdf.salt, memoryKiB: kdf.memoryKiB, iterations: kdf.iterations)
        let nonceData = try randomData(count: nonceLength)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try dataKey.withUnsafeBytes { plain in
                try AES.GCM.seal(
                    plain, using: symmetricKey(kek), nonce: nonce,
                    authenticating: aad(vaultID: vaultID, slotID: id, kdf: kdf)
                )
            }
            return VaultHeader.Slot(
                id: id, type: slotType, kdf: kdf,
                wrap: .init(
                    algorithm: "AES-256-GCM", nonce: nonceData,
                    ciphertext: sealed.ciphertext, tag: sealed.tag
                )
            )
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.io("Could not wrap the data key: \(error)")
        }
    }

    /// Derives the KEK from `password` and opens the slot; any authentication failure is `.wrongPassword`.
    static func unwrapDataKey(slot: VaultHeader.Slot, vaultID: UUID, password: String) throws -> SecureBytes {
        let kek = try deriveKEK(
            password: password, salt: slot.kdf.salt,
            memoryKiB: slot.kdf.memoryKiB, iterations: slot.kdf.iterations
        )
        var plain: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: slot.wrap.nonce),
                ciphertext: slot.wrap.ciphertext,
                tag: slot.wrap.tag
            )
            plain = try AES.GCM.open(
                box, using: symmetricKey(kek),
                authenticating: aad(vaultID: vaultID, slotID: slot.id, kdf: slot.kdf)
            )
        } catch {
            throw VaultError.wrongPassword
        }
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard plain.count == dataKeyLength else { throw VaultError.wrongPassword }
        return SecureBytes(copying: plain)
    }

    // MARK: Database key

    /// HKDF-SHA256(data key, salt = raw vault UUID bytes, info = "imm/v1/db", 32 bytes).
    static func deriveDatabaseKey(dataKey: KeyBuffer, vaultID: UUID) throws -> KeyBuffer {
        let salt = withUnsafeBytes(of: vaultID.uuid) { Data($0) }
        return try dataKey.withBytes { raw in
            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: raw),
                salt: salt,
                info: Data("imm/v1/db".utf8),
                outputByteCount: 32
            )
            return derived.withUnsafeBytes { KeyBuffer(copying: $0) }
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Applies the raw database key to a fresh connection (`PRAGMA key = "x'<64 hex>'"` semantics).
    /// Contingency: if SQLCipher does not honour the raw-key form through `usePassphrase`, replace the
    /// body with `sqlite3_key_v2(db.sqliteConnection, "main", pointer, length)` (`import SQLCipher`).
    static func applyKey(_ key: KeyBuffer, to db: Database) throws {
        var passphrase = try key.withBytes { raw -> Data in
            var data = Data("x'".utf8)
            data.reserveCapacity(raw.count * 2 + 3)
            for byte in raw {
                data.append(hexDigits[Int(byte >> 4)])
                data.append(hexDigits[Int(byte & 0x0F)])
            }
            data.append(UInt8(ascii: "'"))
            return data
        }
        defer { passphrase.resetBytes(in: 0..<passphrase.count) }
        try db.usePassphrase(passphrase)
        try db.execute(sql: "PRAGMA cipher_memory_security = ON")
    }

    static func openPool(at databaseURL: URL, key: KeyBuffer) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "IMMVault"
        configuration.prepareDatabase { db in
            try VaultCrypto.applyKey(key, to: db)
        }
        do {
            return try DatabasePool(path: databaseURL.path, configuration: configuration)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            // The key does not decrypt this file.
            throw VaultError.wrongPassword
        } catch {
            throw VaultError.io("Could not open the database: \(error)")
        }
    }
}
