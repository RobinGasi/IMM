import Foundation
import IMMBanking
import IMMLedger
import Testing
@testable import IMMFinTS

// MARK: - Fakes and fixtures

/// A bank client with canned answers that records what the connector asked for.
private actor FakeBankClient: FinTSBankClient {
    private let accountList: [FinTSSEPAAccount]
    private let balances: [String: FinTSBalance]
    private let entries: [String: [StatementEntry]]
    private let tanName: String?
    private let accountsError: FinTSError?
    private let balanceErrors: [String: FinTSError]

    private(set) var calls: [String] = []
    private(set) var statementStarts: [LocalDate] = []
    private(set) var closeCount = 0

    init(accounts: [FinTSSEPAAccount], balances: [String: FinTSBalance] = [:], entries: [String: [StatementEntry]] = [:],
         tanName: String? = "pushTAN 2.0", accountsError: FinTSError? = nil, balanceErrors: [String: FinTSError] = [:]) {
        self.accountList = accounts
        self.balances = balances
        self.entries = entries
        self.tanName = tanName
        self.accountsError = accountsError
        self.balanceErrors = balanceErrors
    }

    func tanMethodName() async -> String? { tanName }

    func accounts(onApproval: @Sendable (ApprovalState) -> Void) async throws -> [FinTSSEPAAccount] {
        calls.append("accounts")
        if let accountsError { throw accountsError }
        return accountList
    }

    func balance(of account: FinTSSEPAAccount, onApproval: @Sendable (ApprovalState) -> Void) async throws -> FinTSBalance {
        calls.append("balance:\(account.accountNumber)")
        if let error = balanceErrors[account.accountNumber] { throw error }
        return balances[account.accountNumber]
            ?? FinTSBalance(booked: 0, currency: account.currency, date: LocalDate(year: 2026, month: 11, day: 15))
    }

    func statements(of account: FinTSSEPAAccount, from: LocalDate,
                    onApproval: @Sendable (ApprovalState) -> Void) async throws -> [StatementEntry] {
        calls.append("statements:\(account.accountNumber)")
        statementStarts.append(from)
        return entries[account.accountNumber] ?? []
    }

    func close() async { closeCount += 1 }
}

private let testBank = BankDirectoryEntry(name: "Testbank", city: "Berlin", bankCode: "12030000", protocolLabel: "FinTS")

private let directory = FinTSBankDirectory(banks: [
    FinTSBankInfo(bankCode: "12030000", bic: "BYLADEM1001", name: "Testbank", city: "Berlin",
                  pinTanURL: URL(string: "https://fints.example.invalid/testbank")!),
    FinTSBankInfo(bankCode: "37050198", bic: "COLSDE33XXX", name: "Sparkasse KölnBonn", city: "Köln",
                  pinTanURL: URL(string: "https://fints.example.invalid/sparkasse")!),
])

private let giro = FinTSSEPAAccount(
    iban: "DE02 1203 0000 0000 2020 51", bic: nil, accountNumber: "202051", subaccount: nil, bankCode: "12030000",
    productName: " Girokonto ", ownerName: nil, accountType: 1)
private let savings = FinTSSEPAAccount(
    iban: "DE89370400440532013000", bic: nil, accountNumber: "532013000", subaccount: nil, bankCode: "37040044",
    productName: nil, ownerName: nil, accountType: 12)
private let card = FinTSSEPAAccount(
    iban: nil, bic: nil, accountNumber: "4111111", subaccount: nil, bankCode: "12030000", productName: "Visa Card",
    ownerName: nil, accountType: 52)
private let depot = FinTSSEPAAccount(
    iban: nil, bic: nil, accountNumber: "99887766", subaccount: "01", bankCode: "12030000", productName: "Depot",
    ownerName: nil, accountType: 33)

private func day(_ iso: String) -> LocalDate {
    guard let date = LocalDate(iso: iso) else { fatalError("bad date \(iso)") }
    return date
}

private func makeConnector(client: FakeBankClient, productID: String = "TESTPRODUCT") -> FinTSConnector {
    FinTSConnector(
        product: FinTSProduct(id: productID, version: "0.1.0"), directory: directory, stateStore: InMemoryFinTSStateStore(),
        clientFactory: { _, _ in client })
}

private func signIn(_ connector: FinTSConnector, login: String = " user ", pin: String = "12345") async throws -> BankSession {
    try await connector.signIn(
        bank: testBank, credentials: BankCredentials(loginName: login, pin: pin, tanMethod: "pushTAN"), onApproval: { _ in })
}

private func entry(
    _ date: String, _ amount: Int, name: String? = nil, purpose: String = "", text: String? = nil, code: String? = nil,
    reference: String? = nil, creditorID: String? = nil, pending: Bool = false
) -> StatementEntry {
    StatementEntry(
        bookingDate: day(date), valueDate: day(date), amount: amount, currency: "EUR", isPending: pending,
        counterpartyName: name, purpose: purpose, bookingText: text, transactionCode: code, creditorID: creditorID,
        bankReference: reference)
}

// MARK: - Tests

@Suite struct FinTSConnectorTests {
    // MARK: Basics

    @Test func identityAndPayments() async {
        let connector = makeConnector(client: FakeBankClient(accounts: []))
        #expect(connector.id == "fints")
        #expect(FinTSConnector.connectorID == "fints")
        #expect(connector.supportsPayments == false)
    }

    @Test func submitIsRefused() async throws {
        let client = FakeBankClient(accounts: [giro])
        let connector = makeConnector(client: client)
        let session = try await signIn(connector)
        let order = PaymentOrder(
            fromAccount: "x", recipient: "A", iban: "DE02120300000000202051", amount: 100, purpose: "p", execution: .now,
            instant: false)
        await #expect(throws: BankError.bankRejected(code: 0, message: "Sending money is not available yet.")) {
            try await connector.submit(order, session: session, onApproval: { _ in })
        }
    }

    @Test func searchBanksUsesTheDirectory() async throws {
        let connector = makeConnector(client: FakeBankClient(accounts: []))
        let hits = try await connector.searchBanks("sparkasse")
        #expect(hits == [BankDirectoryEntry(name: "Sparkasse KölnBonn", city: "Köln", bankCode: "37050198", protocolLabel: "FinTS")])
        #expect(try await connector.searchBanks("12030000").map(\.name) == ["Testbank"])
        #expect(try await connector.searchBanks("   ").isEmpty)
    }

    // MARK: Sign-in

    @Test func signInWithUnknownBankCodeFails() async throws {
        let client = FakeBankClient(accounts: [giro])
        let connector = makeConnector(client: client)
        let unknown = BankDirectoryEntry(name: "Nobody", city: "", bankCode: "99999999", protocolLabel: "FinTS")
        await #expect(throws: BankError.bankRejected(code: 0, message: "IMM has no FinTS address for this bank.")) {
            try await connector.signIn(
                bank: unknown, credentials: BankCredentials(loginName: "user", pin: "1", tanMethod: ""), onApproval: { _ in })
        }
        #expect(await client.calls.isEmpty)
    }

    @Test func signInWithoutProductIDFails() async throws {
        let client = FakeBankClient(accounts: [giro])
        let connector = makeConnector(client: client, productID: "  ")
        await #expect(throws: BankError.bankRejected(code: 0, message: "Bank access is not configured in this build.")) {
            try await signIn(connector)
        }
        #expect(await client.calls.isEmpty)
    }

    @Test func signInWithoutPINAsksForOneWithoutCallingTheBank() async throws {
        let client = FakeBankClient(accounts: [giro])
        let connector = makeConnector(client: client)
        await #expect(throws: BankError.pinRejected(code: 9931, attemptsLeft: nil)) { try await signIn(connector, pin: "") }
        await #expect(throws: BankError.pinRejected(code: 9931, attemptsLeft: nil)) { try await signIn(connector, login: "  ") }
        #expect(await client.calls.isEmpty)
    }

    @Test func signInFailureClosesTheClientAndMapsTheError() async throws {
        let client = FakeBankClient(accounts: [], accountsError: .pinRejected(code: 9340, message: "PIN falsch"))
        let connector = makeConnector(client: client)
        await #expect(throws: BankError.pinRejected(code: 9340, attemptsLeft: nil)) { try await signIn(connector) }
        #expect(await client.closeCount == 1)
    }

    @Test func signInKeepsTheSessionDetails() async throws {
        let client = FakeBankClient(accounts: [giro], tanName: "pushTAN 2.0")
        let connector = makeConnector(client: client)
        let session = try await signIn(connector)
        #expect(session.connectorID == "fints")
        #expect(session.loginName == "user")
        #expect(session.tanMethod == "pushTAN 2.0")
        #expect(session.bank == testBank)

        let unnamed = FakeBankClient(accounts: [giro], tanName: nil)
        let fallback = try await signIn(makeConnector(client: unnamed))
        #expect(fallback.tanMethod == "pushTAN")
    }

    @Test func unknownSessionIsRefused() async throws {
        let connector = makeConnector(client: FakeBankClient(accounts: [giro]))
        let stranger = BankSession(
            id: "nope", connectorID: "fints", bank: testBank, loginName: "user", tanMethod: "", signedInAt: Date())
        await #expect(throws: BankError.self) { try await connector.accounts(stranger) }
        await #expect(throws: BankError.self) { try await connector.fetch(stranger, accounts: [], since: Date()) }
    }

    // MARK: Accounts

    @Test func accountMapping() async throws {
        let client = FakeBankClient(
            accounts: [giro, savings, card, depot],
            balances: [
                "202051": FinTSBalance(booked: 123_456, currency: "EUR", date: day("2026-11-14"), creditLine: 50_000),
                "532013000": FinTSBalance(booked: 99_999_00, currency: "EUR", date: day("2026-11-14")),
            ])
        let connector = makeConnector(client: client)
        let session = try await signIn(connector)
        let accounts = try await connector.accounts(session)
        #expect(accounts.count == 4)

        let key = FinTSConnector.loginID(bankCode: "12030000", loginName: "user")
        #expect(accounts.allSatisfy { $0.loginKey == key })
        #expect(accounts.map(\.sortOrder) == [0, 1, 2, 3])
        #expect(accounts.allSatisfy { $0.bankName == "Testbank" && $0.statementNote == nil })
        #expect(Set(accounts.map(\.id)).count == 4)

        let g = accounts[0]
        #expect(g.id == "DE02120300000000202051")
        #expect(g.kind == .giro)
        #expect(g.name == "Girokonto")
        #expect(g.iban == "DE02120300000000202051")
        #expect(g.number == nil)
        #expect(g.subtitle == "Testbank · DE02 1203 0000 0000 2020 51")
        #expect(g.balance == 123_456)
        #expect(g.overdraftLimit == 50_000)
        #expect(g.currency == "EUR")

        let s = accounts[1]
        #expect(s.id == "DE89370400440532013000")
        #expect(s.kind == .savings)
        #expect(s.name == "Konto")
        #expect(s.balance == 99_999_00)
        #expect(s.overdraftLimit == nil)

        let c = accounts[2]
        #expect(c.id == "12030000/4111111")
        #expect(c.kind == .creditCard)
        #expect(c.iban == nil)
        #expect(c.number == "4111111")
        #expect(c.subtitle == "Testbank · 4111111")
        #expect(c.name == "Visa Card")

        let d = accounts[3]
        #expect(d.id == "12030000/99887766/01")
        #expect(d.kind == .depot)
        #expect(d.number == "99887766")
    }

    @Test func accountKindTable() {
        let expected: [(Int?, BankAccountKind)] = [
            (nil, .giro), (1, .giro), (9, .giro), (10, .savings), (19, .savings), (20, .savings), (29, .savings),
            (30, .depot), (39, .depot), (40, .giro), (50, .creditCard), (59, .creditCard), (60, .depot), (69, .depot),
            (70, .giro), (99, .giro),
        ]
        for (type, kind) in expected {
            #expect(FinTSConnector.accountKind(type) == kind, "type \(String(describing: type))")
        }
    }

    @Test func loginKeyIsStableAndHidesTheLoginName() async throws {
        let first = try await signIn(makeConnector(client: FakeBankClient(accounts: [giro])))
        let second = try await signIn(makeConnector(client: FakeBankClient(accounts: [giro])), login: "user")
        let other = try await signIn(makeConnector(client: FakeBankClient(accounts: [giro])), login: "someone")

        let connectorA = makeConnector(client: FakeBankClient(accounts: [giro]))
        let sessionA = try await signIn(connectorA)
        let keyA = try await connectorA.accounts(sessionA).first?.loginKey
        let connectorB = makeConnector(client: FakeBankClient(accounts: [giro]))
        let sessionB = try await signIn(connectorB, login: "someone")
        let keyB = try await connectorB.accounts(sessionB).first?.loginKey

        #expect(first.loginName == second.loginName)
        #expect(other.loginName == "someone")
        #expect(keyA == FinTSConnector.loginID(bankCode: "12030000", loginName: "user"))
        #expect(keyA == FinTSConnector.loginID(bankCode: "12030000", loginName: "  user "))
        #expect(keyA != keyB)
        let key = FinTSConnector.loginID(bankCode: "12030000", loginName: "user")
        #expect(key.hasPrefix("fints-12030000-"))
        #expect(key.count == "fints-12030000-".count + 10)
        #expect(!key.contains("user"))
        #expect(FinTSConnector.loginID(bankCode: "120 300 00", loginName: "user") == key)
    }

    @Test func refusedBalanceIsZeroButOtherFailuresPropagate() async throws {
        let refusing = FakeBankClient(
            accounts: [giro, card],
            balances: ["202051": FinTSBalance(booked: 500, currency: "EUR", date: day("2026-11-14"))],
            balanceErrors: ["4111111": .bankRejected(code: 9010, message: "Nicht unterstützt")])
        let first = makeConnector(client: refusing)
        let accounts = try await first.accounts(try await signIn(first))
        #expect(accounts.map(\.balance) == [500, 0])

        let locked = FakeBankClient(accounts: [giro], balanceErrors: ["202051": .pinRejected(code: 9931, message: "PIN")])
        let second = makeConnector(client: locked)
        let session = try await signIn(second)
        await #expect(throws: BankError.pinRejected(code: 9931, attemptsLeft: nil)) { try await second.accounts(session) }
    }

    // MARK: Fetch

    @Test func fetchMapsEntriesAndClosesTheClient() async throws {
        let entries: [StatementEntry] = [
            entry("2026-11-10", -1299, name: "REWE", purpose: "Einkauf", text: "Kartenzahlung", code: "106", reference: "REF1"),
            entry("2026-11-10", -250, name: "Kiosk", purpose: "Kaffee"),
            entry("2026-11-10", -250, name: "Kiosk", purpose: "Kaffee"),
            entry("2026-11-10", -100, name: "A", purpose: "one", reference: "DUP"),
            entry("2026-11-10", -200, name: "B", purpose: "two", reference: "DUP"),
            entry("2026-11-11", 250_000, name: "ACME GmbH", purpose: "Gehalt November", text: "Gutschrift", code: "053"),
            entry("2026-11-11", -4999, name: "Stadtwerke", purpose: "Strom", text: "Lastschrift", code: "005", creditorID: "DE98ZZZ09999999999"),
            entry("2026-11-11", -2000, text: "Geldautomat", code: "082", pending: true),
            entry("2026-11-11", -5000, purpose: "Miete November 2026 Wohnung Nord", text: "Dauerauftrag"),
        ]
        let client = FakeBankClient(
            accounts: [giro, savings],
            balances: ["202051": FinTSBalance(booked: 77_700, currency: "EUR", date: day("2026-11-14"))],
            entries: ["202051": entries])
        let connector = makeConnector(client: client)
        let session = try await signIn(connector)
        let since = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = try await connector.fetch(session, accounts: ["DE02120300000000202051"], since: since)

        #expect(snapshot.accounts.map(\.id) == ["DE02120300000000202051"])
        #expect(snapshot.accounts.first?.balance == 77_700)
        #expect(snapshot.standingOrders.isEmpty && snapshot.holdings.isEmpty && snapshot.depotValueHistory.isEmpty)
        #expect(await client.statementStarts == [LocalDate(since)])
        #expect(await client.calls.contains("statements:532013000") == false)
        #expect(await client.closeCount == 1)

        let transactions = snapshot.transactions
        #expect(transactions.count == 9)
        #expect(transactions.allSatisfy { $0.accountID == "DE02120300000000202051" })

        // References: unique, bank reference kept when not repeated, hash with occurrence suffix otherwise.
        let references = transactions.map(\.reference)
        #expect(Set(references).count == references.count)
        #expect(references[0] == "REF1")
        #expect(references[1].hasPrefix("FINTS-") && references[1].count == "FINTS-".count + 16)
        #expect(references[2] == references[1] + "-1")
        #expect(references[3].hasPrefix("FINTS-") && references[4].hasPrefix("FINTS-"))
        #expect(references[3] != references[4])

        // Sequence restarts each booking day and counts pending entries too.
        #expect(transactions.map(\.sequence) == [1, 2, 3, 4, 5, 1, 2, 3, 4])

        // Kinds.
        #expect(transactions.map(\.kind) == [
            .cardPayment, .transfer, .transfer, .transfer, .transfer, .salary, .directDebit, .atm, .standingOrder,
        ])

        // Field mapping.
        #expect(transactions[0].counterpartyName == "REWE" && transactions[0].shortName == "REWE")
        #expect(transactions[0].bookingText == "Kartenzahlung" && transactions[0].bookedTime == nil)
        #expect(transactions[6].creditorID == "DE98ZZZ09999999999")
        #expect(transactions[7].counterpartyName == "Geldautomat" && transactions[7].shortName == "Geldautomat")
        #expect(transactions[7].bookingText == "Geldautomat" && transactions[7].purpose == "")
        #expect(transactions[8].counterpartyName == "Dauerauftrag")
        #expect(transactions[8].shortName == "Miete November 2026 Wohnung Nord")
        #expect(transactions[1].bookingText == "")
        #expect(transactions[1].currency == "EUR")

        // Pending passes through.
        #expect(transactions.map(\.isPending) == [false, false, false, false, false, false, false, true, false])
    }

    @Test func shortNameUsesTheFirst40CharactersOfThePurpose() {
        let long = String(repeating: "x", count: 60)
        let result = FinTSConnector.transactions(from: [entry("2026-11-10", -1, purpose: long)], accountID: "a")
        #expect(result[0].shortName == String(repeating: "x", count: 40))
        #expect(result[0].counterpartyName == "")
    }

    @Test func referencesAreStableAcrossFetchesOfTheSameData() {
        let data = [
            entry("2026-11-10", -250, name: "Kiosk", purpose: "Kaffee"),
            entry("2026-11-10", -250, name: "Kiosk", purpose: "Kaffee"),
            entry("2026-11-11", -999, name: "X", purpose: "y", reference: "R1"),
        ]
        let first = FinTSConnector.transactions(from: data, accountID: "a")
        let second = FinTSConnector.transactions(from: data, accountID: "a")
        #expect(first == second)
        // Same booking in a longer window keeps its reference.
        let longer = FinTSConnector.transactions(
            from: [entry("2026-11-09", -10, name: "Z", purpose: "early")] + data, accountID: "a")
        #expect(Array(longer.dropFirst().map(\.reference)) == first.map(\.reference))
    }

    @Test func fetchEndsTheSession() async throws {
        let client = FakeBankClient(accounts: [giro])
        let connector = makeConnector(client: client)
        let session = try await signIn(connector)
        _ = try await connector.fetch(session, accounts: [], since: Date())
        #expect(await client.closeCount == 1)
        await #expect(throws: BankError.self) { try await connector.fetch(session, accounts: [], since: Date()) }
    }

    @Test func fetchFailureClosesTheClientAndMapsTheError() async throws {
        let client = FakeBankClient(accounts: [giro], balanceErrors: ["202051": .maintenance(message: "Wartung")])
        let connector = makeConnector(client: client)
        let session = try await signIn(connector)
        do {
            _ = try await connector.fetch(session, accounts: ["DE02120300000000202051"], since: Date())
            Issue.record("fetch should have thrown")
        } catch let BankError.maintenance(until) {
            #expect(until > Date())
        }
        #expect(await client.closeCount == 1)
    }

    // MARK: Kinds

    @Test func transactionKindTable() {
        let samples: [(code: String?, text: String?, amount: Int, kind: BankTransactionKind)] = [
            ("106", nil, -100, .cardPayment), ("107", "Lastschrift", -100, .cardPayment), ("111", nil, -100, .cardPayment),
            ("004", nil, -100, .directDebit), ("005", nil, -100, .directDebit), ("104", nil, -100, .directDebit),
            ("105", nil, -100, .directDebit), ("108", nil, -100, .directDebit), ("109", nil, -100, .directDebit),
            ("191", nil, -100, .directDebit),
            ("008", nil, -100, .transfer), ("009", nil, -100, .transfer), ("112", nil, -100, .transfer),
            ("116", nil, -100, .transfer), ("117", nil, -100, .transfer), ("118", nil, -100, .transfer),
            ("119", nil, -100, .transfer), ("152", nil, -100, .transfer), ("153", nil, -100, .transfer),
            ("166", nil, -100, .transfer), ("167", nil, -100, .transfer), ("168", nil, -100, .transfer),
            ("169", nil, -100, .transfer), ("192", nil, -100, .transfer),
            ("166", "Dauerauftrag", -100, .standingOrder), ("008", "SEPA-Dauerauftrag", -100, .standingOrder),
            ("051", nil, 100, .transfer), ("052", nil, 100, .transfer), ("054", nil, 100, .transfer),
            ("067", nil, 100, .transfer), ("151", nil, 100, .transfer), ("156", nil, 100, .transfer),
            ("053", nil, 100, .salary), ("053", nil, -100, .transfer), ("051", "Gehaltszahlung", 100, .salary),
            ("166", "Lohn/Gehalt", 100, .salary), ("166", "Lohn", -100, .transfer),
            ("082", nil, -100, .atm), ("083", nil, -100, .atm),
            ("805", "Zinsen", 100, .interest), ("814", "Abschluss Zinsen", 100, .interest),
            ("840", "Entgelt", -100, .transfer),
            ("093", nil, -100, .securities), ("165", nil, -100, .securities),
            ("5", nil, -100, .directDebit), ("5", "Kartenzahlung", -100, .directDebit),
            (nil, "Kartenzahlung", -100, .cardPayment), (nil, "girocard", -100, .cardPayment),
            (nil, "Lastschrift", -100, .directDebit), (nil, "Dauerauftrag", -100, .standingOrder),
            (nil, "Zinsen", 100, .interest), (nil, "Geldautomat", -100, .atm), (nil, "Wertpapierkauf", -100, .securities),
            (nil, "Rentenzahlung", 100, .salary), (nil, "Gutschrift", 100, .transfer), (nil, nil, -100, .transfer),
            ("NTRF", "Überweisung", -100, .transfer), ("999", "Lastschrift", -100, .directDebit),
        ]
        for sample in samples {
            let kind = FinTSConnector.transactionKind(code: sample.code, bookingText: sample.text, purpose: "", amount: sample.amount)
            #expect(kind == sample.kind, "code \(sample.code ?? "nil"), text \(sample.text ?? "nil"), amount \(sample.amount)")
        }
    }

    // MARK: Errors

    @Test func errorMapping() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sent = now.addingTimeInterval(-300)
        let table: [(FinTSError, BankError)] = [
            (.pinRejected(code: 9931, message: "PIN falsch"), .pinRejected(code: 9931, attemptsLeft: nil)),
            (.maintenance(message: "Wartung"), .maintenance(until: now.addingTimeInterval(3600))),
            (.transport(message: "offline", offline: true), .offline),
            (.transport(message: "TLS", offline: false), .bankRejected(code: 0, message: "Could not reach the bank: TLS")),
            (.approvalTimedOut(sentAt: sent), .approvalExpired(sentAt: sent, expiredAt: now)),
            (.bankRejected(code: 9050, message: "Teilweise fehlerhaft"), .bankRejected(code: 9050, message: "Teilweise fehlerhaft")),
            (.unsupportedTANMethods(["chipTAN manuell", "smsTAN"]),
             .bankRejected(code: 0, message: "IMM supports app approval (pushTAN) only. Your bank offers: chipTAN manuell, smsTAN.")),
            (.unknownBank(bankCode: "1"), .bankRejected(code: 0, message: "IMM has no FinTS address for this bank.")),
            (.productNotRegistered, .bankRejected(code: 0, message: "Bank access is not configured in this build.")),
            (.malformedResponse("HNHBK"), .bankRejected(code: 0, message: "The bank's answer could not be read: HNHBK")),
        ]
        for (input, expected) in table {
            #expect(FinTSConnector.bankError(for: input, now: now) == expected, "\(input)")
            #expect(FinTSConnector.map(input, now: now) as? BankError == expected, "\(input)")
        }
    }

    @Test func otherErrorsPassThroughTheMapping() {
        #expect(FinTSConnector.map(CancellationError(), now: Date()) is CancellationError)
        #expect(FinTSConnector.map(BankError.offline, now: Date()) as? BankError == .offline)
    }

    // MARK: State store

    @Test func userDefaultsStateStoreKeepsNeitherPINNorLoginName() throws {
        let suite = "dev.gasi.imm.tests.fints.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsFinTSStateStore(defaults: defaults)

        #expect(store.systemID(bankCode: "12030000", loginName: "secretlogin") == nil)
        store.setSystemID("SYS-1", bankCode: "12030000", loginName: "secretlogin")
        store.setTANMethod("921", bankCode: "12030000", loginName: "secretlogin")
        #expect(store.systemID(bankCode: "12030000", loginName: "secretlogin") == "SYS-1")
        #expect(store.tanMethod(bankCode: "12030000", loginName: "secretlogin") == "921")
        #expect(store.systemID(bankCode: "12030000", loginName: "other") == nil)
        #expect(store.systemID(bankCode: "37050198", loginName: "secretlogin") == nil)

        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("fints.") }.sorted()
        #expect(keys.count == 2)
        #expect(keys.allSatisfy { !$0.contains("secretlogin") })
        #expect(keys.contains { $0.hasPrefix("fints.systemID.12030000.") })
        #expect(keys.contains { $0.hasPrefix("fints.tanMethod.12030000.") })
    }
}
