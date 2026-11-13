import Foundation
import GRDB

// One struct per table. Properties are camelCase; GRDB maps them to the snake_case columns (`bankLoginId` ↔ `bank_login_id`).


/// A bank connection (one online-banking login).
public struct BankLoginRecord: LedgerRecord {
    public static let databaseTableName = "bank_login"
    public var id: String
    public var connectorId: String // Connector identifier, e.g. `demo`.
    public var bankName: String
    public var bankCode: String
    public var loginName: String
    public var tanMethod: String // TAN method label, e.g. `pushTAN — S-pushTAN app`.
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        connectorId: String,
        bankName: String,
        bankCode: String,
        loginName: String,
        tanMethod: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.connectorId = connectorId
        self.bankName = bankName
        self.bankCode = bankCode
        self.loginName = loginName
        self.tanMethod = tanMethod
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A bank account, card, wallet or depot.
public struct AccountRecord: LedgerRecord {
    public static let databaseTableName = "account"
    public var id: String
    public var bankLoginId: String? // `bank_login.id`. Device-local, not synced.
    public var connectorAccountId: String? // The connector's id for this account (`BankAccount.id`). Device-local, not synced.
    public var kind: AccountKind
    public var name: String
    public var bankName: String
    public var iban: String? // IBAN or account number.
    public var subtitle: String? // Second line shown under the name, e.g. `Sparkasse KölnBonn · DE…`.
    public var balance: Int // Current balance in minor units. For depot accounts the screens use holdings (see `LedgerDefinitions.netWorth`).
    public var currency: String
    public var overdraftLimit: Int // Overdraft limit in minor units (positive).
    public var statementNote: String? // e.g. `Statement 20.11.`.
    public var sortOrder: Int
    public var lastSyncedAt: Date?
    public var syncStatus: AccountSyncStatus
    public var syncStatusText: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        bankLoginId: String? = nil,
        connectorAccountId: String? = nil,
        kind: AccountKind,
        name: String,
        bankName: String = "",
        iban: String? = nil,
        subtitle: String? = nil,
        balance: Int,
        currency: String = "EUR",
        overdraftLimit: Int = 0,
        statementNote: String? = nil,
        sortOrder: Int = 0,
        lastSyncedAt: Date? = nil,
        syncStatus: AccountSyncStatus = .never,
        syncStatusText: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.bankLoginId = bankLoginId
        self.connectorAccountId = connectorAccountId
        self.kind = kind
        self.name = name
        self.bankName = bankName
        self.iban = iban
        self.subtitle = subtitle
        self.balance = balance
        self.currency = currency
        self.overdraftLimit = overdraftLimit
        self.statementNote = statementNote
        self.sortOrder = sortOrder
        self.lastSyncedAt = lastSyncedAt
        self.syncStatus = syncStatus
        self.syncStatusText = syncStatusText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A spending or income category.
public struct CategoryRecord: LedgerRecord {
    public static let databaseTableName = "category"
    public var id: String
    public var name: String
    public var colorToken: String // Design token name, e.g. `chart-1`, `muted-foreground`, `credit`.
    public var kind: CategoryKind
    public var sortOrder: String // Fractional index (`FractionalIndex`); compares lexicographically.
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        colorToken: String,
        kind: CategoryKind = .expense,
        sortOrder: String = FractionalIndex.midpoint,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorToken = colorToken
        self.kind = kind
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A booked transaction.
public struct TransactionRecord: LedgerRecord {
    public static let databaseTableName = "ledger_transaction"
    public var id: String
    public var accountId: String
    public var bookingDate: LocalDate
    public var valueDate: LocalDate?
    public var bookedTime: String? // `HH:mm` when the bank reports a time.
    public var bookingSeq: Int // Intra-day order assigned by the importer: higher = booked later. Tie-break after `booked_time`.
    public var amount: Int // Signed minor units (negative = outflow).
    public var currency: String
    public var counterpartyName: String
    public var shortName: String? // Short display name, e.g. `REWE`.
    public var counterpartyIban: String?
    public var bookingText: String? // e.g. `Kartenzahlung`.
    public var purpose: String?
    public var creditorId: String?
    public var kind: TransactionKind
    public var categoryId: String?
    public var isOwnTransfer: Bool // Transfer between the user's own accounts; excluded from spending.
    public var isNew: Bool
    public var note: String?
    public var bankRefKind: String? // What `bankRef` is (`bank` = assigned by the bank, `legacy` = pre-sync import). An attribute, never identity.
    public var bankRef: String? // The bank's own reference for the booking. Not unique, not an identity.
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        accountId: String,
        bookingDate: LocalDate,
        valueDate: LocalDate? = nil,
        bookedTime: String? = nil,
        bookingSeq: Int = 0,
        amount: Int,
        currency: String = "EUR",
        counterpartyName: String = "",
        shortName: String? = nil,
        counterpartyIban: String? = nil,
        bookingText: String? = nil,
        purpose: String? = nil,
        creditorId: String? = nil,
        kind: TransactionKind = .cardPayment,
        categoryId: String? = nil,
        isOwnTransfer: Bool = false,
        isNew: Bool = false,
        note: String? = nil,
        bankRefKind: String? = nil,
        bankRef: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.bookedTime = bookedTime
        self.bookingSeq = bookingSeq
        self.amount = amount
        self.currency = currency
        self.counterpartyName = counterpartyName
        self.shortName = shortName
        self.counterpartyIban = counterpartyIban
        self.bookingText = bookingText
        self.purpose = purpose
        self.creditorId = creditorId
        self.kind = kind
        self.categoryId = categoryId
        self.isOwnTransfer = isOwnTransfer
        self.isNew = isNew
        self.note = note
        self.bankRefKind = bankRefKind
        self.bankRef = bankRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// An auto-categorisation rule.
public struct RuleRecord: LedgerRecord {
    public static let databaseTableName = "rule"
    public var id: String
    public var pattern: String
    public var categoryId: String
    public var origin: RuleOrigin
    public var enabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        pattern: String,
        categoryId: String,
        origin: RuleOrigin = .manual,
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.categoryId = categoryId
        self.origin = origin
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A monthly budget limit for one category.
public struct BudgetRecord: LedgerRecord {
    public static let databaseTableName = "budget"
    public var id: String
    public var categoryId: String
    public var monthlyLimit: Int // Minor units (positive).
    public var currency: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        categoryId: String,
        monthlyLimit: Int,
        currency: String = "EUR",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.categoryId = categoryId
        self.monthlyLimit = monthlyLimit
        self.currency = currency
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A key/value setting. `id` equals `key`. Rows with scope `shared` sync; `local` rows never leave the device.
public struct SettingRecord: LedgerRecord {
    public static let databaseTableName = "setting"
    public var id: String
    public var key: String
    public var scope: SettingScope
    public var value: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String? = nil,
        key: String,
        scope: SettingScope? = nil,
        value: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id ?? key
        self.key = key
        self.scope = scope ?? SettingKey(rawValue: key)?.scope ?? .local
        self.value = value
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A standing order or scheduled payment.
public struct StandingOrderRecord: LedgerRecord {
    public static let databaseTableName = "standing_order"
    public var id: String
    public var accountId: String
    public var recipient: String
    public var iban: String
    public var purpose: String?
    public var amount: Int // Signed minor units (negative).
    public var currency: String
    public var rhythm: StandingOrderRhythm
    public var dayOfMonth: Int?
    public var nextExecution: LocalDate?
    public var status: StandingOrderStatus
    public var categoryId: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        accountId: String,
        recipient: String,
        iban: String = "",
        purpose: String? = nil,
        amount: Int,
        currency: String = "EUR",
        rhythm: StandingOrderRhythm = .monthly,
        dayOfMonth: Int? = nil,
        nextExecution: LocalDate? = nil,
        status: StandingOrderStatus = .active,
        categoryId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.recipient = recipient
        self.iban = iban
        self.purpose = purpose
        self.amount = amount
        self.currency = currency
        self.rhythm = rhythm
        self.dayOfMonth = dayOfMonth
        self.nextExecution = nextExecution
        self.status = status
        self.categoryId = categoryId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A recurring contract or recurring income.
public struct ContractRecord: LedgerRecord {
    public static let databaseTableName = "contract"
    public var id: String
    public var provider: String
    public var accountId: String?
    public var groupName: String // Group heading, e.g. `Housing`, `Insurance`.
    public var categoryId: String?
    public var rhythm: ContractRhythm
    public var monthlyAmount: Int // Signed minor units per month (negative = cost).
    public var currency: String
    public var nextDebit: LocalDate?
    public var noticeText: String? // e.g. `3 months`, `Statutory, no notice`.
    public var noticeDeadline: LocalDate?
    public var renewalDate: LocalDate?
    public var renewalAmount: Int? // Cost of the renewed term in minor units.
    public var priceChangeAmount: Int? // New signed monthly amount.
    public var priceChangeStart: LocalDate?
    public var kind: ContractKind
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        provider: String,
        accountId: String? = nil,
        groupName: String = "",
        categoryId: String? = nil,
        rhythm: ContractRhythm = .monthly,
        monthlyAmount: Int,
        currency: String = "EUR",
        nextDebit: LocalDate? = nil,
        noticeText: String? = nil,
        noticeDeadline: LocalDate? = nil,
        renewalDate: LocalDate? = nil,
        renewalAmount: Int? = nil,
        priceChangeAmount: Int? = nil,
        priceChangeStart: LocalDate? = nil,
        kind: ContractKind = .contract,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.accountId = accountId
        self.groupName = groupName
        self.categoryId = categoryId
        self.rhythm = rhythm
        self.monthlyAmount = monthlyAmount
        self.currency = currency
        self.nextDebit = nextDebit
        self.noticeText = noticeText
        self.noticeDeadline = noticeDeadline
        self.renewalDate = renewalDate
        self.renewalAmount = renewalAmount
        self.priceChangeAmount = priceChangeAmount
        self.priceChangeStart = priceChangeStart
        self.kind = kind
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A tradable security.
public struct SecurityRecord: LedgerRecord {
    public static let databaseTableName = "security"
    public var id: String
    public var name: String
    public var isin: String
    public var wkn: String?
    public var kind: SecurityKind
    public var region: String? // Region for the allocation chart.
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        isin: String,
        wkn: String? = nil,
        kind: SecurityKind = .etf,
        region: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isin = isin
        self.wkn = wkn
        self.kind = kind
        self.region = region
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A depot position. Cash has `securityId == nil`, `quantityMicro == 1_000_000` and `price` = cash amount.
public struct HoldingRecord: LedgerRecord {
    public static let databaseTableName = "holding"
    public var id: String
    public var accountId: String
    public var securityId: String?
    public var name: String
    public var isin: String?
    public var quantityMicro: Int // Quantity in millionths of a unit.
    public var price: Int // Unit price in minor units.
    public var priceAt: Date?
    public var costBasis: Int // Total cost basis in minor units.
    public var currency: String
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        accountId: String,
        securityId: String? = nil,
        name: String,
        isin: String? = nil,
        quantityMicro: Int,
        price: Int,
        priceAt: Date? = nil,
        costBasis: Int,
        currency: String = "EUR",
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.securityId = securityId
        self.name = name
        self.isin = isin
        self.quantityMicro = quantityMicro
        self.price = price
        self.priceAt = priceAt
        self.costBasis = costBasis
        self.currency = currency
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Total depot value on a date.
public struct DepotValueRecord: LedgerRecord {
    public static let databaseTableName = "depot_value_history"
    public var id: String
    public var accountId: String
    public var date: LocalDate
    public var value: Int // Minor units.
    public var currency: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        accountId: String,
        date: LocalDate,
        value: Int,
        currency: String = "EUR",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.date = date
        self.value = value
        self.currency = currency
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A monthly savings plan into a depot.
public struct SavingsPlanRecord: LedgerRecord {
    public static let databaseTableName = "savings_plan"
    public var id: String
    public var accountId: String // Depot account.
    public var sourceAccountId: String? // Debited account.
    public var amount: Int // Total per run, minor units.
    public var currency: String
    public var dayOfMonth: Int
    public var nextExecution: LocalDate?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        accountId: String,
        sourceAccountId: String? = nil,
        amount: Int,
        currency: String = "EUR",
        dayOfMonth: Int,
        nextExecution: LocalDate? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.sourceAccountId = sourceAccountId
        self.amount = amount
        self.currency = currency
        self.dayOfMonth = dayOfMonth
        self.nextExecution = nextExecution
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// One security's share of a savings plan.
public struct SavingsPlanItemRecord: LedgerRecord {
    public static let databaseTableName = "savings_plan_item"
    public var id: String
    public var planId: String
    public var securityId: String
    public var amount: Int // Minor units.
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        planId: String,
        securityId: String,
        amount: Int,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.planId = planId
        self.securityId = securityId
        self.amount = amount
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Stored AI-screen content; no model runs.
public struct InsightRecord: LedgerRecord {
    public static let databaseTableName = "insight"
    public var id: String
    public var kind: InsightKind
    public var transactionId: String?
    public var payload: String // JSON text.
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        kind: InsightKind,
        transactionId: String? = nil,
        payload: String,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.transactionId = transactionId
        self.payload = payload
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Single opaque sync row (unused for now); `id` is `singleton`.
public struct SyncStateRecord: LedgerRecord {
    public static let databaseTableName = "sync_state"
    public var id: String
    public var state: Data?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = "singleton",
        state: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A booking the bank reported as pending (*vorgemerkt*). Device-local display data: never synced, never
/// part of spending, balances or `is_new`. The set of one account is replaced by every fetch that includes
/// pending entries, so a booked entry replaces its pending twin simply by no longer being delivered.
public struct PendingTransactionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "pending_transaction"
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }

    public var id: String
    public var accountId: String
    public var position: Int // Delivery order within the account's pending set.
    public var bookingDate: LocalDate?
    public var valueDate: LocalDate?
    public var amount: Int // Signed minor units.
    public var currency: String
    public var counterpartyName: String
    public var counterpartyIban: String?
    public var bookingText: String?
    public var purpose: String?
    public var kind: TransactionKind
    public var fetchedAt: Date

    public init(
        id: String = UUID().uuidString,
        accountId: String,
        position: Int,
        bookingDate: LocalDate? = nil,
        valueDate: LocalDate? = nil,
        amount: Int,
        currency: String = "EUR",
        counterpartyName: String = "",
        counterpartyIban: String? = nil,
        bookingText: String? = nil,
        purpose: String? = nil,
        kind: TransactionKind = .cardPayment,
        fetchedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.position = position
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.amount = amount
        self.currency = currency
        self.counterpartyName = counterpartyName
        self.counterpartyIban = counterpartyIban
        self.bookingText = bookingText
        self.purpose = purpose
        self.kind = kind
        self.fetchedAt = fetchedAt
    }
}
