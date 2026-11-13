import Foundation
import IMMBanking

/// Why one bank could not be updated.
public enum SyncFailureReason: Hashable, Sendable {
    case pinRejected(code: Int, attemptsLeft: Int)
    case maintenance(until: Date)
    case offline
    case other(String)
}

/// One account that was not updated by the last sync.
public struct AccountSyncFailure: Identifiable, Hashable, Sendable {
    /// Ledger account id.
    public var id: String
    public var accountName: String
    public var bankName: String
    /// Ledger `bank_login` id.
    public var loginID: String
    public var reason: SyncFailureReason
    public var failedAt: Date

    public init(id: String, accountName: String, bankName: String, loginID: String, reason: SyncFailureReason, failedAt: Date) {
        self.id = id
        self.accountName = accountName
        self.bankName = bankName
        self.loginID = loginID
        self.reason = reason
        self.failedAt = failedAt
    }
}

/// The failures of one bank login, for the two banner rows of the Sync failed layout.
public struct BankSyncFailure: Identifiable, Hashable, Sendable {
    public var loginID: String
    public var bankName: String
    public var reason: SyncFailureReason
    /// Names of the accounts of this login that were not updated, in ledger order.
    public var accountNames: [String]
    public var id: String { loginID }
}

public enum SyncState: Equatable, Sendable {
    case idle
    case syncing
    case failed([AccountSyncFailure])

    public var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    public var failures: [AccountSyncFailure] {
        if case .failed(let failures) = self { return failures }
        return []
    }

    /// Failures grouped by bank login, in order of first appearance.
    public var byBank: [BankSyncFailure] {
        var groups: [BankSyncFailure] = []
        for failure in failures {
            if let index = groups.firstIndex(where: { $0.loginID == failure.loginID }) {
                groups[index].accountNames.append(failure.accountName)
            } else {
                groups.append(BankSyncFailure(
                    loginID: failure.loginID, bankName: failure.bankName, reason: failure.reason,
                    accountNames: [failure.accountName]))
            }
        }
        return groups
    }
}

/// Progress of the onboarding sign-in (Bank login screen).
public enum SignInState: Equatable, Sendable {
    case idle
    /// Request sent to the bank's app, no answer yet.
    case signingIn
    case waiting(sentAt: Date)
    /// Approved; `accounts` are what the bank offers to import.
    case confirmed(at: Date, accounts: [BankAccount])
    case failed(String)
}
