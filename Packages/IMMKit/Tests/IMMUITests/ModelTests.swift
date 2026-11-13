import AppKit
import Foundation
import GRDB
import IMMBanking
import IMMLedger
import IMMVault
@testable import IMMUI
import Testing

// MARK: - Doubles

/// Touch ID that always works and keeps the data keys in memory.
private final class MemoryBiometricStore: BiometricKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]
    func availability() -> BiometryAvailability { .available }
    func store(vaultID: UUID, dataKey: borrowing SecureBytes) throws {
        let data = dataKey.withUnsafeBytes { Data($0) }
        lock.withLock { keys[vaultID] = data }
    }
    func load(vaultID: UUID, reason: String) async throws -> SecureBytes {
        guard let data = lock.withLock({ keys[vaultID] }) else { throw BiometryError.keyInvalidated }
        return SecureBytes(copying: data)
    }
    func remove(vaultID: UUID) { lock.withLock { keys[vaultID] = nil } }
    func contains(vaultID: UUID) -> Bool { lock.withLock { keys[vaultID] != nil } }
}

private final class MemoryPINStore: PINStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String: String] = [:]
    func store(pin: String, vaultID: UUID, loginID: UUID) throws { lock.withLock { pins["\(vaultID):\(loginID)"] = pin } }
    func pin(vaultID: UUID, loginID: UUID) -> String? { lock.withLock { pins["\(vaultID):\(loginID)"] } }
    func count(vaultID: UUID) -> Int { lock.withLock { pins.keys.filter { $0.hasPrefix("\(vaultID):") }.count } }
    func removeAll(vaultID: UUID) { lock.withLock { pins = pins.filter { !$0.key.hasPrefix("\(vaultID):") } } }
}

/// Hand-advanced time source of the inactivity timer.
@MainActor
private final class TestClock {
    private var base = ContinuousClock.now
    var now: ContinuousClock.Instant { base }
    func advance(_ duration: Duration) { base = base.advanced(by: duration) }
}

/// A model with its own preferences, an in-memory Keychain and a demo bank without delay.
@MainActor
private struct Harness {
    let model: AppModel
    let defaults: UserDefaults
    let bookmarks: VaultBookmarks
    let clock: TestClock
    let pinStore = MemoryPINStore()
    let biometricStore = MemoryBiometricStore()

    init(defaults: UserDefaults? = nil, autoStart: Bool = false) {
        let defaults = defaults ?? UserDefaults(suiteName: "dev.gasi.imm.model-tests.\(UUID().uuidString)") ?? .standard
        let clock = TestClock()
        let bookmarks = VaultBookmarks(defaults: defaults, securityScoped: false)
        self.defaults = defaults
        self.bookmarks = bookmarks
        self.clock = clock
        let pins = pinStore
        let biometrics = biometricStore
        self.model = AppModel(
            biometricStore: biometrics, pinStore: pins, bookmarks: bookmarks,
            connector: DemoConnector(delay: .zero), defaults: defaults,
            clock: { clock.now }, autoStart: autoStart)
    }

    /// Creates a vault at `url` and imports the demo accounts: the model ends in `.ready`.
    func createReadyVault(at url: URL, password: String) async throws {
        try await model.createVault(at: url, password: password, enableTouchID: false)
        try await importDemoAccounts()
    }

    func importDemoAccounts() async throws {
        let bank = DemoConnector.directory[0]
        try await model.bank.signIn(
            bank: bank, credentials: BankCredentials(loginName: "lena", pin: "12345678", tanMethod: "pushTAN"))
        try await model.bank.importAccounts(since: Date(), storePIN: true)
    }
}

private func temporaryDirectory(_ components: String...) throws -> URL {
    var url = FileManager.default.temporaryDirectory
        .appendingPathComponent("imm-model-tests-\(UUID().uuidString)", isDirectory: true)
    for component in components { url.appendPathComponent(component, isDirectory: true) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private func lockedInfo(_ model: AppModel) throws -> AppModel.LockedInfo {
    guard case .locked(let info) = model.phase else {
        throw ModelTestFailure.notLocked("\(model.phase)")
    }
    return info
}

private enum ModelTestFailure: Error { case notLocked(String) }

/// Polls the main actor until `condition` holds (the monitor and notification centre deliver
/// asynchronously).
@MainActor
private func eventually(timeout: Duration = .seconds(4), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

// MARK: - Tests

@MainActor
@Suite(.serialized) struct ModelTests {
    // MARK: Lock

    @Test func manualLockClosesTheVaultAndEverythingOpenOnIt() async throws {
        let harness = Harness()
        let model = harness.model
        let url = try temporaryDirectory().appendingPathComponent("Moneten.imm")
        try await harness.createReadyVault(at: url, password: "kontor-ehrenfeld")
        #expect(model.phase == .ready)
        #expect(model.storedPINCount == 1)
        let pool = try #require(model.ledger).database
        model.navigate(to: .budgets)
        model.openAsk()
        #expect(model.panel == .ask)

        model.lock(.manual)

        guard case .locked(let info) = model.phase else {
            Issue.record("phase is \(model.phase)")
            return
        }
        #expect(info.url == url)
        #expect(info.displayName == "Moneten.imm")
        #expect(info.accountCount == 5)
        #expect(model.lockReason == .manual)
        #expect(model.ledger == nil)
        #expect(model.vaultURL == nil)
        #expect(model.panel == nil)
        #expect(model.route == .overview)
        #expect(model.storedPINCount == 0)
        #expect(!model.touchIDEnabled)
        #expect(model.bank.syncState == .idle)
        // The pool is closed: reading from it fails.
        #expect(throws: (any Error).self) { try pool.read { _ in 0 } }

        // Locking twice does nothing; unlocking works again.
        model.lock(.sleep)
        #expect(model.lockReason == .manual)
        try await model.unlock(password: "kontor-ehrenfeld")
        #expect(model.phase == .ready)
        #expect(model.lockReason == nil)
        model.lock(.manual)
    }

    @Test func inactivityLocksAfterTheChosenMinutes() async throws {
        let harness = Harness()
        let model = harness.model
        let url = try temporaryDirectory().appendingPathComponent("Moneten.imm")
        try await harness.createReadyVault(at: url, password: "kontor-ehrenfeld")
        model.autoLockMinutes = 1

        // 59 s of idle time: still open after the next timer tick.
        harness.clock.advance(.seconds(59))
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(model.phase == .ready)

        harness.clock.advance(.seconds(2))
        let locked = await eventually { model.lockReason != nil }
        #expect(locked)
        #expect(model.lockReason == .inactivity(minutes: 1))
        guard case .locked = model.phase else {
            Issue.record("phase is \(model.phase)")
            return
        }
        #expect(model.ledger == nil)
    }

    @Test func neverMeansNoInactivityLock() async throws {
        let harness = Harness()
        let model = harness.model
        let url = try temporaryDirectory().appendingPathComponent("Moneten.imm")
        try await harness.createReadyVault(at: url, password: "kontor-ehrenfeld")
        model.autoLockMinutes = 0
        harness.clock.advance(.seconds(24 * 3600))
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(model.phase == .ready)
        model.lock(.manual)
    }

    @Test func sleepLocksWhenTheSettingIsOn() async throws {
        let harness = Harness()
        let model = harness.model
        let url = try temporaryDirectory().appendingPathComponent("Moneten.imm")
        try await harness.createReadyVault(at: url, password: "kontor-ehrenfeld")
        #expect(model.lockOnSleep)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)

        let locked = await eventually { model.lockReason != nil }
        #expect(locked)
        #expect(model.lockReason == .sleep)
        guard case .locked = model.phase else {
            Issue.record("phase is \(model.phase)")
            return
        }
    }

    @Test func sleepIsIgnoredWhenTheSettingIsOff() async throws {
        let harness = Harness()
        let model = harness.model
        let url = try temporaryDirectory().appendingPathComponent("Moneten.imm")
        try await harness.createReadyVault(at: url, password: "kontor-ehrenfeld")
        model.lockOnSleep = false

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.phase == .ready)
        #expect(model.lockReason == nil)
        model.lock(.manual)

        // The choice is stored with the database and wins after the next unlock.
        try await model.unlock(password: "kontor-ehrenfeld")
        #expect(!model.lockOnSleep)
        model.lock(.manual)
    }

    // MARK: Password

    @Test func changedPasswordReplacesTheOldOne() async throws {
        let harness = Harness()
        let model = harness.model
        let url = try temporaryDirectory().appendingPathComponent("Moneten.imm")
        try await harness.createReadyVault(at: url, password: "kontor-ehrenfeld")

        await #expect(throws: VaultError.wrongPassword) {
            try await model.changePassword(current: "falsch-falsch", new: "neues-passwort-1")
        }
        try await model.changePassword(current: "kontor-ehrenfeld", new: "neues-passwort-1")
        model.lock(.manual)

        await #expect(throws: VaultError.wrongPassword) {
            try await model.unlock(password: "kontor-ehrenfeld")
        }
        guard case .locked = model.phase else {
            Issue.record("a wrong password must keep the lock screen, phase is \(model.phase)")
            return
        }
        try await model.unlock(password: "neues-passwort-1")
        #expect(model.phase == .ready)
        #expect(model.ledger != nil)
        model.lock(.manual)
    }

    // MARK: Touch ID

    @Test func touchIDUnlocksAndInvalidatedKeyAsksForThePasswordOnce() async throws {
        let harness = Harness()
        let model = harness.model
        let url = try temporaryDirectory().appendingPathComponent("Moneten.imm")
        try await harness.createReadyVault(at: url, password: "kontor-ehrenfeld")
        try await model.setTouchID(true)
        model.lock(.manual)
        let info = try lockedInfo(model)
        #expect(info.touchID == .ready)

        try await model.unlockWithTouchID()
        #expect(model.phase == .ready)
        #expect(model.touchIDEnabled)
        model.lock(.manual)

        // Fingerprints changed: the system dropped the key.
        harness.biometricStore.remove(vaultID: info.vaultID)
        let changed = try lockedInfo(model)
        #expect(changed.touchID == .ready)
        await #expect(throws: BiometryError.keyInvalidated) { try await model.unlockWithTouchID() }
        guard case .locked(let afterwards) = model.phase else {
            Issue.record("phase is \(model.phase)")
            return
        }
        #expect(afterwards.touchID == .invalidated)

        // The password unlock stores the key for the new fingerprints.
        try await model.unlock(password: "kontor-ehrenfeld")
        #expect(model.touchIDEnabled)
        model.lock(.manual)
        let rearmed = try lockedInfo(model)
        #expect(rearmed.touchID == .ready)
    }

    // MARK: Synced folder

    private func syncedURL() throws -> URL {
        try temporaryDirectory("Library", "Mobile Documents", "com~apple~CloudDocs").appendingPathComponent("Moneten.imm")
    }

    @Test func openingADatabaseInASyncedFolderWarnsOnce() async throws {
        let url = try syncedURL()
        _ = try Vault.create(at: url, password: "kontor-ehrenfeld")
        let harness = Harness()
        let model = harness.model

        model.openExisting(at: url)
        guard case .locked(let info) = model.phase else {
            Issue.record("phase is \(model.phase)")
            return
        }
        #expect(info.showsSyncedFolderWarning)

        // Behind the warning Touch ID must not unlock on its own.
        await #expect(throws: BiometryError.cancelled) { try await model.unlockWithTouchID() }

        model.acknowledgeSyncedFolderWarning()
        let acknowledged = try lockedInfo(model)
        #expect(!acknowledged.showsSyncedFolderWarning)
        #expect(harness.bookmarks.syncedFolderWarningShown(vaultID: info.vaultID))

        // Not again: neither after opening the package once more nor after a lock.
        model.openExisting(at: url)
        let again = try lockedInfo(model)
        #expect(!again.showsSyncedFolderWarning)
        try await model.unlock(password: "kontor-ehrenfeld")
        model.lock(.manual)
        let afterLock = try lockedInfo(model)
        #expect(!afterLock.showsSyncedFolderWarning)

        // The flag is per database: a Mac that never acknowledged it (fresh preferences) is warned.
        let other = Harness()
        other.model.openExisting(at: url)
        let fresh = try lockedInfo(other.model)
        #expect(fresh.showsSyncedFolderWarning)
    }

    @Test func aFolderOutsideTheCloudDoesNotWarn() async throws {
        let url = try temporaryDirectory().appendingPathComponent("Moneten.imm")
        _ = try Vault.create(at: url, password: "kontor-ehrenfeld")
        let harness = Harness()
        harness.model.openExisting(at: url)
        guard case .locked(let info) = harness.model.phase else {
            Issue.record("phase is \(harness.model.phase)")
            return
        }
        #expect(!info.showsSyncedFolderWarning)
    }

    @Test func aDatabaseCreatedInASyncedFolderWasAlreadyWarnedAbout() async throws {
        let harness = Harness()
        let url = try syncedURL()
        try await harness.model.createVault(at: url, password: "kontor-ehrenfeld", enableTouchID: false)
        harness.model.lock(.manual)
        let info = try lockedInfo(harness.model)
        #expect(!info.showsSyncedFolderWarning)
    }

    @Test func theRememberedDatabaseStartsLockedWithTheWarning() async throws {
        let url = try syncedURL()
        let vaultID = try Vault.create(at: url, password: "kontor-ehrenfeld").vaultID
        let first = Harness()
        try first.bookmarks.saveLastVault(url)

        let restarted = Harness(defaults: first.defaults, autoStart: true)
        guard case .locked(let info) = restarted.model.phase else {
            Issue.record("phase is \(restarted.model.phase)")
            return
        }
        #expect(info.vaultID == vaultID)
        #expect(info.showsSyncedFolderWarning)
    }
}
