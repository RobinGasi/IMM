import Foundation
import GRDB

// Everything the Overview shows, computed from the ledger in one read.
// Definitions: `LedgerDefinitions` (net worth, spending, monthly average); "today" is `LedgerClock`.

/// One month-end value of the net-worth chart.
public struct NetWorthPoint: Hashable, Sendable {
    /// Three-letter English month name (`Dec`).
    public var label: String
    /// Month end, or the ledger's today for the running month.
    public var date: LocalDate
    /// Minor units.
    public var value: Int
}

/// One row of "Needs attention": a stored `attention` insight.
public struct OverviewAttention: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    /// Label of the row's button (`Categorize`); nil for rows that are links as a whole.
    public var actionTitle: String?
    /// Where the row leads: `suggestions` or `contracts`.
    public var target: String
}

/// The grey text between the account name and its amount.
public enum OverviewAccountDetail: Hashable, Sendable {
    case none
    /// Shortened IBAN, e.g. `DE80 … 0827 51`.
    case iban(String)
    /// Statement note from the bank, shown as is (`Statement 20.11.`).
    case statement(String)
    /// Depot: number of securities and whether cash is held next to them.
    case holdings(securities: Int, allETFs: Bool, hasCash: Bool)
}

public struct OverviewAccount: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: AccountKind
    /// Balance, or the holdings value for a depot (minor units).
    public var value: Int
    public var detail: OverviewAccountDetail
}

public struct OverviewAccountGroup: Hashable, Sendable, Identifiable {
    public var bankName: String
    public var accounts: [OverviewAccount]
    public var id: String { bankName }
}

/// One expense category with spending this month.
public struct OverviewSpending: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Design token name (`chart-1`).
    public var colorToken: String
    /// Positive minor units.
    public var amount: Int
}

/// One expected booking on the Girokonto.
public struct OverviewUpcoming: Hashable, Sendable, Identifiable {
    public var id: String
    public var date: LocalDate
    public var label: String
    /// Signed minor units.
    public var amount: Int
}

public struct OverviewSnapshot: Hashable, Sendable {
    public var today: LocalDate
    public var netWorth: Int
    public var accountCount: Int
    /// Last day of the previous month, the reference of "since October".
    public var previousMonthEnd: LocalDate
    /// `netWorth` minus the net worth on `previousMonthEnd`.
    public var netWorthChange: Int
    /// The 12 months up to the current one, oldest first.
    public var netWorthSeries: [NetWorthPoint]
    public var attention: [OverviewAttention]
    public var accountGroups: [OverviewAccountGroup]
    /// Most recent `last_synced_at` of any account.
    public var lastSyncedAt: Date?
    /// First day of the current month through today.
    public var spentFrom: LocalDate
    /// Categories with spending, largest first.
    public var spending: [OverviewSpending]
    public var spentTotal: Int
    /// Mean spending of the 11 complete months before the current one.
    public var monthlyAverage: Int
    public var daysToGo: Int
    /// Name of the account the "Coming up" list is about (the first Girokonto).
    public var upcomingAccountName: String
    /// Bookings after today up to and including `upcomingUntil`, by date.
    public var upcoming: [OverviewUpcoming]
    /// First day of next month.
    public var upcomingUntil: LocalDate
    /// Girokonto balance after all `upcoming` bookings.
    public var projectedBalance: Int

    /// Spending as a share of the monthly average, rounded; nil without an average.
    public var averagePercent: Int? {
        guard monthlyAverage > 0 else { return nil }
        return Int((Double(spentTotal) * 100 / Double(monthlyAverage)).rounded())
    }
}

public enum OverviewQueries {
    /// Standing orders below this amount (100,00 €) are not listed under "Coming up".
    static let minimumStandingOrder = 10_000

    public static func snapshot(_ db: Database) throws -> OverviewSnapshot {
        let today = try LedgerClock.today(db)
        let monthStart = today.firstOfMonth
        let previousMonthEnd = monthStart.adding(days: -1)

        let accounts = try AccountRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        let netWorth = try LedgerDefinitions.netWorth(db)
        let netWorthBefore = try LedgerDefinitions.netWorth(db, on: previousMonthEnd)

        var series: [NetWorthPoint] = []
        for offset in -11...0 {
            let start = monthStart.adding(months: offset)
            let end = offset == 0 ? today : start.adding(months: 1).adding(days: -1)
            let value = offset == 0 ? netWorth : try LedgerDefinitions.netWorth(db, on: end)
            series.append(NetWorthPoint(label: String(DateFormats.monthName(start).prefix(3)), date: end, value: value))
        }

        let spending = try LedgerDefinitions.spending(db, from: monthStart, through: today)
        let categories = try CategoryRecord.live().order(Column("sort_order")).fetchAll(db)
        let rows = categories
            .filter { $0.kind == .expense && (spending[$0.id] ?? 0) > 0 }
            .map { OverviewSpending(id: $0.id, name: $0.name, colorToken: $0.colorToken, amount: spending[$0.id] ?? 0) }
            .sorted { $0.amount > $1.amount }

        let upcomingAccount = accounts.first { $0.kind == .giro }
        let upcoming = try upcomingItems(db, accounts: accounts, giro: upcomingAccount, today: today)
        let horizon = firstOfNextMonth(today)

        return OverviewSnapshot(
            today: today,
            netWorth: netWorth,
            accountCount: accounts.count,
            previousMonthEnd: previousMonthEnd,
            netWorthChange: netWorth - netWorthBefore,
            netWorthSeries: series,
            attention: try attention(db),
            accountGroups: try accountGroups(db, accounts: accounts),
            lastSyncedAt: accounts.compactMap(\.lastSyncedAt).max(),
            spentFrom: monthStart,
            spending: rows,
            spentTotal: rows.reduce(0) { $0 + $1.amount },
            monthlyAverage: try LedgerDefinitions.monthlyAverageSpending(db, today: today),
            daysToGo: today.daysInMonth - today.day,
            upcomingAccountName: upcomingAccount?.name ?? "",
            upcoming: upcoming,
            upcomingUntil: horizon,
            projectedBalance: (upcomingAccount?.balance ?? 0) + upcoming.reduce(0) { $0 + $1.amount })
    }

    /// Re-emits whenever one of the tables behind the snapshot changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<OverviewSnapshot> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }

    // MARK: Needs attention

    /// Content of an `attention` insight (written by the demo data set as `AttentionPayload`).
    private struct AttentionContent: Decodable {
        var title: String
        var detail: String
        var actionTitle: String?
        var target: String
    }

    private static func attention(_ db: Database) throws -> [OverviewAttention] {
        let insights = try InsightRecord.live()
            .filter(sql: "kind = ?", arguments: [InsightKind.attention.rawValue])
            .order(Column("sort_order"), Column("id"))
            .fetchAll(db)
        let decoder = JSONDecoder()
        return insights.compactMap { insight -> OverviewAttention? in
            guard let content = try? decoder.decode(AttentionContent.self, from: Data(insight.payload.utf8)) else { return nil }
            return OverviewAttention(
                id: insight.id, title: content.title, detail: content.detail, actionTitle: content.actionTitle,
                target: content.target)
        }
    }

    // MARK: Accounts

    private static func accountGroups(_ db: Database, accounts: [AccountRecord]) throws -> [OverviewAccountGroup] {
        var groups: [OverviewAccountGroup] = []
        for account in accounts {
            var value = account.balance
            var detail = OverviewAccountDetail.none
            switch account.kind {
            case .depot:
                if let holdings = try LedgerDefinitions.holdingsValue(db, accountID: account.id) { value = holdings }
                detail = try depotDetail(db, accountID: account.id)
            case .giro:
                if let iban = account.iban { detail = .iban(shortIBAN(iban)) }
            case .creditCard:
                if let note = account.statementNote, !note.isEmpty { detail = .statement(note) }
            case .savings, .wallet:
                break
            }
            let row = OverviewAccount(id: account.id, name: displayName(account), kind: account.kind, value: value, detail: detail)
            if let index = groups.firstIndex(where: { $0.bankName == account.bankName }) {
                groups[index].accounts.append(row)
            } else {
                groups.append(OverviewAccountGroup(bankName: account.bankName, accounts: [row]))
            }
        }
        return groups
    }

    /// The row label without a repeated bank prefix ("PayPal Wallet" under "PayPal" reads "Wallet").
    private static func displayName(_ account: AccountRecord) -> String {
        let prefix = account.bankName + " "
        if !account.bankName.isEmpty, account.name.hasPrefix(prefix) {
            return String(account.name.dropFirst(prefix.count))
        }
        return account.name
    }

    private static func depotDetail(_ db: Database, accountID: String) throws -> OverviewAccountDetail {
        let rows = try Row.fetchAll(db, sql: """
            SELECT h.security_id AS security_id, s.kind AS kind
            FROM holding h LEFT JOIN security s ON s.id = h.security_id
            WHERE h.account_id = ? AND h.deleted_at IS NULL
            """, arguments: [accountID])
        var securities = 0
        var etfs = 0
        var cash = false
        for row in rows {
            let securityID: String? = row["security_id"]
            if securityID == nil {
                cash = true
            } else {
                securities += 1
                let kind: String? = row["kind"]
                if kind == SecurityKind.etf.rawValue { etfs += 1 }
            }
        }
        return .holdings(securities: securities, allETFs: securities == etfs, hasCash: cash)
    }

    /// `DE80 3705 0198 1934 0827 51` → `DE80 … 0827 51`.
    static func shortIBAN(_ iban: String) -> String {
        let compact = iban.filter { !$0.isWhitespace }
        guard compact.count > 10 else { return iban }
        let tail = compact.suffix(6)
        return String(compact.prefix(4)) + " \u{2026} " + tail.prefix(4) + " " + tail.suffix(2)
    }

    // MARK: Coming up

    private static func firstOfNextMonth(_ today: LocalDate) -> LocalDate {
        today.firstOfMonth.adding(months: 1)
    }

    /// Girokonto bookings expected after today up to the first of next month.
    ///
    /// - monthly standing orders from the Girokonto that are active, at least 100,00 € and not a
    ///   transfer to one of the user's own non-depot accounts, due after today up to and including the horizon;
    /// - contract debits from the Girokonto due after today and before the horizon day;
    /// - recurring income due after today up to and including the horizon;
    /// - the credit card statement when its date falls in the window.
    /// Sorted by date, larger amounts first.
    private static func upcomingItems(
        _ db: Database, accounts: [AccountRecord], giro: AccountRecord?, today: LocalDate
    ) throws -> [OverviewUpcoming] {
        guard let giro else { return [] }
        let horizon = firstOfNextMonth(today)
        let others = accounts.filter { $0.id != giro.id && $0.kind != .depot }
        var items: [OverviewUpcoming] = []

        let orders = try StandingOrderRecord.live().filter(sql: "account_id = ?", arguments: [giro.id]).fetchAll(db)
        for order in orders {
            guard order.status == .active, order.rhythm == .monthly, order.amount <= -minimumStandingOrder,
                  let next = order.nextExecution, next > today, next <= horizon,
                  !isOwnTransfer(order, others: others) else { continue }
            items.append(OverviewUpcoming(id: order.id, date: next, label: order.recipient, amount: order.amount))
        }

        let contracts = try ContractRecord.live().filter(sql: "account_id = ?", arguments: [giro.id]).fetchAll(db)
        for contract in contracts {
            guard let next = contract.nextDebit, next > today else { continue }
            switch contract.kind {
            case .contract:
                if next < horizon { items.append(OverviewUpcoming(id: contract.id, date: next, label: contract.provider, amount: contract.monthlyAmount)) }
            case .income:
                if next <= horizon { items.append(OverviewUpcoming(id: contract.id, date: next, label: contract.provider, amount: contract.monthlyAmount)) }
            }
        }

        for account in accounts where account.kind == .creditCard && account.balance < 0 {
            guard let date = statementDate(account.statementNote, today: today), date > today, date <= horizon else { continue }
            let product = account.name.replacingOccurrences(of: " Card", with: "")
            items.append(OverviewUpcoming(
                id: account.id, date: date, label: "\(account.bankName) \(product) statement", amount: account.balance))
        }

        return items.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return abs(lhs.amount) > abs(rhs.amount)
        }
    }

    private static func isOwnTransfer(_ order: StandingOrderRecord, others: [AccountRecord]) -> Bool {
        let iban = order.iban.filter { !$0.isWhitespace }.uppercased()
        for account in others {
            if !iban.isEmpty, let accountIBAN = account.iban,
               accountIBAN.filter({ !$0.isWhitespace }).uppercased() == iban { return true }
            if order.recipient.lowercased().hasPrefix(account.name.lowercased()) { return true }
        }
        return false
    }

    /// `Statement 20.11.` → 20.11. of the ledger's year.
    private static func statementDate(_ note: String?, today: LocalDate) -> LocalDate? {
        guard let note else { return nil }
        let numbers = note.split(whereSeparator: { !$0.isNumber })
        guard numbers.count >= 2, let day = Int(numbers[0]), let month = Int(numbers[1]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let monthLength = LocalDate(year: today.year, month: month, day: 1).daysInMonth
        return LocalDate(year: today.year, month: month, day: min(day, monthLength))
    }
}
