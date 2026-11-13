import Foundation
import IMMLedger

/// Turns a ledger snapshot into the rows of the transaction table. Pure: no UI, no database.
enum TransactionRowsBuilder {
    enum Mode: Equatable {
        /// Full list: marker, balance column (single account), month totals and closing balances.
        case list
        /// Beside the inspector: no balance column, no month totals, month headers only when the list spans months.
        case inspector
    }

    static func tableLayout(for snapshot: TransactionListSnapshot, mode: Mode) -> TransactionTableLayout {
        switch mode {
        case .list: return .list(showsBalance: showsBalance(snapshot))
        case .inspector: return .inspector
        }
    }

    /// The single-account list has the Balance column; the All variant does not.
    static func showsBalance(_ snapshot: TransactionListSnapshot) -> Bool {
        if case .account = snapshot.filter.scope { return true }
        return false
    }

    static func rows(for snapshot: TransactionListSnapshot, mode: Mode) -> [TransactionTableRow] {
        let categories = Dictionary(snapshot.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let isAll = snapshot.filter.scope == .all
        let showsClosing = mode == .list && showsBalance(snapshot)
        let showsHeaders = mode == .list || snapshot.months.count > 1
        let showsTotals = mode == .list
        let monthByFirst = Dictionary(snapshot.months.map { ($0.first, $0) }, uniquingKeysWith: { first, _ in first })

        var rows: [TransactionTableRow] = []
        rows.reserveCapacity(snapshot.items.count + snapshot.months.count * 2)

        var currentMonth: LocalDate?
        func closeMonth() {
            guard showsClosing, let first = currentMonth, let closing = monthByFirst[first]?.previousClosing else { return }
            let day = first.adding(days: -1)
            rows.append(.closingBalance(
                id: "closing-" + day.iso,
                label: String(localized: "Closing balance \(DateFormats.dayMonthYear(day))", bundle: .module),
                amount: MoneyFormatter.string(closing),
                date: DateFormats.dayMonth(day)))
        }

        for item in snapshot.items {
            let first = item.bookingDate.firstOfMonth
            if first != currentMonth {
                closeMonth()
                currentMonth = first
                if showsHeaders, let month = monthByFirst[first] {
                    rows.append(.monthHeader(
                        id: "month-" + first.iso,
                        title: DateFormats.monthYear(first),
                        total: showsTotals ? MoneyFormatter.string(month.total, sign: .negativeOnly) : nil))
                }
            }
            let category = item.categoryID.flatMap { categories[$0] }
            rows.append(.transaction(TransactionRowData(
                id: item.id,
                isNew: item.isNew,
                date: DateFormats.dayMonth(item.bookingDate),
                payee: item.payee,
                secondary: isAll ? item.accountName : item.purpose,
                categoryName: category?.name,
                categoryColorToken: category?.colorToken,
                amount: MoneyFormatter.string(item.amount, currency: item.currency, sign: .always, symbol: mode == .list),
                isPositive: item.amount > 0,
                balance: item.balanceAfter.map { MoneyFormatter.string($0, currency: item.currency) })))
        }
        closeMonth()
        return rows
    }
}

/// Texts of the Transactions screen.
enum TransactionText {
    /// "148 transactions", "1 transaction".
    static func count(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 transaction", bundle: .module)
            : String(localized: "\(count) transactions", bundle: .module)
    }

    static func kind(_ kind: TransactionKind) -> String {
        switch kind {
        case .cardPayment: return String(localized: "Card payment", bundle: .module)
        case .directDebit: return String(localized: "Direct debit", bundle: .module)
        case .transfer: return String(localized: "Transfer", bundle: .module)
        case .standingOrder: return String(localized: "Standing order", bundle: .module)
        case .salary: return String(localized: "Salary", bundle: .module)
        case .atm: return String(localized: "Cash withdrawal", bundle: .module)
        case .interest: return String(localized: "Interest", bundle: .module)
        case .securities: return String(localized: "Securities", bundle: .module)
        }
    }

    /// "Card payment · Wed 11.11.2026, 18:42"
    static func detailSubtitle(_ item: TransactionItem) -> String {
        var when = DateFormats.weekdayShort(item.bookingDate) + " " + DateFormats.dayMonthYear(item.bookingDate)
        if let time = item.bookedTime { when += ", " + time }
        return kind(item.kind) + " · " + when
    }

    /// Footer of the inspector layout: "Spent in November so far".
    static func footerLabel(_ snapshot: TransactionListSnapshot) -> String {
        let total = snapshot.items.reduce(0) { $0 + $1.amount }
        let period: String
        switch snapshot.filter.period {
        case .thisMonth: period = String(localized: "\(DateFormats.monthName(snapshot.today)) so far", bundle: .module)
        case .lastMonth: period = DateFormats.monthName(snapshot.today.firstOfMonth.adding(months: -1))
        case .last30Days: period = String(localized: "the last 30 days", bundle: .module)
        case .last90Days: period = String(localized: "the last 90 days", bundle: .module)
        case .thisYear: period = String(localized: "\(snapshot.today.year) so far", bundle: .module)
        case .allTime: period = String(localized: "all time", bundle: .module)
        }
        switch snapshot.filter.direction {
        case .spending: return String(localized: "Spent in \(period)", bundle: .module)
        case .income: return String(localized: "Received in \(period)", bundle: .module)
        case .all:
            return total <= 0
                ? String(localized: "Spent in \(period)", bundle: .module)
                : String(localized: "Net in \(period)", bundle: .module)
        }
    }

    /// "01.–12.11.2026" for one month, "14.08.–12.11.2026" otherwise.
    static func footerRange(_ snapshot: TransactionListSnapshot) -> String {
        let end = snapshot.through
        let first = snapshot.from ?? snapshot.items.last?.bookingDate ?? end
        let sameMonth = first.year == end.year && first.month == end.month
        let endText = DateFormats.dayMonthYear(end)
        if sameMonth {
            return LocalDate.padded(first.day) + ".\u{2013}" + endText
        }
        return DateFormats.dayMonth(first) + "\u{2013}" + endText
    }
}

extension LocalDate {
    /// Two-digit day for ranges such as "01.–12.11.2026".
    fileprivate static func padded(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
