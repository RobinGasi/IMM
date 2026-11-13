import Foundation
import GRDB
import Testing
@testable import IMMLedger

@Suite struct DefinitionsTests {
    // MARK: Running balance

    @Test func runningBalancesFollowNewestFirstOrder() throws {
        let ledger = try TestLedger()
        try ledger.seed { db in
            try AccountRecord(id: "giro", kind: .giro, name: "Girokonto", balance: 100_000).insert(db)
            try AccountRecord(id: "other", kind: .giro, name: "Other", balance: 5_000).insert(db)
            // Newest first: n1 (nov 11), same-day pair with times, same-day pair with seq, oldest.
            try TransactionRecord.fixture("n1", account: "giro", "2026-11-11", -1_000).insert(db)
            try TransactionRecord.fixture("t_early", account: "giro", "2026-11-05", -100, time: "09:00").insert(db)
            try TransactionRecord.fixture("t_late", account: "giro", "2026-11-05", -200, time: "18:00").insert(db)
            try TransactionRecord.fixture("s_low", account: "giro", "2026-11-01", -10, seq: 1).insert(db)
            try TransactionRecord.fixture("s_high", account: "giro", "2026-11-01", -20, seq: 2).insert(db)
            try TransactionRecord.fixture("old", account: "giro", "2026-10-20", 5_000).insert(db)
            try TransactionRecord.fixture("gone", account: "giro", "2026-10-25", -99_999).insert(db)
            try db.execute(sql: "UPDATE ledger_transaction SET deleted_at = '2026-11-12' WHERE id = 'gone'")
            try TransactionRecord.fixture("foreign", account: "other", "2026-11-11", -777).insert(db)
        }
        let balances = try ledger.database.read { try LedgerDefinitions.runningBalances($0, accountID: "giro") }
        #expect(balances.count == 6)
        #expect(balances["n1"] == 100_000)
        #expect(balances["t_late"] == 101_000)
        #expect(balances["t_early"] == 101_200)
        #expect(balances["s_high"] == 101_300)
        #expect(balances["s_low"] == 101_320)
        #expect(balances["old"] == 101_330)
        #expect(balances["foreign"] == nil)
        // Balance before the oldest row, i.e. after `old` minus its own amount.
        #expect(balances["old"]! - 5_000 == 96_330)
    }

    @Test func orderingFragment() {
        #expect(LedgerOrder.transactionsNewestFirst() == "booking_date DESC, COALESCE(booked_time, '') DESC, booking_seq DESC, id DESC")
        #expect(LedgerOrder.transactionsNewestFirst(alias: "t").hasPrefix("t.booking_date DESC"))
    }

    // MARK: Spending

    private func insertSpendingFixture(_ db: Database) throws {
        try AccountRecord(id: "giro", kind: .giro, name: "Girokonto", balance: 0).insert(db)
        try AccountRecord(id: "visa", kind: .creditCard, name: "Visa", balance: 0).insert(db)
        try CategoryRecord(id: "groceries", name: "Groceries", colorToken: "chart-5").insert(db)
        try CategoryRecord(id: "leisure", name: "Leisure", colorToken: "chart-2").insert(db)
        try CategoryRecord(id: "income", name: "Income", colorToken: "credit", kind: .income).insert(db)

        var n = 0
        func add(_ date: String, _ amount: Int, category: String? = "groceries", account: String = "giro", own: Bool = false) throws {
            n += 1
            try TransactionRecord.fixture("t\(n)", account: account, date, amount, category: category, own: own).insert(db)
        }
        // 11 complete months before November 2026: Dec 2025 … Oct 2026, one 100,00 € grocery row each …
        for offset in 0..<11 {
            let month = d("2025-12-15").adding(months: offset)
            try add(month.iso, -10_000, account: offset.isMultiple(of: 2) ? "giro" : "visa")
        }
        // … plus 50,00 € leisure in October (on the last day of the window).
        try add("2026-10-31", -5_000, category: "leisure")
        // Excluded rows.
        try add("2026-11-03", -99_999)                              // current month
        try add("2025-11-30", -77_777)                              // before the window
        try add("2026-03-10", -50_000, own: true)                   // own transfer
        try add("2026-03-11", 20_000)                               // positive amount
        try add("2026-03-12", -33_333, category: nil)               // uncategorised
        try add("2026-03-13", -44_444, category: "income")          // income-kind category
        try add("2026-03-14", -55_555)
        try db.execute(sql: "UPDATE ledger_transaction SET deleted_at = '2026-11-12' WHERE id = ?", arguments: ["t\(n)"])  // tombstone
        // Current-month rows by category.
        try add("2026-11-10", -2_500, category: "leisure", account: "visa")
    }

    @Test func spendingByCategoryAndTotal() throws {
        let ledger = try TestLedger()
        try ledger.seed(insertSpendingFixture)
        try ledger.database.read { db throws in
            let november = try LedgerDefinitions.spending(db, from: d("2026-11-01"), through: d("2026-11-12"))
            #expect(november == ["groceries": 99_999, "leisure": 2_500])
            #expect(try LedgerDefinitions.totalSpending(db, from: d("2026-11-01"), through: d("2026-11-12")) == 102_499)

            // Inclusive bounds.
            let one = try LedgerDefinitions.spending(db, from: d("2026-11-10"), through: d("2026-11-10"))
            #expect(one == ["leisure": 2_500])
            #expect(try LedgerDefinitions.spending(db, from: d("2026-11-04"), through: d("2026-11-09")).isEmpty)
        }
    }

    @Test func monthlyAverageOverElevenCompleteMonths() throws {
        let ledger = try TestLedger()
        try ledger.seed(insertSpendingFixture)
        try ledger.database.read { db throws in
            // Window Dec 2025 … Oct 2026 = 11 × 100,00 + 50,00 = 1.150,00 → /11 = 104,5454… → 104,55 (half-up).
            #expect(try LedgerDefinitions.monthlyAverageSpending(db, today: d("2026-11-12")) == 10_455)
            // Same window for any day in November.
            #expect(try LedgerDefinitions.monthlyAverageSpending(db, today: d("2026-11-01")) == 10_455)
            #expect(try LedgerDefinitions.monthlyAverageSpending(db, today: d("2026-11-30")) == 10_455)
            // One month later the window is Jan … Nov 2026 and includes the 999,99 € of November.
            let next = try LedgerDefinitions.monthlyAverageSpending(db, today: d("2026-12-05"))
            #expect(next == (2 * (115_000 - 10_000 + 102_499) + 11) / 22)
        }
    }

    @Test func averageRoundsHalfUp() throws {
        let ledger = try TestLedger()
        try ledger.seed { db in
            try AccountRecord(id: "a", kind: .giro, name: "A", balance: 0).insert(db)
            try CategoryRecord(id: "c", name: "C", colorToken: "chart-1").insert(db)
            try TransactionRecord.fixture("x", account: "a", "2026-05-01", -16, category: "c").insert(db)  // 16 / 11 = 1.4545 → 1
        }
        try ledger.database.read { db throws in
            #expect(try LedgerDefinitions.monthlyAverageSpending(db, today: d("2026-11-12")) == 1)
        }
        try ledger.seed { db in
            try TransactionRecord.fixture("y", account: "a", "2026-06-01", -1, category: "c").insert(db)  // 17 / 11 = 1.545 → 2
        }
        try ledger.database.read { db throws in
            #expect(try LedgerDefinitions.monthlyAverageSpending(db, today: d("2026-11-12")) == 2)
        }
    }

    // MARK: Net worth

    @Test func netWorthNowAndOnPastDates() throws {
        let ledger = try TestLedger()
        try ledger.seed { db in
            try AccountRecord(id: "giro", kind: .giro, name: "Girokonto", balance: 100_000).insert(db)
            try AccountRecord(id: "wallet", kind: .wallet, name: "Wallet", balance: 5_000).insert(db)
            try AccountRecord(id: "depot", kind: .depot, name: "Depot", balance: 0).insert(db)
            try AccountRecord(id: "closed", kind: .savings, name: "Closed", balance: 999_999).insert(db)
            try db.execute(sql: "UPDATE account SET deleted_at = '2026-11-12' WHERE id = 'closed'")
            try TransactionRecord.fixture("a", account: "giro", "2026-11-05", -10_000).insert(db)
            try TransactionRecord.fixture("b", account: "giro", "2026-10-20", -5_000).insert(db)
            try HoldingRecord(id: "h1", accountId: "depot", name: "ETF", isin: "IE00B4L5Y983", quantityMicro: 2_000_000, price: 5_000, costBasis: 9_000).insert(db)
            try HoldingRecord(id: "cash", accountId: "depot", name: "Cash", quantityMicro: 1_000_000, price: 2_500, costBasis: 2_500).insert(db)
            try DepotValueRecord(id: "v1", accountId: "depot", date: d("2026-10-31"), value: 11_000).insert(db)
            try DepotValueRecord(id: "v0", accountId: "depot", date: d("2026-09-30"), value: 9_000).insert(db)
        }
        try ledger.database.read { db throws in
            #expect(try LedgerDefinitions.holdingsValue(db, accountID: "depot") == 12_500)
            #expect(try LedgerDefinitions.holdingsValue(db, accountID: "giro") == nil)
            #expect(try LedgerDefinitions.netWorth(db) == 100_000 + 5_000 + 12_500)
            #expect(try LedgerDefinitions.netWorth(db, on: nil) == 117_500)
            // On 31.10.: giro before the 5 Nov booking, depot from history.
            #expect(try LedgerDefinitions.netWorth(db, on: d("2026-10-31")) == 110_000 + 5_000 + 11_000)
            // On 15.10.: both giro bookings undone, depot from 30.09.
            #expect(try LedgerDefinitions.netWorth(db, on: d("2026-10-15")) == 115_000 + 5_000 + 9_000)
            // Booking on the date itself is included.
            #expect(try LedgerDefinitions.netWorth(db, on: d("2026-11-05")) == 100_000 + 5_000 + 11_000)
            // Before any depot history the depot contributes nothing.
            #expect(try LedgerDefinitions.netWorth(db, on: d("2026-01-01")) == 115_000 + 5_000)
            #expect(try LedgerDefinitions.depotValue(db, accountID: "depot", on: d("2026-10-30")) == 9_000)
            #expect(try LedgerDefinitions.depotValue(db, accountID: "depot", on: d("2026-01-01")) == nil)
        }
    }

    @Test func holdingsValueRoundsHalfUpPerHolding() throws {
        let ledger = try TestLedger()
        try ledger.seed { db in
            try AccountRecord(id: "depot", kind: .depot, name: "Depot", balance: 777).insert(db)
            try HoldingRecord(id: "h", accountId: "depot", name: "ETF", quantityMicro: 182_000_000, price: 10_845, costBasis: 1).insert(db)  // 182 × 108,45 = 19.737,90
            try HoldingRecord(id: "f", accountId: "depot", name: "Frac", quantityMicro: 500_000, price: 3, costBasis: 1).insert(db)         // 0,5 × 3 cents = 1,5 cents → 2
        }
        try ledger.database.read { db throws in
            #expect(try LedgerDefinitions.holdingsValue(db, accountID: "depot") == 1_973_790 + 2)
        }
    }

    @Test func depotWithoutHoldingsFallsBackToBalance() throws {
        let ledger = try TestLedger()
        try ledger.seed { db in
            try AccountRecord(id: "depot", kind: .depot, name: "Depot", balance: 4_200).insert(db)
        }
        try ledger.database.read { db throws in
            #expect(try LedgerDefinitions.netWorth(db) == 4_200)
        }
    }

    // MARK: Counts

    @Test func newAndUncategorisedCounts() throws {
        let ledger = try TestLedger()
        try ledger.seed { db in
            try AccountRecord(id: "a", kind: .giro, name: "A", balance: 0).insert(db)
            try CategoryRecord(id: "c", name: "C", colorToken: "chart-1").insert(db)
            try TransactionRecord.fixture("1", account: "a", "2026-11-01", -1, new: true).insert(db)                     // new + uncategorised
            try TransactionRecord.fixture("2", account: "a", "2026-11-02", -1, category: "c", new: true).insert(db)      // new
            try TransactionRecord.fixture("3", account: "a", "2026-11-03", -1).insert(db)                                // uncategorised
            try TransactionRecord.fixture("4", account: "a", "2026-11-04", -1, kind: .transfer).insert(db)               // transfer to a person: uncategorised
            try TransactionRecord.fixture("5", account: "a", "2026-11-05", -1, own: true).insert(db)                     // own transfer: excluded
            try TransactionRecord.fixture("6", account: "a", "2026-11-06", -1, category: "c").insert(db)
            try TransactionRecord.fixture("7", account: "a", "2026-11-07", -1, new: true).insert(db)
            try db.execute(sql: "UPDATE ledger_transaction SET deleted_at = '2026-11-12' WHERE id = '7'")
        }
        try ledger.database.read { db throws in
            #expect(try LedgerDefinitions.newCount(db) == 2)
            #expect(try LedgerDefinitions.uncategorisedCount(db) == 3)
        }
    }
}
