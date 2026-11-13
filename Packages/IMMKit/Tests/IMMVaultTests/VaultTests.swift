import Foundation
import GRDB
import Testing
@testable import IMMVault

private let password = "correct horse battery"

private func base64Length(_ value: Any?) throws -> Int {
    let text = try #require(value as? String)
    return try #require(Data(base64Encoded: text)).count
}

@Suite struct VaultTests {
    @Test func createOpenRoundTrip() throws {
        try withTempDirectory { directory in
            let url = vaultURL(in: directory)
            let created = try Vault.create(at: url, password: password)
            let vaultID = created.vaultID
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("vault.json").path))
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("data.sqlite").path))

            try created.database.write { db in
                try db.execute(sql: "CREATE TABLE note (text TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO note (text) VALUES (?)", arguments: ["REWE Markt GmbH"])
            }
            created.lock()

            let header = try Vault.header(at: url)
            #expect(header.vaultID == vaultID)
            #expect(header.format == 1)

            let reopened = try Vault.open(at: url, password: password)
            defer { reopened.lock() }
            #expect(reopened.vaultID == vaultID)
            #expect(reopened.packageURL == url)
            let text = try reopened.database.read { try String.fetchOne($0, sql: "SELECT text FROM note") }
            #expect(text == "REWE Markt GmbH")

            #expect(throws: VaultError.wrongPassword) {
                try Vault.open(at: url, password: "not the password")
            }
        }
    }

    @Test func headerLayout() throws {
        try withTempDirectory { directory in
            let url = vaultURL(in: directory)
            try Vault.create(at: url, password: password).lock()

            let data = try Data(contentsOf: url.appendingPathComponent("vault.json"))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["format"] as? Int == 1)
            let vaultIDText = try #require(object["vaultID"] as? String)
            #expect(UUID(uuidString: vaultIDText) != nil)
            #expect(object["createdAt"] is String)
            let slots = try #require(object["slots"] as? [[String: Any]])
            #expect(slots.count == 1)
            let slot = slots[0]
            #expect(slot["type"] as? String == "password")
            let kdf = try #require(slot["kdf"] as? [String: Any])
            #expect(kdf["algorithm"] as? String == "argon2id")
            #expect(kdf["version"] as? Int == 19)
            #expect(kdf["memoryKiB"] as? Int == 65_536)
            #expect(kdf["iterations"] as? Int == 3)
            #expect(kdf["parallelism"] as? Int == 1)
            #expect(kdf["normalization"] as? String == "NFC")
            #expect(try base64Length(kdf["salt"]) == 16)
            let wrap = try #require(slot["wrap"] as? [String: Any])
            #expect(wrap["algorithm"] as? String == "AES-256-GCM")
            #expect(try base64Length(wrap["nonce"]) == 12)
            #expect(try base64Length(wrap["ciphertext"]) == 32)
            #expect(try base64Length(wrap["tag"]) == 16)
        }
    }

    @Test func existingAndMissingPackages() throws {
        try withTempDirectory { directory in
            let url = vaultURL(in: directory)
            try Vault.create(at: url, password: password).lock()
            #expect(throws: VaultError.alreadyExists) { try Vault.create(at: url, password: password) }

            let missing = directory.appendingPathComponent("Nothing.imm", isDirectory: true)
            #expect(throws: VaultError.notAVault) { try Vault.header(at: missing) }
            #expect(throws: VaultError.notAVault) { try Vault.open(at: missing, password: password) }

            try Data("not json".utf8).write(to: url.appendingPathComponent("vault.json"))
            #expect(throws: VaultError.notAVault) { try Vault.header(at: url) }
        }
    }

    @Test func changePasswordLeavesDatabaseUntouched() throws {
        try withTempDirectory { directory in
            let url = vaultURL(in: directory)
            let databaseFile = url.appendingPathComponent("data.sqlite")
            let created = try Vault.create(at: url, password: password)
            try created.database.write { db in
                try db.execute(sql: "CREATE TABLE note (text TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO note (text) VALUES ('one')")
            }
            created.lock()
            let headerBefore = try Vault.header(at: url)

            // GRDB itself writes to the database on open, so compare the file around the password change only.
            let vault = try Vault.open(at: url, password: password)
            let before = try Data(contentsOf: databaseFile)
            #expect(throws: VaultError.wrongPassword) {
                try vault.changePassword(current: "wrong wrong wrong", new: "new password 1")
            }
            try vault.changePassword(current: password, new: "new password 1")
            let after = try Data(contentsOf: databaseFile)
            #expect(before == after)
            vault.lock()

            let headerAfter = try Vault.header(at: url)
            #expect(headerAfter.vaultID == headerBefore.vaultID)
            #expect(headerAfter.slots[0].id == headerBefore.slots[0].id)
            #expect(headerAfter.slots[0].kdf.salt != headerBefore.slots[0].kdf.salt)
            #expect(headerAfter.slots[0].wrap.nonce != headerBefore.slots[0].wrap.nonce)

            #expect(throws: VaultError.wrongPassword) { try Vault.open(at: url, password: password) }
            let reopened = try Vault.open(at: url, password: "new password 1")
            defer { reopened.lock() }
            #expect(try reopened.database.read { try String.fetchOne($0, sql: "SELECT text FROM note") } == "one")
            // No temporary files left behind.
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            #expect(!names.contains { $0.hasSuffix(".tmp") })
        }
    }

    @Test func unicodePasswordsAreNormalised() throws {
        try withTempDirectory { directory in
            let url = vaultURL(in: directory)
            // "é" precomposed at creation, decomposed at open.
            try Vault.create(at: url, password: "caf\u{00E9} cr\u{00E8}me").lock()
            let reopened = try Vault.open(at: url, password: "cafe\u{0301} cre\u{0300}me")
            reopened.lock()
        }
    }

    @Test func tamperedHeaderFieldsFailAuthentication() throws {
        try withTempDirectory { directory in
            let url = vaultURL(in: directory)
            try Vault.create(at: url, password: password).lock()
            let original = try Data(contentsOf: url.appendingPathComponent("vault.json"))
            func restore() throws { try original.write(to: url.appendingPathComponent("vault.json")) }

            try mutateKDF(at: url) { $0["iterations"] = 4 }
            #expect(throws: VaultError.wrongPassword) { try Vault.open(at: url, password: password) }

            try restore()
            try mutateKDF(at: url) { $0["memoryKiB"] = 65_536 + 1024 }
            #expect(throws: VaultError.wrongPassword) { try Vault.open(at: url, password: password) }

            try restore()
            try mutateKDF(at: url) { $0["salt"] = Data(repeating: 7, count: 16).base64EncodedString() }
            #expect(throws: VaultError.wrongPassword) { try Vault.open(at: url, password: password) }

            try restore()
            try mutateSlot(at: url) { $0["id"] = UUID().uuidString }
            #expect(throws: VaultError.wrongPassword) { try Vault.open(at: url, password: password) }

            try restore()
            try mutateHeader(at: url) { $0["vaultID"] = UUID().uuidString }
            #expect(throws: VaultError.wrongPassword) { try Vault.open(at: url, password: password) }

            // Untouched header still works.
            try restore()
            try Vault.open(at: url, password: password).lock()
        }
    }

    @Test func weakAndUnsupportedHeadersAreRejected() throws {
        try withTempDirectory { directory in
            let url = vaultURL(in: directory)
            try Vault.create(at: url, password: password).lock()
            let original = try Data(contentsOf: url.appendingPathComponent("vault.json"))
            func restore() throws { try original.write(to: url.appendingPathComponent("vault.json")) }

            try mutateKDF(at: url) { $0["memoryKiB"] = 19_455 }
            #expect(throws: VaultError.weakKDFParameters) { try Vault.open(at: url, password: password) }
            #expect(throws: VaultError.weakKDFParameters) { try Vault.header(at: url) }

            try restore()
            try mutateKDF(at: url) { $0["iterations"] = 1 }
            #expect(throws: VaultError.weakKDFParameters) { try Vault.open(at: url, password: password) }

            try restore()
            try mutateHeader(at: url) { $0["format"] = 2 }
            #expect(throws: VaultError.unsupportedFormat(2)) { try Vault.open(at: url, password: password) }
            #expect(throws: VaultError.unsupportedFormat(2)) { try Vault.header(at: url) }
        }
    }

    @Test func databaseFileIsEncrypted() throws {
        try withTempDirectory { directory in
            let url = vaultURL(in: directory)
            let created = try Vault.create(at: url, password: password)
            try created.database.write { db in
                try db.execute(sql: "CREATE TABLE ledger_transaction (counterparty TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO ledger_transaction VALUES ('REWE Markt GmbH')")
            }
            created.lock()

            let bytes = try Data(contentsOf: url.appendingPathComponent("data.sqlite"))
            #expect(bytes.count > 0)
            #expect(Array(bytes.prefix(16)) != Array("SQLite format 3\0".utf8))
            #expect(bytes.range(of: Data("REWE".utf8)) == nil)
            #expect(bytes.range(of: Data("ledger_transaction".utf8)) == nil)
            for suffix in ["-wal", "-shm"] {
                let sidecar = url.appendingPathComponent("data.sqlite" + suffix)
                if let sidecarBytes = try? Data(contentsOf: sidecar) {
                    #expect(sidecarBytes.range(of: Data("REWE".utf8)) == nil)
                }
            }
        }
    }

    @Test func sqlCipherIsLinked() throws {
        try withTempDirectory { directory in
            let vault = try Vault.create(at: vaultURL(in: directory), password: password)
            defer { vault.lock() }
            let version = try vault.database.read { try String.fetchOne($0, sql: "PRAGMA cipher_version") }
            #expect(version?.isEmpty == false)
        }
    }

    @Test func openWithDataKeyAndLock() throws {
        try withTempDirectory { directory in
            let url = vaultURL(in: directory)
            let first = try Vault.create(at: url, password: password)
            try first.database.write { db in
                try db.execute(sql: "CREATE TABLE note (text TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO note (text) VALUES ('keyed')")
            }
            // Extract the key, then use it after the first vault is locked.
            let second = try first.withDataKey { key -> UnlockedVault in
                let length = key.count
                #expect(length == 32)
                first.lock()
                return try Vault.open(at: url, dataKey: key)
            }
            defer { second.lock() }
            #expect(try second.database.read { try String.fetchOne($0, sql: "SELECT text FROM note") } == "keyed")

            // A different random key does not open the database.
            let wrong = try SecureBytes.random(count: 32)
            var caught: VaultError?
            do { _ = try Vault.open(at: url, dataKey: wrong) } catch { caught = error as? VaultError }
            #expect(caught == .wrongPassword)
        }
    }

    @Test func lockClosesPoolAndIsIdempotent() throws {
        try withTempDirectory { directory in
            let vault = try Vault.create(at: vaultURL(in: directory), password: password)
            let observed = LockFlag()
            vault.onLock { observed.set() }
            #expect(!vault.isLocked)
            #expect(try vault.database.read { try Int.fetchOne($0, sql: "SELECT 1") } == 1)
            vault.lock()
            vault.lock()
            #expect(vault.isLocked)
            #expect(observed.value)
            #expect(throws: (any Error).self) { try vault.database.read { _ in 1 } }
            #expect(throws: (any Error).self) { try vault.database.write { _ in 1 } }
        }
    }

    @Test func secureBytesBasics() throws {
        let zero = SecureBytes(count: 8)
        let zeroCount = zero.count
        let allZero = zero.withUnsafeBytes { buffer in buffer.allSatisfy { $0 == 0 } }
        #expect(zeroCount == 8)
        #expect(allZero)

        let copy = SecureBytes(copying: Data([1, 2, 3, 4]))
        let copied = copy.withUnsafeBytes { Array($0) }
        #expect(copied == [1, 2, 3, 4])
        let same = SecureBytes(copying: Data([1, 2, 3, 4]))
        let other = SecureBytes(copying: Data([1, 2, 3, 5]))
        let equalToSame = copy.isEqual(to: same)
        let equalToOther = copy.isEqual(to: other)
        #expect(equalToSame)
        #expect(!equalToOther)

        let a = try SecureBytes.random(count: 32)
        let b = try SecureBytes.random(count: 32)
        let randomCount = a.count
        let randomEqual = a.isEqual(to: b)
        #expect(randomCount == 32)
        #expect(!randomEqual)
    }
}

/// Thread-safe flag for the `@Sendable` lock handler.
private final class LockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
