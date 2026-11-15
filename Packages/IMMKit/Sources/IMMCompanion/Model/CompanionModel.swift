import Foundation
import GRDB
import IMMLedger
import IMMSync
import IMMSyncCore
import IMMVault
import Observation

// The iPhone companion's model: one encrypted ledger copy (`Vault` + `LedgerStore`), synced with the Mac through its sync
// agent (`SyncEngine` / `SyncClient`, as in the `imm-sync-peer` tool). Screens read the published values and call the
// actions; every blocking step (Argon2id, SQLite, network) runs off the main actor.

/// Where the model keeps things and how it reaches the Mac. `live(deviceName:)` is what the app uses; tests inject the
/// closures and options.
public struct CompanionEnvironment: Sendable {
    /// `Application Support/IMM/Companion.imm`.
    public var vaultURL: URL
    /// The device key that opens the vault.
    public var keyStore: any CompanionKeyStore
    /// Name this device announces to the Mac (`UIDevice.current.name` on iOS).
    public var deviceName: String
    /// Builds the client for an engine; `log` receives its events (the model follows the pairing with them).
    public var makeSyncClient: @Sendable (SyncEngine, @escaping @Sendable (SyncClientEvent) -> Void) -> SyncClient
    public var now: @Sendable () -> Date
    /// Limits of a normal sync run.
    public var syncOptions: SyncClient.Options
    /// Limits of the pairing run; the default allows 150 s for the user to confirm on the Mac.
    public var pairingOptions: SyncClient.Options

    public init(
        vaultURL: URL, keyStore: any CompanionKeyStore, deviceName: String,
        makeSyncClient: @escaping @Sendable (SyncEngine, @escaping @Sendable (SyncClientEvent) -> Void) -> SyncClient = {
            SyncClient(engine: $0, log: $1)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        syncOptions: SyncClient.Options = .init(),
        pairingOptions: SyncClient.Options = .init(timeout: .seconds(150))
    ) {
        self.vaultURL = vaultURL
        self.keyStore = keyStore
        self.deviceName = deviceName
        self.makeSyncClient = makeSyncClient
        self.now = now
        self.syncOptions = syncOptions
        self.pairingOptions = pairingOptions
    }

    public static func live(deviceName: String) -> CompanionEnvironment {
        let directory = URL.applicationSupportDirectory.appending(path: "IMM", directoryHint: .isDirectory)
        return CompanionEnvironment(
            vaultURL: directory.appending(path: "Companion.imm", directoryHint: .isDirectory),
            keyStore: KeychainCompanionKeyStore(), deviceName: deviceName)
    }
}

public enum CompanionError: Error, Equatable, Sendable, LocalizedError {
    /// An action needed the open vault.
    case locked

    public var errorDescription: String? {
        String(localized: "IMM is locked. Unlock it first.", bundle: .module)
    }
}

/// The Mac's address, stored in the vault's `sync_secret` table (encrypted with the vault, deleted with it) under
/// ``secretName`` as JSON, so a locked phone leaks neither the Tailscale address nor the Mac's name.
struct CompanionHub: Codable, Sendable, Equatable {
    static let secretName = "companion.hub"
    var host: String
    var port: UInt16
    var macName: String

    static func load(from session: CompanionSession) throws -> CompanionHub? {
        try session.engine.secrets.read(secretName).flatMap { try? JSONDecoder().decode(CompanionHub.self, from: $0) }
    }

    /// After pairing: the Mac's name from the QR payload, else the hub's roster entry from the grant, stored with the address.
    static func store(in session: CompanionSession, host: String, port: UInt16, invitedName: String?) throws -> CompanionHub {
        let secrets = session.engine.secrets
        let rosterName = try secrets.readInt(SyncSecretName.hubNode)
            .flatMap { try secrets.device(node: UInt64(bitPattern: $0))?.name }
        let name = [invitedName, rosterName].lazy.compactMap { $0 }.first { !$0.isEmpty }
        let hub = CompanionHub(host: host, port: port, macName: name ?? CompanionMessages.yourMac)
        try secrets.write(secretName, try JSONEncoder().encode(hub))
        return hub
    }
}

/// An open vault with the ledger, engine and client on it.
struct CompanionSession: Sendable {
    let vault: UnlockedVault
    let store: LedgerStore
    let engine: SyncEngine
    let client: SyncClient
}

private enum CodeDecision { case match, mismatch, cancelled }

private struct CodesDidNotMatch: Error {}

private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: work).value
}

@MainActor @Observable
public final class CompanionModel {
    public enum Phase: Sendable, Equatable { case welcome, pairing(CompanionPairingStep), locked, ready }

    public private(set) var phase: Phase = .welcome
    public private(set) var syncStatus: CompanionSyncStatus = .idle
    public private(set) var macName: String?
    public private(set) var overview: CompanionOverview?
    public private(set) var accounts: [CompanionAccount] = []
    public private(set) var categories: [CompanionCategory] = []
    /// Why the last `unlock()` failed (nil after a success or when the user dismissed Face ID).
    public private(set) var unlockError: String?

    @ObservationIgnored private let environment: CompanionEnvironment
    @ObservationIgnored private var session: CompanionSession?
    @ObservationIgnored private var hub: CompanionHub?
    /// The vault created for a pairing that has not finished.
    @ObservationIgnored private var pairingSession: CompanionSession?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var teardownTask: Task<Void, Never>?
    @ObservationIgnored private var codeDecision: CheckedContinuation<CodeDecision, Never>?
    /// Changes whenever the open session changes, so a sync run of a closed session does not block the next one.
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var syncingGeneration: Int?
    @ObservationIgnored private var syncRequested = false
    @ObservationIgnored private var isUnlocking = false
    @ObservationIgnored private var previewContent: CompanionPreviewContent?

    public init(environment: CompanionEnvironment) {
        self.environment = environment
    }

    /// Canned state for previews and screenshots; performs no I/O.
    init(previewing content: CompanionPreviewContent) {
        environment = CompanionEnvironment(
            vaultURL: URL(fileURLWithPath: "/dev/null/Companion.imm"), keyStore: PreviewKeyStore(), deviceName: "iPhone")
        previewContent = content
        apply(preview: content)
    }

    // MARK: Lifecycle

    /// Decides what to show: no vault and no key → welcome; both → locked (the app then calls `unlock()`). A vault without
    /// its key (device passcode removed) or a key without a vault cannot be used any more; both are cleared.
    public func start() async {
        guard previewContent == nil, session == nil, pairingTask == nil else { return }
        guard phase == .welcome || phase == .locked else { return }
        await teardownTask?.value
        let url = environment.vaultURL
        let hasVault = FileManager.default.fileExists(atPath: url.path)
        let hasKey = environment.keyStore.hasKey()
        switch (hasVault, hasKey) {
        case (true, true):
            phase = .locked
        case (true, false):
            try? await offMain { try FileManager.default.removeItem(at: url) }
            phase = .welcome
        case (false, true):
            environment.keyStore.deleteKey()
            phase = .welcome
        case (false, false):
            phase = .welcome
        }
    }

    /// Face ID / passcode → opens the vault → `.ready`, then syncs. A dismissed prompt leaves the phone `.locked`.
    public func unlock() async {
        if let previewContent {
            apply(preview: previewContent)
            return
        }
        guard phase == .locked, !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        unlockError = nil
        do {
            let password = try await environment.keyStore.readKey(reason: String(localized: "Unlock your IMM data", bundle: .module))
            let opened = try await openSession(create: false, password: password)
            let loaded: (hub: CompanionHub?, data: CompanionData)
            do {
                let hub = try await offMain { try CompanionHub.load(from: opened) }
                loaded = (hub, try await opened.store.database.read { try CompanionQueries.load($0) })
            } catch {
                opened.vault.lock()
                throw error
            }
            guard phase == .locked else {
                opened.vault.lock()
                return
            }
            session = opened
            sessionGeneration += 1
            hub = loaded.hub
            macName = loaded.hub?.macName
            apply(loaded.data)
            syncStatus = .idle
            phase = .ready
        } catch {
            unlockError = CompanionMessages.unlock(error)
            return
        }
        await syncNow()
    }

    /// Closes the vault and drops everything read from it.
    public func lock() {
        guard phase == .ready else { return }
        let opened = session
        session = nil
        sessionGeneration += 1
        hub = nil
        opened?.vault.lock()
        clearData()
        syncStatus = .idle
        phase = .locked
    }

    // MARK: Pairing

    public func startPairing() {
        switch phase {
        case .welcome, .pairing(.failed): phase = .pairing(.scanning)
        default: break
        }
    }

    /// `payload` is the QR text from the Mac (`PairingInvite` JSON). Returns when the pairing has finished or failed.
    public func handleScanned(_ payload: String) async {
        guard case .pairing(.scanning) = phase else { return }
        let invite: PairingInvite
        do {
            invite = try PairingInvite(parsing: payload)
        } catch {
            phase = .pairing(.failed(message: String(localized: "That is not an IMM pairing code. Scan the QR code on your Mac.", bundle: .module)))
            return
        }
        if let expiry = invite.expiry, expiry < environment.now() {
            phase = .pairing(.failed(message: String(localized: "This pairing code has expired. Show a new one on your Mac.", bundle: .module)))
            return
        }
        guard let host = invite.host, let port = invite.port, invite.agentKey != nil else {
            phase = .pairing(.failed(message: String(localized: "This code does not say where your Mac is. Scan the QR code, not the typed code.", bundle: .module)))
            return
        }
        phase = .pairing(.connecting(macName: invite.hubName))
        let task = Task { await self.runPairing(invite: invite, host: host, port: port) }
        pairingTask = task
        await task.value
    }

    /// The user tapped "Codes match"; the Mac's user confirms there.
    public func confirmCodesMatch() {
        guard case .pairing(.confirm(_, let name)) = phase else { return }
        phase = .pairing(.waitingForMac(macName: name))
        resolveCode(.match)
    }

    /// The user tapped "Codes don't match".
    public func rejectCodes() {
        guard case .pairing(.confirm) = phase else { return }
        phase = .pairing(.failed(message: CompanionMessages.codesMismatch))
        resolveCode(.mismatch)
    }

    /// Stops the pairing. A vault and key created for it are deleted once the pairing task has ended.
    public func cancelPairing() {
        guard case .pairing = phase else { return }
        let task = pairingTask
        pairingTask = nil
        task?.cancel()
        resolveCode(.cancelled)
        phase = session == nil ? .welcome : .ready
        guard session == nil, previewContent == nil, let task else { return }
        teardownTask = Task {
            await task.value
            await self.discard(self.pairingSession)
            self.pairingSession = nil
        }
    }

    private func runPairing(invite: PairingInvite, host: String, port: UInt16) async {
        await teardownTask?.value
        teardownTask = nil
        guard !Task.isCancelled else { return }
        let invitedName = invite.hubName.flatMap { $0.isEmpty ? nil : $0 }

        let created: CompanionSession
        do {
            let password = try environment.keyStore.createKey()
            created = try await openSession(create: true, password: password)
        } catch {
            guard !Task.isCancelled else { return }
            await failPairing(CompanionMessages.setup(error))
            return
        }
        pairingSession = created
        guard !Task.isCancelled else { return }

        do {
            _ = try await created.client.pair(invite: invite, host: host, port: port, options: environment.pairingOptions) { [weak self] code in
                guard let self else { throw CancellationError() }
                try await self.askToConfirm(code, macName: invitedName)
            }
            try Task.checkCancellation()
            let endpoint = try await offMain { try CompanionHub.store(in: created, host: host, port: port, invitedName: invitedName) }
            let data = try await created.store.database.read { try CompanionQueries.load($0) }
            try Task.checkCancellation()
            session = created
            sessionGeneration += 1
            pairingSession = nil
            pairingTask = nil
            hub = endpoint
            macName = endpoint.macName
            apply(data)
            syncStatus = .synced(at: environment.now())
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            await failPairing(CompanionMessages.pairing(error))
        }
    }

    private func askToConfirm(_ code: ShortAuthCode, macName: String?) async throws {
        try Task.checkCancellation()
        phase = .pairing(.confirm(code: code, macName: macName ?? CompanionMessages.yourMac))
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<CodeDecision, Never>) in
            codeDecision = continuation
        }
        switch decision {
        case .match: return
        case .mismatch: throw CodesDidNotMatch()
        case .cancelled: throw CancellationError()
        }
    }

    private func resolveCode(_ decision: CodeDecision) {
        codeDecision?.resume(returning: decision)
        codeDecision = nil
    }

    /// Follows the client's events: the grant arrived, the snapshot is being applied.
    private func follow(_ event: SyncClientEvent) {
        guard case .pairing(.waitingForMac) = phase else { return }
        switch event {
        case .paired, .bootstrapped: phase = .pairing(.importing)
        default: break
        }
    }

    private func failPairing(_ message: String) async {
        phase = .pairing(.failed(message: message))
        let discarded = pairingSession
        pairingSession = nil
        pairingTask = nil
        await discard(discarded)
    }

    /// Removes a vault and key that never finished pairing.
    private func discard(_ session: CompanionSession?) async {
        environment.keyStore.deleteKey()
        let url = environment.vaultURL
        try? await offMain {
            session?.vault.lock()
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Sync and data

    /// One sync run with the Mac (at the address stored at pairing), then reloads the figures. Calls that arrive during a
    /// run are folded into one more run afterwards, so an edit made mid-sync still gets pushed.
    public func syncNow() async {
        if previewContent != nil {
            syncStatus = .synced(at: environment.now())
            return
        }
        guard phase == .ready, session != nil, hub != nil else { return }
        let generation = sessionGeneration
        if syncingGeneration == generation {
            syncRequested = true
            return
        }
        syncingGeneration = generation
        defer { if syncingGeneration == generation { syncingGeneration = nil } }
        repeat {
            syncRequested = false
            guard phase == .ready, sessionGeneration == generation, let session, let hub else { return }
            await syncOnce(session, hub: hub)
        } while syncRequested && sessionGeneration == generation
    }

    private func syncOnce(_ opened: CompanionSession, hub: CompanionHub) async {
        syncStatus = .syncing
        let outcome: Result<SyncReport, Error>
        do {
            outcome = .success(try await opened.client.sync(host: hub.host, port: hub.port, options: environment.syncOptions))
        } catch {
            outcome = .failure(error)
        }
        guard isCurrent(opened) else { return }
        await reload()
        guard isCurrent(opened) else { return }
        switch outcome {
        case .success(let report):
            syncStatus = report.hubLocked ? .macLocked(at: environment.now()) : .synced(at: environment.now())
        case .failure(let error):
            syncStatus = error is CancellationError ? .idle : CompanionMessages.syncStatus(for: error)
        }
    }

    /// Bookings newest first, at most 500; `search` matches payee, purpose, note and category name.
    public func transactions(accountID: String?, search: String) async -> [CompanionTransaction] {
        if let previewContent { return previewContent.transactions(accountID: accountID, search: search) }
        guard let session else { return [] }
        return (try? await session.store.database.read { try CompanionQueries.transactions($0, accountID: accountID, search: search) }) ?? []
    }

    public func detail(transactionID: String) async -> CompanionTransactionDetail? {
        if let previewContent { return previewContent.detail(transactionID: transactionID) }
        guard let session else { return nil }
        return try? await session.store.database.read { try CompanionQueries.detail($0, transactionID: transactionID) }
    }

    /// Files the booking under `categoryID` (nil: uncategorised) in the local ledger, then pushes it to the Mac.
    public func setCategory(_ categoryID: String?, transactionID: String) async throws {
        if previewContent != nil {
            previewContent?.setCategory(categoryID, transactionID: transactionID)
            refreshPreview()
            return
        }
        guard let session else { throw CompanionError.locked }
        try await offMain { try session.store.writer.setCategory(transactionID: transactionID, categoryID: categoryID) }
        await reload()
        pushInBackground()
    }

    /// Stores the note (empty: removes it) in the local ledger, then pushes it to the Mac.
    public func setNote(_ note: String, transactionID: String) async throws {
        if previewContent != nil {
            previewContent?.setNote(note, transactionID: transactionID)
            refreshPreview()
            return
        }
        guard let session else { throw CompanionError.locked }
        try await offMain { try session.store.writer.setNote(transactionID: transactionID, note: note) }
        await reload()
        pushInBackground()
    }

    /// Locks, deletes the vault directory (ledger, sync keys and group, roster and the Mac's address live inside it) and the
    /// Keychain key.
    public func unpair() async {
        let task = pairingTask
        pairingTask = nil
        task?.cancel()
        resolveCode(.cancelled)
        await task?.value
        await teardownTask?.value
        teardownTask = nil

        let opened = session
        session = nil
        sessionGeneration += 1
        hub = nil
        opened?.vault.lock()
        clearData()
        macName = nil
        syncStatus = .idle
        unlockError = nil
        if previewContent == nil {
            await discard(pairingSession)
            pairingSession = nil
        }
        phase = .welcome
    }

    // MARK: Internals

    private func pushInBackground() {
        guard hub != nil else { return }
        Task { await self.syncNow() }
    }

    private func isCurrent(_ candidate: CompanionSession) -> Bool {
        session?.vault === candidate.vault
    }

    private func reload() async {
        guard let opened = session else { return }
        guard let data = try? await opened.store.database.read({ try CompanionQueries.load($0) }) else { return }
        guard isCurrent(opened) else { return }
        apply(data)
    }

    private func apply(_ data: CompanionData) {
        overview = data.overview
        accounts = data.accounts
        categories = data.categories
    }

    private func clearData() {
        overview = nil
        accounts = []
        categories = []
    }

    private func openSession(create: Bool, password: String) async throws -> CompanionSession {
        let url = environment.vaultURL
        let deviceName = environment.deviceName
        let makeClient = environment.makeSyncClient
        let log: @Sendable (SyncClientEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.follow(event) }
        }
        return try await offMain {
            let vault = create ? try Vault.create(at: url, password: password) : try Vault.open(at: url, password: password)
            do {
                let store = try LedgerStore(database: vault.database)
                let engine = try SyncEngine(ledger: store, deviceName: deviceName)
                return CompanionSession(vault: vault, store: store, engine: engine, client: makeClient(engine, log))
            } catch {
                vault.lock()
                throw error
            }
        }
    }

    // MARK: Preview support

    private func apply(preview content: CompanionPreviewContent) {
        phase = content.phase
        syncStatus = content.syncStatus
        macName = content.macName
        overview = content.overview
        accounts = content.accounts
        categories = content.categories
    }

    private func refreshPreview() {
        guard let previewContent, var current = overview else { return }
        current.recent = Array(previewContent.transactions(accountID: nil, search: "").prefix(CompanionQueries.recentCount))
        current.uncategorisedCount = previewContent.uncategorisedCount
        overview = current
    }
}

/// User-facing sentences for the failures the phone can run into.
enum CompanionMessages {
    static var yourMac: String { String(localized: "your Mac", bundle: .module) }
    static var codesMismatch: String { String(localized: "The codes did not match. Pairing was cancelled.", bundle: .module) }
    static var unreachable: String { String(localized: "Can't reach your Mac. Is Tailscale on?", bundle: .module) }

    /// No route to the Mac: connection failures, a Mac that closed or never answered, no Tailscale on the Mac.
    static func isUnreachable(_ error: Error) -> Bool {
        if error is NWConnectionStreamError || error is ByteStreamError || error is URLError || error is POSIXError { return true }
        switch error as? SyncError {
        case .timedOut?, .noTailscale?, .agentUnavailable?: return true
        default: return false
        }
    }

    static func syncStatus(for error: Error) -> CompanionSyncStatus {
        if isUnreachable(error) { return .unreachable(message: unreachable) }
        switch error {
        case SyncError.notPaired:
            return .failed(message: String(localized: "This iPhone is not paired with a Mac.", bundle: .module))
        case SyncError.unknownDevice, SyncError.pairingRejected, NoiseSessionError.peerNotAllowed:
            return .failed(message: String(localized: "Your Mac no longer knows this iPhone. Unpair and pair again.", bundle: .module))
        case NoiseSessionError.pinMismatch:
            return .failed(message: String(localized: "The Mac that answered is not the one you paired with.", bundle: .module))
        default:
            return .failed(message: String(localized: "Sync failed. Try again in a moment.", bundle: .module))
        }
    }

    static func pairing(_ error: Error) -> String {
        switch error {
        case is CodesDidNotMatch, SyncError.pairingCodeMismatch:
            return codesMismatch
        case SyncError.pairingRejected:
            return String(localized: "Your Mac rejected the pairing. Try again with a new code.", bundle: .module)
        case SyncError.pairingNotActive:
            return String(localized: "This pairing code is no longer active. Show a new one on your Mac.", bundle: .module)
        case SyncError.invalidInvite:
            return String(localized: "That is not an IMM pairing code. Scan the QR code on your Mac.", bundle: .module)
        case SyncError.snapshotFailed(let text):
            return text
        case SyncError.protocolViolation:
            return String(localized: "Your Mac closed the connection before the pairing finished. Show a new code and try again.", bundle: .module)
        case NoiseSessionError.pinMismatch:
            return String(localized: "The Mac that answered does not match this code. Scan a fresh code.", bundle: .module)
        case is NoiseSessionError:
            return String(localized: "The pairing code is wrong or has expired. Show a new one on your Mac.", bundle: .module)
        case SyncError.timedOut:
            return String(localized: "Your Mac did not answer in time. Make sure IMM is open and unlocked there, then try again.", bundle: .module)
        case ByteStreamError.closed:
            return String(localized: "Your Mac closed the connection. Show a new code and try again.", bundle: .module)
        default:
            if isUnreachable(error) {
                return String(localized: "Can't reach your Mac. Make sure Tailscale is on, on this iPhone and on your Mac, and that IMM is open there.", bundle: .module)
            }
            return String(localized: "Pairing failed. Try again.", bundle: .module)
        }
    }

    /// Creating the key or the vault failed.
    static func setup(_ error: Error) -> String {
        if error is CompanionKeyStoreError {
            return String(localized: "Could not create the device key. IMM needs a device passcode to protect your data.", bundle: .module)
        }
        return String(localized: "Could not set up secure storage on this iPhone.", bundle: .module)
    }

    /// nil when the user simply dismissed Face ID / passcode.
    static func unlock(_ error: Error) -> String? {
        switch error as? CompanionKeyStoreError {
        case .cancelled?: return nil
        case .notFound?:
            return String(localized: "The device key is gone, for example because the device passcode was removed. Unpair and pair again.", bundle: .module)
        default:
            return String(localized: "Could not unlock your data. Try again.", bundle: .module)
        }
    }
}
