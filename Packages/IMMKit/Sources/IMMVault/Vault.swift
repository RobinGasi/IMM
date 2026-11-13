import Foundation
import GRDB

/// Entry points for encrypted database packages (`<name>.imm/` with `vault.json` and `data.sqlite`).
/// All functions are synchronous and CPU-heavy (Argon2id, 64 MiB): call them off the main thread.
public enum Vault {
    /// Creates a new package at `url` (which must not exist), including an encrypted, empty `data.sqlite`.
    public static func create(at url: URL, password: String) throws -> UnlockedVault {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { throw VaultError.alreadyExists }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VaultError.io("Could not create \(url.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            let vaultID = UUID()
            let kdf = VaultHeader.KDF(salt: try VaultCrypto.randomData(count: VaultCrypto.saltLength))
            let dataKey = try SecureBytes.random(count: VaultCrypto.dataKeyLength)
            let slot = try VaultCrypto.makeSlot(
                id: UUID(), vaultID: vaultID, password: password, kdf: kdf, dataKey: dataKey
            )
            let header = VaultHeader(
                format: VaultHeader.currentFormat, vaultID: vaultID, createdAt: Date(), slots: [slot]
            )
            try VaultFiles.writeHeader(header, to: url)
            return try makeUnlocked(packageURL: url, header: header, dataKey: dataKey, creating: true)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    /// Opens the package with the database password.
    public static func open(at url: URL, password: String) throws -> UnlockedVault {
        let header = try VaultFiles.readHeader(at: url)
        guard let slot = header.slots.first(where: { $0.type == VaultCrypto.slotType }) else {
            throw VaultError.notAVault
        }
        let dataKey = try VaultCrypto.unwrapDataKey(slot: slot, vaultID: header.vaultID, password: password)
        return try makeUnlocked(packageURL: url, header: header, dataKey: dataKey, creating: false)
    }

    /// Opens the package with the 32-byte data key (Touch ID path).
    /// A key that does not decrypt the database throws `.wrongPassword`.
    public static func open(at url: URL, dataKey: borrowing SecureBytes) throws -> UnlockedVault {
        guard dataKey.count == VaultCrypto.dataKeyLength else { throw VaultError.wrongPassword }
        let header = try VaultFiles.readHeader(at: url)
        return try makeUnlocked(packageURL: url, header: header, dataKey: dataKey, creating: false)
    }

    /// Reads and validates `vault.json` without any secret.
    public static func header(at url: URL) throws -> VaultHeader {
        try VaultFiles.readHeader(at: url)
    }

    private static func makeUnlocked(
        packageURL: URL, header: VaultHeader, dataKey: borrowing SecureBytes, creating: Bool
    ) throws -> UnlockedVault {
        let databaseURL = VaultFiles.databaseURL(packageURL)
        if !creating, !FileManager.default.fileExists(atPath: databaseURL.path) {
            throw VaultError.notAVault
        }
        let dataBuffer = KeyBuffer.make(copying: dataKey)
        let databaseKey = try VaultCrypto.deriveDatabaseKey(dataKey: dataBuffer, vaultID: header.vaultID)
        let pool = try VaultCrypto.openPool(at: databaseURL, key: databaseKey)
        if creating {
            // Force the encrypted file header to disk so `data.sqlite` exists after create.
            do {
                try pool.write { try $0.execute(sql: "PRAGMA user_version = 0") }
            } catch {
                throw VaultError.io("Could not initialise the database: \(error)")
            }
        }
        return UnlockedVault(
            vaultID: header.vaultID, packageURL: packageURL, database: pool,
            dataKey: dataBuffer, databaseKey: databaseKey
        )
    }
}

/// An open vault. Thread-safe; `lock()` may be called from any thread and is idempotent.
public final class UnlockedVault: @unchecked Sendable {
    public let vaultID: UUID
    public let packageURL: URL
    /// Closed (reads and writes throw) after `lock()`.
    public let database: DatabasePool

    private let dataKey: KeyBuffer
    private let databaseKey: KeyBuffer
    private let stateLock = NSLock()
    private let passwordChangeLock = NSLock()
    private var locked = false
    private var lockHandlers: [@Sendable () -> Void] = []

    init(vaultID: UUID, packageURL: URL, database: DatabasePool, dataKey: KeyBuffer, databaseKey: KeyBuffer) {
        self.vaultID = vaultID
        self.packageURL = packageURL
        self.database = database
        self.dataKey = dataKey
        self.databaseKey = databaseKey
    }

    deinit {
        lock()
    }

    public var isLocked: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return locked
    }

    /// Registers work to run at the start of `lock()` (e.g. cancelling `ValueObservation`s).
    public func onLock(_ handler: @escaping @Sendable () -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if locked {
            handler()
        } else {
            lockHandlers.append(handler)
        }
    }

    /// Re-wraps the data key under `new`. The database file is not touched.
    public func changePassword(current: String, new: String) throws {
        passwordChangeLock.lock()
        defer { passwordChangeLock.unlock() }
        guard !isLocked else { throw VaultError.io("The vault is locked.") }

        let header = try VaultFiles.readHeader(at: packageURL)
        guard let index = header.slots.firstIndex(where: { $0.type == VaultCrypto.slotType }) else {
            throw VaultError.notAVault
        }
        let slot = header.slots[index]
        let unwrapped = try VaultCrypto.unwrapDataKey(slot: slot, vaultID: header.vaultID, password: current)
        let kdf = VaultHeader.KDF(salt: try VaultCrypto.randomData(count: VaultCrypto.saltLength))
        let newSlot = try VaultCrypto.makeSlot(
            id: slot.id, vaultID: header.vaultID, password: new, kdf: kdf, dataKey: unwrapped
        )
        var updated = header
        updated.slots[index] = newSlot
        try VaultFiles.writeHeader(updated, to: packageURL)
    }

    /// Hands a temporary copy of the data key to `body`; the copy is wiped afterwards.
    /// Must not be called after `lock()`.
    public func withDataKey<T>(_ body: (borrowing SecureBytes) throws -> T) rethrows -> T {
        precondition(!dataKey.isWiped, "UnlockedVault.withDataKey called after lock()")
        let copy = dataKey.copyOut()
        return try body(copy)
    }

    /// Runs lock handlers, checkpoints (truncate) and closes the pool, then wipes all key material.
    public func lock() {
        stateLock.lock()
        if locked {
            stateLock.unlock()
            return
        }
        locked = true
        let handlers = lockHandlers
        lockHandlers = []
        stateLock.unlock()

        for handler in handlers { handler() }
        _ = try? database.barrierWriteWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
        try? database.close()
        dataKey.wipe()
        databaseKey.wipe()
    }
}
