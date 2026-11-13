import AppKit
import Foundation
import GRDB
import IMMBanking
import IMMLedger
import IMMSync
import IMMVault
import Observation
import UniformTypeIdentifiers

/// The state of the whole app: which database is open, what the windows show, the lock settings, and
/// the bank connector. Created once by the app and injected with `.environment(model)`; screens read it
/// with `@Environment(AppModel.self)`.
///
/// Vault and Argon2 work runs off the main actor; every method here is called from the main actor.
@MainActor @Observable
public final class AppModel {
    // MARK: Phase

    /// What the lock screen needs to know about the database it is about to unlock.
    public struct LockedInfo: Equatable, Sendable {
        public enum TouchID: Equatable, Sendable {
            /// Not turned on, no sensor, not enrolled, or this build lacks the entitlement.
            case unavailable
            /// Turned on and the key is intact: prompt automatically.
            case ready
            /// Turned on but the system invalidated the key (fingerprints changed): password required once.
            case invalidated
        }

        public var url: URL
        public var vaultID: UUID
        /// File name of the package, for example `Moneten.imm`.
        public var displayName: String
        /// From IMM's preferences on this Mac (nil on the first unlock after the info was lost).
        public var lastOpened: Date?
        public var accountCount: Int?
        public var touchID: TouchID
        /// The package sits in a cloud-synced folder and the one-time warning has not been shown yet.
        public var showsSyncedFolderWarning: Bool
    }

    public enum Phase: Equatable, Sendable {
        /// No database remembered: Create vault.
        case noVault
        /// The remembered database is gone or unreadable; the URL is where it was.
        case missingVault(URL)
        /// A database is known and closed: Unlock.
        case locked(LockedInfo)
        /// Open, but no accounts yet: Add bank / Bank login (setup resumes here after an unlock).
        case needsBank
        /// Open with accounts: main window.
        case ready
    }

    public private(set) var phase: Phase = .noVault {
        didSet {
            if phase != oldValue { windows.showWindows(for: phase) }
        }
    }

    /// Why the database was locked last (drives the Unlock subtitle); nil when it was not locked by IMM
    /// in this session ("Unlock to see your accounts.").
    public var lockReason: LockReason?

    // MARK: Navigation

    public var route: MainRoute = .overview
    public var panel: Panel?
    /// Transaction the Transactions screen should select when it appears or its scope changes; the screen
    /// clears it after consuming it. Set by `showTransaction(id:accountID:)`.
    public var pendingTransactionSelection: String?

    // MARK: Database

    /// The open ledger; nil while locked.
    public private(set) var ledger: LedgerStore?
    public private(set) var biometry: BiometryAvailability
    public private(set) var touchIDEnabled = false
    public private(set) var storedPINCount = 0

    /// Minutes of inactivity before locking: 1, 5, 15, 60, or 0 for "Never". Default 5.
    public var autoLockMinutes: Int {
        didSet {
            guard !isLoadingLockSettings, autoLockMinutes != oldValue else { return }
            monitor.autoLockMinutes = autoLockMinutes > 0 ? autoLockMinutes : nil
            persistLockSettings()
        }
    }

    /// Lock at once on sleep, display sleep, screen lock and user switching. Default on.
    public var lockOnSleep: Bool {
        didSet {
            guard !isLoadingLockSettings, lockOnSleep != oldValue else { return }
            monitor.lockOnSleep = lockOnSleep
            persistLockSettings()
        }
    }

    public let bank: BankController
    /// Sync over Tailscale: switch, status, devices, pairing. Started on unlock, stopped on lock.
    public let sync: SyncService
    /// Live numbers for the sidebar and toolbar.
    public let sidebar = SidebarModel()
    let windows = WindowManager()

    /// Path of the open database package, for Settings ("Show in Finder").
    public var vaultURL: URL? { vault?.packageURL }

    /// Debug menu switches mirrored onto `DemoBankBehaviour.shared`.
    public var demoSyncFails = false {
        didSet { DemoBankBehaviour.shared.sync = demoSyncFails ? .fails : .succeeds }
    }
    public var demoApprovalExpires = false {
        didSet { DemoBankBehaviour.shared.approval = demoApprovalExpires ? .expires : .approves }
    }

    @ObservationIgnored private let biometricStore: any BiometricKeyStore
    @ObservationIgnored private let pinStore: any PINStore
    @ObservationIgnored private let bookmarks: VaultBookmarks
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let monitor: LockMonitor
    @ObservationIgnored private var vault: UnlockedVault?
    @ObservationIgnored private var accessedURL: URL?
    @ObservationIgnored private var isLoadingLockSettings = false
    @ObservationIgnored private var isDemoSession = false

    var currentVaultID: UUID? { vault?.vaultID }

    // MARK: Init

    /// - Parameters:
    ///   - clock: time source of the inactivity timer (tests advance it by hand).
    ///   - autoStart: resolves the remembered database (and, in debug builds, the `-IMMDemoVault YES`
    ///     launch argument). Tests and previews pass `false`.
    public init(
        biometricStore: any BiometricKeyStore = KeychainBiometricKeyStore(),
        pinStore: any PINStore = KeychainPINStore(),
        bookmarks: VaultBookmarks = VaultBookmarks(),
        connector: any BankConnector = DemoConnector(),
        sync: SyncService = SyncService(),
        defaults: UserDefaults = .standard,
        clock: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        autoStart: Bool = true
    ) {
        self.biometricStore = biometricStore
        self.pinStore = pinStore
        self.bookmarks = bookmarks
        self.defaults = defaults
        self.biometry = biometricStore.availability()
        let minutes = defaults.object(forKey: Keys.autoLockMinutes) as? Int ?? 5
        let sleep = defaults.object(forKey: Keys.lockOnSleep) as? Bool ?? true
        self.autoLockMinutes = minutes
        self.lockOnSleep = sleep
        self.monitor = LockMonitor(autoLockMinutes: minutes > 0 ? minutes : nil, lockOnSleep: sleep, now: clock)
        self.bank = BankController(connector: connector, pinStore: pinStore)
        self.sync = sync
        self.bank.model = self
        #if DEBUG
        // -IMMSyncEnable, -IMMSyncPrintPairingCode, -IMMSyncAutoConfirm, -IMMSyncDebugEdit, -IMMSyncDumpOnChange (development builds only).
        self.sync.debugOptions = SyncDebugOptions(defaults: defaults)
        #endif
        self.monitor.onLock = { [weak self] reason in self?.lock(reason) }

        guard autoStart else { return }
        #if DEBUG
        if defaults.bool(forKey: "IMMResetState") { resetForTesting() }
        #endif
        resolveRememberedVault()
        #if DEBUG
        if defaults.bool(forKey: "IMMCloudKitSelfTest") {
            // Two temporary vaults exchange edits through the real CloudKit relay (zone imm-sync-selftest, deleted at the end);
            // prints `CLOUDKIT SELFTEST PASS` or `FAIL` and exits with 0 / 1.
            Task.detached {
                let passed = await CloudKitSelfTest.run { store in
                    let bank = try DemoDataset.load()
                    try LedgerImporter.importSnapshot(bank.snapshot, profile: bank.profile, into: store)
                }
                exit(passed ? 0 : 1)
            }
        }
        if defaults.bool(forKey: "IMMDemoVault") {
            Task { @MainActor [weak self] in await self?.startDemoVault() }
        }
        #endif
    }

    /// A model that starts in `.ready` on `store` (screenshot tests and previews). Nothing touches the
    /// Keychain, the real preferences or the demo bank; `vault` may be nil when the store is in memory.
    public static func preview(store: LedgerStore, vault: UnlockedVault?) -> AppModel {
        let suite = "dev.gasi.imm.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let model = AppModel(
            biometricStore: PreviewBiometricKeyStore(), pinStore: PreviewPINStore(),
            bookmarks: VaultBookmarks(defaults: defaults, securityScoped: false),
            connector: DemoConnector(delay: .milliseconds(300)), defaults: defaults, autoStart: false)
        model.ledger = store
        model.vault = vault
        model.phase = .ready
        model.sidebar.start(ledger: store)
        return model
    }

    /// Puts a preview model into a state the screenshot tests need (setup, lock and settings
    /// screens). Only for models built by `preview(store:vault:)`; never call it on the live model.
    func setPreviewState(phase: Phase? = nil, biometry: BiometryAvailability? = nil,
                         touchIDEnabled: Bool? = nil, storedPINCount: Int? = nil) {
        if let phase { self.phase = phase }
        if let biometry { self.biometry = biometry }
        if let touchIDEnabled { self.touchIDEnabled = touchIDEnabled }
        if let storedPINCount { self.storedPINCount = storedPINCount }
    }

    enum Keys {
        static let autoLockMinutes = "autoLockMinutes"
        static let lockOnSleep = "lockOnSleep"
        static func touchID(_ id: UUID) -> String { "touchIDEnabled.\(id.uuidString)" }
    }

    // MARK: Remembered database

    private func resolveRememberedVault() {
        if let url = bookmarks.resolveLastVault() {
            beginAccess(url)
            if let header = try? Vault.header(at: url) {
                phase = .locked(makeLockedInfo(url: url, vaultID: header.vaultID))
            } else {
                phase = .missingVault(url)
            }
        } else if let path = bookmarks.lastVaultPath {
            phase = .missingVault(URL(fileURLWithPath: path))
        } else {
            phase = .noVault
        }
    }

    private func beginAccess(_ url: URL) {
        endAccess()
        if url.startAccessingSecurityScopedResource() { accessedURL = url }
    }

    private func endAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    private func makeLockedInfo(url: URL, vaultID: UUID) -> LockedInfo {
        biometry = biometricStore.availability()
        let enabled = defaults.bool(forKey: Keys.touchID(vaultID))
        let touchID: LockedInfo.TouchID
        if enabled, biometry == .available {
            touchID = biometricStore.contains(vaultID: vaultID) ? .ready : .invalidated
        } else {
            touchID = .unavailable
        }
        let info = bookmarks.info(vaultID: vaultID)
        return LockedInfo(
            url: url, vaultID: vaultID, displayName: url.lastPathComponent,
            lastOpened: info?.lastOpened, accountCount: info?.accountCount, touchID: touchID,
            showsSyncedFolderWarning: SyncedFolderDetector.isSynced(url.deletingLastPathComponent())
                && !bookmarks.syncedFolderWarningShown(vaultID: vaultID))
    }

    /// Marks the one-time cloud-folder warning of the locked database as shown.
    public func acknowledgeSyncedFolderWarning() {
        guard case .locked(var info) = phase else { return }
        bookmarks.setSyncedFolderWarningShown(true, vaultID: info.vaultID)
        info.showsSyncedFolderWarning = false
        phase = .locked(info)
    }

    // MARK: Create, open, unlock

    /// Creates `<name>.imm` at `url` (which must not exist), opens it and moves to Add bank.
    /// Throws `VaultError` (for example `.alreadyExists`, `.io`).
    public func createVault(at url: URL, password: String, enableTouchID: Bool) async throws {
        if vault != nil { lock(.manual) }
        beginAccess(url)
        let created: UnlockedVault
        do {
            created = try await Task.detached(priority: .userInitiated) {
                try Vault.create(at: url, password: password)
            }.value
        } catch {
            endAccess()
            throw error
        }
        do {
            try finishOpen(vault: created, url: url, created: true)
        } catch {
            created.lock()
            endAccess()
            throw error
        }
        if !isDemoSession {
            try? bookmarks.saveLastVault(url)
            if SyncedFolderDetector.isSynced(url.deletingLastPathComponent()) {
                bookmarks.setSyncedFolderWarningShown(true, vaultID: created.vaultID)
            }
        }
        if enableTouchID { try? await setTouchID(true) }
    }

    /// Switches to the unlock screen for the database at `url`; a database that is open is locked first.
    /// A package that cannot be read shows the "can't be found" screen.
    public func openExisting(at url: URL) {
        if vault != nil { lock(.manual) }
        beginAccess(url)
        lockReason = nil
        do {
            let header = try Vault.header(at: url)
            if !isDemoSession { try? bookmarks.saveLastVault(url) }
            phase = .locked(makeLockedInfo(url: url, vaultID: header.vaultID))
        } catch {
            phase = .missingVault(url)
        }
    }

    /// Shows the Create vault screen (from "Create new database" on the missing-database screen).
    public func showCreateVault() {
        if vault != nil { lock(.manual) }
        lockReason = nil
        phase = .noVault
    }

    /// Runs the standard open panel for `.imm` packages and calls `openExisting(at:)` with the choice.
    /// Returns false when cancelled.
    @discardableResult
    public func chooseDatabase() -> Bool {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Database", bundle: .module)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if let type = UTType("dev.gasi.imm.vault") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        openExisting(at: url)
        return true
    }

    /// Unlocks the database shown on the lock screen with its password.
    /// Throws `VaultError.wrongPassword` (and others from `Vault.open`).
    public func unlock(password: String) async throws {
        guard case .locked(let info) = phase else { throw VaultError.notAVault }
        let url = info.url
        let opened = try await Task.detached(priority: .userInitiated) {
            try Vault.open(at: url, password: password)
        }.value
        do {
            try finishOpen(vault: opened, url: url, created: false)
        } catch {
            opened.lock()
            throw error
        }
    }

    /// Prompts for a fingerprint and unlocks. Throws `BiometryError` (`.cancelled`, `.failed`,
    /// `.keyInvalidated`: after that the lock screen shows the "fingerprints changed" state).
    public func unlockWithTouchID() async throws {
        guard case .locked(let info) = phase else { throw VaultError.notAVault }
        // The automatic prompt must not unlock behind the one-time cloud-folder warning.
        guard !info.showsSyncedFolderWarning else { throw BiometryError.cancelled }
        do {
            let key = try await biometricStore.load(
                vaultID: info.vaultID,
                reason: String(localized: "Unlock \(info.displayName)", bundle: .module))
            let opened = try Vault.open(at: info.url, dataKey: key)
            do {
                try finishOpen(vault: opened, url: info.url, created: false)
            } catch {
                opened.lock()
                throw error
            }
        } catch BiometryError.keyInvalidated {
            phase = .locked(makeLockedInfo(url: info.url, vaultID: info.vaultID))
            throw BiometryError.keyInvalidated
        }
    }

    private func finishOpen(vault opened: UnlockedVault, url: URL, created: Bool) throws {
        let store = try LedgerStore(database: opened.database)
        vault = opened
        ledger = store
        loadLockSettings(from: store)
        biometry = biometricStore.availability()
        touchIDEnabled = defaults.bool(forKey: Keys.touchID(opened.vaultID)) && biometricStore.contains(vaultID: opened.vaultID)
        if !created { rearmTouchIDIfNeeded(opened) }
        refreshStoredPINCount()

        let count = accountCount(in: store)
        if !isDemoSession {
            bookmarks.saveInfo(
                VaultInfo(displayName: url.lastPathComponent, lastOpened: Date(), accountCount: count),
                vaultID: opened.vaultID)
        }
        lockReason = nil
        route = .overview
        panel = nil
        pendingTransactionSelection = nil
        sidebar.start(ledger: store)
        sync.start(ledger: store, vaultID: opened.vaultID)
        monitor.start()
        phase = count == 0 ? .needsBank : .ready
    }

    /// After the fingerprints changed the key is gone; a password unlock stores it again.
    private func rearmTouchIDIfNeeded(_ opened: UnlockedVault) {
        let id = opened.vaultID
        guard defaults.bool(forKey: Keys.touchID(id)), biometry == .available,
              !biometricStore.contains(vaultID: id) else { return }
        let store = biometricStore
        do {
            try opened.withDataKey { key in try store.store(vaultID: id, dataKey: key) }
            touchIDEnabled = true
        } catch {
            touchIDEnabled = false
        }
    }

    private func accountCount(in store: LedgerStore) -> Int {
        let count: Int? = try? store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account WHERE deleted_at IS NULL")
        }
        return count ?? 0
    }

    /// Called by `BankController` after the first import: opens the main window.
    func finishOnboarding() throws {
        guard let ledger else { throw BankControllerError.notReady }
        let count = accountCount(in: ledger)
        if let vault, !isDemoSession {
            bookmarks.saveInfo(
                VaultInfo(displayName: vault.packageURL.lastPathComponent, lastOpened: Date(), accountCount: count),
                vaultID: vault.vaultID)
        }
        phase = count == 0 ? .needsBank : .ready
    }

    // MARK: Lock

    /// Closes the database, wipes the keys, closes Settings and panels and shows the unlock screen.
    /// Does nothing when no database is open.
    ///
    /// Order: everything that can start work on the ledger is stopped first (the monitor, bank tasks, the sidebar observation, sync),
    /// the ledger reference is dropped, and only then the pool closes. `sync.stop()` returns once no sync step is still running on
    /// the ledger. A bank import that is in flight ends as cancelled (`BankController.importAccounts`).
    public func lock(_ reason: LockReason) {
        guard let opened = vault else { return }
        monitor.stop()
        bank.reset()
        sidebar.stop()
        sync.stop()
        let count = ledger.map(accountCount(in:))
        let url = opened.packageURL
        let id = opened.vaultID
        panel = nil
        route = .overview
        pendingTransactionSelection = nil
        ledger = nil
        opened.lock()
        vault = nil
        touchIDEnabled = false
        storedPINCount = 0
        if !isDemoSession {
            let previous = bookmarks.info(vaultID: id)
            bookmarks.saveInfo(
                VaultInfo(
                    displayName: url.lastPathComponent, lastOpened: previous?.lastOpened ?? Date(),
                    accountCount: count ?? previous?.accountCount ?? 0),
                vaultID: id)
        }
        lockReason = reason
        phase = .locked(makeLockedInfo(url: url, vaultID: id))
    }

    // MARK: Security settings

    /// Re-wraps the data key under `new`. Throws `VaultError.wrongPassword` for a wrong `current`.
    /// The 8-character rule is the caller's (the screen's) to enforce.
    public func changePassword(current: String, new: String) async throws {
        guard let opened = vault else { throw VaultError.notAVault }
        try await Task.detached(priority: .userInitiated) {
            try opened.changePassword(current: current, new: new)
        }.value
    }

    /// Turns Touch ID unlock on (stores the data key behind the current fingerprints) or off.
    /// Throws `BiometryError.failed` when Touch ID is not `.available`.
    public func setTouchID(_ on: Bool) async throws {
        guard let opened = vault else { throw VaultError.notAVault }
        let id = opened.vaultID
        let store = biometricStore
        if on {
            biometry = store.availability()
            guard biometry == .available else { throw BiometryError.failed }
            try opened.withDataKey { key in try store.store(vaultID: id, dataKey: key) }
        } else {
            store.remove(vaultID: id)
        }
        defaults.set(on, forKey: Keys.touchID(id))
        touchIDEnabled = on
    }

    public func removeStoredPINs() {
        guard let id = vault?.vaultID else { return }
        pinStore.removeAll(vaultID: id)
        refreshStoredPINCount()
    }

    func refreshStoredPINCount() {
        storedPINCount = vault.map { pinStore.count(vaultID: $0.vaultID) } ?? 0
    }

    private func loadLockSettings(from store: LedgerStore) {
        isLoadingLockSettings = true
        defer { isLoadingLockSettings = false }
        let minutes = (try? store.setting(.autoLockMinutes)).flatMap { Int($0) }
        let sleep = (try? store.setting(.lockOnSleep)).map { $0 == "1" }
        autoLockMinutes = minutes ?? defaults.object(forKey: Keys.autoLockMinutes) as? Int ?? 5
        lockOnSleep = sleep ?? defaults.object(forKey: Keys.lockOnSleep) as? Bool ?? true
        monitor.autoLockMinutes = autoLockMinutes > 0 ? autoLockMinutes : nil
        monitor.lockOnSleep = lockOnSleep
        defaults.set(autoLockMinutes, forKey: Keys.autoLockMinutes)
        defaults.set(lockOnSleep, forKey: Keys.lockOnSleep)
    }

    private func persistLockSettings() {
        defaults.set(autoLockMinutes, forKey: Keys.autoLockMinutes)
        defaults.set(lockOnSleep, forKey: Keys.lockOnSleep)
        try? ledger?.setSetting(.autoLockMinutes, String(autoLockMinutes))
        try? ledger?.setSetting(.lockOnSleep, lockOnSleep ? "1" : "0")
    }

    // MARK: Navigation helpers

    public func navigate(to route: MainRoute) {
        self.route = route
    }

    /// Opens the Transactions screen on `accountID` with `id` selected (Suggestions and Tax return rows).
    public func showTransaction(id: String, accountID: String) {
        pendingTransactionSelection = id
        route = .transactions(.account(accountID))
    }

    public func openNewTransfer(_ draft: TransferDraft? = nil) {
        guard phase == .ready else { return }
        panel = .newTransfer(draft)
    }

    public func openAsk() {
        guard phase == .ready else { return }
        panel = .ask
    }

    /// Closes the open panel (Esc, a click on the dim, Cancel). Closing the TAN sheet while a request is
    /// pending abandons the payment.
    public func closePanel() {
        if let panel, case .tan = panel {
            bank.cancelTransfer()
        }
        panel = nil
    }

    /// Opens the Settings window (sidebar sync line, "Why this happens", "Change TAN method", ⌘,).
    public func openSettings() {
        guard phase == .ready || phase == .needsBank else { return }
        windows.open("settings")
    }

    // MARK: Debug demo vault

    #if DEBUG
    /// `-IMMResetState YES`: forget everything this Mac remembers about databases, so the app starts on
    /// Create vault. Removes the Keychain vault keys and banking PINs of every remembered database, the
    /// app's preferences and the demo vault. Database packages saved elsewhere are left on disk.
    private func resetForTesting() {
        let prefixes = ["vaultInfo.", "touchIDEnabled.", "biometricKeyStored.", "syncedFolderWarningShown."]
        let vaultIDs = Set(defaults.dictionaryRepresentation().keys.compactMap { key in
            prefixes.first(where: key.hasPrefix).flatMap { UUID(uuidString: String(key.dropFirst($0.count))) }
        })
        for id in vaultIDs {
            biometricStore.remove(vaultID: id)
            pinStore.removeAll(vaultID: id)
        }
        let demo = FileManager.default.temporaryDirectory.appendingPathComponent("IMM-Demo.imm", isDirectory: true)
        try? FileManager.default.removeItem(at: demo)
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        NSLog("IMM reset: forgot \(vaultIDs.count) database(s)")
    }
    #endif

    #if DEBUG
    /// `-IMMDemoVault YES`: `IMM-Demo.imm` in the temporary directory, password `demo-demo`, demo profile
    /// imported, unlocked.
    private func startDemoVault() async {
        isDemoSession = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IMM-Demo.imm", isDirectory: true)
        let password = "demo-demo"
        // `-IMMDemoVaultFresh YES`: start from an empty demo vault (the two-device sync test needs a new group every run).
        if defaults.bool(forKey: "IMMDemoVaultFresh") { try? FileManager.default.removeItem(at: url) }
        do {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("vault.json").path) {
                openExisting(at: url)
                try await unlock(password: password)
            } else {
                try await createVault(at: url, password: password, enableTouchID: false)
            }
            if phase == .needsBank {
                try await bank.signIn(
                    bank: DemoConnector.directory[0],
                    credentials: BankCredentials(loginName: "demo", pin: "12345", tanMethod: "pushTAN — S-pushTAN app"))
                try await bank.importAccounts()
            }
            // The two-device sync test waits for this line before it pairs a second device (a snapshot of a half-imported ledger would be empty).
            print("\(Int64(Date().timeIntervalSince1970 * 1000)) demo-ready")
            fflush(stdout)
        } catch {
            NSLog("IMM demo vault failed: \(error)")
        }
    }
    #endif
}

// MARK: - Preview doubles (no Keychain, no persistence)

private struct PreviewBiometricKeyStore: BiometricKeyStore {
    func availability() -> BiometryAvailability { .noSensor }
    func store(vaultID: UUID, dataKey: borrowing SecureBytes) throws { throw BiometryError.failed }
    func load(vaultID: UUID, reason: String) async throws -> SecureBytes { throw BiometryError.failed }
    func remove(vaultID: UUID) {}
    func contains(vaultID: UUID) -> Bool { false }
}

private final class PreviewPINStore: PINStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String: String] = [:]
    func store(pin: String, vaultID: UUID, loginID: UUID) throws {
        lock.withLock { pins["\(vaultID):\(loginID)"] = pin }
    }
    func pin(vaultID: UUID, loginID: UUID) -> String? { lock.withLock { pins["\(vaultID):\(loginID)"] } }
    func count(vaultID: UUID) -> Int { lock.withLock { pins.keys.filter { $0.hasPrefix("\(vaultID):") }.count } }
    func removeAll(vaultID: UUID) { lock.withLock { pins = pins.filter { !$0.key.hasPrefix("\(vaultID):") } } }
}
