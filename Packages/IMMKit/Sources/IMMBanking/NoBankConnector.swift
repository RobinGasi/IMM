import Foundation

/// The connector of builds that cannot talk to banks (no FinTS registration, no demo bank): the directory
/// is empty and every other call refuses. The app asks `AppModel.bankAccessAvailable` first and offers
/// manual accounts instead, so none of these calls is reached from the screens.
public struct NoBankConnector: BankConnector {
    public static let connectorID = "none"

    public static let unavailableError = BankError.bankRejected(
        code: 0, message: "Connecting to banks is not available yet.")

    public var id: String { Self.connectorID }
    public var supportsPayments: Bool { false }

    public init() {}

    public func searchBanks(_ query: String) async throws -> [BankDirectoryEntry] { [] }

    public func signIn(bank: BankDirectoryEntry, credentials: BankCredentials,
                       onApproval: @Sendable (ApprovalState) -> Void) async throws -> BankSession {
        throw Self.unavailableError
    }

    public func accounts(_ session: BankSession) async throws -> [BankAccount] {
        throw Self.unavailableError
    }

    public func fetch(_ session: BankSession, accounts: [String], since: Date) async throws -> BankSnapshot {
        throw Self.unavailableError
    }

    public func submit(_ order: PaymentOrder, session: BankSession,
                       onApproval: @Sendable (ApprovalState) -> Void) async throws -> PaymentResult {
        throw Self.unavailableError
    }
}
