import AppKit
import Foundation
import GRDB
import IMMBanking
import IMMLedger
import IMMVault
@testable import IMMUI
import Testing

// MARK: - World shared by ScenarioTests and FlowTests

/// Touch ID that always works and keeps the data keys in memory.
final class ScenarioBiometricStore: BiometricKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]
    private let reported: BiometryAvailability

    init(availability: BiometryAvailability = .available) { self.reported = availability }

    func availability() -> BiometryAvailability { reported }
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

final class ScenarioPINStore: PINStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String: String] = [:]
    func store(pin: String, vaultID: UUID, loginID: UUID) throws { lock.withLock { pins["\(vaultID):\(loginID)"] = pin } }
    func pin(vaultID: UUID, loginID: UUID) -> String? { lock.withLock { pins["\(vaultID):\(loginID)"] } }
    func count(vaultID: UUID) -> Int { lock.withLock { pins.keys.filter { $0.hasPrefix("\(vaultID):") }.count } }
    func removeAll(vaultID: UUID) { lock.withLock { pins = pins.filter { !$0.key.hasPrefix("\(vaultID):") } } }
}

/// Hand-advanced time source of the inactivity timer.
@MainActor
final class ScenarioClock {
    private var base = ContinuousClock.now
    var now: ContinuousClock.Instant { base }
    func advance(_ duration: Duration) { base = base.advanced(by: duration) }
}

/// The demo data set, decoded once for every connector of every world.
enum ScenarioData {
    static let bank: DemoBank = {
        do { return try DemoDataset.load() } catch { fatalError("DemoBank.json: \(error)") }
    }()
}

enum ScenarioFailure: Error, CustomStringConvertible {
    case missing(String)
    var description: String {
        switch self {
        case .missing(let what): return "missing: \(what)"
        }
    }
}

/// A real `AppModel` on a temporary directory with its own preferences, an in-memory Keychain and a
/// demo bank that answers at once (or holds approvals for an `ApprovalGate`). Nothing touches the real preferences,
/// the Keychain or `DemoBankBehaviour.shared`.
///
/// Sleep notifications are never posted by these tests: `NSWorkspace.shared.notificationCenter` is
/// process-wide, so a posted `willSleepNotification` would lock the models of other suites that run at
/// the same time (`ModelTests` covers sleep). The worlds switch "Lock when the Mac goes to sleep" off so
/// that those suites cannot lock them either.
@MainActor
final class ScenarioWorld {
    static let password = "kontor-ehrenfeld"

    let directory: URL
    let defaults: UserDefaults
    let biometrics: ScenarioBiometricStore
    let pins = ScenarioPINStore()
    let behaviour = DemoBankBehaviour()
    let clock: ScenarioClock
    let model: AppModel

    var vaultURL: URL { directory.appendingPathComponent("Moneten.imm", isDirectory: true) }

    /// With `approvals`, the demo bank holds an approval in `.waiting` when the test armed it with `approvals.holdNext()`,
    /// until the test calls `approvals.release()`: the test sees the waiting state however busy the main actor is.
    /// Approvals the test did not arm (a re-sign-in during sync) pass at once.
    init(approvals: ApprovalGate? = nil, biometry: BiometryAvailability = .available) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imm-scenario-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "dev.gasi.imm.scenario.\(UUID().uuidString)") ?? .standard
        // From the first moment, not after the import: any suite may be posting a sleep notification while this world is
        // in the middle of a flow, and a lock then closes the database under whatever the flow is doing.
        defaults.set(false, forKey: "lockOnSleep")
        let biometrics = ScenarioBiometricStore(availability: biometry)
        let clock = ScenarioClock()
        self.directory = directory
        self.defaults = defaults
        self.biometrics = biometrics
        self.clock = clock
        let behaviour = self.behaviour
        self.model = AppModel(
            biometricStore: biometrics, pinStore: pins,
            bookmarks: VaultBookmarks(defaults: defaults, securityScoped: false),
            connector: Self.connector(
                DemoConnector(
                    behaviour: behaviour, delay: .zero, expiryDelay: .milliseconds(10),
                    bankProvider: { ScenarioData.bank }),
                approvals: approvals),
            defaults: defaults, clock: { clock.now }, autoStart: false)
    }

    private static func connector(_ demo: DemoConnector, approvals: ApprovalGate?) -> any BankConnector {
        guard let approvals else { return demo }
        return GatedConnector(inner: demo, approvals: approvals)
    }

    /// A second model on the same directory, preferences and Keychain (the next launch of the app).
    func makeRelaunchedModel() -> AppModel {
        let clock = self.clock
        let behaviour = self.behaviour
        return AppModel(
            biometricStore: biometrics, pinStore: pins,
            bookmarks: VaultBookmarks(defaults: defaults, securityScoped: false),
            connector: DemoConnector(
                behaviour: behaviour, delay: .zero, expiryDelay: .milliseconds(10),
                bankProvider: { ScenarioData.bank }),
            defaults: defaults, clock: { clock.now }, autoStart: false)
    }

    /// Creates the vault (phase `.needsBank`), then signs in at Sparkasse KölnBonn and imports (phase `.ready`).
    func createReadyVault(storePIN: Bool = false) async throws {
        try await model.createVault(at: vaultURL, password: Self.password, enableTouchID: false)
        try await importDemo(storePIN: storePIN)
        model.lockOnSleep = false
    }

    func importDemo(storePIN: Bool) async throws {
        try await model.bank.signIn(
            bank: DemoConnector.directory[0],
            credentials: BankCredentials(loginName: "lena", pin: "12345678", tanMethod: "pushTAN"))
        try await model.bank.importAccounts(since: Date(), storePIN: storePIN)
    }

    /// Ledger account id by account name (`Girokonto`, `Tagesgeld`, `Visa Card`, `Depot`, `PayPal Wallet`).
    func accountID(_ name: String) async throws -> String {
        let ledger = try ledger()
        return try await ledger.database.read { db in
            guard let account = try AccountRecord.live().filter(Column("name") == name).fetchOne(db) else {
                throw ScenarioFailure.missing("account \(name)")
            }
            return account.id
        }
    }

    func balance(_ name: String) async throws -> Int {
        let ledger = try ledger()
        return try await ledger.database.read { db in
            guard let account = try AccountRecord.live().filter(Column("name") == name).fetchOne(db) else {
                throw ScenarioFailure.missing("account \(name)")
            }
            return account.balance
        }
    }

    func ledger() throws -> LedgerStore {
        guard let ledger = model.ledger else { throw ScenarioFailure.missing("open ledger") }
        return ledger
    }

    /// Waits until `condition` holds (observations and timers deliver asynchronously).
    func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    func finish() {
        model.lock(.manual)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Holds the approvals a test arms with `holdNext()` until it calls `release()`; all others pass at once.
actor ApprovalGate {
    private var armed = 0
    private var released = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// The next approval that reaches the gate waits for a `release()`.
    func holdNext() { armed += 1 }

    func release() {
        if waiters.isEmpty {
            released += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func wait() async {
        guard armed > 0 else { return }
        armed -= 1
        if released > 0 {
            released -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// The demo bank with approvals held at `.waiting` until `ApprovalGate.release()`: the inner connector answers at
/// once, its `.confirmed` is withheld and sent only after the release. Expired approvals still throw at once.
struct GatedConnector: BankConnector {
    let inner: DemoConnector
    let approvals: ApprovalGate

    var id: String { inner.id }

    func searchBanks(_ query: String) async throws -> [BankDirectoryEntry] { try await inner.searchBanks(query) }

    func signIn(
        bank: BankDirectoryEntry, credentials: BankCredentials, onApproval: @Sendable (ApprovalState) -> Void
    ) async throws -> BankSession {
        let session = try await inner.signIn(bank: bank, credentials: credentials) { state in
            if case .waiting = state { onApproval(state) }
        }
        await approvals.wait()
        onApproval(.confirmed(at: Date()))
        return session
    }

    func accounts(_ session: BankSession) async throws -> [BankAccount] { try await inner.accounts(session) }

    func fetch(_ session: BankSession, accounts: [String], since: Date) async throws -> BankSnapshot {
        try await inner.fetch(session, accounts: accounts, since: since)
    }

    func submit(
        _ order: PaymentOrder, session: BankSession, onApproval: @Sendable (ApprovalState) -> Void
    ) async throws -> PaymentResult {
        let result = try await inner.submit(order, session: session) { state in
            if case .waiting = state { onApproval(state) }
        }
        await approvals.wait()
        onApproval(.confirmed(at: Date()))
        return result
    }
}

// MARK: - Scenarios

/// The manual test scenarios 1–8 as one chained model-level path on one model: create → onboard →
/// auto-lock → unlock → inspect → transfer → sync failure → recovery → change password → relaunch.
///
/// Covered one by one elsewhere (not repeated): `CreateVaultTests` (validation copy), `OnboardingTests`
/// (search, sign-in, import, PIN count), `ModelTests` (manual lock, sleep notification, password change,
/// Touch ID), `UnlockTests`, `TransferTests` (booking, invalid IBAN), `SyncTests` (fail → PIN → succeed).
@MainActor
@Suite(.serialized) struct ScenarioTests {
    private let nbsp = "\u{00A0}"

    @Test func endToEndPath() async throws {
        // Approvals wait at `.waiting` until released, so the test sees that state however busy the main actor is.
        let approvals = ApprovalGate()
        let world = ScenarioWorld(approvals: approvals)
        let model = world.model
        defer { world.finish() }

        // 1. Create vault: the screen's rules, then the database package.
        #expect(CreateVaultRules.isTooShort("1234567"))
        #expect(!CreateVaultRules.isValid(password: "1234567", confirm: "1234567"))
        #expect(CreateVaultRules.isMismatch(password: ScenarioWorld.password, confirm: "kontor-ehrenfeldX"))
        #expect(!CreateVaultRules.isValid(password: ScenarioWorld.password, confirm: "kontor-ehrenfeldX"))
        #expect(!CreateVaultRules.canSubmit(password: "", confirm: ""))
        #expect(CreateVaultRules.isValid(password: ScenarioWorld.password, confirm: ScenarioWorld.password))
        #expect(model.phase == .noVault)

        try await model.createVault(at: world.vaultURL, password: ScenarioWorld.password, enableTouchID: false)
        #expect(model.phase == .needsBank)
        let manager = FileManager.default
        let items = try manager.contentsOfDirectory(atPath: world.vaultURL.path).filter { !$0.hasPrefix(".") }
        #expect(items.contains("vault.json"))
        #expect(items.contains("data.sqlite"))
        let header = try Data(contentsOf: world.vaultURL.appendingPathComponent("data.sqlite")).prefix(16)
        #expect(String(decoding: header, as: UTF8.self) != "SQLite format 3\u{0}")

        // 2. Add bank: the search filters, the sign-in waits for approval, then the confirmed accounts.
        #expect(await model.bank.searchBanks("").count == 4)
        let found = await model.bank.searchBanks("Köln")
        #expect(found.map(\.name) == ["Sparkasse KölnBonn", "Kreissparkasse Köln"])
        #expect(await model.bank.searchBanks("Gummersbach").map(\.name) == ["Sparkasse Gummersbach"])
        model.bank.selectedBank = found[0]
        #expect(model.bank.signInState == .idle)

        await approvals.holdNext()
        let signIn = Task { @MainActor in
            try await model.bank.signIn(
                bank: found[0],
                credentials: BankCredentials(loginName: "lena", pin: "12345678", tanMethod: "pushTAN"))
        }
        let waiting = await world.eventually {
            if case .waiting = model.bank.signInState { return true }
            return false
        }
        #expect(waiting)
        await approvals.release()
        try await signIn.value
        guard case .confirmed(_, let offered) = model.bank.signInState else {
            Issue.record("sign-in state is \(model.bank.signInState)")
            return
        }
        #expect(offered.count == 2)

        try await model.bank.importAccounts(since: Date(), storePIN: true)
        model.lockOnSleep = false
        #expect(model.phase == .ready)
        #expect(model.route == .overview)
        #expect(model.bank.signInState == .idle)
        #expect(model.storedPINCount == 1)
        let loaded = await world.eventually {
            model.sidebar.snapshot.accounts.count == 5 && model.sidebar.snapshot.netWorth == 6_305_854
        }
        #expect(loaded)
        #expect(MoneyFormatter.string(model.sidebar.snapshot.netWorth) == "63.058,54\(nbsp)€")
        #expect(model.sidebar.snapshot.newCount == 14)
        model.removeStoredPINs()
        #expect(model.storedPINCount == 0)

        // 3. Auto-lock after one idle minute: closed database, unlock screen, wrong then right password.
        model.autoLockMinutes = 1
        world.clock.advance(.seconds(61))
        let locked = await world.eventually { model.lockReason != nil }
        #expect(locked)
        #expect(model.lockReason == .inactivity(minutes: 1))
        guard case .locked(let info) = model.phase else {
            Issue.record("phase is \(model.phase)")
            return
        }
        #expect(info.displayName == "Moneten.imm")
        #expect(info.accountCount == 5)
        #expect(model.ledger == nil)

        await #expect(throws: VaultError.wrongPassword) { try await model.unlock(password: "kontor-ehrenfeld!") }
        guard case .locked = model.phase else {
            Issue.record("a wrong password must keep the unlock screen, phase is \(model.phase)")
            return
        }
        try await model.unlock(password: ScenarioWorld.password)
        #expect(model.phase == .ready)
        #expect(model.lockReason == nil)
        #expect(model.autoLockMinutes == 1)
        model.autoLockMinutes = 0

        // 4. Girokonto: REWE 11.11. in the inspector, Income shows positive rows only.
        let giro = try await world.accountID("Girokonto")
        let ledger = try world.ledger()
        model.navigate(to: .transactions(.account(giro)))
        let list = TransactionsModel(filter: TransactionFilter(scope: .account(giro)))
        let observing = Task { await list.observe(ledger) }
        defer { observing.cancel() }
        let listed = await world.eventually { list.snapshot != nil }
        #expect(listed)
        let rewe = try #require(list.snapshot?.items.first { $0.shortName == "REWE" })
        list.selection = rewe.id
        let selected = try #require(list.selectedItem)
        #expect(selected.counterpartyName == "REWE Markt GmbH")
        #expect(MoneyFormatter.string(selected.amount) == "−63,48\(nbsp)€")
        let next = try #require(list.snapshot?.items.first { $0.id != rewe.id })
        list.selection = next.id
        #expect(list.selectedItem?.id == next.id)
        list.clearSelection()
        #expect(list.selectedItem == nil)

        let income = try await ledger.database.read {
            try TransactionQueries.snapshot($0, filter: TransactionFilter(scope: .account(giro), direction: .income))
        }
        #expect(!income.items.isEmpty)
        #expect(income.items.allSatisfy { $0.amount > 0 })

        // 5. Transfer: an invalid IBAN keeps Send off; the designed transfer is approved and booked.
        var draft = TransferDraft(
            recipient: "Jonas Weber", iban: "DE89 3704 0044 0532 0130 01", amountMinor: 12_000,
            purpose: "Konzertkarten Dezember", execution: .now, instant: true)
        #expect(!draft.isSendable)
        draft.iban = "DE89 3704 0044 0532 0130 00"
        #expect(draft.isSendable)
        #expect(try await world.balance("Girokonto") == 241_836)

        model.openNewTransfer(draft)
        #expect(model.panel == .newTransfer(draft))
        await approvals.holdNext()
        let booking = model.bank.submit(draft)
        let waitingSheet = await world.eventually {
            if case .tan(.waiting)? = model.panel { return true }
            return false
        }
        #expect(waitingSheet)
        await approvals.release()
        await booking.value
        guard case .tan(.booked(_, _, let order))? = model.panel else {
            Issue.record("panel is \(String(describing: model.panel))")
            return
        }
        #expect(order.amount == 12_000)
        #expect(model.bank.approval == nil)
        #expect(try await world.balance("Girokonto") == 229_836)
        let booked = try await ledger.database.read { db in
            try TransactionRecord.live().filter(Column("account_id") == giro)
                .order(Column("booking_date").desc, Column("booking_seq").desc).fetchOne(db)
        }
        #expect(booked?.amount == -12_000)
        #expect(booked?.counterpartyName == "Jonas Weber")
        model.finishTransfer(order)
        #expect(model.panel == nil)
        #expect(model.route == .transactions(.account(giro)))

        // An unanswered approval expires: "TAN expired", nothing booked, Cancel closes the sheet.
        world.behaviour.approval = .expires
        await model.bank.submit(draft).value
        guard case .tan(.expired)? = model.panel else {
            Issue.record("panel is \(String(describing: model.panel))")
            return
        }
        #expect(try await world.balance("Girokonto") == 229_836)
        model.closePanel()
        #expect(model.panel == nil)
        world.behaviour.approval = .approves

        // 6. Sync failure: Sparkasse rejects the PIN, DKB is under maintenance; a new PIN recovers.
        world.behaviour.sync = .fails
        await model.bank.sync().value
        guard case .failed(let failures) = model.bank.syncState else {
            Issue.record("sync state is \(model.bank.syncState)")
            return
        }
        #expect(failures.count == 3)
        let banks = model.bank.syncState.byBank
        #expect(banks.map(\.bankName) == ["Sparkasse KölnBonn", "DKB"])
        #expect(banks[0].reason == .pinRejected(code: 9931, attemptsLeft: 2))
        #expect(banks[0].accountNames == ["Girokonto", "Tagesgeld"])
        if case .maintenance = banks[1].reason {} else { Issue.record("DKB reason is \(banks[1].reason)") }
        #expect(banks[1].accountNames == ["Visa Card"])
        let warned = await world.eventually { model.sidebar.snapshot.failedAccountCount == 3 }
        #expect(warned)

        model.navigate(to: .overview)
        model.panel = .pin
        world.behaviour.sync = .succeeds
        await model.bank.sync(newPIN: "87654321", storePIN: true).value
        #expect(model.bank.syncState == .idle)
        #expect(model.panel == nil)
        #expect(model.storedPINCount == 1)
        let recovered = await world.eventually { model.sidebar.snapshot.failedAccountCount == 0 }
        #expect(recovered)

        // 7. Change the password; the old one fails after the next lock, the new one opens.
        await #expect(throws: VaultError.wrongPassword) {
            try await model.changePassword(current: "not-the-password", new: "neues-passwort")
        }
        try await model.changePassword(current: ScenarioWorld.password, new: "neues-passwort")
        model.lock(.manual)
        #expect(model.lockReason == .manual)
        await #expect(throws: VaultError.wrongPassword) { try await model.unlock(password: ScenarioWorld.password) }
        try await model.unlock(password: "neues-passwort")
        #expect(model.phase == .ready)
        #expect(try await world.balance("Girokonto") == 229_836)

        // 8. The next launch remembers the database and starts on the unlock screen.
        model.lock(.manual)
        let relaunched = world.makeRelaunchedModel()
        defer { relaunched.lock(.manual) }
        relaunched.openExisting(at: world.vaultURL)
        guard case .locked(let again) = relaunched.phase else {
            Issue.record("relaunched phase is \(relaunched.phase)")
            return
        }
        #expect(again.accountCount == 5)
        try await relaunched.unlock(password: "neues-passwort")
        #expect(relaunched.phase == .ready)
    }
}
