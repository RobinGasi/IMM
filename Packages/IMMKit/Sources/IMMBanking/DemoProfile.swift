import Foundation
import IMMLedger

/// Everything the ledger needs beyond the bank's own data: logins, categories, rules, budgets,
/// contracts, savings plan and the stored AI insights.
public struct DemoBank: Sendable, Codable, Hashable {
    public var snapshot: BankSnapshot
    public var profile: DemoProfile

    public init(snapshot: BankSnapshot, profile: DemoProfile) {
        self.snapshot = snapshot
        self.profile = profile
    }
}

public struct DemoProfile: Sendable, Codable, Hashable {
    /// While the ledger holds only demo-bank data this day is "today".
    public var ledgerToday: LocalDate
    public var logins: [DemoBankLogin]
    public var categories: [DemoCategory]
    /// Category name per transaction bank reference; transactions without an entry are uncategorised.
    public var categoryByReference: [String: String]
    /// References of transfers between own accounts (excluded from spending and from "uncategorised").
    public var ownTransferReferences: [String]
    /// References of the 14 rows flagged new.
    public var newReferences: [String]
    public var rules: [DemoRule]
    public var budgets: [DemoBudget]
    public var fixedCosts: [DemoFixedCost]
    public var contracts: [DemoContract]
    public var savingsPlan: DemoSavingsPlan
    public var fundRegionWeights: [DemoFundRegionWeights]
    public var insights: [DemoInsight]

    public init(ledgerToday: LocalDate, logins: [DemoBankLogin], categories: [DemoCategory],
                categoryByReference: [String: String], ownTransferReferences: [String], newReferences: [String],
                rules: [DemoRule], budgets: [DemoBudget], fixedCosts: [DemoFixedCost], contracts: [DemoContract],
                savingsPlan: DemoSavingsPlan, fundRegionWeights: [DemoFundRegionWeights], insights: [DemoInsight]) {
        self.ledgerToday = ledgerToday
        self.logins = logins
        self.categories = categories
        self.categoryByReference = categoryByReference
        self.ownTransferReferences = ownTransferReferences
        self.newReferences = newReferences
        self.rules = rules
        self.budgets = budgets
        self.fixedCosts = fixedCosts
        self.contracts = contracts
        self.savingsPlan = savingsPlan
        self.fundRegionWeights = fundRegionWeights
        self.insights = insights
    }
}

public struct DemoBankLogin: Sendable, Codable, Hashable, Identifiable {
    /// Same as the accounts' `loginKey`.
    public var id: String
    public var connectorID: String
    public var bankName: String
    /// Eight digits, empty for PayPal.
    public var bankCode: String
    public var loginName: String
    public var tanMethod: String
    public var accountIDs: [String]

    public init(id: String, connectorID: String, bankName: String, bankCode: String, loginName: String,
                tanMethod: String, accountIDs: [String]) {
        self.id = id
        self.connectorID = connectorID
        self.bankName = bankName
        self.bankCode = bankCode
        self.loginName = loginName
        self.tanMethod = tanMethod
        self.accountIDs = accountIDs
    }
}

public enum DemoCategoryKind: String, Sendable, Codable, Hashable {
    case expense
    case income
}

public struct DemoCategory: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    /// Design token name: `chart-1` … `chart-5`, `muted-foreground`, `input`, `credit`.
    public var colorToken: String
    public var kind: DemoCategoryKind
    public var sortOrder: Int

    public var id: String { name }

    public init(name: String, colorToken: String, kind: DemoCategoryKind, sortOrder: Int) {
        self.name = name
        self.colorToken = colorToken
        self.kind = kind
        self.sortOrder = sortOrder
    }
}

public struct DemoRule: Sendable, Codable, Hashable {
    public var pattern: String
    public var category: String
    /// `manual` or `learned`.
    public var origin: String
    public var enabled: Bool

    public init(pattern: String, category: String, origin: String, enabled: Bool) {
        self.pattern = pattern
        self.category = category
        self.origin = origin
        self.enabled = enabled
    }
}

public struct DemoBudget: Sendable, Codable, Hashable {
    public var category: String
    /// Monthly limit in minor units.
    public var monthlyLimit: Int

    public init(category: String, monthlyLimit: Int) {
        self.category = category
        self.monthlyLimit = monthlyLimit
    }
}

public struct DemoFixedCostItem: Sendable, Codable, Hashable {
    public var label: String
    /// Positive minor units per month.
    public var amount: Int

    public init(label: String, amount: Int) {
        self.label = label
        self.amount = amount
    }
}

/// A fixed cost shown beside the budgets (rent, electricity, contracts and insurance).
public struct DemoFixedCost: Sendable, Codable, Hashable {
    public var label: String
    /// Positive minor units per month.
    public var amount: Int
    /// The parts of the amount when it is a group (contracts and insurance); empty otherwise.
    public var items: [DemoFixedCostItem]

    public init(label: String, amount: Int, items: [DemoFixedCostItem]) {
        self.label = label
        self.amount = amount
        self.items = items
    }
}

public enum DemoContractKind: String, Sendable, Codable, Hashable {
    case contract
    case income
}

public struct DemoContract: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var provider: String
    public var accountID: String
    public var groupName: String
    public var category: String
    /// `monthly`.
    public var rhythm: String
    /// Signed monthly amount in minor units (negative for contracts, positive for the salary).
    public var monthlyAmount: Int
    public var nextDebit: LocalDate
    public var noticeText: String
    public var noticeDeadline: LocalDate?
    public var renewalDate: LocalDate?
    /// New signed monthly amount after a price change.
    public var priceChangeAmount: Int?
    public var priceChangeStart: LocalDate?
    public var kind: DemoContractKind

    public init(id: String, provider: String, accountID: String, groupName: String, category: String, rhythm: String,
                monthlyAmount: Int, nextDebit: LocalDate, noticeText: String, noticeDeadline: LocalDate?,
                renewalDate: LocalDate?, priceChangeAmount: Int?, priceChangeStart: LocalDate?, kind: DemoContractKind) {
        self.id = id
        self.provider = provider
        self.accountID = accountID
        self.groupName = groupName
        self.category = category
        self.rhythm = rhythm
        self.monthlyAmount = monthlyAmount
        self.nextDebit = nextDebit
        self.noticeText = noticeText
        self.noticeDeadline = noticeDeadline
        self.renewalDate = renewalDate
        self.priceChangeAmount = priceChangeAmount
        self.priceChangeStart = priceChangeStart
        self.kind = kind
    }
}

public struct DemoSavingsPlanItem: Sendable, Codable, Hashable {
    public var isin: String
    public var name: String
    /// Share of the monthly amount in percent.
    public var sharePercent: Int
    public var amount: Int

    public init(isin: String, name: String, sharePercent: Int, amount: Int) {
        self.isin = isin
        self.name = name
        self.sharePercent = sharePercent
        self.amount = amount
    }
}

public struct DemoSavingsPlan: Sendable, Codable, Hashable {
    public var depotAccountID: String
    public var sourceAccountID: String
    public var monthlyAmount: Int
    public var dayOfMonth: Int
    public var nextExecution: LocalDate
    public var items: [DemoSavingsPlanItem]

    public init(depotAccountID: String, sourceAccountID: String, monthlyAmount: Int, dayOfMonth: Int,
                nextExecution: LocalDate, items: [DemoSavingsPlanItem]) {
        self.depotAccountID = depotAccountID
        self.sourceAccountID = sourceAccountID
        self.monthlyAmount = monthlyAmount
        self.dayOfMonth = dayOfMonth
        self.nextExecution = nextExecution
        self.items = items
    }
}

/// Estimated regional weights of a fund in permille (sum 1000), used for "Allocation by region".
public struct DemoFundRegionWeights: Sendable, Codable, Hashable {
    public var isin: String
    public var northAmerica: Int
    public var europe: Int
    public var emergingMarkets: Int
    public var japanPacific: Int

    public init(isin: String, northAmerica: Int, europe: Int, emergingMarkets: Int, japanPacific: Int) {
        self.isin = isin
        self.northAmerica = northAmerica
        self.europe = europe
        self.emergingMarkets = emergingMarkets
        self.japanPacific = japanPacific
    }
}

public enum DemoInsightKind: String, Sendable, Codable, Hashable {
    case ask
    case suggestion
    case notice
    case review
    case tax
    case attention
}

/// A stored AI result. `payload` is JSON text of the typed payload struct for `kind`
/// (see `DemoInsightPayloads.swift`); decode it with `payload(as:)`.
public struct DemoInsight: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var kind: DemoInsightKind
    /// Bank reference of the transaction the insight is about (suggestions).
    public var transactionReference: String?
    public var sortOrder: Int
    public var payload: String

    public init(id: String, kind: DemoInsightKind, transactionReference: String?, sortOrder: Int, payload: String) {
        self.id = id
        self.kind = kind
        self.transactionReference = transactionReference
        self.sortOrder = sortOrder
        self.payload = payload
    }

    public func payload<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(payload.utf8))
    }
}
