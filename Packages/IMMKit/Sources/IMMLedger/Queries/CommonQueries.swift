import Foundation
import GRDB

/// Canonical transaction ordering.
public enum LedgerOrder {
    /// `ORDER BY` terms for newest-first: booking date, then booked time (rows without a time sort
    /// before rows with one on the same day), then the importer's `booking_seq`, then `id`.
    /// `alias` is a table alias such as `"t"`; pass `""` for unqualified columns.
    public static func transactionsNewestFirst(alias: String = "") -> String {
        let p = alias.isEmpty ? "" : alias + "."
        return "\(p)booking_date DESC, COALESCE(\(p)booked_time, '') DESC, \(p)booking_seq DESC, \(p)id DESC"
    }
}

/// The definitions every screen uses for the same quantities. All amounts are minor units.
public enum LedgerDefinitions {
    /// Spending per category between `from` and `through` (both inclusive, by booking date).
    ///
    /// Counts rows that are not tombstoned, have `amount < 0`, `is_own_transfer = 0` and a category of
    /// kind `expense`, on all accounts. Returns positive minor units keyed by category id; categories
    /// without spending are absent.
    public static func spending(_ db: Database, from: LocalDate, through: LocalDate) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.category_id AS category_id, -SUM(t.amount) AS total
            FROM ledger_transaction t
            JOIN category c ON c.id = t.category_id
            WHERE t.deleted_at IS NULL AND c.deleted_at IS NULL
              AND t.amount < 0 AND t.is_own_transfer = 0 AND c.kind = 'expense'
              AND t.booking_date BETWEEN ? AND ?
            GROUP BY t.category_id
            """, arguments: [from.iso, through.iso])
        var result: [String: Int] = [:]
        for row in rows {
            let id: String = row["category_id"]
            let total: Int = row["total"]
            result[id] = total
        }
        return result
    }

    /// Sum of ``spending(_:from:through:)`` over all categories.
    public static func totalSpending(_ db: Database, from: LocalDate, through: LocalDate) throws -> Int {
        try spending(db, from: from, through: through).values.reduce(0, +)
    }

    /// Mean total spending of the 11 complete calendar months before the month of `today`
    /// (for 12.11.2026: December 2025 … October 2026), rounded half-up to whole minor units.
    public static func monthlyAverageSpending(_ db: Database, today: LocalDate) throws -> Int {
        let currentMonth = today.firstOfMonth
        let start = currentMonth.adding(months: -11)
        let end = currentMonth.adding(days: -1)
        let total = try totalSpending(db, from: start, through: end)
        return (2 * total + 11) / 22
    }

    /// Balance after each non-tombstoned transaction of `accountID`, keyed by transaction id.
    ///
    /// Defined as the account's current balance minus the sum of all later transactions, where "later"
    /// follows ``LedgerOrder/transactionsNewestFirst(alias:)`` reversed. The newest row therefore shows
    /// the account balance. Computed with a SQL window function.
    public static func runningBalances(_ db: Database, accountID: String) throws -> [String: Int] {
        let order = LedgerOrder.transactionsNewestFirst(alias: "t")
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id AS id,
                   a.balance - COALESCE(
                       SUM(t.amount) OVER (
                           ORDER BY \(order)
                           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                       ), 0) AS balance_after
            FROM ledger_transaction t
            JOIN account a ON a.id = t.account_id
            WHERE t.account_id = ? AND t.deleted_at IS NULL
            """, arguments: [accountID])
        var result: [String: Int] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let id: String = row["id"]
            let balance: Int = row["balance_after"]
            result[id] = balance
        }
        return result
    }

    /// Market value of the holdings of a depot account: per holding `quantity × price`, rounded
    /// half-up to minor units, summed (cash is a holding with quantity 1). `nil` when the account has no holdings.
    public static func holdingsValue(_ db: Database, accountID: String) throws -> Int? {
        let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n,
                   COALESCE(SUM((quantity_micro * price + 500000) / 1000000), 0) AS value
            FROM holding
            WHERE account_id = ? AND deleted_at IS NULL
            """, arguments: [accountID])
        guard let row else { return nil }
        let count: Int = row["n"]
        let value: Int = row["value"]
        return count == 0 ? nil : value
    }

    /// Depot value from `depot_value_history` on the latest date on or before `date`; `nil` if there is none.
    public static func depotValue(_ db: Database, accountID: String, on date: LocalDate) throws -> Int? {
        let row = try Row.fetchOne(db, sql: """
            SELECT value FROM depot_value_history
            WHERE account_id = ? AND date <= ? AND deleted_at IS NULL
            ORDER BY date DESC LIMIT 1
            """, arguments: [accountID, date.iso])
        guard let row else { return nil }
        let value: Int = row["value"]
        return value
    }

    /// Sum of account values (non-tombstoned accounts).
    ///
    /// - `on == nil` (now): non-depot accounts contribute `balance`; depot accounts contribute their
    ///   holdings value (``holdingsValue(_:accountID:)``), or `balance` when they have no holdings.
    /// - `on == date`: non-depot accounts contribute `balance` minus all transactions booked after
    ///   `date`; depot accounts contribute ``depotValue(_:accountID:on:)`` (0 when no history on or before `date`).
    public static func netWorth(_ db: Database, on date: LocalDate? = nil) throws -> Int {
        let accounts = try Row.fetchAll(db, sql: "SELECT id, kind, balance FROM account WHERE deleted_at IS NULL")
        var total = 0
        for row in accounts {
            let id: String = row["id"]
            let kind: String = row["kind"]
            let balance: Int = row["balance"]
            if kind == AccountKind.depot.rawValue {
                if let date {
                    total += try depotValue(db, accountID: id, on: date) ?? 0
                } else {
                    total += try holdingsValue(db, accountID: id) ?? balance
                }
            } else if let date {
                let later = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(amount), 0) FROM ledger_transaction
                    WHERE account_id = ? AND deleted_at IS NULL AND booking_date > ?
                    """, arguments: [id, date.iso]) ?? 0
                total += balance - later
            } else {
                total += balance
            }
        }
        return total
    }

    /// Number of non-tombstoned transactions with `is_new = 1`.
    public static func newCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ledger_transaction WHERE is_new = 1 AND deleted_at IS NULL") ?? 0
    }

    /// Number of non-tombstoned transactions without category, excluding own transfers
    /// (`is_own_transfer = 0`). Transfers from or to other people still need a category.
    public static func uncategorisedCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ledger_transaction
            WHERE category_id IS NULL AND is_own_transfer = 0 AND deleted_at IS NULL
            """) ?? 0
    }
}
