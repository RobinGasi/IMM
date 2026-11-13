import Foundation
import GRDB

// Everything the Categories screen shows, computed from the ledger in one read.
// Definitions: `LedgerDefinitions` (spending per category, monthly average); "today" is `LedgerClock`.

/// One expense category with the merchants that make up most of its spending.
public struct CategoriesCategory: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Design token name (`chart-1`).
    public var colorToken: String
    /// Up to three payees, most frequent first (`Miete, Strom`).
    public var merchants: [String]
}

/// Spending of one calendar month, per category.
public struct CategoriesMonth: Hashable, Sendable, Identifiable {
    /// Three-letter English month name (`Dec`).
    public var label: String
    public var start: LocalDate
    /// Last day of the month, or the ledger's today for the running month.
    public var end: LocalDate
    /// The running month: its bar and its figures are not final.
    public var isPartial: Bool
    /// Positive minor units keyed by category id; categories without spending are absent.
    public var byCategory: [String: Int]

    public var id: LocalDate { start }
    public var total: Int { byCategory.values.reduce(0, +) }
}

public struct CategoriesSnapshot: Hashable, Sendable {
    public var today: LocalDate
    /// Expense categories in ledger order.
    public var categories: [CategoriesCategory]
    /// The 12 months up to the current one, oldest first. The last one is partial.
    public var months: [CategoriesMonth]
    /// First day of the calendar quarter of `today`.
    public var quarterStart: LocalDate
    /// Spending from `quarterStart` through today, positive minor units by category id.
    public var quarterSpending: [String: Int]
    /// Mean spending of the 11 complete months before the current one (`LedgerDefinitions`).
    public var monthlyAverage: Int
    /// Amount of the latest salary booking (positive minor units); 0 without one.
    public var salary: Int
    /// Enabled categorisation rules.
    public var rulesCount: Int

    /// The running month.
    public var currentMonth: CategoriesMonth { months[months.count - 1] }
    /// The months before the running one.
    public var completeMonths: [CategoriesMonth] { Array(months.dropLast()) }

    /// Mean spending of one category over the complete months, rounded half away from zero.
    public func average(of category: String) -> Int {
        let complete = completeMonths
        guard !complete.isEmpty else { return 0 }
        let sum = complete.reduce(0) { $0 + ($1.byCategory[category] ?? 0) }
        return (2 * sum + complete.count) / (2 * complete.count)
    }

    /// Spending of one category over all 12 months, the running month included.
    public func yearTotal(of category: String) -> Int {
        months.reduce(0) { $0 + ($1.byCategory[category] ?? 0) }
    }

    /// Spending of one category in the running month.
    public func thisMonth(of category: String) -> Int { currentMonth.byCategory[category] ?? 0 }

    /// Spending of one category from the start of the quarter through today.
    public func thisQuarter(of category: String) -> Int { quarterSpending[category] ?? 0 }

    public var thisMonthTotal: Int { categories.reduce(0) { $0 + thisMonth(of: $1.id) } }
    public var thisQuarterTotal: Int { categories.reduce(0) { $0 + thisQuarter(of: $1.id) } }
    public var yearTotal: Int { categories.reduce(0) { $0 + yearTotal(of: $1.id) } }
    /// Sum of the category averages (equals `monthlyAverage` up to rounding of single rows).
    public var averageOfRows: Int { categories.reduce(0) { $0 + average(of: $1.id) } }

    /// The complete month with the highest spending; the earlier one on a tie.
    public var mostExpensiveMonth: CategoriesMonth? {
        var best: CategoriesMonth?
        for month in completeMonths where month.total > (best?.total ?? -1) { best = month }
        return best
    }

    /// Salary less the monthly average and its share of the salary in whole percent; nil without a salary.
    public var leftAfterAverage: (amount: Int, percent: Int)? {
        guard salary > 0 else { return nil }
        let left = salary - monthlyAverage
        return (left, (left * 200 + salary) / (2 * salary))
    }
}

public enum CategoriesQueries {
    /// Payees listed beside a category name.
    static let merchantLimit = 3

    public static func snapshot(_ db: Database) throws -> CategoriesSnapshot {
        let today = try LedgerClock.today(db)
        let monthStart = today.firstOfMonth
        let allCategories = try CategoryRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        let expense = allCategories.filter { $0.kind == .expense }

        var months: [CategoriesMonth] = []
        for offset in -11...0 {
            let start = monthStart.adding(months: offset)
            let isPartial = offset == 0
            let end = isPartial ? today : start.adding(months: 1).adding(days: -1)
            months.append(CategoriesMonth(
                label: String(DateFormats.monthName(start).prefix(3)), start: start, end: end,
                isPartial: isPartial, byCategory: try LedgerDefinitions.spending(db, from: start, through: end)))
        }

        let quarterStart = LocalDate(year: today.year, month: (today.month - 1) / 3 * 3 + 1, day: 1)
        let merchants = try merchants(db, from: months[0].start, through: today)
        let categories = expense.map {
            CategoriesCategory(id: $0.id, name: $0.name, colorToken: $0.colorToken, merchants: merchants[$0.id] ?? [])
        }
        let salary = try Int.fetchOne(db, sql: """
            SELECT amount FROM ledger_transaction WHERE kind = 'salary' AND deleted_at IS NULL
            ORDER BY booking_date DESC, booking_seq DESC LIMIT 1
            """) ?? 0
        let rules = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rule WHERE deleted_at IS NULL AND enabled = 1") ?? 0

        return CategoriesSnapshot(
            today: today,
            categories: categories,
            months: months,
            quarterStart: quarterStart,
            quarterSpending: try LedgerDefinitions.spending(db, from: quarterStart, through: today),
            monthlyAverage: try LedgerDefinitions.monthlyAverageSpending(db, today: today),
            salary: max(0, salary),
            rulesCount: rules)
    }

    /// Re-emits whenever one of the tables behind the snapshot changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<CategoriesSnapshot> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }

    /// The most frequent payees per category over the period (same rows as `LedgerDefinitions.spending`), ties by spending.
    private static func merchants(_ db: Database, from: LocalDate, through: LocalDate) throws -> [String: [String]] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.category_id AS category_id,
                   COALESCE(NULLIF(t.short_name, ''), t.counterparty_name) AS payee,
                   COUNT(*) AS bookings,
                   -SUM(t.amount) AS total
            FROM ledger_transaction t
            JOIN category c ON c.id = t.category_id
            WHERE t.deleted_at IS NULL AND c.deleted_at IS NULL
              AND t.amount < 0 AND t.is_own_transfer = 0 AND c.kind = 'expense'
              AND t.booking_date BETWEEN ? AND ?
            GROUP BY t.category_id, payee
            ORDER BY bookings DESC, total DESC, payee
            """, arguments: [from.iso, through.iso])
        var result: [String: [String]] = [:]
        for row in rows {
            let category: String = row["category_id"]
            let payee: String = row["payee"]
            if result[category, default: []].count < merchantLimit { result[category, default: []].append(payee) }
        }
        return result
    }
}
