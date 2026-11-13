import Foundation
import Testing
@testable import IMMLedger

@Suite struct LocalDateTests {
    @Test func parsesAndFormats() {
        let date = LocalDate(iso: "2026-11-12")
        #expect(date == LocalDate(year: 2026, month: 11, day: 12))
        #expect(date?.iso == "2026-11-12")
        #expect(date?.description == "2026-11-12")
        #expect(LocalDate(year: 987, month: 3, day: 4).iso == "0987-03-04")
    }

    @Test func rejectsInvalidStrings() {
        for s in ["", "2026-13-01", "2026-02-30", "2025-02-29", "2026-1-01", "26-01-01", "2026/01/01", "2026-01-0a", "+026-01-01", "2026-00-10", "2026-01-00"] {
            #expect(LocalDate(iso: s) == nil, "\(s)")
        }
        #expect(LocalDate(iso: "2024-02-29") != nil)
    }

    @Test func addingDays() {
        #expect(d("2026-11-12").adding(days: 0) == d("2026-11-12"))
        #expect(d("2026-11-12").adding(days: 19) == d("2026-12-01"))
        #expect(d("2026-12-31").adding(days: 1) == d("2027-01-01"))
        #expect(d("2026-03-01").adding(days: -1) == d("2026-02-28"))
        #expect(d("2024-03-01").adding(days: -1) == d("2024-02-29"))
        #expect(d("2026-11-12").adding(days: -365) == d("2025-11-12"))
        #expect(d("1969-12-31").adding(days: 1) == d("1970-01-01"))
    }

    @Test func addingMonthsClamps() {
        #expect(d("2026-01-31").adding(months: 1) == d("2026-02-28"))
        #expect(d("2024-01-31").adding(months: 1) == d("2024-02-29"))
        #expect(d("2026-11-12").adding(months: 1) == d("2026-12-12"))
        #expect(d("2026-11-12").adding(months: 2) == d("2027-01-12"))
        #expect(d("2026-11-12").adding(months: -11) == d("2025-12-12"))
        #expect(d("2026-01-15").adding(months: -1) == d("2025-12-15"))
        #expect(d("2026-01-15").adding(months: -13) == d("2024-12-15"))
        #expect(d("2026-03-31").adding(months: -1) == d("2026-02-28"))
        #expect(d("2026-11-12").adding(months: 0) == d("2026-11-12"))
    }

    @Test func monthProperties() {
        #expect(d("2026-11-12").firstOfMonth == d("2026-11-01"))
        #expect(d("2026-11-12").daysInMonth == 30)
        #expect(d("2026-12-01").daysInMonth == 31)
        #expect(d("2026-02-01").daysInMonth == 28)
        #expect(d("2024-02-01").daysInMonth == 29)
        #expect(d("2100-02-01").daysInMonth == 28)
        #expect(d("2000-02-01").daysInMonth == 29)
    }

    @Test func weekdays() {
        #expect(d("2026-11-12").weekday == 5) // Thursday
        #expect(d("2026-11-15").weekday == 1) // Sunday
        #expect(d("2026-11-14").weekday == 7) // Saturday
        #expect(d("1970-01-01").weekday == 5)
        #expect(d("1969-12-28").weekday == 1)
    }

    @Test func differenceAndOrder() {
        #expect(d("2026-11-12") - d("2026-11-01") == 11)
        #expect(d("2026-11-01") - d("2026-11-12") == -11)
        #expect(d("2027-01-01") - d("2026-01-01") == 365)
        #expect(d("2025-03-01") - d("2024-03-01") == 365)
        #expect(d("2024-03-01") - d("2023-03-01") == 366)
        #expect(d("2026-11-12") < d("2026-12-01"))
        #expect(d("2026-11-12") < d("2027-01-01"))
        #expect(d("2026-11-12") > d("2026-11-11"))
        #expect(d("2026-11-12") <= d("2026-11-12"))
    }

    @Test func codableIsSingleString() throws {
        let data = try JSONEncoder().encode([d("2026-11-12")])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-11-12\"]")
        let back = try JSONDecoder().decode([LocalDate].self, from: data)
        #expect(back == [d("2026-11-12")])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([LocalDate].self, from: Data("[\"2026-02-31\"]".utf8))
        }
    }

    @Test func convertsToAndFromDate() throws {
        let tz = try #require(TimeZone(identifier: "Europe/Berlin"))
        let date = d("2026-11-12").date(timeZone: tz)
        #expect(LocalDate(date, timeZone: tz) == d("2026-11-12"))
        // 23:30 UTC on 11th is already the 12th in Berlin.
        let utc = try #require(TimeZone(identifier: "UTC"))
        let late = d("2026-11-11").date(timeZone: utc).addingTimeInterval(23.5 * 3600)
        #expect(LocalDate(late, timeZone: tz) == d("2026-11-12"))
        #expect(LocalDate(late, timeZone: utc) == d("2026-11-11"))
    }
}
