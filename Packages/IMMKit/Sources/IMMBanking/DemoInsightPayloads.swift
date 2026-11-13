import Foundation
import IMMLedger

// Typed payloads of `DemoInsight.payload` (JSON text). Money is signed minor units unless noted;
// every sentence is final text with its numbers already formatted from the data set.

/// `attention`: one row of "Needs attention" on the Overview.
public struct AttentionPayload: Sendable, Codable, Hashable {
    public var title: String
    public var detail: String
    public var actionTitle: String?
    /// Where the row leads: `suggestions` or `contracts`.
    public var target: String

    public init(title: String, detail: String, actionTitle: String?, target: String) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.target = target
    }
}

/// `suggestion`: a proposed category for one uncategorised transaction (`transactionReference` is set).
public struct SuggestionPayload: Sendable, Codable, Hashable {
    public var suggestedCategory: String
    /// `sure`, `likely` or `check`.
    public var confidence: String
    /// `Sure`, `Likely` or `Check this`.
    public var confidenceLabel: String
    public var reason: String
    /// Number of the source line `[n]` the reason cites.
    public var sourceNumber: Int?
    /// Checked when the screen opens.
    public var preselected: Bool

    public init(suggestedCategory: String, confidence: String, confidenceLabel: String, reason: String,
                sourceNumber: Int?, preselected: Bool) {
        self.suggestedCategory = suggestedCategory
        self.confidence = confidence
        self.confidenceLabel = confidenceLabel
        self.reason = reason
        self.sourceNumber = sourceNumber
        self.preselected = preselected
    }
}

/// One numbered source line (`[1] 14.10.2026 Amazon … −27,49 €`).
public struct InsightSource: Sendable, Codable, Hashable {
    public var number: Int
    /// `14.10.2026`, `25.–31.10.2026`, `08. + 22.10.2026`.
    public var dateText: String
    public var label: String
    public var amount: Int?
    public var transactionReferences: [String]

    public init(number: Int, dateText: String, label: String, amount: Int?, transactionReferences: [String]) {
        self.number = number
        self.dateText = dateText
        self.label = label
        self.amount = amount
        self.transactionReferences = transactionReferences
    }
}

/// `notice`: variants `doubleCharge`, `newRule` and `sources` ("Also noticed" and "Sources" on Suggestions).
public struct NoticePayload: Sendable, Codable, Hashable {
    public var variant: String
    public var text: String
    public var sourceNumber: Int?
    public var actionTitle: String?
    public var transactionReferences: [String]
    /// `newRule` only.
    public var pattern: String?
    public var category: String?
    /// `sources` only.
    public var sources: [InsightSource]

    public init(variant: String, text: String, sourceNumber: Int?, actionTitle: String?, transactionReferences: [String],
                pattern: String?, category: String?, sources: [InsightSource]) {
        self.variant = variant
        self.text = text
        self.sourceNumber = sourceNumber
        self.actionTitle = actionTitle
        self.transactionReferences = transactionReferences
        self.pattern = pattern
        self.category = category
        self.sources = sources
    }
}

public struct AskMonth: Sendable, Codable, Hashable {
    /// `Jun` … `Nov`.
    public var label: String
    /// Positive minor units.
    public var amount: Int
    /// True for the running month.
    public var partial: Bool

    public init(label: String, amount: Int, partial: Bool) {
        self.label = label
        self.amount = amount
        self.partial = partial
    }
}

public struct AskGroup: Sendable, Codable, Hashable {
    public var name: String
    /// `22 orders`, `14 visits`, `19 payments`.
    public var countText: String
    public var count: Int
    /// Negative minor units.
    public var amount: Int
    public var sourceNumber: Int
    public var transactionReferences: [String]

    public init(name: String, countText: String, count: Int, amount: Int, sourceNumber: Int, transactionReferences: [String]) {
        self.name = name
        self.countText = countText
        self.count = count
        self.amount = amount
        self.sourceNumber = sourceNumber
        self.transactionReferences = transactionReferences
    }
}

/// `ask`: the one stored question and its answer.
public struct AskPayload: Sendable, Codable, Hashable {
    public var question: String
    /// `Leisure & eating out, 01.06.–12.11.2026`.
    public var headline: String
    /// Negative minor units.
    public var total: Int
    public var confidenceLabel: String
    /// `About 331 € a month, 18 % more than the same months last year`.
    public var summary: String
    public var summarySourceNumber: Int
    public var monthly: [AskMonth]
    public var monthlyCaption: String
    public var groups: [AskGroup]
    /// `Total since 01.06.`
    public var totalLabel: String
    public var totalPayments: Int
    /// Spending in the same months of the previous year (positive) and the rounded change in percent.
    public var previousYearTotal: Int
    public var percentChange: Int
    public var actions: [String]
    public var transactionReferences: [String]

    public init(question: String, headline: String, total: Int, confidenceLabel: String, summary: String,
                summarySourceNumber: Int, monthly: [AskMonth], monthlyCaption: String, groups: [AskGroup],
                totalLabel: String, totalPayments: Int, previousYearTotal: Int, percentChange: Int,
                actions: [String], transactionReferences: [String]) {
        self.question = question
        self.headline = headline
        self.total = total
        self.confidenceLabel = confidenceLabel
        self.summary = summary
        self.summarySourceNumber = summarySourceNumber
        self.monthly = monthly
        self.monthlyCaption = monthlyCaption
        self.groups = groups
        self.totalLabel = totalLabel
        self.totalPayments = totalPayments
        self.previousYearTotal = previousYearTotal
        self.percentChange = percentChange
        self.actions = actions
        self.transactionReferences = transactionReferences
    }
}

public struct ReviewRow: Sendable, Codable, Hashable {
    public var label: String
    public var month: Int
    public var average: Int

    public init(label: String, month: Int, average: Int) {
        self.label = label
        self.month = month
        self.average = average
    }
}

public struct ReviewFinding: Sendable, Codable, Hashable {
    public var number: Int
    public var title: String
    public var detail: String
    /// `+196 €`, `±0 €`.
    public var deltaText: String
    public var deltaAmount: Int
    public var sourceNumbers: [Int]

    public init(number: Int, title: String, detail: String, deltaText: String, deltaAmount: Int, sourceNumbers: [Int]) {
        self.number = number
        self.title = title
        self.detail = detail
        self.deltaText = deltaText
        self.deltaAmount = deltaAmount
        self.sourceNumbers = sourceNumbers
    }
}

public struct ForecastDay: Sendable, Codable, Hashable {
    public var date: LocalDate
    public var expected: Int
    public var low: Int
    public var high: Int

    public init(date: LocalDate, expected: Int, low: Int, high: Int) {
        self.date = date
        self.expected = expected
        self.low = low
        self.high = high
    }
}

public struct ReviewOutlook: Sendable, Codable, Hashable {
    public var todayBalance: Int
    public var salaryDate: LocalDate
    public var salaryAmount: Int
    public var lowestAmount: Int
    public var lowestDate: LocalDate
    public var endDate: LocalDate
    public var expectedEnd: Int
    public var rangeLow: Int
    public var rangeHigh: Int
    /// `Lowest 1.000 € on 26.11.`
    public var lowestText: String
    /// `Likely 5.150–5.750 € on 30.11.`
    public var rangeText: String
    /// `Then Miete −1.120,00 € is booked on 01.12.`
    public var rentText: String
    public var days: [ForecastDay]

    public init(todayBalance: Int, salaryDate: LocalDate, salaryAmount: Int, lowestAmount: Int, lowestDate: LocalDate,
                endDate: LocalDate, expectedEnd: Int, rangeLow: Int, rangeHigh: Int, lowestText: String,
                rangeText: String, rentText: String, days: [ForecastDay]) {
        self.todayBalance = todayBalance
        self.salaryDate = salaryDate
        self.salaryAmount = salaryAmount
        self.lowestAmount = lowestAmount
        self.lowestDate = lowestDate
        self.endDate = endDate
        self.expectedEnd = expectedEnd
        self.rangeLow = rangeLow
        self.rangeHigh = rangeHigh
        self.lowestText = lowestText
        self.rangeText = rangeText
        self.rentText = rentText
        self.days = days
    }
}

public struct ReviewStep: Sendable, Codable, Hashable {
    public var title: String
    public var detail: String
    public var actionTitle: String
    public var sourceNumber: Int?

    public init(title: String, detail: String, actionTitle: String, sourceNumber: Int?) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.sourceNumber = sourceNumber
    }
}

/// `review`: the October review.
public struct ReviewPayload: Sendable, Codable, Hashable {
    public var month: LocalDate
    public var headline: String
    /// Income, Spending, Saved; `month` and `average` are signed minor units (spending negative).
    public var rows: [ReviewRow]
    public var findings: [ReviewFinding]
    public var sources: [InsightSource]
    public var outlook: ReviewOutlook
    public var steps: [ReviewStep]

    public init(month: LocalDate, headline: String, rows: [ReviewRow], findings: [ReviewFinding],
                sources: [InsightSource], outlook: ReviewOutlook, steps: [ReviewStep]) {
        self.month = month
        self.headline = headline
        self.rows = rows
        self.findings = findings
        self.sources = sources
        self.outlook = outlook
        self.steps = steps
    }
}

public struct TaxItem: Sendable, Codable, Hashable {
    public var transactionReferences: [String]
    /// Date of the (first) payment.
    public var date: LocalDate
    public var payee: String
    public var purpose: String
    public var why: String
    /// `attached`, `needed` or `statementEnough`.
    public var receipt: String
    public var receiptLabel: String
    /// Negative minor units (sum of the payments).
    public var amount: Int
    /// Part that counts when it differs from the payment (`520,00 eligible`).
    public var eligibleAmount: Int?
    public var sourceNumber: Int?

    public init(transactionReferences: [String], date: LocalDate, payee: String, purpose: String, why: String,
                receipt: String, receiptLabel: String, amount: Int, eligibleAmount: Int?, sourceNumber: Int?) {
        self.transactionReferences = transactionReferences
        self.date = date
        self.payee = payee
        self.purpose = purpose
        self.why = why
        self.receipt = receipt
        self.receiptLabel = receiptLabel
        self.amount = amount
        self.eligibleAmount = eligibleAmount
        self.sourceNumber = sourceNumber
    }
}

public struct TaxGroup: Sendable, Codable, Hashable {
    /// `Anlage N — Werbungskosten`.
    public var form: String
    public var itemCountText: String
    /// Positive minor units.
    public var total: Int
    public var items: [TaxItem]

    public init(form: String, itemCountText: String, total: Int, items: [TaxItem]) {
        self.form = form
        self.itemCountText = itemCountText
        self.total = total
        self.items = items
    }
}

/// `tax`: Tax return 2026.
public struct TaxPayload: Sendable, Codable, Hashable {
    public var year: Int
    /// Positive minor units.
    public var total: Int
    public var totalCaption: String
    /// `8 items from Girokonto and Visa Card, 4 with receipts`.
    public var summary: String
    public var itemCount: Int
    public var formCount: Int
    public var needsReceiptCount: Int
    public var groups: [TaxGroup]
    public var footnotes: [InsightSource]
    public var disclaimer: String

    public init(year: Int, total: Int, totalCaption: String, summary: String, itemCount: Int, formCount: Int,
                needsReceiptCount: Int, groups: [TaxGroup], footnotes: [InsightSource], disclaimer: String) {
        self.year = year
        self.total = total
        self.totalCaption = totalCaption
        self.summary = summary
        self.itemCount = itemCount
        self.formCount = formCount
        self.needsReceiptCount = needsReceiptCount
        self.groups = groups
        self.footnotes = footnotes
        self.disclaimer = disclaimer
    }
}
