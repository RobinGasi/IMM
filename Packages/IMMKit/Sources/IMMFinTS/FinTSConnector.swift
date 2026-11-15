import CryptoKit
import Foundation
import IMMBanking
import IMMLedger

/// Reads accounts, balances and statements from German banks over FinTS PIN/TAN. Read-only: `supportsPayments` is
/// false and `submit` never sends money.
///
/// A sign-in opens the bank dialog (including the app approval) and keeps the `FinTSBankClient` and the accounts it
/// found in a cache keyed by the session id; `accounts(_:)` and `fetch(_:accounts:since:)` reuse them. The PIN stays
/// inside the client, so a session cannot be rebuilt later: a session this connector did not create (or one that
/// `fetch` already finished and closed) is refused, and the caller signs in again.
public struct FinTSConnector: BankConnector {
    public static let connectorID = "fints"

    public typealias ClientFactory = @Sendable (FinTSEndpoint, FinTSUser) -> any FinTSBankClient

    private let product: FinTSProduct
    private let directory: FinTSBankDirectory
    private let clientFactory: ClientFactory
    private let sessions = SessionCache()

    /// - Parameter clientFactory: builds the client of one login; nil uses `FinTSClient` with `stateStore`.
    public init(product: FinTSProduct, directory: FinTSBankDirectory, stateStore: any FinTSStateStore,
                clientFactory: ClientFactory? = nil) {
        self.product = product
        self.directory = directory
        self.clientFactory = clientFactory ?? { endpoint, user in
            FinTSClient(endpoint: endpoint, user: user, product: product, stateStore: stateStore)
        }
    }

    public var id: String { Self.connectorID }
    public var supportsPayments: Bool { false }

    /// The id of the `bank_login` row for one login: stable across launches and devices, free of the raw login name.
    public static func loginID(bankCode: String, loginName: String) -> String {
        "fints-\(bankCode.filter { !$0.isWhitespace })-\(FinTSDigest.loginHash(loginName))"
    }

    // MARK: BankConnector

    public func searchBanks(_ query: String) async throws -> [BankDirectoryEntry] {
        directory.search(query).map(\.directoryEntry)
    }

    public func signIn(bank: BankDirectoryEntry, credentials: BankCredentials,
                       onApproval: @Sendable (ApprovalState) -> Void) async throws -> BankSession {
        let now = Date()
        guard !product.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Self.bankError(for: .productNotRegistered, now: now)
        }
        let loginName = credentials.loginName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same answer the bank gives for a wrong PIN, so the app opens its PIN sheet instead of calling the bank.
        guard !loginName.isEmpty, !credentials.pin.isEmpty else {
            throw BankError.pinRejected(code: 9931, attemptsLeft: nil)
        }
        guard let info = directory.bank(code: bank.bankCode) else {
            throw Self.bankError(for: .unknownBank(bankCode: bank.bankCode), now: now)
        }
        let client = clientFactory(
            FinTSEndpoint(bankCode: info.bankCode, url: info.pinTanURL),
            FinTSUser(loginName: loginName, pin: credentials.pin))
        let accounts: [FinTSSEPAAccount]
        do {
            accounts = try await client.accounts(onApproval: onApproval)
        } catch {
            await client.close()
            throw Self.map(error, now: Date())
        }
        let session = BankSession(
            id: UUID().uuidString, connectorID: id, bank: bank, loginName: loginName,
            tanMethod: await client.tanMethodName() ?? credentials.tanMethod, signedInAt: Date())
        await sessions.store(SessionCache.Entry(client: client, accounts: accounts), for: session.id)
        return session
    }

    public func accounts(_ session: BankSession) async throws -> [BankAccount] {
        let entry = try await entry(for: session)
        do {
            return try await Self.mappedAccounts(entry, session: session, only: nil).map { $0.account }
        } catch {
            throw Self.map(error, now: Date())
        }
    }

    public func fetch(_ session: BankSession, accounts ids: [String], since: Date) async throws -> BankSnapshot {
        let entry = try await entry(for: session)
        let snapshot: BankSnapshot
        do {
            let mapped = try await Self.mappedAccounts(entry, session: session, only: Set(ids))
            let from = LocalDate(since)
            var transactions: [BankTransaction] = []
            for (account, raw) in mapped {
                let statements = try await entry.client.statements(of: raw, from: from) { _ in }
                transactions += Self.transactions(from: statements, accountID: account.id)
            }
            snapshot = BankSnapshot(
                accounts: mapped.map { $0.account }, transactions: transactions, standingOrders: [], holdings: [],
                depotValueHistory: [])
        } catch {
            await sessions.release(session.id)
            throw Self.map(error, now: Date())
        }
        await sessions.release(session.id)
        return snapshot
    }

    public func submit(_ order: PaymentOrder, session: BankSession,
                       onApproval: @Sendable (ApprovalState) -> Void) async throws -> PaymentResult {
        throw BankError.bankRejected(code: 0, message: "Sending money is not available yet.")
    }

    // MARK: Sessions

    private func entry(for session: BankSession) async throws -> SessionCache.Entry {
        guard let entry = await sessions.entry(for: session.id) else {
            throw BankError.bankRejected(code: 0, message: "The bank session has ended. Sign in again.")
        }
        return entry
    }

    private actor SessionCache {
        struct Entry: Sendable {
            var client: any FinTSBankClient
            var accounts: [FinTSSEPAAccount]
        }

        private var entries: [String: Entry] = [:]

        func store(_ entry: Entry, for id: String) { entries[id] = entry }
        func entry(for id: String) -> Entry? { entries[id] }

        /// Forgets the session and ends its bank dialog.
        func release(_ id: String) async {
            guard let entry = entries.removeValue(forKey: id) else { return }
            await entry.client.close()
        }
    }

    // MARK: Errors

    /// `FinTSError` becomes the `BankError` the app shows; every other error passes through unchanged.
    static func map(_ error: Error, now: Date) -> Error {
        guard let error = error as? FinTSError else { return error }
        return bankError(for: error, now: now)
    }

    static func bankError(for error: FinTSError, now: Date) -> BankError {
        switch error {
        case .pinRejected(let code, _):
            return .pinRejected(code: code, attemptsLeft: nil)
        case .maintenance:
            return .maintenance(until: now.addingTimeInterval(3600))
        case .transport(_, offline: true):
            return .offline
        case .approvalTimedOut(let sentAt):
            return .approvalExpired(sentAt: sentAt, expiredAt: now)
        case .bankRejected(let code, let message):
            return .bankRejected(code: code, message: message)
        case .unsupportedTANMethods(let names):
            let offered = names.isEmpty ? "none that IMM can use" : names.joined(separator: ", ")
            return .bankRejected(
                code: 0, message: "IMM supports app approval (pushTAN) only. Your bank offers: \(offered).")
        case .unknownBank:
            return .bankRejected(code: 0, message: "IMM has no FinTS address for this bank.")
        case .productNotRegistered:
            return .bankRejected(code: 0, message: "Bank access is not configured in this build.")
        case .transport(let message, _):
            return .bankRejected(code: 0, message: "Could not reach the bank: \(message)")
        case .malformedResponse(let detail):
            return .bankRejected(code: 0, message: "The bank's answer could not be read: \(detail)")
        }
    }

    // MARK: Accounts

    /// The accounts of the login with fresh balances, in the bank's order. `only` keeps the listed connector ids
    /// (sort order stays the position among all accounts).
    private static func mappedAccounts(
        _ entry: SessionCache.Entry, session: BankSession, only wanted: Set<String>?
    ) async throws -> [(account: BankAccount, raw: FinTSSEPAAccount)] {
        let loginKey = loginID(bankCode: session.bank.bankCode, loginName: session.loginName)
        var result: [(account: BankAccount, raw: FinTSSEPAAccount)] = []
        for (index, raw) in entry.accounts.enumerated() {
            let id = accountID(raw)
            if let wanted, !wanted.contains(id) { continue }
            let balance: FinTSBalance?
            do {
                balance = try await entry.client.balance(of: raw) { _ in }
            } catch FinTSError.bankRejected {
                // Some accounts (cards, depots, loans) refuse HKSAL: show them with a zero balance.
                balance = nil
            }
            result.append((account(raw, id: id, balance: balance, session: session, loginKey: loginKey, sortOrder: index), raw))
        }
        return result
    }

    /// The connector's account id: unique per login and stable across sign-ins.
    static func accountID(_ account: FinTSSEPAAccount) -> String {
        if let iban = account.iban.map(IBAN.normalized), !iban.isEmpty { return iban }
        var id = "\(account.bankCode)/\(account.accountNumber)"
        if let sub = account.subaccount?.trimmingCharacters(in: .whitespaces), !sub.isEmpty { id += "/\(sub)" }
        return id
    }

    static func accountKind(_ type: Int?) -> BankAccountKind {
        guard let type else { return .giro }
        switch type {
        case 10...29: return .savings
        case 30...39, 60...69: return .depot
        case 50...59: return .creditCard
        default: return .giro
        }
    }

    private static func account(
        _ raw: FinTSSEPAAccount, id: String, balance: FinTSBalance?, session: BankSession, loginKey: String, sortOrder: Int
    ) -> BankAccount {
        let iban = raw.iban.map(IBAN.normalized).flatMap { $0.isEmpty ? nil : $0 }
        let number = iban == nil ? raw.accountNumber : nil
        let name = raw.productName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Konto"
        let identifier = iban.map(IBAN.formatted) ?? raw.accountNumber
        return BankAccount(
            id: id, kind: accountKind(raw.accountType), name: name, bankName: session.bank.name, iban: iban, number: number,
            subtitle: "\(session.bank.name) · \(identifier)", balance: balance?.booked ?? 0, currency: raw.currency,
            overdraftLimit: balance?.creditLine, statementNote: nil, loginKey: loginKey, sortOrder: sortOrder)
    }

    // MARK: Transactions

    /// Maps the entries of one account, in delivery order.
    ///
    /// `reference` is the bank's own reference when it is unique among these entries, else a hash of the booking's
    /// content, suffixed `-n` for the n-th identical entry (n ≥ 1). `sequence` counts the entries of one booking day.
    static func transactions(from entries: [StatementEntry], accountID: String) -> [BankTransaction] {
        var referenceCounts: [String: Int] = [:]
        for entry in entries {
            if let reference = entry.bankReference?.trimmingCharacters(in: .whitespaces), !reference.isEmpty {
                referenceCounts[reference, default: 0] += 1
            }
        }
        var hashCounts: [String: Int] = [:]
        var daySequence: [LocalDate: Int] = [:]
        var usedReferences = Set<String>()
        var transactions: [BankTransaction] = []
        transactions.reserveCapacity(entries.count)
        for entry in entries {
            let hash = contentHash(entry)
            let occurrence = hashCounts[hash, default: 0]
            hashCounts[hash] = occurrence + 1
            var reference: String
            if let bankReference = entry.bankReference?.trimmingCharacters(in: .whitespaces), !bankReference.isEmpty,
               referenceCounts[bankReference] == 1 {
                reference = bankReference
            } else {
                reference = "FINTS-\(hash)" + (occurrence > 0 ? "-\(occurrence)" : "")
            }
            // A bank reference could in theory equal a generated one; keep references unique regardless.
            var suffix = 1
            let base = reference
            while !usedReferences.insert(reference).inserted {
                reference = "\(base)~\(suffix)"
                suffix += 1
            }

            let sequence = daySequence[entry.bookingDate, default: 0] + 1
            daySequence[entry.bookingDate] = sequence

            let name = entry.counterpartyName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let bookingText = entry.bookingText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let purposeHead = String(entry.purpose.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            transactions.append(BankTransaction(
                reference: reference, accountID: accountID, bookingDate: entry.bookingDate, valueDate: entry.valueDate,
                bookedTime: nil, sequence: sequence, amount: entry.amount, currency: entry.currency,
                counterpartyName: name ?? bookingText ?? "", shortName: name ?? purposeHead ?? bookingText ?? "",
                counterpartyIBAN: entry.counterpartyIBAN.map(IBAN.normalized).flatMap { $0.isEmpty ? nil : $0 },
                bookingText: bookingText ?? "", purpose: entry.purpose, creditorID: entry.creditorID,
                kind: transactionKind(code: entry.transactionCode, bookingText: bookingText, purpose: entry.purpose,
                                      amount: entry.amount),
                isPending: entry.isPending))
        }
        return transactions
    }

    /// First 16 hex characters of SHA-256 over the fields that identify a booking.
    private static func contentHash(_ entry: StatementEntry) -> String {
        let counterparty = entry.counterpartyIBAN.map(IBAN.normalized).flatMap { $0.isEmpty ? nil : $0 }
            ?? entry.counterpartyName ?? ""
        return FinTSDigest.hex(
            [entry.bookingDate.iso, String(entry.amount), entry.currency, counterparty, entry.purpose, entry.endToEndID ?? ""],
            bytes: 8)
    }

    // MARK: Transaction kinds

    // The business transaction code (Geschäftsvorfallcode, MT940 `:86:` prefix) decides first; banks reuse codes, so
    // this table is a best guess for the common ones, not a specification:
    //
    //   card payment   106 107 111           (girocard / debit card at many banks)
    //   direct debit   004 005 104 105 108 109 191
    //   ATM            082 083
    //   salary         053                   (Lohn/Gehalt/Rente), credits only
    //   securities     090–099 165
    //   interest       805 814 840           only when the text mentions Zinsen, else a plain booking
    //   transfer       008 009 112 116 117 118 119 152 153 166 167 168 169 192
    //                  and the credit codes 051 052 054 067 068 069 151 154 155 156
    //
    // A generic transfer is refined by the booking text ("Dauerauftrag" → standing order); salary is also recognised
    // from "Lohn", "Gehalt" or "Rente" in a credit's booking text. Entries whose code is missing or unknown fall back to
    // the booking text alone ("Kartenzahlung", "Lastschrift", "Dauerauftrag", "Zinsen", "Geldautomat", "Wertpapier"),
    // then `.transfer`.
    private static let cardCodes: Set<String> = ["106", "107", "111"]
    private static let directDebitCodes: Set<String> = ["004", "005", "104", "105", "108", "109", "191"]
    private static let atmCodes: Set<String> = ["082", "083"]
    private static let securitiesCodes: Set<String> = Set((90...99).map { String(format: "%03d", $0) } + ["165"])
    private static let interestOrFeeCodes: Set<String> = ["805", "814", "840"]
    private static let transferCodes: Set<String> = [
        "008", "009", "112", "116", "117", "118", "119", "152", "153", "166", "167", "168", "169", "192",
        "051", "052", "054", "067", "068", "069", "151", "154", "155", "156",
    ]

    static func transactionKind(code: String?, bookingText: String?, purpose: String, amount: Int) -> BankTransactionKind {
        let text = fold(bookingText ?? "")
        let isCredit = amount > 0
        let salaryText = text.contains("lohn") || text.contains("gehalt") || text.contains("rente")

        if let code = normalizedCode(code) {
            if cardCodes.contains(code) { return .cardPayment }
            if directDebitCodes.contains(code) { return .directDebit }
            if atmCodes.contains(code) { return .atm }
            if securitiesCodes.contains(code) { return .securities }
            if code == "053" { return isCredit ? .salary : .transfer }
            if interestOrFeeCodes.contains(code) {
                return text.contains("zins") || fold(purpose).contains("zins") ? .interest : .transfer
            }
            if transferCodes.contains(code) {
                if isCredit && salaryText { return .salary }
                return text.contains("dauerauftrag") ? .standingOrder : .transfer
            }
        }
        if text.contains("kartenzahlung") || text.contains("girocard") || text.contains("debitkarte") { return .cardPayment }
        if text.contains("lastschrift") || text.contains("einzug") { return .directDebit }
        if text.contains("dauerauftrag") { return .standingOrder }
        if text.contains("zins") { return .interest }
        if text.contains("geldautomat") || text.contains("bargeld") || text.contains("auszahlung") { return .atm }
        if text.contains("wertpapier") { return .securities }
        if isCredit && salaryText { return .salary }
        return .transfer
    }

    /// Three digits, or nil when `code` has none (`5` → `005`, `NTRF` → nil).
    private static func normalizedCode(_ code: String?) -> String? {
        guard let digits = code?.filter(\.isASCII).filter(\.isNumber), !digits.isEmpty, digits.count <= 3 else { return nil }
        return String(repeating: "0", count: 3 - digits.count) + digits
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

// MARK: - Helpers

enum FinTSDigest {
    /// The first `bytes` bytes of SHA-256 over the UTF-8 parts, separated by U+001F, as lower-case hex.
    static func hex(_ parts: [String], bytes: Int) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Ten hex characters identifying a login name in keys and ids without revealing it.
    static func loginHash(_ loginName: String) -> String {
        hex([loginName.trimmingCharacters(in: .whitespacesAndNewlines)], bytes: 5)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
