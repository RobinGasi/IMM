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
    case pinRejected(code: Int, attemptsLeft: Int)
    case maintenance(until: Date)
    case approvalExpired(sentAt: Date, expiredAt: Date)
    case offline
}

/// One way of talking to banks. The demo connector implements it for every screen of the app; real
/// connectors (FinTS, file import, Enable Banking) follow in later plans.
public protocol BankConnector: Sendable {
    var id: String { get }
    func searchBanks(_ query: String) async throws -> [BankDirectoryEntry]
    func signIn(bank: BankDirectoryEntry, credentials: BankCredentials, onApproval: @Sendable (ApprovalState) -> Void) async throws -> BankSession
    func accounts(_ session: BankSession) async throws -> [BankAccount]
    func fetch(_ session: BankSession, accounts: [String], since: Date) async throws -> BankSnapshot
    func submit(_ order: PaymentOrder, session: BankSession, onApproval: @Sendable (ApprovalState) -> Void) async throws -> PaymentResult
}
