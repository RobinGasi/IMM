import Foundation
import GRDB

/// Common shape of every ledger table row: client-generated string `id`, timestamps and tombstone
/// (`deleted_at`).
///
/// Properties are camelCase and GRDB converts them to snake_case columns, so a property named
/// `bankLoginId` is stored in `bank_login_id` (note the `Id` spelling that this conversion yields).
public protocol LedgerRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable where ID == String {
    var id: String { get }
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }
}

extension LedgerRecord {
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }

    /// Request over rows that are not tombstoned.
    public static func live() -> QueryInterfaceRequest<Self> {
        all().filter(sql: "deleted_at IS NULL")
    }
}

public enum AccountKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case giro, savings
    case creditCard = "credit_card"
    case depot, wallet
}

/// Result of the last sync for one account.
public enum AccountSyncStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case ok, failed, never
}

public enum CategoryKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case expense, income
}

public enum TransactionKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case cardPayment = "card_payment"
    case directDebit = "direct_debit"
    case transfer
    case standingOrder = "standing_order"
    case salary, atm, interest, securities
}

public enum RuleOrigin: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case manual, suggested, imported
}

public enum StandingOrderRhythm: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case once, monthly
}

public enum StandingOrderStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case active, scheduled, paused
}

public enum ContractRhythm: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case monthly, quarterly, yearly
}

public enum ContractKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case contract, income
}

public enum SecurityKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case etf, stock, fund, other
}

public enum InsightKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case ask, suggestion, notice, review, tax, attention
}

/// Whether a setting row syncs between devices.
public enum SettingScope: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case shared, local
}
