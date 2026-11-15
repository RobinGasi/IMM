import Foundation

public enum ApprovalState: Sendable, Equatable {
    case waiting(sentAt: Date)
    case confirmed(at: Date)
}

public enum PaymentResult: Sendable, Equatable {
    case booked(BankTransaction)
    case scheduled(BankStandingOrder)
}

public enum BankError: Error, Sendable, Equatable {
    /// `attemptsLeft` is nil when the bank does not say (FinTS reports no count).
    case pinRejected(code: Int, attemptsLeft: Int?)
    /// The bank refused the request with its own return code and text.
    case bankRejected(code: Int, message: String)
    case maintenance(until: Date)
    case approvalExpired(sentAt: Date, expiredAt: Date)
    case offline
}

/// One way of talking to banks. The demo connector implements it for every screen of the app; the FinTS
/// connector (`IMMFinTS`) talks to German banks and is read-only for now.
public protocol BankConnector: Sendable {
    var id: String { get }
    /// Whether `submit` can send money. False: the app shows payment controls with a "Soon" badge and never
    /// calls `submit`.
    var supportsPayments: Bool { get }
    func searchBanks(_ query: String) async throws -> [BankDirectoryEntry]
    func signIn(bank: BankDirectoryEntry, credentials: BankCredentials, onApproval: @Sendable (ApprovalState) -> Void) async throws -> BankSession
    func accounts(_ session: BankSession) async throws -> [BankAccount]
    func fetch(_ session: BankSession, accounts: [String], since: Date) async throws -> BankSnapshot
    func submit(_ order: PaymentOrder, session: BankSession, onApproval: @Sendable (ApprovalState) -> Void) async throws -> PaymentResult
}
