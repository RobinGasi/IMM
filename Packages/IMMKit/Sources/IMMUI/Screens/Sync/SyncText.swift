import Foundation
import IMMLedger

/// Texts of the Sync failed layout, computed from the failures and the ledger's `last_synced_at` values.
enum SyncText {
    /// `HH:mm` (24-hour, any system locale).
    static func clock(_ date: Date) -> String { ShellText.time(date) }

    /// `today 08:42`, `yesterday 07:30` or `12.11. 07:30` (real clock): the point in time of a last update.
    static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = clock(date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "today \(time)", bundle: .module)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "yesterday \(time)", bundle: .module)
        }
        return DateFormats.dayMonth(LocalDate(date)) + " " + time
    }

    /// "Girokonto", "Girokonto and Tagesgeld", "A, B and C".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default:
            let head = names.dropLast().joined(separator: ", ")
            return String(localized: "\(head) and \(names[names.count - 1])", bundle: .module)
        }
    }

    /// The day part of "Includes balances from … for N accounts".
    static func balanceDay(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return String(localized: "an earlier sync", bundle: .module) }
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "earlier today", bundle: .module) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "yesterday", bundle: .module)
        }
        return DateFormats.dayMonth(LocalDate(date))
    }

    static func balanceCaption(count: Int, oldest: Date?, now: Date = Date()) -> String {
        let day = balanceDay(oldest, now: now)
        return count == 1
            ? String(localized: "Includes balances from \(day) for 1 account", bundle: .module)
            : String(localized: "Includes balances from \(day) for \(count) accounts", bundle: .module)
    }

    static func updatedCount(updated: Int, total: Int) -> String {
        String(localized: "\(updated) of \(total) updated today", bundle: .module)
    }

    /// "Updated 08:42", or with the date when the update was not today.
    static func updated(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return String(localized: "Not synced yet", bundle: .module) }
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "Updated \(clock(date))", bundle: .module)
        }
        return String(localized: "Updated \(DateFormats.dayMonth(LocalDate(date))) \(clock(date))", bundle: .module)
    }

    struct RowStatus {
        var text: String
        var isWarning: Bool
    }

    /// The status column of one account row.
    static func status(for failure: AccountSyncFailure?, lastSyncedAt: Date?, now: Date = Date()) -> RowStatus {
        guard let failure else { return RowStatus(text: updated(lastSyncedAt, now: now), isWarning: false) }
        switch failure.reason {
        case .maintenance(let until):
            return RowStatus(text: String(localized: "Available again at \(clock(until))", bundle: .module), isWarning: false)
        case .pinRejected, .offline, .other:
            let text = lastSyncedAt.map { String(localized: "Not updated since \(moment($0, now: now))", bundle: .module) }
                ?? String(localized: "Not updated yet", bundle: .module)
            return RowStatus(text: text, isWarning: true)
        }
    }
}
