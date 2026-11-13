import Foundation
import IMMLedger

/// The bank connector behind every screen: answers for the four designed Sparkasse entries, accepts
/// any non-empty login, and returns the deterministic demo data set.
public struct DemoConnector: BankConnector {
    public static let connectorID = "demo"

    /// The four banks of the designed list (`Onboarding2AddBankSetup`).
    public static let directory: [BankDirectoryEntry] = [
        BankDirectoryEntry(name: "Sparkasse KölnBonn", city: "Köln", bankCode: "37050198", protocolLabel: "FinTS"),
        BankDirectoryEntry(name: "Kreissparkasse Köln", city: "Köln", bankCode: "37050299", protocolLabel: "FinTS"),
        BankDirectoryEntry(name: "Sparkasse Leverkusen", city: "Leverkusen", bankCode: "37551440", protocolLabel: "FinTS"),
        BankDirectoryEntry(name: "Sparkasse Gummersbach", city: "Gummersbach", bankCode: "38450000", protocolLabel: "FinTS"),
    ]

    public var id: String { Self.connectorID }

    private let behaviour: DemoBankBehaviour
    private let delay: Duration
    private let expiryDelay: Duration
    private let approvalWindow: TimeInterval
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let bankProvider: @Sendable () throws -> DemoBank

    /// - Parameters:
    ///   - behaviour: failure switches; the app passes `DemoBankBehaviour.shared`.
    ///   - delay: time between "waiting" and "confirmed" (3 s); tests pass `.zero`.
    ///   - expiryDelay: time until an unanswered approval expires when `behaviour.approval == .expires` (5 s).
    ///   - approvalWindow: seconds after `sentAt` reported as `expiredAt` (5 minutes).
    ///   - now: clock for approval timestamps and booking times.
    ///   - bankProvider: source of the demo data; defaults to the bundled `DemoBank.json`.
    public init(behaviour: DemoBankBehaviour = .shared,
                delay: Duration = .seconds(3),
                expiryDelay: Duration = .seconds(5),
                approvalWindow: TimeInterval = 300,
                timeZone: TimeZone = .current,
                now: @escaping @Sendable () -> Date = { Date() },
                bankProvider: @escaping @Sendable () throws -> DemoBank = { try DemoDataset.load() }) {
        self.behaviour = behaviour
        self.delay = delay
        self.expiryDelay = expiryDelay
        self.approvalWindow = approvalWindow
        self.timeZone = timeZone
        self.now = now
        self.bankProvider = bankProvider
    }

    // MARK: BankConnector

    public func searchBanks(_ query: String) async throws -> [BankDirectoryEntry] {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return Self.directory }
        let digits = needle.filter(\.isNumber)
        return Self.directory.filter { entry in
            if Self.fold(entry.name).contains(needle) || Self.fold(entry.city).contains(needle) { return true }
            if Self.fold(entry.bankCode).contains(needle) || Self.fold(entry.bankCodeFormatted).contains(needle) { return true }
            return !digits.isEmpty && entry.bankCode.contains(digits)
        }
    }

    public func signIn(bank: BankDirectoryEntry, credentials: BankCredentials,
                       onApproval: @Sendable (ApprovalState) -> Void) async throws -> BankSession {
        let login = credentials.loginName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty, !credentials.pin.isEmpty else {
            throw BankError.pinRejected(code: 9931, attemptsLeft: 2)
        }
        try await approve(onApproval)
        return BankSession(id: UUID().uuidString, connectorID: id, bank: bank, loginName: login,
                           tanMethod: credentials.tanMethod, signedInAt: now())
    }

    public func accounts(_ session: BankSession) async throws -> [BankAccount] {
        let key = Self.loginKey(for: session.bank)
        return try bankProvider().snapshot.accounts.filter { $0.loginKey == key }
    }

    public func fetch(_ session: BankSession, accounts: [String], since: Date) async throws -> BankSnapshot {
        let key = Self.loginKey(for: session.bank)
        if behaviour.sync == .fails {
            if key == "sparkasse" && session.bank.name == "Sparkasse KölnBonn" {
                throw BankError.pinRejected(code: 9931, attemptsLeft: 2)
            }
            if key == "dkb" {
                throw BankError.maintenance(until: tenOClockToday())
            }
        }
        let snapshot = try bankProvider().snapshot
        let wanted = Set(accounts)
        let sinceDay = LocalDate(since, timeZone: timeZone)
        return BankSnapshot(
            accounts: snapshot.accounts.filter { wanted.contains($0.id) },
            transactions: snapshot.transactions.filter { wanted.contains($0.accountID) && $0.bookingDate >= sinceDay },
            standingOrders: snapshot.standingOrders.filter { wanted.contains($0.accountID) },
            holdings: snapshot.holdings.filter { wanted.contains($0.accountID) },
            depotValueHistory: snapshot.depotValueHistory.filter { wanted.contains($0.accountID) && $0.date >= sinceDay })
    }

    public func submit(_ order: PaymentOrder, session: BankSession,
                       onApproval: @Sendable (ApprovalState) -> Void) async throws -> PaymentResult {
        try await approve(onApproval)
        let stamp = String(UUID().uuidString.prefix(8))
        let iban = IBAN.normalized(order.iban)
        switch order.execution {
        case .now:
            let today = DemoDataset.today
            let transaction = BankTransaction(
                reference: "DEMO-PAY-\(stamp)", accountID: order.fromAccount, bookingDate: today, valueDate: today,
                bookedTime: bookingTime(), sequence: Int(now().timeIntervalSince1970), amount: -order.amount, currency: order.currency,
                counterpartyName: order.recipient, shortName: order.recipient, counterpartyIBAN: iban,
                bookingText: order.instant ? "Echtzeitüberweisung" : "Überweisung", purpose: order.purpose,
                creditorID: nil, kind: .transfer)
            return .booked(transaction)
        case .onDate(let date):
            return .scheduled(BankStandingOrder(
                id: "demo-so-\(stamp)", accountID: order.fromAccount, recipient: order.recipient, iban: iban,
                purpose: order.purpose, amount: -order.amount, currency: order.currency, rhythm: .once,
                dayOfMonth: nil, nextExecution: date, status: .scheduled))
        case .standingOrder(let first):
            return .scheduled(BankStandingOrder(
                id: "demo-so-\(stamp)", accountID: order.fromAccount, recipient: order.recipient, iban: iban,
                purpose: order.purpose, amount: -order.amount, currency: order.currency, rhythm: .monthly,
                dayOfMonth: first.day, nextExecution: first, status: .active))
        }
    }

    // MARK: Helpers

    /// Reports `.waiting`, then either confirms after `delay` or expires after `expiryDelay`.
    private func approve(_ onApproval: @Sendable (ApprovalState) -> Void) async throws {
        let sentAt = now()
        onApproval(.waiting(sentAt: sentAt))
        switch behaviour.approval {
        case .approves:
            try await Task.sleep(for: delay)
            onApproval(.confirmed(at: now()))
        case .expires:
            try await Task.sleep(for: expiryDelay)
            throw BankError.approvalExpired(sentAt: sentAt, expiredAt: sentAt.addingTimeInterval(approvalWindow))
        }
    }

    /// 10:00 on the day of `now()` in the connector's time zone.
    func tenOClockToday() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now()) ?? now()
    }

    private func bookingTime() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: now())
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return (hour < 10 ? "0" : "") + String(hour) + ":" + (minute < 10 ? "0" : "") + String(minute)
    }

    static func loginKey(for bank: BankDirectoryEntry) -> String {
        switch bank.name {
        case "DKB": return "dkb"
        case "ING": return "ing"
        case "PayPal": return "paypal"
        default: return "sparkasse"
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
