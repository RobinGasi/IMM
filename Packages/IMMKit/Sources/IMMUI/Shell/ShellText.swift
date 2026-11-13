import Foundation
import IMMLedger

/// Texts of the sidebar footer and the toolbar, derived from ledger values.
enum ShellText {
    /// `HH:mm`, 24-hour, regardless of the system locale.
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `today, 08:42`, `yesterday, 07:30`, or `12.11., 08:42` (real clock, `now`).
    static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let clock = time(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "today, \(clock)", bundle: .module)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "yesterday, \(clock)", bundle: .module)
        }
        return DateFormats.dayMonth(LocalDate(date)) + ", " + clock
    }

    /// The sync line under the net worth.
    static func syncLine(snapshot: SidebarSnapshot, state: SyncState, now: Date = Date()) -> (text: String, isWarning: Bool) {
        if state.isSyncing {
            return (String(localized: "Syncing…", bundle: .module), false)
        }
        let failed = state.failures.isEmpty ? snapshot.failedAccountCount : state.failures.count
        if failed > 0 {
            let text = failed == 1
                ? String(localized: "1 account not updated", bundle: .module)
                : String(localized: "\(failed) accounts not updated", bundle: .module)
            return (text, true)
        }
        if let last = snapshot.lastSyncedAt {
            return (String(localized: "Synced \(relative(last, now: now))", bundle: .module), false)
        }
        return (String(localized: "Not synced yet", bundle: .module), false)
    }

    /// `Dec 2025`
    static func shortMonthYear(_ date: LocalDate) -> String {
        String(DateFormats.monthName(date).prefix(3)) + " " + String(date.year)
    }

    /// Title and subtitle of the toolbar for the current route.
    static func toolbar(route: MainRoute, snapshot: SidebarSnapshot, state: SyncState) -> (title: String, subtitle: String) {
        let today = snapshot.today
        switch route {
        case .overview:
            if !state.failures.isEmpty || snapshot.failedAccountCount > 0 {
                let oldest = snapshot.accounts.compactMap(\.lastSyncedAt).min()
                let when = oldest.map { relative($0) } ?? ""
                return (String(localized: "Overview", bundle: .module), String(localized: "Last full sync \(when)", bundle: .module))
            }
            return (String(localized: "Overview", bundle: .module), DateFormats.monthYear(today))
        case .transactions(.all):
            return (
                String(localized: "All transactions", bundle: .module),
                String(localized: "\(snapshot.accounts.count) accounts", bundle: .module))
        case .transactions(.account(let id)):
            guard let account = snapshot.accounts.first(where: { $0.id == id }) else {
                return (String(localized: "All transactions", bundle: .module), "")
            }
            return (account.name, account.subtitle ?? account.bankName)
        case .suggestions:
            let count = snapshot.uncategorisedCount
            return (
                String(localized: "Suggestions", bundle: .module),
                count == 1
                    ? String(localized: "1 transaction without a category", bundle: .module)
                    : String(localized: "\(count) transactions without a category", bundle: .module))
        case .monthReview:
            let last = previousMonthEnd(today)
            return (
                String(localized: "\(DateFormats.monthName(last)) review", bundle: .module),
                String(localized: "All accounts · closed \(DateFormats.dayMonthYear(last))", bundle: .module))
        case .depot:
            let depot = snapshot.accounts.first { $0.kind == .depot }
            let base = depot?.subtitle ?? ""
            let prices = String(localized: "prices from Tradegate, \(DateFormats.dayMonthYear(today)) 09:15", bundle: .module)
            return (String(localized: "Depot", bundle: .module), base.isEmpty ? prices : base + " · " + prices)
        case .budgets:
            let daysLeft = today.daysInMonth - today.day
            return (
                String(localized: "Budgets", bundle: .module),
                String(localized: "\(DateFormats.monthYear(today)) · \(daysLeft) days left", bundle: .module))
        case .standingOrders:
            let bank = snapshot.accounts.first { $0.kind == .giro }?.bankName ?? ""
            return (
                String(localized: "Standing orders", bundle: .module),
                String(localized: "\(bank) · synced with your bank", bundle: .module))
        case .contracts:
            return (String(localized: "Contracts", bundle: .module), String(localized: "Detected from recurring payments", bundle: .module))
        case .categories:
            let start = today.adding(months: -11)
            return (
                String(localized: "Categories", bundle: .module),
                String(localized: "All accounts · \(shortMonthYear(start)) – \(shortMonthYear(today))", bundle: .module))
        case .taxReturn:
            let year = String(today.year)
            return (
                String(localized: "Tax return \(year)", bundle: .module),
                String(localized: "Einkommensteuererklärung · 1 Jan – 31 Dec \(year)", bundle: .module))
        case .payInvoice:
            return (String(localized: "Pay an invoice", bundle: .module), "Rechnung_2026-118.pdf")
        }
    }

    /// Last day of the month before `date`'s month.
    static func previousMonthEnd(_ date: LocalDate) -> LocalDate {
        date.firstOfMonth.adding(days: -1)
    }
}
