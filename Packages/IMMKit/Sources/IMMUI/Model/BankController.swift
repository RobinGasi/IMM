import CryptoKit
import Foundation
import GRDB
import IMMBanking
import IMMLedger
import IMMVault
import Observation

/// Talks to the bank connector and writes the results into the ledger: onboarding sign-in and import,
/// "Sync", and payments. One instance lives in `AppModel.bank`; screens read its published state and
/// call its methods.
///
/// Method summary for screens:
/// - Onboarding: `searchBanks`, `selectedBank`, `signIn(bank:credentials:)` (watch `signInState`),
///   `importAccounts(since:accountIDs:storePIN:)`, `resetSignIn()`.
/// - Sync button and PIN sheet: `sync()` / `sync(newPIN:storePIN:)`; read `syncState`.
/// - Payments: `submit(_:)` drives `model.panel = .tan(…)` and `approval`; `cancelTransfer()`.
@MainActor @Observable
public final class BankController {
    public private(set) var syncState: SyncState = .idle
    /// Approval of the running payment (or sign-in); nil when none is pending.
    public private(set) var approval: ApprovalState?
    /// The bank chosen on Add bank (nil until the user presses Continue; Back clears it).
    public var selectedBank: BankDirectoryEntry?
    public private(set) var signInState: SignInState = .idle

    @ObservationIgnored let connector: any BankConnector
    @ObservationIgnored private let pinStore: any PINStore
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var pending: PendingSignIn?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var transferTask: Task<Void, Never>?

    /// What the sign-in left behind for the import step.
    private struct PendingSignIn {
        var bank: BankDirectoryEntry
        /// Includes the typed PIN, which stays here until the import writes it to the Keychain (when
        /// the user asked for that) or the sign-in is reset.
        var credentials: BankCredentials
        var session: BankSession
    }

    /// PIN used for the demo bank when none is stored (the demo connector only requires a non-empty PIN).
    static let demoPlaceholderPIN = "demo"

    public init(connector: any BankConnector, pinStore: any PINStore) {
        self.connector = connector
        self.pinStore = pinStore
    }

    /// Stops running work and forgets sign-in state. Called by `AppModel.lock`.
    func reset() {
        syncTask?.cancel()
        transferTask?.cancel()
        syncTask = nil
        transferTask = nil
        syncState = .idle
        approval = nil
        selectedBank = nil
        signInState = .idle
        pending = nil
    }

    // MARK: Onboarding

    /// Banks matching `query` (empty query lists the directory). Connector errors yield an empty list.
    public func searchBanks(_ query: String) async -> [BankDirectoryEntry] {
        (try? await connector.searchBanks(query)) ?? []
    }

    /// Signs in and loads the accounts the bank offers. `signInState` goes `.signingIn` → `.waiting` →
    /// `.confirmed`, or `.failed(message)` (the error is rethrown too).
    public func signIn(bank: BankDirectoryEntry, credentials: BankCredentials) async throws {
        pending = nil
        signInState = .signingIn
        do {
            let session = try await connector.signIn(bank: bank, credentials: credentials) { [weak self] state in
                Task { @MainActor in self?.applySignInApproval(state) }
            }
            let accounts = try await connector.accounts(session)
            pending = PendingSignIn(bank: bank, credentials: credentials, session: session)
            signInState = .confirmed(at: Date(), accounts: accounts)
        } catch {
            signInState = .failed(Self.message(for: error))
            throw error
        }
    }

    private func applySignInApproval(_ state: ApprovalState) {
        if case .waiting(let sentAt) = state, case .signingIn = signInState {
            signInState = .waiting(sentAt: sentAt)
        }
    }

    /// Back to the empty sign-in state: the credentials changed or the user went back. Forgets the
    /// session and the typed PIN.
    public func resetSignIn() {
        pending = nil
        signInState = .idle
    }

    /// Imports the accounts of the confirmed sign-in into the ledger and moves the app to `.ready`.
    ///
    /// - Parameters:
    ///   - since: oldest booking date to fetch (default: three months back).
    ///   - accountIDs: the bank accounts to import; nil imports everything the bank offers. The demo
    ///     connector ignores it and always loads the whole demo data set (all five designed accounts and
    ///     four bank logins); other connectors fetch only these accounts.
    ///   - storePIN: writes the PIN typed at sign-in to the PIN store (macOS Keychain) for the login of
    ///     the signed-in bank. The choice is made here, not at sign-in, so the checkbox can change after
    ///     the bank confirmed.
    public func importAccounts(since: Date? = nil, accountIDs: Set<String>? = nil, storePIN: Bool = false) async throws {
        guard let model, let ledger = model.ledger, let vaultID = model.currentVaultID else { throw BankControllerError.notReady }
        guard let pending else { throw BankControllerError.notSignedIn }
        let connector = self.connector
        let since = since ?? Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()

        let bankName = pending.bank.name
        let loginID: String?
        do {
            if connector.id == DemoConnector.connectorID {
                try await Task.detached(priority: .userInitiated) {
                    let bank = try DemoDataset.load()
                    try LedgerImporter.importSnapshot(bank.snapshot, profile: bank.profile, into: ledger)
                }.value
            } else {
                let session = pending.session
                try await Task.detached(priority: .userInitiated) {
                    let offered = try await connector.accounts(session).map(\.id)
                    let wanted = accountIDs.map { ids in offered.filter(ids.contains) } ?? offered
                    let snapshot = try await connector.fetch(session, accounts: wanted, since: since)
                    try LedgerImporter.importSnapshot(snapshot, profile: nil, into: ledger)
                }.value
            }
            let now = Date()
            loginID = try await ledger.database.write { db in
                try ledger.writer.markAccountsSynced(at: now, in: db)
                let logins = try BankLoginRecord.live().order(Column("created_at")).fetchAll(db)
                return (logins.first { $0.bankName == bankName } ?? logins.first)?.id
            }
        } catch {
            // The database locked (sleep, screen lock, auto-lock) while the import ran: the vault closed under it and the next write
            // failed with "SQLite error 21: out of memory", GRDB's answer to a closed connection. That is the import being
            // cancelled, not a failing database.
            if model.ledger !== ledger { throw CancellationError() }
            throw error
        }
        if storePIN, let loginID {
            try? pinStore.store(pin: pending.credentials.pin, vaultID: vaultID, loginID: LoginIdentity.uuid(for: loginID))
        }
        self.pending = nil
        selectedBank = nil
        signInState = .idle
        model.refreshStoredPINCount()
        try model.finishOnboarding()
    }

    // MARK: Sync

    /// Runs a sync of every bank login: sign in, fetch, import. Does nothing while a sync is running.
    /// `newPIN` (from the PIN sheet) replaces the PIN of logins whose PIN was rejected; with `storePIN`
    /// it is written to the Keychain after a successful sync.
    @discardableResult
    public func sync(newPIN: String? = nil, storePIN: Bool = false) -> Task<Void, Never> {
        if syncState.isSyncing, let syncTask { return syncTask }
        let task = Task<Void, Never> { @MainActor [weak self] in
            await self?.performSync(newPIN: newPIN, storePIN: storePIN)
        }
        syncTask = task
        return task
    }

    private struct LoginWork: Sendable {
        var login: BankLoginRecord
        var accounts: [AccountRecord]
        var pin: String
    }

    private enum LoginOutcome: Sendable {
        case updated(loginID: String)
        case failed(loginID: String, reason: SyncFailureReason)
    }

    private func performSync(newPIN: String?, storePIN: Bool) async {
        guard let model, let ledger = model.ledger, let vaultID = model.currentVaultID, !syncState.isSyncing else { return }
        let previousFailures = syncState.failures
        syncState = .syncing
        if model.panel == .pin { model.panel = nil }

        let connector = self.connector
        let rejectedLogins = Set(previousFailures.compactMap { failure -> String? in
            if case .pinRejected = failure.reason { return failure.loginID }
            return nil
        })
        let isDemo = connector.id == DemoConnector.connectorID

        let loaded: (logins: [BankLoginRecord], accounts: [AccountRecord])
        do {
            loaded = try await ledger.database.read { db in
                (try BankLoginRecord.live().order(Column("created_at")).fetchAll(db),
                 try AccountRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db))
            }
        } catch {
            syncState = .failed([])
            return
        }

        let work: [LoginWork] = loaded.logins.map { login in
            let own = loaded.accounts.filter { $0.bankLoginId == login.id }
            var pin = pinStore.pin(vaultID: vaultID, loginID: LoginIdentity.uuid(for: login.id)) ?? ""
            if let newPIN, rejectedLogins.isEmpty || rejectedLogins.contains(login.id) { pin = newPIN }
            if pin.isEmpty && isDemo { pin = Self.demoPlaceholderPIN }
            return LoginWork(login: login, accounts: own, pin: pin)
        }
        let since = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()

        var outcomes: [LoginOutcome] = []
        await withTaskGroup(of: LoginOutcome.self) { group in
            for item in work {
                group.addTask {
                    do {
                        let entry = BankDirectoryEntry(
                            name: item.login.bankName, city: "", bankCode: item.login.bankCode, protocolLabel: "")
                        let credentials = BankCredentials(
                            loginName: item.login.loginName, pin: item.pin, tanMethod: item.login.tanMethod)
                        let session = try await connector.signIn(bank: entry, credentials: credentials) { _ in }
                        // The connector knows accounts by its own ids, not by the ledger's.
                        let snapshot = try await connector.fetch(
                            session, accounts: item.accounts.map { $0.connectorAccountId ?? $0.id }, since: since)
                        try LedgerImporter.importSnapshot(snapshot, profile: nil, into: ledger)
                        return .updated(loginID: item.login.id)
                    } catch is CancellationError {
                        return .failed(loginID: item.login.id, reason: .offline)
                    } catch {
                        return .failed(loginID: item.login.id, reason: Self.reason(for: error))
                    }
                }
            }
            for await outcome in group { outcomes.append(outcome) }
        }
        if Task.isCancelled || model.ledger == nil { syncState = .idle; return }

        let now = Date()
        var failures: [AccountSyncFailure] = []
        var updatedLogins: [String] = []
        var failedTexts: [(accountID: String, text: String)] = []
        for item in work {
            guard let outcome = outcomes.first(where: {
                switch $0 {
                case .updated(let id), .failed(let id, _): return id == item.login.id
                }
            }) else { continue }
            switch outcome {
            case .updated:
                updatedLogins.append(item.login.id)
            case .failed(_, let reason):
                for account in item.accounts {
                    failures.append(AccountSyncFailure(
                        id: account.id, accountName: account.name, bankName: item.login.bankName,
                        loginID: item.login.id, reason: reason, failedAt: now))
                    failedTexts.append((account.id, Self.statusText(for: reason)))
                }
            }
        }

        let updated = updatedLogins
        let texts = failedTexts
        _ = try? await ledger.database.write { db in
            for loginID in updated {
                try ledger.writer.markAccountsSynced(loginID: loginID, at: now, in: db)
            }
            for item in texts {
                try ledger.writer.set(table: "account", rowID: item.accountID, values: [
                    "sync_status": .text(AccountSyncStatus.failed.rawValue), "sync_status_text": .text(item.text),
                ], in: db)
            }
        }

        if failures.isEmpty, storePIN, let newPIN {
            for loginID in rejectedLogins {
                try? pinStore.store(pin: newPIN, vaultID: vaultID, loginID: LoginIdentity.uuid(for: loginID))
            }
            model.refreshStoredPINCount()
        }
        syncState = failures.isEmpty ? .idle : .failed(failures)
    }

    private nonisolated static func reason(for error: Error) -> SyncFailureReason {
        switch error {
        case BankError.pinRejected(let code, let attemptsLeft): return .pinRejected(code: code, attemptsLeft: attemptsLeft)
        case BankError.maintenance(let until): return .maintenance(until: until)
        case BankError.offline: return .offline
        case BankError.approvalExpired: return .other("The approval request expired.")
        default: return .other(error.localizedDescription)
        }
    }

    private nonisolated static func statusText(for reason: SyncFailureReason) -> String {
        switch reason {
        case .maintenance(let until):
            let parts = Calendar.current.dateComponents([.hour, .minute], from: until)
            return String(localized: "Retry at \(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))", bundle: .module)
        case .pinRejected: return String(localized: "PIN rejected", bundle: .module)
        case .offline: return String(localized: "Offline", bundle: .module)
        case .other(let message): return message
        }
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        case BankError.pinRejected(let code, let attemptsLeft):
            return String(localized: "The bank rejected this PIN (error \(code)). \(attemptsLeft) attempts left.", bundle: .module)
        case BankError.maintenance: return String(localized: "The bank is under maintenance.", bundle: .module)
        case BankError.offline: return String(localized: "You appear to be offline.", bundle: .module)
        case BankError.approvalExpired: return String(localized: "The approval request expired.", bundle: .module)
        default: return error.localizedDescription
        }
    }

    // MARK: Payments

    /// Sends `draft` from its source account (default: the first Girokonto).
    @discardableResult
    public func submit(_ draft: TransferDraft) -> Task<Void, Never> {
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self, let model = self.model, let ledger = model.ledger else { return }
            let accountID: String?
            if let id = draft.fromAccount {
                accountID = id
            } else {
                accountID = try? await ledger.database.read { db in
                    try AccountRecord.live().filter(Column("kind") == AccountKind.giro.rawValue)
                        .order(Column("sort_order")).fetchOne(db)?.id
                }
            }
            guard let accountID else { return }
            await self.performSubmit(draft.order(fromAccount: accountID))
        }
        transferTask = task
        return task
    }

    /// Sends `order`: opens `.tan(.waiting)`, asks the connector, books the result into the ledger and
    /// ends in `.tan(.booked)`, `.tan(.expired)` or `.tan(.failed)`. The Send button, "Send a new request"
    /// and Pay invoice "Schedule" all call this.
    @discardableResult
    public func submit(_ order: PaymentOrder) -> Task<Void, Never> {
        transferTask?.cancel()
        let task = Task<Void, Never> { @MainActor [weak self] in
            await self?.performSubmit(order)
        }
        transferTask = task
        return task
    }

    /// Closes the TAN sheet and abandons the running request.
    public func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
        approval = nil
        if let panel = model?.panel, case .tan = panel { model?.panel = nil }
    }

    private func performSubmit(_ order: PaymentOrder) async {
        guard let model, let ledger = model.ledger else { return }
        let sentAt = Date()
        approval = .waiting(sentAt: sentAt)
        model.panel = .tan(.waiting(sentAt: sentAt, order: order))
        let connector = self.connector
        do {
            let session = try await makeSession(for: order.fromAccount, ledger: ledger)
            let result = try await connector.submit(order, session: session) { [weak self] state in
                Task { @MainActor in self?.applyPaymentApproval(state, order: order) }
            }
            try Task.checkCancellation()
            try await book(result, ledger: ledger)
            approval = nil
            model.panel = .tan(.booked(sentAt: sentAt, at: Date(), order: order))
        } catch is CancellationError {
            approval = nil
        } catch BankError.approvalExpired(let sentAt, let expiredAt) {
            approval = nil
            model.panel = .tan(.expired(sentAt: sentAt, expiredAt: expiredAt, order: order))
        } catch {
            approval = nil
            model.panel = .tan(.failed(message: Self.message(for: error), order: order))
        }
    }

    private func applyPaymentApproval(_ state: ApprovalState, order: PaymentOrder) {
        guard let panel = model?.panel, case .tan = panel, approval != nil else { return }
        approval = state
        if case .waiting(let sentAt) = state { model?.panel = .tan(.waiting(sentAt: sentAt, order: order)) }
    }

    private func makeSession(for accountID: String, ledger: LedgerStore) async throws -> BankSession {
        let (account, login) = try await ledger.database.read { db -> (AccountRecord?, BankLoginRecord?) in
            let account = try AccountRecord.fetchOne(db, key: accountID)
            let login = try account?.bankLoginId.flatMap { try BankLoginRecord.fetchOne(db, key: $0) }
            return (account, login)
        }
        guard let account, let login else { throw BankControllerError.unknownAccount(accountID) }
        let entry = BankDirectoryEntry(name: account.bankName, city: "", bankCode: login.bankCode, protocolLabel: "")
        return BankSession(
            id: UUID().uuidString, connectorID: connector.id, bank: entry, loginName: login.loginName,
            tanMethod: login.tanMethod, signedInAt: Date())
    }

    /// Writes a payment result into the ledger: a booked transfer becomes a `ledger_transaction` dated
    /// "today" (the ledger's clock) and changes the account balance; a scheduled payment becomes a
    /// `standing_order`.
    private func book(_ result: PaymentResult, ledger: LedgerStore) async throws {
        let today = try await ledger.database.read { try LedgerClock.today($0) }
        try LedgerImporter.book(result, into: ledger, on: today)
    }

    /// Sets observable state directly for screenshot tests of sync, sign-in and approval states.
    /// Only for preview models; the live app reaches these states through the connector.
    func setPreviewState(syncState: SyncState? = nil, signInState: SignInState? = nil,
                         approval: ApprovalState?? = nil) {
        if let syncState { self.syncState = syncState }
        if let signInState { self.signInState = signInState }
        if let approval { self.approval = approval }
    }
}

public enum BankControllerError: Error, Equatable, Sendable {
    /// No open database.
    case notReady
    /// `importAccounts` before a confirmed sign-in.
    case notSignedIn
    case unknownAccount(String)
}

/// Stable mapping from ledger `bank_login.id` strings to the UUIDs `PINStore` wants.
enum LoginIdentity {
    static func uuid(for id: String) -> UUID {
        if let uuid = UUID(uuidString: id) { return uuid }
        let digest = Array(SHA256.hash(data: Data("imm.bank-login:\(id)".utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}
