import Foundation
import GRDB

/// A calendar day without time zone (proleptic Gregorian). Encoded as the string `YYYY-MM-DD`
/// in `Codable` and in the database (TEXT), so that string order equals date order.
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`; returns nil for anything else or for impossible dates.
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return nil }
        func number(_ s: Substring) -> Int? {
            guard s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int(s)
        }
        guard let y = number(parts[0]), let m = number(parts[1]), let d = number(parts[2]),
              (1...12).contains(m), d >= 1, d <= LocalDate.daysIn(month: m, year: y) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The calendar day of `date` in `timeZone`.
    public init(_ date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// `2026-11-12`.
    public var iso: String {
        LocalDate.pad(year, 4) + "-" + LocalDate.pad(month, 2) + "-" + LocalDate.pad(day, 2)
    }

    public var description: String { iso }

    public func adding(days: Int) -> LocalDate {
        let (y, m, d) = LocalDate.civil(fromDays: daysSinceEpoch + days)
        return LocalDate(year: y, month: m, day: d)
    }

    /// Adds calendar months; the day is clamped to the length of the target month.
    public func adding(months: Int) -> LocalDate {
        let total = year * 12 + (month - 1) + months
        let y = total >= 0 ? total / 12 : -((-total + 11) / 12)
        let m = total - y * 12 + 1
        return LocalDate(year: y, month: m, day: min(day, LocalDate.daysIn(month: m, year: y)))
    }

    public var firstOfMonth: LocalDate { LocalDate(year: year, month: month, day: 1) }

    public var daysInMonth: Int { LocalDate.daysIn(month: month, year: year) }

    /// Gregorian weekday, 1 = Sunday … 7 = Saturday.
    public var weekday: Int {
        // 1970-01-01 was a Thursday (5).
        let r = (daysSinceEpoch + 4) % 7
        return (r < 0 ? r + 7 : r) + 1
    }

    /// Whole days `lhs - rhs`.
    public static func - (lhs: LocalDate, rhs: LocalDate) -> Int {
        lhs.daysSinceEpoch - rhs.daysSinceEpoch
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Midnight of this day in `timeZone`.
    public func date(timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = LocalDate(iso: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date '\(string)', expected YYYY-MM-DD")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }

    // MARK: Calendar arithmetic

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// Days since 1970-01-01.
    var daysSinceEpoch: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

extension LocalDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { iso.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> LocalDate? {
        guard let string = String.fromDatabaseValue(dbValue) else { return nil }
        return LocalDate(iso: string)
    }
}
