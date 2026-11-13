import Foundation
import GRDB

// Everything the October review shows. The stored `review` insight supplies the sentences and the
// forecast; the figures next to them (income, spending, saved, category comparisons, source amounts)
// are computed from the ledger with the shared definitions.

/// A ledger transaction cited by a stored insight (by bank reference).
public struct CitedTransaction: Hashable, Sendable {
    public var id: String
    public var accountID: String
    public var accountName: String
    public var bookingDate: LocalDate
    /// Signed minor units.
    public var amount: Int
    public var categoryID: String?
}

enum CitedTransactions {
    /// The live transaction with this bank reference (first account in ledger order when several match).
    static func find(_ db: Database, reference: String) throws -> CitedTransaction? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT t.id AS id, t.account_id AS account_id, a.name AS account_name, t.booking_date AS booking_date,
                   t.amount AS amount, t.category_id AS category_id
            FROM ledger_transaction t JOIN account a ON a.id = t.account_id
            WHERE t.bank_ref = ? AND t.deleted_at IS NULL AND a.deleted_at IS NULL
            ORDER BY a.sort_order, a.name
            LIMIT 1
            """, arguments: [reference])
        else { return nil }
        let id: String = row["id"]
        let accountID: String = row["account_id"]
        let accountName: String = row["account_name"]
        let date: String = row["booking_date"]
        let amount: Int = row["amount"]
        let categoryID: String? = row["category_id"]
        guard let bookingDate = LocalDate(iso: date) else { return nil }
        return CitedTransaction(
            id: id, accountID: accountID, accountName: accountName, bookingDate: bookingDate, amount: amount,
            categoryID: categoryID)
    }

    /// Cited rows in the order of `references`; unknown references are skipped.
    static func find(_ db: Database, references: [String]) throws -> [CitedTransaction] {
        try references.compactMap { try find(db, reference: $0) }
    }
}

/// One finding under "What changed": the stored sentences and the category it is about.
public struct ReviewFindingRow: Hashable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var detail: String
    /// Design token of the category the cited transactions belong to; `muted-foreground` when unknown.
    public var colorToken: String
    /// Spending of the reviewed month in that category (positive minor units).
    public var monthAmount: Int
    /// Mean monthly spending of the six months before (positive minor units).
    public var averageAmount: Int
    /// `+201 €`, `±0 €`: month minus average in whole euros.
    public var deltaText: String
    public var sourceNumbers: [Int]
    public var id: Int { number }
}

/// One cited source row.
public struct ReviewSourceRow: Hashable, Sendable, Identifiable {
    public var number: Int
    public var dateText: String
    public var label: String
    /// Sum of the cited ledger rows (signed minor units).
    public var amount: Int
    public var transactions: [CitedTransaction]
    public var id: Int { number }
}

/// One day of the November outlook.
public struct ReviewForecastPoint: Hashable, Sendable {
    public var date: LocalDate
    public var expected: Int
    public var low: Int
    public var high: Int
}

public struct ReviewOutlookFigures: Hashable, Sendable {
    public var accountName: String
    public var todayBalance: Int
    public var startDate: LocalDate
    public var salaryDate: LocalDate
    public var salaryAmount: Int
    public var lowestAmount: Int
    public var lowestDate: LocalDate
    public var endDate: LocalDate
    public var lowestText: String
    public var rangeText: String
    public var rentText: String
    public var points: [ReviewForecastPoint]
}

/// A transfer the "Prepare transfer" step starts with.
public struct ReviewTransferHint: Hashable, Sendable {
    public var fromAccountID: String
    public var recipient: String
    public var iban: String
    /// Positive minor units.
    public var amount: Int
}

public struct ReviewStepRow: Hashable, Sendable, Identifiable {
    public var index: Int
    public var title: String
    public var detail: String
    public var actionTitle: String
    public var sourceNumber: Int?
    /// Set for a step that moves money to the user's own savings account.
    public var transfer: ReviewTransferHint?
    public var id: Int { index }
}

public struct ReviewSnapshot: Hashable, Sendable {
    /// First day of the reviewed month.
    public var month: LocalDate
    public var closedOn: LocalDate
    public var headline: String
    /// Income of the month: positive rows filed under an income category (minor units).
    public var income: Int
    public var incomeAverage: Int
    /// Spending of the month (positive minor units, `LedgerDefinitions.totalSpending`).
    public var spending: Int
    public var spendingAverage: Int
    public var findings: [ReviewFindingRow]
    /// Common scale of the finding bars (minor units): the largest value rounded up to 100,00 €.
    public var barScale: Int
    public var sources: [ReviewSourceRow]
    public var outlook: ReviewOutlookFigures
    public var steps: [ReviewStepRow]

    public var saved: Int { income - spending }
    public var savedAverage: Int { incomeAverage - spendingAverage }
}

public enum ReviewQueries {
    // MARK: Stored content (mirrors of `ReviewPayload` in IMMBanking, only the fields used here)

    private struct Payload: Decodable {
        var month: LocalDate
        var headline: String
        var findings: [Finding]
        var sources: [Source]
        var outlook: Outlook
        var steps: [Step]

        struct Finding: Decodable {
            var number: Int
            var title: String
            var detail: String
            var deltaText: String
            var sourceNumbers: [Int]
        }

        struct Source: Decodable {
            var number: Int
            var dateText: String
            var label: String
            var amount: Int?
            var transactionReferences: [String]
        }

        struct Day: Decodable {
            var date: LocalDate
            var expected: Int
            var low: Int
            var high: Int
        }

        struct Outlook: Decodable {
            var todayBalance: Int
            var salaryDate: LocalDate
            var salaryAmount: Int
            var lowestAmount: Int
            var lowestDate: LocalDate
            var endDate: LocalDate
            var lowestText: String
            var rangeText: String
            var rentText: String
            var days: [Day]
        }

        struct Step: Decodable {
            var title: String
            var detail: String
            var actionTitle: String
            var sourceNumber: Int?
        }
    }

    /// The review of the stored `review` insight, or nil when there is none.
    public static func snapshot(_ db: Database) throws -> ReviewSnapshot? {
        guard let insight = try InsightRecord.live()
            .filter(sql: "kind = ?", arguments: [InsightKind.review.rawValue])
            .order(Column("sort_order"), Column("id"))
            .fetchOne(db),
            let payload = try? JSONDecoder().decode(Payload.self, from: Data(insight.payload.utf8))
        else { return nil }

        let start = payload.month.firstOfMonth
        let end = start.adding(months: 1).adding(days: -1)

        // Income: positive rows filed under an income category.
        func income(_ from: LocalDate, _ through: LocalDate) throws -> Int {
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(t.amount), 0) FROM ledger_transaction t JOIN category k ON k.id = t.category_id
                WHERE t.deleted_at IS NULL AND k.kind = 'income' AND t.amount > 0 AND t.booking_date BETWEEN ? AND ?
                """, arguments: [from.iso, through.iso]) ?? 0
        }

        // "6-month average": the six complete months before the reviewed month, whole minor units by
        // truncating division.
        var sixIncome = 0
        var sixSpending = 0
        var sixByCategory: [String: Int] = [:]
        for offset in -6...(-1) {
            let from = start.adding(months: offset)
            let through = from.adding(months: 1).adding(days: -1)
            sixIncome += try income(from, through)
            let spending = try LedgerDefinitions.spending(db, from: from, through: through)
            sixSpending += spending.values.reduce(0, +)
            for (id, amount) in spending { sixByCategory[id, default: 0] += amount }
        }
        let month = try LedgerDefinitions.spending(db, from: start, through: end)

        let categories = try CategoryRecord.live().fetchAll(db)
        let tokens = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.colorToken) })

        // Sources first: findings find their category through the rows their sources cite.
        let sources = try payload.sources.map { source -> ReviewSourceRow in
            let rows = try CitedTransactions.find(db, references: source.transactionReferences)
            let amount = rows.isEmpty ? (source.amount ?? 0) : rows.reduce(0) { $0 + $1.amount }
            return ReviewSourceRow(
                number: source.number, dateText: source.dateText, label: source.label, amount: amount, transactions: rows)
        }

        var findings: [ReviewFindingRow] = []
        for finding in payload.findings {
            let cited = sources.filter { finding.sourceNumbers.contains($0.number) }.flatMap(\.transactions)
            var counts: [String: Int] = [:]
            for row in cited { if let id = row.categoryID { counts[id, default: 0] += 1 } }
            let categoryID = counts.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?.key
            let monthAmount = categoryID.flatMap { month[$0] } ?? 0
            let averageAmount = categoryID.flatMap { sixByCategory[$0] }.map { $0 / 6 } ?? 0
            findings.append(ReviewFindingRow(
                number: finding.number, title: finding.title, detail: finding.detail,
                colorToken: categoryID.flatMap { tokens[$0] } ?? "muted-foreground",
                monthAmount: monthAmount, averageAmount: averageAmount,
                deltaText: categoryID == nil ? finding.deltaText : wholeEuroDelta(monthAmount - averageAmount),
                sourceNumbers: finding.sourceNumbers))
        }
        let largest = findings.flatMap { [$0.monthAmount, $0.averageAmount] }.max() ?? 0
        let barScale = max(10_000, (largest + 9_999) / 10_000 * 10_000)

        // Outlook.
        let accounts = try AccountRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        let giro = accounts.first { $0.kind == .giro }
        let days = payload.outlook.days
        let outlook = ReviewOutlookFigures(
            accountName: giro?.name ?? "",
            todayBalance: giro?.balance ?? payload.outlook.todayBalance,
            startDate: days.first?.date ?? payload.outlook.endDate,
            salaryDate: payload.outlook.salaryDate, salaryAmount: payload.outlook.salaryAmount,
            lowestAmount: payload.outlook.lowestAmount, lowestDate: payload.outlook.lowestDate,
            endDate: payload.outlook.endDate, lowestText: payload.outlook.lowestText,
            rangeText: payload.outlook.rangeText, rentText: payload.outlook.rentText,
            points: days.map { ReviewForecastPoint(date: $0.date, expected: $0.expected, low: $0.low, high: $0.high) })

        // Steps; a "Move N € to Tagesgeld" step carries the transfer it prepares.
        let savings = accounts.first { $0.kind == .savings }
        let steps = payload.steps.enumerated().map { index, step -> ReviewStepRow in
            var transfer: ReviewTransferHint?
            if let giro, let savings, let iban = savings.iban, step.actionTitle == "Prepare transfer",
               let amount = firstWholeEuroAmount(in: step.title) {
                transfer = ReviewTransferHint(fromAccountID: giro.id, recipient: savings.name, iban: iban, amount: amount)
            }
            return ReviewStepRow(
                index: index, title: step.title, detail: step.detail, actionTitle: step.actionTitle,
                sourceNumber: step.sourceNumber, transfer: transfer)
        }

        let monthIncome = try income(start, end)
        return ReviewSnapshot(
            month: start, closedOn: end, headline: payload.headline,
            income: monthIncome, incomeAverage: sixIncome / 6,
            spending: month.values.reduce(0, +), spendingAverage: sixSpending / 6,
            findings: findings, barScale: barScale, sources: sources, outlook: outlook, steps: steps)
    }

    /// Re-emits whenever one of the tables behind the review changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<ReviewSnapshot?> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }

    // MARK: Formatting

    /// `+201 €`, `−35 €`, `±0 €`: whole euros, rounded half away from zero.
    static func wholeEuroDelta(_ minor: Int) -> String {
        let rounded = Int((Double(minor) / 100.0).rounded()) * 100
        if rounded == 0 { return "±" + MoneyFormatter.string(0).replacingOccurrences(of: ",00", with: "") }
        return MoneyFormatter.string(rounded, sign: .always).replacingOccurrences(of: ",00", with: "")
    }

    /// The first `1.000 €` style amount of a sentence in minor units.
    static func firstWholeEuroAmount(in text: String) -> Int? {
        guard let range = text.range(of: #"\d{1,3}(\.\d{3})*(?=[\s\u00A0]?€)"#, options: .regularExpression) else { return nil }
        guard let euros = Int(text[range].replacingOccurrences(of: ".", with: "")) else { return nil }
        return euros * 100
    }
}
