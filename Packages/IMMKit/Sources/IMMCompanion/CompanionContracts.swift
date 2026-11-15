import Foundation
import IMMLedger
import IMMSyncCore

// Values the companion screens show, produced by `CompanionModel`. Amounts are signed minor units (cents).

public struct CompanionAccount: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var bankName: String
    /// Second line, for example `Sparkasse KölnBonn · DE44 …`.
    public var subtitle: String
    public var balance: Int
    public var currency: String
    /// `AccountKind` raw value (`giro`, `savings`, `credit_card`, `depot`, `wallet`).
    public var kind: String

    public init(id: String, name: String, bankName: String, subtitle: String, balance: Int, currency: String, kind: String) {
        self.id = id
        self.name = name
        self.bankName = bankName
        self.subtitle = subtitle
        self.balance = balance
        self.currency = currency
        self.kind = kind
    }
}

public struct CompanionTransaction: Sendable, Hashable, Identifiable {
    public var id: String
    public var accountID: String
    public var bookingDate: LocalDate
    public var counterparty: String
    public var purpose: String
    public var amount: Int
    public var currency: String
    public var categoryName: String?
    /// Design token name of the category colour (`IMMColor` token), nil when uncategorised.
    public var categoryColorToken: String?
    public var isPending: Bool

    public init(id: String, accountID: String, bookingDate: LocalDate, counterparty: String, purpose: String, amount: Int,
                currency: String, categoryName: String?, categoryColorToken: String?, isPending: Bool) {
        self.id = id
        self.accountID = accountID
        self.bookingDate = bookingDate
        self.counterparty = counterparty
        self.purpose = purpose
        self.amount = amount
        self.currency = currency
        self.categoryName = categoryName
        self.categoryColorToken = categoryColorToken
        self.isPending = isPending
    }
}

public struct CompanionTransactionDetail: Sendable, Hashable {
    public var transaction: CompanionTransaction
    public var accountName: String
    public var valueDate: LocalDate
    public var counterpartyIBAN: String?
    public var bookingText: String
    public var note: String?
    public var categoryID: String?

    public init(transaction: CompanionTransaction, accountName: String, valueDate: LocalDate, counterpartyIBAN: String?,
                bookingText: String, note: String?, categoryID: String?) {
        self.transaction = transaction
        self.accountName = accountName
        self.valueDate = valueDate
        self.counterpartyIBAN = counterpartyIBAN
        self.bookingText = bookingText
        self.note = note
        self.categoryID = categoryID
    }
}

public struct CompanionCategory: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var colorToken: String
    public var isIncome: Bool

    public init(id: String, name: String, colorToken: String, isIncome: Bool) {
        self.id = id
        self.name = name
        self.colorToken = colorToken
        self.isIncome = isIncome
    }
}

public struct CompanionOverview: Sendable, Hashable {
    public var netWorth: Int
    public var spentThisMonth: Int
    public var averageMonthlySpending: Int
    public var uncategorisedCount: Int
    /// The newest bookings, at most 8.
    public var recent: [CompanionTransaction]

    public init(netWorth: Int, spentThisMonth: Int, averageMonthlySpending: Int, uncategorisedCount: Int, recent: [CompanionTransaction]) {
        self.netWorth = netWorth
        self.spentThisMonth = spentThisMonth
        self.averageMonthlySpending = averageMonthlySpending
        self.uncategorisedCount = uncategorisedCount
        self.recent = recent
    }
}

public enum CompanionPairingStep: Sendable, Equatable {
    case scanning
    case connecting(macName: String?)
    /// The phone shows the code; the user taps "Codes match" or "Codes don't match".
    case confirm(code: ShortAuthCode, macName: String)
    /// The user tapped "Codes match"; the Mac's user confirms there.
    case waitingForMac(macName: String)
    /// The grant arrived; the snapshot is being applied.
    case importing
    case failed(message: String)
}

public enum CompanionSyncStatus: Sendable, Equatable {
    case idle
    case syncing
    case synced(at: Date)
    /// The Mac reported that IMM is locked there; the phone's data may be stale.
    case macLocked(at: Date)
    /// No route to the Mac (Tailscale off, Mac asleep).
    case unreachable(message: String)
    case failed(message: String)
}

/// The device key that opens the phone's vault, behind Face ID / passcode.
public protocol CompanionKeyStore: Sendable {
    func hasKey() -> Bool
    /// Creates and stores a random vault password; returns it.
    func createKey() throws -> String
    /// Reads the password, asking for Face ID / passcode (`.userPresence`); `reason` is shown in the prompt.
    func readKey(reason: String) async throws -> String
    func deleteKey()
}
