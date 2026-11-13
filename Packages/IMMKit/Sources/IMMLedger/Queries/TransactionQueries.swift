import Foundation
import GRDB

// Queries behind the Transactions screen: the filtered list with running balances, month totals and
// closing balances, the 90-day balance chart, and the extras the inspector needs.

/// Which accounts a transaction list covers.
public enum TransactionScope: Hashable, Sendable {
    case all
    /// Ledger account id.
    case account(String)
}

/// The period select. "Last N days" runs from `today − N` to `today`, so "Last 90 days" is
/// 14.08.–12.11.2026 for the ledger date 12.11.2026.
public enum TransactionPeriod: String, CaseIterable, Hashable, Sendable {
    case last30Days, last90Days, thisMonth, lastMonth, thisYear, allTime

    /// First and last booking date (inclusive); `from == nil` means no lower bound.
    public func window(today: LocalDate) -> (from: LocalDate?, through: LocalDate) {
        switch self {
        case .last30Days: return (today.adding(days: -30), today)
        case .last90Days: return (today.adding(days: -90), today)
        case .thisMonth: return (today.firstOfMonth, today)
        case .lastMonth:
            let first = today.firstOfMonth.adding(months: -1)
            return (first, today.firstOfMonth.adding(days: -1))
        case .thisYear: return (LocalDate(year: today.year, month: 1, day: 1), today)
        case .allTime: return (nil, today)
        }
    }
}

/// The All / Income / Spending toggle.
public enum TransactionDirection: String, CaseIterable, Hashable, Sendable {
    case all, income, spending
}

/// The category select.
public enum TransactionCategoryFilter: Hashable, Sendable {
    case all
    case category(String)
    /// Rows without a category (own transfers included).
    case uncategorised
}

public struct TransactionFilter: Hashable, Sendable {
    public var scope: TransactionScope
    public var period: TransactionPeriod
    public var direction: TransactionDirection
    public var category: TransactionCategoryFilter

    public init(
        scope: TransactionScope, period: TransactionPeriod = .last90Days,
        direction: TransactionDirection = .all, category: TransactionCategoryFilter = .all
    ) {
        self.scope = scope
        self.period = period
        self.direction = direction
        self.category = category
    }

    /// True when only the period narrows the list (closing balances stay valid).
    public var isOnlyPeriod: Bool { direction == .all && category == .all }
}

public struct TransactionCategory: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Design token name, e.g. `chart-5`.
    public var colorToken: String
    public var kind: CategoryKind
}

/// One row of the list with everything the inspector shows.
public struct TransactionItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var accountID: String
    public var accountName: String
    public var bookingDate: LocalDate
    public var valueDate: LocalDate?
    /// `HH:mm` when the bank reported a time.
    public var bookedTime: String?
    public var shortName: String?
    public var counterpartyName: String
    public var purpose: String?
    public var bookingText: String?
    public var creditorID: String?
    public var kind: TransactionKind
    /// Signed minor units.
    public var amount: Int
    public var currency: String
    public var categoryID: String?
    public var isOwnTransfer: Bool
    public var isNew: Bool
    public var note: String?
    /// Running balance after this row (single-account scopes only).
    public var balanceAfter: Int?

    /// Name the list shows: the short name, else the counterparty.
    public var payee: String { shortName.flatMap { $0.isEmpty ? nil : $0 } ?? counterpartyName }
}

/// One calendar month of the list.
public struct TransactionMonth: Hashable, Sendable {
    /// First day of the month.
    public var first: LocalDate
    /// Sum of the listed rows of this month, signed minor units.
    public var total: Int
    /// Balance at the end of the previous month (single account, period-only filters); nil when unknown
    /// or when no earlier transaction exists.
    public var previousClosing: Int?
}

/// The 90-day balance curve (end-of-day balances; days with a large booking get a vertical step).
public struct TransactionChart: Hashable, Sendable {
    public struct Point: Hashable, Sendable {
        /// 0 … 1 over the window.
        public var x: Double
        public var value: Int
    }
    public struct Payday: Hashable, Sendable {
        public var date: LocalDate
        public var x: Double
    }

    public var start: LocalDate
    public var end: LocalDate
    public var points: [Point]
    public var paydays: [Payday]
    public var minValue: Int
    public var maxValue: Int
}

public struct TransactionListSnapshot: Hashable, Sendable {
    public var filter: TransactionFilter
    public var today: LocalDate
    /// Period window in use (`from == nil` = all time).
    public var from: LocalDate?
    public var through: LocalDate
    /// Account name for single-account scopes.
    public var accountName: String?
    /// Account balance today (single account) or the sum over the non-depot accounts (all).
    public var balance: Int
    /// Overdraft limit of the single account (0 for none and for All).
    public var overdraftLimit: Int
    /// Statement note or bank name, the caption of accounts without an overdraft.
    public var balanceNote: String?
    /// All scope: number of accounts summed.
    public var summedAccountCount: Int
    /// All scope: a depot account exists and is left out.
    public var excludesDepot: Bool
    public var categories: [TransactionCategory]
    /// Filtered rows, newest first.
    public var items: [TransactionItem]
    /// Months with rows, newest first.
    public var months: [TransactionMonth]
    public var chart: TransactionChart
}

/// Extras shown below the facts of one transaction.
public struct TransactionRuleInfo: Hashable, Sendable {
    /// An enabled rule files this payee under the transaction's category.
    public var ruleExists: Bool
    /// Earlier transactions of the same payee.
    public var earlierCount: Int
}

public enum TransactionQueries {
    /// Window of the balance chart in days.
    public static let chartDays = 90

    public static func snapshot(_ db: Database, filter: TransactionFilter) throws -> TransactionListSnapshot {
        let today = try LedgerClock.today(db)
        let window = filter.period.window(today: today)

        let accounts = try AccountRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        let categories = try CategoryRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
            .map { TransactionCategory(id: $0.id, name: $0.name, colorToken: $0.colorToken, kind: $0.kind) }

        let scopeAccounts: [AccountRecord]
        var accountName: String?
        switch filter.scope {
        case .all:
            scopeAccounts = accounts.filter { $0.kind != .depot }
        case .account(let id):
            scopeAccounts = accounts.filter { $0.id == id }
            accountName = scopeAccounts.first?.name
        }

        // Rows.
        var clauses = ["t.deleted_at IS NULL", "a.deleted_at IS NULL"]
        var arguments: [any DatabaseValueConvertible] = []
        if case .account(let id) = filter.scope {
            clauses.append("t.account_id = ?")
            arguments.append(id)
        }
        if let from = window.from {
            clauses.append("t.booking_date >= ?")
            arguments.append(from.iso)
        }
        clauses.append("t.booking_date <= ?")
        arguments.append(window.through.iso)
        switch filter.direction {
        case .all: break
        case .income: clauses.append("t.amount > 0")
        case .spending: clauses.append("t.amount < 0")
        }
        switch filter.category {
        case .all: break
        case .category(let id):
            clauses.append("t.category_id = ?")
            arguments.append(id)
        case .uncategorised: clauses.append("t.category_id IS NULL")
        }

        let rows = try Row.fetchAll(db, sql: """
            SELECT t.*, a.name AS account_name
            FROM ledger_transaction t JOIN account a ON a.id = t.account_id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(LedgerOrder.transactionsNewestFirst(alias: "t"))
            """, arguments: StatementArguments(arguments))

        var balances: [String: Int] = [:]
        if case .account(let id) = filter.scope {
            balances = try LedgerDefinitions.runningBalances(db, accountID: id)
        }

        var items: [TransactionItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            let record = try TransactionRecord(row: row)
            let accountName: String = row["account_name"]
            items.append(TransactionItem(
                id: record.id, accountID: record.accountId, accountName: accountName,
                bookingDate: record.bookingDate, valueDate: record.valueDate, bookedTime: record.bookedTime,
                shortName: record.shortName, counterpartyName: record.counterpartyName, purpose: record.purpose,
                bookingText: record.bookingText, creditorID: record.creditorId, kind: record.kind,
                amount: record.amount, currency: record.currency, categoryID: record.categoryId,
                isOwnTransfer: record.isOwnTransfer, isNew: record.isNew, note: record.note,
                balanceAfter: balances[record.id]))
        }

        // Months: totals of the listed rows, closing balance of the previous month.
        var totals: [LocalDate: Int] = [:]
        var order: [LocalDate] = []
        for item in items {
            let first = item.bookingDate.firstOfMonth
            if totals[first] == nil { order.append(first) }
            totals[first, default: 0] += item.amount
        }
        var months: [TransactionMonth] = []
        for first in order {
            var closing: Int?
            if case .account(let id) = filter.scope, filter.isOnlyPeriod, let account = scopeAccounts.first {
                let hasEarlier = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM ledger_transaction
                                  WHERE account_id = ? AND deleted_at IS NULL AND booking_date < ?)
                    """, arguments: [id, first.iso]) ?? false
                if hasEarlier {
                    let since = try Int.fetchOne(db, sql: """
                        SELECT COALESCE(SUM(amount), 0) FROM ledger_transaction
                        WHERE account_id = ? AND deleted_at IS NULL AND booking_date >= ?
                        """, arguments: [id, first.iso]) ?? 0
                    closing = account.balance - since
                }
            }
            months.append(TransactionMonth(first: first, total: totals[first] ?? 0, previousClosing: closing))
        }

        // Balance block.
        var balance = 0
        var overdraft = 0
        var note: String?
        switch filter.scope {
        case .all:
            balance = scopeAccounts.reduce(0) { $0 + $1.balance }
        case .account:
            if let account = scopeAccounts.first {
                balance = account.balance
                if account.kind == .depot, let holdings = try LedgerDefinitions.holdingsValue(db, accountID: account.id) {
                    balance = holdings
                }
                overdraft = account.overdraftLimit
                note = account.statementNote ?? (account.bankName.isEmpty ? nil : account.bankName)
            }
        }

        return TransactionListSnapshot(
            filter: filter, today: today, from: window.from, through: window.through, accountName: accountName,
            balance: balance, overdraftLimit: overdraft, balanceNote: note,
            summedAccountCount: scopeAccounts.count, excludesDepot: accounts.contains { $0.kind == .depot },
            categories: categories, items: items, months: months,
            chart: try chart(db, accounts: scopeAccounts, today: today))
    }

    /// The balance curve over the last ``chartDays`` days for `accounts` (summed).
    static func chart(_ db: Database, accounts: [AccountRecord], today: LocalDate) throws -> TransactionChart {
        let start = today.adding(days: -chartDays)
        var running = 0
        var daily: [LocalDate: Int] = [:]
        var paydayDates: Set<LocalDate> = []
        for account in accounts {
            let after = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(amount), 0) FROM ledger_transaction
                WHERE account_id = ? AND deleted_at IS NULL AND booking_date > ?
                """, arguments: [account.id, start.iso]) ?? 0
            running += account.balance - after
            let rows = try Row.fetchAll(db, sql: """
                SELECT booking_date, SUM(amount) AS net,
                       MAX(CASE WHEN kind = 'salary' THEN 1 ELSE 0 END) AS has_salary
                FROM ledger_transaction
                WHERE account_id = ? AND deleted_at IS NULL AND booking_date > ? AND booking_date <= ?
                GROUP BY booking_date
                """, arguments: [account.id, start.iso, today.iso])
            for row in rows {
                let date: LocalDate = row["booking_date"]
                let net: Int = row["net"]
                let salary: Int = row["has_salary"]
                daily[date, default: 0] += net
                if salary == 1 { paydayDates.insert(date) }
            }
        }

        let span = Double(chartDays)
        var points = [TransactionChart.Point(x: 0, value: running)]
        for date in daily.keys.sorted() {
            let x = Double(date - start) / span
            let net = daily[date] ?? 0
            if abs(net) >= 50_000 { points.append(.init(x: x, value: running)) }
            running += net
            points.append(.init(x: x, value: running))
        }
        if let last = points.last, last.x < 1 { points.append(.init(x: 1, value: last.value)) }

        let paydays = paydayDates.sorted().map { TransactionChart.Payday(date: $0, x: Double($0 - start) / span) }
        let values = points.map(\.value)
        return TransactionChart(
            start: start, end: today, points: points, paydays: paydays,
            minValue: values.min() ?? 0, maxValue: values.max() ?? 0)
    }

    /// Rule state of `item` for the inspector's "Always file … under …" row.
    public static func ruleInfo(_ db: Database, item: TransactionItem) throws -> TransactionRuleInfo {
        let name = item.payee
        let ruleExists = try !matchingRuleIDs(db, item: item).isEmpty
        let seq = try Int.fetchOne(db, sql: "SELECT booking_seq FROM ledger_transaction WHERE id = ?", arguments: [item.id]) ?? 0
        let earlier = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ledger_transaction
            WHERE deleted_at IS NULL AND id <> ?
              AND COALESCE(short_name, counterparty_name) = ?
              AND (booking_date < ? OR (booking_date = ? AND booking_seq < ?))
            """, arguments: [item.id, name, item.bookingDate.iso, item.bookingDate.iso, seq]) ?? 0
        return TransactionRuleInfo(ruleExists: ruleExists, earlierCount: earlier)
    }

    /// Ids of the uncategorised bookings (own transfers excluded) whose payee or counterparty contains
    /// `pattern`, case-insensitively: the rows a new rule for `pattern` files away.
    public static func uncategorisedMatches(_ db: Database, pattern: String) throws -> [String] {
        let needle = pattern.lowercased()
        guard !needle.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, COALESCE(short_name, counterparty_name) AS payee, counterparty_name FROM ledger_transaction
            WHERE deleted_at IS NULL AND category_id IS NULL AND is_own_transfer = 0
            ORDER BY booking_date DESC, id
            """)
        return rows.compactMap { row in
            let payee: String = row["payee"]
            let counterparty: String = row["counterparty_name"]
            return (payee + " " + counterparty).lowercased().contains(needle) ? row["id"] as String : nil
        }
    }

    /// The enabled rules that file `item` under its current category (what the checkbox shows as on).
    public static func matchingRuleIDs(_ db: Database, item: TransactionItem) throws -> [String] {
        guard let category = item.categoryID else { return [] }
        let haystack = (item.payee + " " + item.counterpartyName).lowercased()
        return try RuleRecord.live().filter(Column("category_id") == category && Column("enabled") == true).fetchAll(db)
            .filter { haystack.contains($0.pattern.lowercased()) }
            .map(\.id)
    }

    /// Re-emits whenever a table behind the list changes.
    public static func observe(in store: LedgerStore, filter: TransactionFilter) -> AsyncValueObservation<TransactionListSnapshot> {
        ValueObservation.tracking { try snapshot($0, filter: filter) }.values(in: store.database)
    }
}
