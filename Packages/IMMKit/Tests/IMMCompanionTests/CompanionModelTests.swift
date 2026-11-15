import Foundation
import GRDB
import IMMLedger
import IMMSync
import IMMSyncCore
import IMMVault
import Testing

@testable import IMMCompanion

// MARK: - Support

/// A key store in memory.
final class FakeKeyStore: CompanionKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    func hasKey() -> Bool { lock.withLock { key != nil } }

    func createKey() throws -> String {
        lock.withLock {
            let created = "key-" + UUID().uuidString
            key = created
            return created
        }
    }

    func readKey(reason: String) async throws -> String {
        try lock.withLock {
            guard let key else { throw CompanionKeyStoreError.notFound }
            return key
        }
    }

    func deleteKey() { lock.withLock { key = nil } }
}

/// A temporary directory, removed when the value goes away.
final class Scratch: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("imm-companion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var vaultURL: URL { directory.appendingPathComponent("Companion.imm", isDirectory: true) }
}

/// Known rows: two accounts, three categories, four bookings. All spending is booked today, so "spent this month" does not
/// depend on the day the test runs; the two older rows are 40 days back.
enum Fixture {
    static let today = LocalDate(Date())

    static func seed(_ store: LedgerStore) throws {
        let writer = store.writer
        try store.database.write { db in
            try writer.insert(
                AccountRecord(
                    id: "acc-giro", kind: .giro, name: "Girokonto", bankName: "Testbank", iban: "DE89370400440532013000",
                    subtitle: "Testbank · DE89 … 3000", balance: 250_000, sortOrder: 0), in: db)
            try writer.insert(
                AccountRecord(id: "acc-save", kind: .savings, name: "Tagesgeld", bankName: "Testbank", balance: 500_000, sortOrder: 1), in: db)
            try writer.insert(CategoryRecord(id: "cat-groceries", name: "Groceries", colorToken: "chart-5", kind: .expense), in: db)
            try writer.insert(CategoryRecord(id: "cat-income", name: "Income", colorToken: "credit", kind: .income), in: db)
            try writer.insert(CategoryRecord(id: "cat-rent", name: "Rent", colorToken: "chart-1", kind: .expense), in: db)
            try writer.insert(
                TransactionRecord(
                    id: "t1", accountId: "acc-giro", bookingDate: today, valueDate: today.adding(days: 1), bookingSeq: 2, amount: -4_500,
                    counterpartyName: "REWE SAGT DANKE", shortName: "REWE", bookingText: "Kartenzahlung", purpose: "Einkauf",
                    categoryId: "cat-groceries"), in: db)
            try writer.insert(
                TransactionRecord(
                    id: "t2", accountId: "acc-giro", bookingDate: today, bookingSeq: 1, amount: -80_000, counterpartyName: "Vermieter",
                    counterpartyIban: "DE02120300000000202051", bookingText: "Dauerauftrag", purpose: "Miete", categoryId: "cat-rent",
                    note: "monthly"), in: db)
            try writer.insert(
                TransactionRecord(
                    id: "t3", accountId: "acc-giro", bookingDate: today.adding(days: -40), bookingSeq: 0, amount: -1_000,
                    counterpartyName: "Cafe Bonn", purpose: "Lunch"), in: db)
            try writer.insert(
                TransactionRecord(
                    id: "t4", accountId: "acc-save", bookingDate: today.adding(days: -40), bookingSeq: 1, amount: 300_000,
                    counterpartyName: "Employer", purpose: "Salary", categoryId: "cat-income"), in: db)
        }
    }

    /// Creates a vault with the fixture at `url` and locks it again.
    static func makeVault(at url: URL, password: String) throws {
        let vault = try Vault.create(at: url, password: password)
        defer { vault.lock() }
        try seed(try LedgerStore(database: vault.database))
    }
}

@MainActor
func eventually(timeout: Duration = .seconds(30), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// The QR text of a Mac offer, pointed at the in-process agent.
func qrPayload(for offer: PairingOffer, host: String = "127.0.0.1", port: UInt16) throws -> String {
    var object = try #require(JSONSerialization.jsonObject(with: Data(offer.qrPayload.utf8)) as? [String: Any])
    object["host"] = host
    object["port"] = Int(port)
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// A pairing QR text that parses but leads nowhere.
func syntheticPayload(host: String, port: Int, expiry: Date) throws -> String {
    let object: [String: Any] = [
        "v": 1, "device": "1", "agent": Data(repeating: 7, count: 32).base64EncodedString(), "secret": PairingSecret.generate().code,
        "expiry": expiry.timeIntervalSince1970, "host": host, "port": port,
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

// MARK: - Queries

@Suite struct CompanionQueriesTests {
    private func open() throws -> (Scratch, UnlockedVault) {
        let scratch = try Scratch()
        let vault = try Vault.create(at: scratch.vaultURL, password: "pw")
        try Fixture.seed(try LedgerStore(database: vault.database))
        return (scratch, vault)
    }

    @Test func mapsOverviewAccountsAndCategories() async throws {
        let (scratch, vault) = try open()
        defer { vault.lock() }
        _ = scratch
        let data = try await vault.database.read { try CompanionQueries.load($0) }

        let overview = data.overview
        #expect(overview.netWorth == 750_000)
        #expect(overview.spentThisMonth == 84_500)
        #expect(overview.uncategorisedCount == 1)
        #expect(overview.recent.map(\.id) == ["t1", "t2", "t4", "t3"])
        let first = try #require(overview.recent.first)
        #expect(first.counterparty == "REWE")
        #expect(first.purpose == "Einkauf")
        #expect(first.amount == -4_500)
        #expect(first.currency == "EUR")
        #expect(first.categoryName == "Groceries")
        #expect(first.categoryColorToken == "chart-5")
        #expect(first.accountID == "acc-giro")
        #expect(first.bookingDate == Fixture.today)
        #expect(first.isPending == false)
        let uncategorised = try #require(overview.recent.last)
        #expect(uncategorised.categoryName == nil)
        #expect(uncategorised.categoryColorToken == nil)

        #expect(data.accounts.map(\.id) == ["acc-giro", "acc-save"])
        let giro = data.accounts[0]
        #expect(giro.name == "Girokonto")
        #expect(giro.bankName == "Testbank")
        #expect(giro.subtitle == "Testbank · DE89 … 3000")
        #expect(giro.balance == 250_000)
        #expect(giro.kind == "giro")
        let savings = data.accounts[1]
        #expect(savings.subtitle == "Testbank")
        #expect(savings.kind == "savings")

        #expect(data.categories.map(\.name) == ["Groceries", "Income", "Rent"])
        #expect(data.categories.map(\.isIncome) == [false, true, false])
        #expect(data.categories[0].colorToken == "chart-5")
    }

    @Test func listsAndSearchesTransactions() async throws {
        let (scratch, vault) = try open()
        defer { vault.lock() }
        _ = scratch
        func ids(_ accountID: String?, _ search: String) async throws -> [String] {
            try await vault.database.read { try CompanionQueries.transactions($0, accountID: accountID, search: search) }.map(\.id)
        }

        #expect(try await ids(nil, "") == ["t1", "t2", "t4", "t3"])
        #expect(try await ids("acc-giro", "") == ["t1", "t2", "t3"])
        #expect(try await ids("acc-save", "  ") == ["t4"])
        #expect(try await ids(nil, "rewe") == ["t1"])
        #expect(try await ids(nil, "MIETE") == ["t2"])
        #expect(try await ids(nil, "monthly") == ["t2"])
        #expect(try await ids(nil, "groceries einkauf") == ["t1"])
        #expect(try await ids(nil, "income") == ["t4"])
        #expect(try await ids("acc-save", "rewe").isEmpty)
        #expect(try await ids(nil, "nothing like this").isEmpty)
    }

    @Test func mapsDetail() async throws {
        let (scratch, vault) = try open()
        defer { vault.lock() }
        _ = scratch
        let rent = try #require(try await vault.database.read { try CompanionQueries.detail($0, transactionID: "t2") })
        #expect(rent.transaction.id == "t2")
        #expect(rent.transaction.counterparty == "Vermieter")
        #expect(rent.accountName == "Girokonto")
        #expect(rent.valueDate == Fixture.today)
        #expect(rent.counterpartyIBAN == "DE02120300000000202051")
        #expect(rent.bookingText == "Dauerauftrag")
        #expect(rent.note == "monthly")
        #expect(rent.categoryID == "cat-rent")

        let shop = try #require(try await vault.database.read { try CompanionQueries.detail($0, transactionID: "t1") })
        #expect(shop.valueDate == Fixture.today.adding(days: 1))
        #expect(shop.note == nil)

        let cafe = try #require(try await vault.database.read { try CompanionQueries.detail($0, transactionID: "t3") })
        #expect(cafe.bookingText == "")
        #expect(cafe.categoryID == nil)
        #expect(cafe.counterpartyIBAN == nil)

        #expect(try await vault.database.read { try CompanionQueries.detail($0, transactionID: "missing") } == nil)
    }
}

// MARK: - Model

@MainActor @Suite struct CompanionModelTests {
    private func environment(_ scratch: Scratch, keys: FakeKeyStore) -> CompanionEnvironment {
        CompanionEnvironment(vaultURL: scratch.vaultURL, keyStore: keys, deviceName: "Test iPhone")
    }

    /// A model on an existing fixture vault, unlocked.
    private func unlockedModel() async throws -> (CompanionModel, Scratch, FakeKeyStore) {
        let scratch = try Scratch()
        let keys = FakeKeyStore()
        try Fixture.makeVault(at: scratch.vaultURL, password: try keys.createKey())
        let model = CompanionModel(environment: environment(scratch, keys: keys))
        await model.start()
        await model.unlock()
        return (model, scratch, keys)
    }

    @Test func startWithoutVaultOrKeyShowsWelcome() async throws {
        let scratch = try Scratch()
        let model = CompanionModel(environment: environment(scratch, keys: FakeKeyStore()))
        await model.start()
        #expect(model.phase == .welcome)
    }

    @Test func startWithVaultAndKeyIsLocked() async throws {
        let scratch = try Scratch()
        let keys = FakeKeyStore()
        try Fixture.makeVault(at: scratch.vaultURL, password: try keys.createKey())
        let model = CompanionModel(environment: environment(scratch, keys: keys))
        await model.start()
        #expect(model.phase == .locked)
        #expect(model.overview == nil)
    }

    @Test func startClearsHalfStates() async throws {
        let vaultOnly = try Scratch()
        try Fixture.makeVault(at: vaultOnly.vaultURL, password: "lost-key")
        let keyless = FakeKeyStore()
        let model = CompanionModel(environment: environment(vaultOnly, keys: keyless))
        await model.start()
        #expect(model.phase == .welcome)
        #expect(!FileManager.default.fileExists(atPath: vaultOnly.vaultURL.path))

        let keyOnly = try Scratch()
        let keys = FakeKeyStore()
        _ = try keys.createKey()
        let other = CompanionModel(environment: environment(keyOnly, keys: keys))
        await other.start()
        #expect(other.phase == .welcome)
        #expect(!keys.hasKey())
    }

    @Test func unlockOpensTheVaultAndLoadsData() async throws {
        let (model, scratch, _) = try await unlockedModel()
        defer { withExtendedLifetime(scratch) {} }
        #expect(model.phase == .ready)
        #expect(model.overview?.netWorth == 750_000)
        #expect(model.accounts.map(\.id) == ["acc-giro", "acc-save"])
        #expect(model.categories.count == 3)
        #expect(model.unlockError == nil)
        let all = await model.transactions(accountID: nil, search: "")
        #expect(all.count == 4)
        let detail = await model.detail(transactionID: "t2")
        #expect(detail?.note == "monthly")
    }

    @Test func unlockWithoutKeyStaysLockedWithAMessage() async throws {
        let scratch = try Scratch()
        let keys = FakeKeyStore()
        try Fixture.makeVault(at: scratch.vaultURL, password: try keys.createKey())
        let model = CompanionModel(environment: environment(scratch, keys: keys))
        await model.start()
        keys.deleteKey()
        await model.unlock()
        #expect(model.phase == .locked)
        #expect(model.unlockError != nil)
    }

    @Test func lockDropsTheDataAndUnlockBringsItBack() async throws {
        let (model, scratch, _) = try await unlockedModel()
        defer { withExtendedLifetime(scratch) {} }
        model.lock()
        #expect(model.phase == .locked)
        #expect(model.overview == nil)
        #expect(model.accounts.isEmpty)
        #expect(model.categories.isEmpty)
        #expect(await model.transactions(accountID: nil, search: "").isEmpty)
        #expect(await model.detail(transactionID: "t1") == nil)
        await #expect(throws: CompanionError.locked) { try await model.setNote("x", transactionID: "t1") }

        await model.unlock()
        #expect(model.phase == .ready)
        #expect(model.accounts.count == 2)
    }

    @Test func notesPersistAcrossLockAndUnlock() async throws {
        let (model, scratch, _) = try await unlockedModel()
        defer { withExtendedLifetime(scratch) {} }
        try await model.setNote("Lunch with Sam", transactionID: "t3")
        #expect(await model.detail(transactionID: "t3")?.note == "Lunch with Sam")
        #expect(await model.transactions(accountID: nil, search: "sam").map(\.id) == ["t3"])

        model.lock()
        await model.unlock()
        #expect(await model.detail(transactionID: "t3")?.note == "Lunch with Sam")

        try await model.setNote("", transactionID: "t3")
        #expect(await model.detail(transactionID: "t3")?.note == nil)
    }

    @Test func categoriesPersistAndUpdateTheOverview() async throws {
        let (model, scratch, _) = try await unlockedModel()
        defer { withExtendedLifetime(scratch) {} }
        #expect(model.overview?.uncategorisedCount == 1)

        try await model.setCategory("cat-groceries", transactionID: "t3")
        let detail = try #require(await model.detail(transactionID: "t3"))
        #expect(detail.categoryID == "cat-groceries")
        #expect(detail.transaction.categoryName == "Groceries")
        #expect(model.overview?.uncategorisedCount == 0)
        #expect(model.overview?.recent.last?.categoryName == "Groceries")

        model.lock()
        await model.unlock()
        #expect(await model.detail(transactionID: "t3")?.categoryID == "cat-groceries")

        try await model.setCategory(nil, transactionID: "t3")
        #expect(await model.detail(transactionID: "t3")?.categoryID == nil)
        #expect(model.overview?.uncategorisedCount == 1)
    }

    @Test func unpairRemovesVaultAndKey() async throws {
        let (model, scratch, keys) = try await unlockedModel()
        #expect(FileManager.default.fileExists(atPath: scratch.vaultURL.path))
        #expect(keys.hasKey())

        await model.unpair()
        #expect(model.phase == .welcome)
        #expect(model.overview == nil)
        #expect(model.accounts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch.vaultURL.path))
        #expect(!keys.hasKey())

        await model.start()
        #expect(model.phase == .welcome)
    }

    @Test func syncNowWithoutAMacDoesNothing() async throws {
        let (model, scratch, _) = try await unlockedModel()
        defer { withExtendedLifetime(scratch) {} }
        await model.syncNow()
        #expect(model.syncStatus == .idle)
    }

    // MARK: Pairing failures

    @Test func aScannedNonInviteFails() async throws {
        let scratch = try Scratch()
        let keys = FakeKeyStore()
        let model = CompanionModel(environment: environment(scratch, keys: keys))
        await model.start()
        model.startPairing()
        #expect(model.phase == .pairing(.scanning))
        await model.handleScanned("https://example.com")
        guard case .pairing(.failed) = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
        #expect(!keys.hasKey())
        #expect(!FileManager.default.fileExists(atPath: scratch.vaultURL.path))

        model.startPairing()
        #expect(model.phase == .pairing(.scanning))
        model.cancelPairing()
        #expect(model.phase == .welcome)
    }

    @Test func anExpiredInviteFails() async throws {
        let scratch = try Scratch()
        let model = CompanionModel(environment: environment(scratch, keys: FakeKeyStore()))
        model.startPairing()
        await model.handleScanned(try syntheticPayload(host: "127.0.0.1", port: 1, expiry: Date().addingTimeInterval(-60)))
        guard case .pairing(.failed(let message)) = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
        #expect(message.contains("expired"))
    }

    @Test func anUnreachableMacFailsAndLeavesNothingBehind() async throws {
        let scratch = try Scratch()
        let keys = FakeKeyStore()
        let model = CompanionModel(environment: environment(scratch, keys: keys))
        await model.start()
        model.startPairing()
        await model.handleScanned(try syntheticPayload(host: "127.0.0.1", port: 1, expiry: Date().addingTimeInterval(120)))
        guard case .pairing(.failed(let message)) = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
        #expect(message.contains("Tailscale"))
        #expect(!keys.hasKey())
        #expect(!FileManager.default.fileExists(atPath: scratch.vaultURL.path))

        model.cancelPairing()
        #expect(model.phase == .welcome)
    }

    // MARK: Preview

    @Test func previewStatesBuild() async throws {
        for state in CompanionPreviewState.allCases {
            let model = CompanionModel.preview(state)
            switch state {
            case .welcome: #expect(model.phase == .welcome)
            case .scanning: #expect(model.phase == .pairing(.scanning))
            case .connecting: #expect(model.phase == .pairing(.connecting(macName: "Robin's MacBook")))
            case .confirm:
                guard case .pairing(.confirm(let code, let name)) = model.phase else {
                    Issue.record("confirm preview has phase \(model.phase)")
                    continue
                }
                #expect(code.formatted == "482 913")
                #expect(name == "Robin's MacBook")
            case .waitingForMac: #expect(model.phase == .pairing(.waitingForMac(macName: "Robin's MacBook")))
            case .importing: #expect(model.phase == .pairing(.importing))
            case .failed:
                guard case .pairing(.failed(let message)) = model.phase else {
                    Issue.record("failed preview has phase \(model.phase)")
                    continue
                }
                #expect(!message.isEmpty)
            case .locked: #expect(model.phase == .locked)
            case .ready:
                #expect(model.phase == .ready)
                #expect(model.macName == "Robin's MacBook")
                #expect(model.accounts.count == 4)
                #expect(model.categories.isEmpty == false)
                #expect(model.overview?.recent.count == 8)
            }
        }
    }

    @Test func previewReadyServesCannedRows() async throws {
        let model = CompanionModel.preview(.ready)
        let all = await model.transactions(accountID: nil, search: "")
        #expect(all.count == 12)
        #expect(await model.transactions(accountID: "acc-savings", search: "").count == 1)
        let rewe = await model.transactions(accountID: nil, search: "rewe")
        #expect(rewe.count == 1)
        let first = try #require(rewe.first)
        let detail = try #require(await model.detail(transactionID: first.id))
        #expect(detail.accountName == "Girokonto")

        try await model.setCategory(nil, transactionID: detail.transaction.id)
        #expect(await model.detail(transactionID: detail.transaction.id)?.categoryID == nil)
        try await model.setNote("hello", transactionID: detail.transaction.id)
        #expect(await model.detail(transactionID: detail.transaction.id)?.note == "hello")

        model.lock()
        #expect(model.phase == .locked)
        await model.unlock()
        #expect(model.phase == .ready)
    }

    @Test func previewConfirmFlow() async throws {
        let model = CompanionModel.preview(.confirm)
        model.confirmCodesMatch()
        #expect(model.phase == .pairing(.waitingForMac(macName: "Robin's MacBook")))

        let rejecting = CompanionModel.preview(.confirm)
        rejecting.rejectCodes()
        #expect(rejecting.phase == .pairing(.failed(message: "The codes did not match. Pairing was cancelled.")))
    }
}

// MARK: - Pairing with an in-process Mac

final class FakeRegistrar: AgentRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var state: AgentRegistrationStatus = .enabled

    func status() -> AgentRegistrationStatus { lock.withLock { state } }
    func register() throws { lock.withLock { state = .enabled } }
    func unregister() async throws { lock.withLock { state = .notRegistered } }
    func openApprovalSettings() {}
}

/// The Mac side: a vault with the fixture ledger, a loopback sync agent and the app's `SyncService` wired to it (the same
/// wiring as `IMMSyncTests.MacRig`, minus the demo data).
@MainActor
final class MacHub {
    let scratch: Scratch
    let vault: UnlockedVault
    let store: LedgerStore
    let server: AgentServer
    let xpc: AgentXPCService
    let service: SyncService
    let port: UInt16

    init() async throws {
        scratch = try Scratch()
        vault = try Vault.create(at: scratch.directory.appendingPathComponent("Mac.imm", isDirectory: true), password: "mac")
        store = try LedgerStore(database: vault.database)
        try Fixture.seed(store)

        server = try AgentServer(
            configuration: AgentConfiguration(
                storage: AgentStorage(groupContainer: scratch.directory.appendingPathComponent("agent", isDirectory: true)),
                binding: .loopback(port: 0), build: "test", handshakeTimeout: .seconds(60)))
        try await server.start()
        port = try #require(await server.boundPort)
        xpc = AgentXPCService(server: server, listener: .anonymous(), requirement: nil)
        xpc.resume()

        let endpoint = xpc.endpoint
        service = SyncService(
            registrar: FakeRegistrar(), defaults: UserDefaults(suiteName: "imm-companion-test-\(UUID().uuidString)")!,
            makeClient: { AgentXPCClient(listenerEndpoint: endpoint, endpoint: $0) }, bundleVersion: "1", deviceName: "Test Mac",
            resolveHost: { $0 }, requiresSigning: false, publishDelay: .milliseconds(300))
        service.start(ledger: store, vaultID: vault.vaultID)
        await service.setEnabled(true)
        let listening = await eventually {
            if case .listening = self.service.status { return true }
            return false
        }
        #expect(listening, "status \(service.status), error \(String(describing: service.lastError))")
    }

    func shutDown() async {
        service.stop()
        xpc.invalidate()
        await server.stop()
        vault.lock()
    }

    /// The Mac's user sees `code` and confirms it.
    func confirm(matching code: ShortAuthCode) async throws {
        let shown = await eventually {
            if case .confirming = self.service.pairing { return true }
            return false
        }
        #expect(shown)
        guard case .confirming(_, let macCode) = service.pairing else { throw SyncError.pairingNotActive }
        #expect(macCode.digits == code.digits)
        try await service.confirmPairing(macCode.digits)
    }

    func note(of id: String) async throws -> String? {
        try await store.database.read { try TransactionRecord.live().filter(Column("id") == id).fetchOne($0)?.note }
    }
}

@MainActor @Suite struct CompanionPairingTests {
    private func phoneEnvironment(_ scratch: Scratch, keys: FakeKeyStore) -> CompanionEnvironment {
        CompanionEnvironment(
            vaultURL: scratch.vaultURL, keyStore: keys, deviceName: "Test iPhone", syncOptions: .init(timeout: .seconds(60)),
            pairingOptions: .init(timeout: .seconds(60)))
    }

    @Test func pairsWithAnInProcessMacAndSyncsEdits() async throws {
        let mac = try await MacHub()
        let scratch = try Scratch()
        let keys = FakeKeyStore()
        let model = CompanionModel(environment: phoneEnvironment(scratch, keys: keys))
        await model.start()
        #expect(model.phase == .welcome)
        model.startPairing()

        let offer = try await mac.service.beginPairing()
        let payload = try qrPayload(for: offer, port: mac.port)
        let scan = Task { await model.handleScanned(payload) }

        let shown = await eventually {
            if case .pairing(.confirm) = model.phase { return true }
            return false
        }
        #expect(shown, "phase \(model.phase)")
        guard case .pairing(.confirm(let code, _)) = model.phase else {
            scan.cancel()
            await mac.shutDown()
            return
        }
        model.confirmCodesMatch()
        guard case .pairing(.waitingForMac) = model.phase else {
            Issue.record("expected waitingForMac, got \(model.phase)")
            await mac.shutDown()
            return
        }
        try await mac.confirm(matching: code)
        await scan.value

        #expect(model.phase == .ready)
        #expect(keys.hasKey())
        #expect(FileManager.default.fileExists(atPath: scratch.vaultURL.path))
        #expect(model.accounts.map(\.id) == ["acc-giro", "acc-save"])
        #expect(model.overview?.netWorth == 750_000)
        #expect(model.overview?.recent.map(\.id) == ["t1", "t2", "t4", "t3"])
        #expect(model.categories.count == 3)
        #expect(model.macName?.isEmpty == false)
        #expect(model.macName != CompanionMessages.yourMac)
        guard case .synced = model.syncStatus else {
            Issue.record("expected synced, got \(model.syncStatus)")
            await mac.shutDown()
            return
        }

        // An edit on the phone reaches the Mac.
        try await model.setNote("from the phone", transactionID: "t3")
        let arrived = await eventually { (try? await mac.note(of: "t3")) == "from the phone" }
        #expect(arrived)

        // Lock and unlock again: the Mac's address was kept in the vault, so the phone syncs on its own.
        let name = model.macName
        model.lock()
        #expect(model.phase == .locked)
        await model.unlock()
        #expect(model.phase == .ready)
        #expect(model.macName == name)
        guard case .synced = model.syncStatus else {
            Issue.record("expected synced after unlock, got \(model.syncStatus)")
            await mac.shutDown()
            return
        }
        #expect(await model.detail(transactionID: "t3")?.note == "from the phone")

        await model.unpair()
        #expect(model.phase == .welcome)
        #expect(!keys.hasKey())
        #expect(!FileManager.default.fileExists(atPath: scratch.vaultURL.path))
        await mac.shutDown()
    }

    @Test func rejectedCodesCancelThePairingAndCleanUp() async throws {
        let mac = try await MacHub()
        let scratch = try Scratch()
        let keys = FakeKeyStore()
        let model = CompanionModel(environment: phoneEnvironment(scratch, keys: keys))
        await model.start()
        model.startPairing()

        let offer = try await mac.service.beginPairing()
        let payload = try qrPayload(for: offer, port: mac.port)
        let scan = Task { await model.handleScanned(payload) }
        let shown = await eventually {
            if case .pairing(.confirm) = model.phase { return true }
            return false
        }
        #expect(shown, "phase \(model.phase)")

        model.rejectCodes()
        await scan.value
        #expect(model.phase == .pairing(.failed(message: "The codes did not match. Pairing was cancelled.")))
        #expect(!keys.hasKey())
        #expect(!FileManager.default.fileExists(atPath: scratch.vaultURL.path))

        model.cancelPairing()
        #expect(model.phase == .welcome)
        await mac.service.cancelPairing()
        await mac.shutDown()
    }

    @Test func cancellingWhileTheCodeIsShownCleansUp() async throws {
        let mac = try await MacHub()
        let scratch = try Scratch()
        let keys = FakeKeyStore()
        let model = CompanionModel(environment: phoneEnvironment(scratch, keys: keys))
        await model.start()
        model.startPairing()

        let offer = try await mac.service.beginPairing()
        let payload = try qrPayload(for: offer, port: mac.port)
        let scan = Task { await model.handleScanned(payload) }
        let shown = await eventually {
            if case .pairing(.confirm) = model.phase { return true }
            return false
        }
        #expect(shown, "phase \(model.phase)")

        model.cancelPairing()
        #expect(model.phase == .welcome)
        await scan.value
        let cleaned = await eventually { !keys.hasKey() && !FileManager.default.fileExists(atPath: scratch.vaultURL.path) }
        #expect(cleaned)

        await mac.service.cancelPairing()
        await mac.shutDown()
    }
}
