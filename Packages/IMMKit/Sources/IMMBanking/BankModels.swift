import Foundation
import IMMLedger

// MARK: - Enumerations (raw values match the ledger's column values)

public enum BankAccountKind: String, Sendable, Codable, Hashable, CaseIterable {
    case giro
    case savings
    case creditCard = "credit_card"
    case depot
    case wallet
}

public enum BankTransactionKind: String, Sendable, Codable, Hashable, CaseIterable {
    case cardPayment = "card_payment"
    case directDebit = "direct_debit"
    case transfer
    case standingOrder = "standing_order"
    case salary
    case atm
    case interest
    case securities
}

public enum StandingOrderRhythm: String, Sendable, Codable, Hashable, CaseIterable {
    case once
    case monthly
}

public enum StandingOrderStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case active
    case scheduled
    case paused
}

public enum SecurityKind: String, Sendable, Codable, Hashable, CaseIterable {
    case etf
    case stock
    case fund
}

// MARK: - Directory, credentials, session

public struct BankDirectoryEntry: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var city: String
    /// Eight digits without spaces, for example `37050198`; empty for banks without a bank code (PayPal).
    public var bankCode: String
    /// Protocol label shown in the list, for example `FinTS`.
    public var protocolLabel: String

    public var id: String { bankCode.isEmpty ? name : bankCode }

    public init(name: String, city: String, bankCode: String, protocolLabel: String) {
        self.name = name
        self.city = city
        self.bankCode = bankCode
        self.protocolLabel = protocolLabel
    }

    /// `370 501 98` for `37050198`, grouped as printed in the design ("BLZ 370 501 98").
    public var bankCodeFormatted: String {
        guard bankCode.count == 8 else { return bankCode }
        let chars = Array(bankCode)
        return String(chars[0..<3]) + " " + String(chars[3..<6]) + " " + String(chars[6..<8])
    }
}

public struct BankCredentials: Sendable, Codable, Hashable {
    public var loginName: String
    public var pin: String
    public var tanMethod: String

    public init(loginName: String, pin: String, tanMethod: String) {
        self.loginName = loginName
        self.pin = pin
        self.tanMethod = tanMethod
    }
}

public struct BankSession: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var connectorID: String
    public var bank: BankDirectoryEntry
    public var loginName: String
    public var tanMethod: String
    public var signedInAt: Date

    public init(id: String, connectorID: String, bank: BankDirectoryEntry, loginName: String, tanMethod: String, signedInAt: Date) {
        self.id = id
        self.connectorID = connectorID
        self.bank = bank
        self.loginName = loginName
        self.tanMethod = tanMethod
        self.signedInAt = signedInAt
    }
}

// MARK: - Data transfer objects

public struct BankAccount: Sendable, Codable, Hashable, Identifiable {
    /// Stable string id, for example `sparkasse-giro`.
    public var id: String
    public var kind: BankAccountKind
    public var name: String
    public var bankName: String
    public var iban: String?
    /// Card or depot number when the account has no IBAN.
    public var number: String?
    /// Line under the account name in toolbars and lists, for example `Sparkasse KölnBonn · DE44 …`.
    public var subtitle: String
    /// Balance in minor units; for a depot the total value (holdings plus cash).
    public var balance: Int
    public var currency: String
    public var overdraftLimit: Int?
    public var statementNote: String?
    /// Key of the bank login this account belongs to (`sparkasse`, `dkb`, `ing`, `paypal`).
    public var loginKey: String
    public var sortOrder: Int

    public init(id: String, kind: BankAccountKind, name: String, bankName: String, iban: String?, number: String?,
                subtitle: String, balance: Int, currency: String = "EUR", overdraftLimit: Int?,
                statementNote: String?, loginKey: String, sortOrder: Int) {
        self.id = id
        self.kind = kind
        self.name = name
        self.bankName = bankName
        self.iban = iban
        self.number = number
        self.subtitle = subtitle
        self.balance = balance
        self.currency = currency
        self.overdraftLimit = overdraftLimit
        self.statementNote = statementNote
        self.loginKey = loginKey
        self.sortOrder = sortOrder
    }
}

public struct BankTransaction: Sendable, Codable, Hashable, Identifiable {
    /// Bank reference; the ledger's dedupe key.
    public var reference: String
    public var accountID: String
    public var bookingDate: LocalDate
    public var valueDate: LocalDate
    /// `HH:mm` for card payments, nil otherwise.
    public var bookedTime: String?
    /// 1-based position among the account's transactions of the same booking day, in booking order
    /// (older first). Order a day's rows by this number for running balances.
    public var sequence: Int
    /// Signed minor units.
    public var amount: Int
    public var currency: String
    public var counterpartyName: String
    public var shortName: String
    public var counterpartyIBAN: String?
    public var bookingText: String
    public var purpose: String
    public var creditorID: String?
    public var kind: BankTransactionKind
    /// A pending (*vorgemerkt*) entry: shown, never booked. The importer keeps these in the device-local
    /// `pending_transaction` table and never gives them an id, a category or an `is_new` flag.
    public var isPending: Bool

    public var id: String { reference }

    public init(reference: String, accountID: String, bookingDate: LocalDate, valueDate: LocalDate, bookedTime: String?,
                sequence: Int, amount: Int, currency: String = "EUR", counterpartyName: String, shortName: String,
                counterpartyIBAN: String?, bookingText: String, purpose: String, creditorID: String?, kind: BankTransactionKind,
                isPending: Bool = false) {
        self.reference = reference
        self.accountID = accountID
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.bookedTime = bookedTime
        self.sequence = sequence
        self.amount = amount
        self.currency = currency
        self.counterpartyName = counterpartyName
        self.shortName = shortName
        self.counterpartyIBAN = counterpartyIBAN
        self.bookingText = bookingText
        self.purpose = purpose
        self.creditorID = creditorID
        self.kind = kind
        self.isPending = isPending
    }

    private enum CodingKeys: String, CodingKey {
        case reference, accountID, bookingDate, valueDate, bookedTime, sequence, amount, currency, counterpartyName
        case shortName, counterpartyIBAN, bookingText, purpose, creditorID, kind, isPending
    }

    // `isPending` is written only when true, so data sets that never carry pending entries stay byte-identical.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reference = try c.decode(String.self, forKey: .reference)
        accountID = try c.decode(String.self, forKey: .accountID)
        bookingDate = try c.decode(LocalDate.self, forKey: .bookingDate)
        valueDate = try c.decode(LocalDate.self, forKey: .valueDate)
        bookedTime = try c.decodeIfPresent(String.self, forKey: .bookedTime)
        sequence = try c.decode(Int.self, forKey: .sequence)
        amount = try c.decode(Int.self, forKey: .amount)
        currency = try c.decode(String.self, forKey: .currency)
        counterpartyName = try c.decode(String.self, forKey: .counterpartyName)
        shortName = try c.decode(String.self, forKey: .shortName)
        counterpartyIBAN = try c.decodeIfPresent(String.self, forKey: .counterpartyIBAN)
        bookingText = try c.decode(String.self, forKey: .bookingText)
        purpose = try c.decode(String.self, forKey: .purpose)
        creditorID = try c.decodeIfPresent(String.self, forKey: .creditorID)
        kind = try c.decode(BankTransactionKind.self, forKey: .kind)
        isPending = try c.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reference, forKey: .reference)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(bookingDate, forKey: .bookingDate)
        try c.encode(valueDate, forKey: .valueDate)
        try c.encodeIfPresent(bookedTime, forKey: .bookedTime)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(amount, forKey: .amount)
        try c.encode(currency, forKey: .currency)
        try c.encode(counterpartyName, forKey: .counterpartyName)
        try c.encode(shortName, forKey: .shortName)
        try c.encodeIfPresent(counterpartyIBAN, forKey: .counterpartyIBAN)
        try c.encode(bookingText, forKey: .bookingText)
        try c.encode(purpose, forKey: .purpose)
        try c.encodeIfPresent(creditorID, forKey: .creditorID)
        try c.encode(kind, forKey: .kind)
        if isPending { try c.encode(true, forKey: .isPending) }
    }
}

public struct BankStandingOrder: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var accountID: String
    public var recipient: String
    public var iban: String
    public var purpose: String
    /// Signed minor units (negative = leaves the account).
    public var amount: Int
    public var currency: String
    public var rhythm: StandingOrderRhythm
    public var dayOfMonth: Int?
    public var nextExecution: LocalDate?
    public var status: StandingOrderStatus

    public init(id: String, accountID: String, recipient: String, iban: String, purpose: String, amount: Int,
                currency: String = "EUR", rhythm: StandingOrderRhythm, dayOfMonth: Int?, nextExecution: LocalDate?,
                status: StandingOrderStatus) {
        self.id = id
        self.accountID = accountID
        self.recipient = recipient
        self.iban = iban
        self.purpose = purpose
        self.amount = amount
        self.currency = currency
        self.rhythm = rhythm
        self.dayOfMonth = dayOfMonth
        self.nextExecution = nextExecution
        self.status = status
    }
}

public struct BankSecurity: Sendable, Codable, Hashable {
    public var name: String
    public var isin: String
    public var wkn: String
    public var kind: SecurityKind

    public init(name: String, isin: String, wkn: String, kind: SecurityKind) {
        self.name = name
        self.isin = isin
        self.wkn = wkn
        self.kind = kind
    }
}

public struct BankHolding: Sendable, Codable, Hashable {
    public var accountID: String
    /// Nil for the cash account of the depot.
    public var security: BankSecurity?
    /// Number of units; 1 for the cash position.
    public var quantity: Double
    /// Price per unit in minor units; for cash the cash amount.
    public var price: Int
    public var priceTime: Date?
    /// Total cost in minor units; equals the amount for cash.
    public var costBasis: Int

    public init(accountID: String, security: BankSecurity?, quantity: Double, price: Int, priceTime: Date?, costBasis: Int) {
        self.accountID = accountID
        self.security = security
        self.quantity = quantity
        self.price = price
        self.priceTime = priceTime
        self.costBasis = costBasis
    }

    /// Market value in minor units.
    public var value: Int { Int((quantity * Double(price)).rounded()) }
}

public struct BankDepotValuePoint: Sendable, Codable, Hashable {
    public var accountID: String
    public var date: LocalDate
    /// Total depot value in minor units.
    public var value: Int

    public init(accountID: String, date: LocalDate, value: Int) {
        self.accountID = accountID
        self.date = date
        self.value = value
    }
}

public struct BankSnapshot: Sendable, Codable, Hashable {
    public var accounts: [BankAccount]
    public var transactions: [BankTransaction]
    public var standingOrders: [BankStandingOrder]
    public var holdings: [BankHolding]
    public var depotValueHistory: [BankDepotValuePoint]

    public init(accounts: [BankAccount], transactions: [BankTransaction], standingOrders: [BankStandingOrder],
                holdings: [BankHolding], depotValueHistory: [BankDepotValuePoint]) {
        self.accounts = accounts
        self.transactions = transactions
        self.standingOrders = standingOrders
        self.holdings = holdings
        self.depotValueHistory = depotValueHistory
    }
}

public enum PaymentExecution: Sendable, Codable, Hashable {
    case now
    case onDate(LocalDate)
    /// Monthly standing order whose first execution is the given date.
    case standingOrder(firstExecution: LocalDate)
}

public struct PaymentOrder: Sendable, Codable, Hashable {
    public var fromAccount: String
    public var recipient: String
    public var iban: String
    /// Positive minor units.
    public var amount: Int
    public var currency: String
    public var purpose: String
    public var execution: PaymentExecution
    public var instant: Bool

    public init(fromAccount: String, recipient: String, iban: String, amount: Int, currency: String = "EUR",
                purpose: String, execution: PaymentExecution, instant: Bool) {
        self.fromAccount = fromAccount
        self.recipient = recipient
        self.iban = iban
        self.amount = amount
        self.currency = currency
        self.purpose = purpose
        self.execution = execution
        self.instant = instant
    }
}
