import Foundation
import Testing
import IMMLedger
@testable import IMMBanking

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ApprovalState] = []
    func add(_ state: ApprovalState) { lock.withLock { states.append(state) } }
    var all: [ApprovalState] { lock.withLock { states } }
}

private let sparkasse = DemoConnector.directory[0]
private let dkb = BankDirectoryEntry(name: "DKB", city: "Berlin", bankCode: "12030000", protocolLabel: "FinTS")
private let credentials = BankCredentials(loginName: "41093872", pin: "12345", tanMethod: "pushTAN — S-pushTAN app")
private let fixedNow = Date(timeIntervalSince1970: 1_794_500_000)   // 12.11.2026

private func connector(_ behaviour: DemoBankBehaviour = DemoBankBehaviour(), delay: Duration = .zero,
                       expiryDelay: Duration = .zero) -> DemoConnector {
    DemoConnector(behaviour: behaviour, delay: delay, expiryDelay: expiryDelay, timeZone: TimeZone(identifier: "Europe/Berlin")!,
                  now: { fixedNow }, bankProvider: { demoBank })
}

@Suite("Demo connector")
struct DemoConnectorTests {
    @Test func identity() {
        #expect(connector().id == "demo")
    }

    @Test func directoryHasTheFourDesignedEntries() async throws {
        let all = try await connector().searchBanks("")
        #expect(all.map(\.name) == ["Sparkasse KölnBonn", "Kreissparkasse Köln", "Sparkasse Leverkusen", "Sparkasse Gummersbach"])
        #expect(all.map(\.bankCode) == ["37050198", "37050299", "37551440", "38450000"])
        #expect(all[0].bankCodeFormatted == "370 501 98")
    }

    @Test func searchFiltersOnNameCityAndBankCode() async throws {
        let c = connector()
        #expect(try await c.searchBanks("Köln").map(\.name) == ["Sparkasse KölnBonn", "Kreissparkasse Köln"])
        #expect(try await c.searchBanks("koeln").isEmpty)
        #expect(try await c.searchBanks("KOLN").map(\.name) == ["Sparkasse KölnBonn", "Kreissparkasse Köln"])
        #expect(try await c.searchBanks("leverkusen").map(\.name) == ["Sparkasse Leverkusen"])
        #expect(try await c.searchBanks("3845").map(\.name) == ["Sparkasse Gummersbach"])
        #expect(try await c.searchBanks("370 501").map(\.name) == ["Sparkasse KölnBonn"])
        #expect(try await c.searchBanks("zzz").isEmpty)
    }

    @Test func signInReportsWaitingThenConfirmed() async throws {
        let recorder = Recorder()
        let session = try await connector().signIn(bank: sparkasse, credentials: credentials) { recorder.add($0) }
        #expect(recorder.all == [.waiting(sentAt: fixedNow), .confirmed(at: fixedNow)])
        #expect(session.connectorID == "demo")
        #expect(session.bank == sparkasse)
        #expect(session.loginName == "41093872")
    }

    @Test func anyNonEmptyLoginWorks() async throws {
        let session = try await connector().signIn(bank: sparkasse, credentials: BankCredentials(loginName: "x", pin: "y", tanMethod: "pushTAN — S-pushTAN app")) { _ in }
        #expect(session.loginName == "x")
    }

    @Test func signInHonoursTheConfiguredDelay() async throws {
        let c = connector(delay: .milliseconds(150))
        let start = ContinuousClock.now
        _ = try await c.signIn(bank: sparkasse, credentials: credentials) { _ in }
        #expect(ContinuousClock.now - start >= .milliseconds(140))
    }

    @Test func accountsOfTheSparkasseLogin() async throws {
        let c = connector()
        let session = try await c.signIn(bank: sparkasse, credentials: credentials) { _ in }
        let accounts = try await c.accounts(session)
        #expect(accounts.map(\.name) == ["Girokonto", "Tagesgeld"])
        #expect(accounts.map(\.balance) == [241_836, 1_205_000])
    }

    @Test func fetchReturnsRequestedAccountsSince() async throws {
        let c = connector()
        let session = try await c.signIn(bank: sparkasse, credentials: credentials) { _ in }
        let since = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "Europe/Berlin"),
                                                                              year: 2026, month: 11, day: 1))!
        let snapshot = try await c.fetch(session, accounts: [DemoAccountID.giro], since: since)
        #expect(snapshot.accounts.map(\.id) == [DemoAccountID.giro])
        #expect(snapshot.transactions.count == 9)
        #expect(snapshot.transactions.allSatisfy { $0.accountID == DemoAccountID.giro && $0.bookingDate >= day(2026, 11, 1) })
        #expect(snapshot.standingOrders.count == 6)
        let all = try await c.fetch(session, accounts: DemoAccountID.all, since: .distantPast)
        #expect(all == demoBank.snapshot)
    }

    @Test func depotFetchCarriesHoldingsAndHistory() async throws {
        let c = connector()
        let ing = BankDirectoryEntry(name: "ING", city: "Frankfurt", bankCode: "50010517", protocolLabel: "FinTS")
        let session = try await c.signIn(bank: ing, credentials: credentials) { _ in }
        let snapshot = try await c.fetch(session, accounts: [DemoAccountID.depot], since: .distantPast)
        #expect(snapshot.holdings.count == 4)
        #expect(!snapshot.depotValueHistory.isEmpty)
    }

    @Test func syncFailsWithPinRejectedForSparkasse() async throws {
        let behaviour = DemoBankBehaviour(sync: .succeeds)
        let c = connector(behaviour)
        let session = try await c.signIn(bank: sparkasse, credentials: credentials) { _ in }
        behaviour.sync = .fails
        await #expect(throws: BankError.pinRejected(code: 9931, attemptsLeft: 2)) {
            _ = try await c.fetch(session, accounts: [DemoAccountID.giro], since: .distantPast)
        }
        behaviour.sync = .succeeds
        _ = try await c.fetch(session, accounts: [DemoAccountID.giro], since: .distantPast)
    }

    @Test func syncFailsWithMaintenanceForDKB() async throws {
        let behaviour = DemoBankBehaviour(sync: .fails)
        let c = connector(behaviour)
        let session = try await c.signIn(bank: dkb, credentials: credentials) { _ in }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let tenOClock = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: fixedNow)!
        await #expect(throws: BankError.maintenance(until: tenOClock)) {
            _ = try await c.fetch(session, accounts: [DemoAccountID.visa], since: .distantPast)
        }
        let parts = calendar.dateComponents([.hour, .minute], from: tenOClock)
        #expect(parts.hour == 10 && parts.minute == 0)
    }

    @Test func approvalExpires() async throws {
        let behaviour = DemoBankBehaviour(approval: .expires)
        let c = connector(behaviour)
        let recorder = Recorder()
        await #expect(throws: BankError.approvalExpired(sentAt: fixedNow, expiredAt: fixedNow.addingTimeInterval(300))) {
            _ = try await c.signIn(bank: sparkasse, credentials: credentials) { recorder.add($0) }
        }
        #expect(recorder.all == [.waiting(sentAt: fixedNow)])
    }

    @Test func submitTransferBooksOnTheGirokonto() async throws {
        let c = connector()
        let session = try await c.signIn(bank: sparkasse, credentials: credentials) { _ in }
        let recorder = Recorder()
        let order = PaymentOrder(fromAccount: DemoAccountID.giro, recipient: "Jonas Weber", iban: IBAN.formatted(DemoIBANs.jonas),
                                 amount: 12_000, purpose: "Konzertkarten", execution: .now, instant: false)
        let result = try await c.submit(order, session: session) { recorder.add($0) }
        guard case .booked(let transaction) = result else { Issue.record("expected booked"); return }
        #expect(recorder.all == [.waiting(sentAt: fixedNow), .confirmed(at: fixedNow)])
        #expect(transaction.accountID == DemoAccountID.giro)
        #expect(transaction.amount == -12_000)
        #expect(transaction.counterpartyName == "Jonas Weber")
        #expect(transaction.counterpartyIBAN == DemoIBANs.jonas)
        #expect(transaction.bookingDate == day(2026, 11, 12))
        #expect(transaction.purpose == "Konzertkarten")
        #expect(transaction.kind == .transfer)
        #expect(transaction.reference.hasPrefix("DEMO-PAY-"))
    }

    @Test func submitScheduledBecomesStandingOrder() async throws {
        let c = connector()
        let session = try await c.signIn(bank: sparkasse, credentials: credentials) { _ in }
        let order = PaymentOrder(fromAccount: DemoAccountID.giro, recipient: "Jonas Weber", iban: DemoIBANs.jonas, amount: 12_000,
                                 purpose: "Konzertkarten", execution: .onDate(day(2026, 12, 2)), instant: false)
        guard case .scheduled(let standing) = try await c.submit(order, session: session, onApproval: { _ in }) else {
            Issue.record("expected scheduled"); return
        }
        #expect(standing.amount == -12_000)
        #expect(standing.rhythm == .once)
        #expect(standing.status == .scheduled)
        #expect(standing.nextExecution == day(2026, 12, 2))
        let monthly = PaymentOrder(fromAccount: DemoAccountID.giro, recipient: "Mia Hoffmann", iban: DemoIBANs.mia, amount: 4_000,
                                   purpose: "Taschengeld", execution: .standingOrder(firstExecution: day(2026, 12, 1)), instant: false)
        guard case .scheduled(let repeating) = try await c.submit(monthly, session: session, onApproval: { _ in }) else {
            Issue.record("expected scheduled"); return
        }
        #expect(repeating.rhythm == .monthly)
        #expect(repeating.dayOfMonth == 1)
        #expect(repeating.status == .active)
    }

    @Test func submitExpiresWhenApprovalExpires() async throws {
        let behaviour = DemoBankBehaviour()
        let c = connector(behaviour)
        let session = try await c.signIn(bank: sparkasse, credentials: credentials) { _ in }
        behaviour.approval = .expires
        let order = PaymentOrder(fromAccount: DemoAccountID.giro, recipient: "Jonas Weber", iban: DemoIBANs.jonas, amount: 100,
                                 purpose: "x", execution: .now, instant: false)
        await #expect(throws: BankError.approvalExpired(sentAt: fixedNow, expiredAt: fixedNow.addingTimeInterval(300))) {
            _ = try await c.submit(order, session: session) { _ in }
        }
    }

    @Test func behaviourDefaultsAndSharedInstance() {
        let b = DemoBankBehaviour()
        #expect(b.sync == .succeeds)
        #expect(b.approval == .approves)
        b.sync = .fails
        b.approval = .expires
        #expect(b.sync == .fails && b.approval == .expires)
        #expect(DemoBankBehaviour.shared === DemoBankBehaviour.shared)
    }
}
