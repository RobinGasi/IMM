import Foundation
import GRDB
import Testing
@testable import IMMLedger

@Suite struct ClockAndSettingsTests {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    @Test func settingsRoundTrip() throws {
        let ledger = try TestLedger()
        let store = ledger.store
        #expect(try store.setting(.autoLockMinutes) == nil)
        try store.setSetting(.autoLockMinutes, "5")
        #expect(try store.setting(.autoLockMinutes) == "5")
        try store.setSetting(.autoLockMinutes, "15")
        #expect(try store.setting(.autoLockMinutes) == "15")
        try store.setSetting(.lockOnSleep, "1")
        #expect(try store.setting(.lockOnSleep) == "1")
        try store.setSetting(.autoLockMinutes, nil)
        #expect(try store.setting(.autoLockMinutes) == nil)
        #expect(try store.setting(.lockOnSleep) == "1")
        #expect(SettingKey.ledgerToday.rawValue == "ledger_today")
        #expect(SettingKey.rolloverEnabled.rawValue == "rollover_enabled")
    }

    @Test func clockUsesLedgerTodayOnlyWhenDemoOnly() throws {
        let ledger = try TestLedger()
        let store = ledger.store
        let now = d("2027-05-03").date(timeZone: berlin).addingTimeInterval(12 * 3600)
        func today() throws -> LocalDate {
            try store.database.read { try LedgerClock.today($0, now: now, timeZone: berlin) }
        }

        // No settings: system date.
        #expect(try today() == d("2027-05-03"))

        // ledger_today alone is ignored.
        try store.setSetting(.ledgerToday, "2026-11-12")
        #expect(try today() == d("2027-05-03"))

        // demo_only = 0: system date.
        try store.setSetting(.demoOnly, "0")
        #expect(try today() == d("2027-05-03"))

        // demo_only = 1: ledger date.
        try store.setSetting(.demoOnly, "1")
        #expect(try today() == d("2026-11-12"))
        #expect(try store.today() == d("2026-11-12"))

        // Garbage ledger_today falls back to the system date.
        try store.setSetting(.ledgerToday, "garbage")
        #expect(try today() == d("2027-05-03"))

        try store.setSetting(.ledgerToday, "2026-11-12")
        try store.setSetting(.demoOnly, nil)
        #expect(try today() == d("2027-05-03"))
    }
}
