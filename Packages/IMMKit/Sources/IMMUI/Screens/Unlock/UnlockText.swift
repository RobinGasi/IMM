import Foundation
import IMMVault

/// The strings of the Unlock screen that depend on state.
enum UnlockText {
    /// The line under the title; follows why the database was locked.
    static func subtitle(for reason: LockReason?) -> String {
        switch reason {
        case .inactivity(let minutes):
            inactivitySubtitle(minutes: minutes)
        case .sleep:
            String(localized: "Locked when your Mac went to sleep.", bundle: .module)
        case .manual, nil:
            String(localized: "Unlock to see your accounts.", bundle: .module)
        }
    }

    private static func inactivitySubtitle(minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1
                ? String(localized: "Locked automatically after 1 hour of inactivity.", bundle: .module)
                : String(localized: "Locked automatically after \(hours) hours of inactivity.", bundle: .module)
        }
        return minutes == 1
            ? String(localized: "Locked automatically after 1 minute of inactivity.", bundle: .module)
            : String(localized: "Locked automatically after \(minutes) minutes of inactivity.", bundle: .module)
    }

    /// `Last opened today, 08:12 · 5 accounts · Encrypted on this Mac`. The first two parts are left out
    /// when IMM's preferences on this Mac do not know them.
    static func footer(lastOpened: Date?, accountCount: Int?, now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let lastOpened {
            parts.append(lastOpenedText(lastOpened, now: now, calendar: calendar))
        }
        if let accountCount {
            parts.append(
                accountCount == 1
                    ? String(localized: "1 account", bundle: .module)
                    : String(localized: "\(accountCount) accounts", bundle: .module))
        }
        parts.append(String(localized: "Encrypted on this Mac", bundle: .module))
        return parts.joined(separator: " · ")
    }

    private static func lastOpenedText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = format(date, "HH:mm", calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "Last opened today, \(time)", bundle: .module)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Last opened yesterday, \(time)", bundle: .module)
        }
        let day = format(date, "dd.MM.yyyy", calendar: calendar)
        return String(localized: "Last opened \(day), \(time)", bundle: .module)
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
