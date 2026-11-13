import Foundation
import Testing
import IMMLedger
@testable import IMMBanking

@Suite("Demo ledger: hard anchors")
struct DemoAnchorTests {
    private let giro = DemoAccountID.giro

    // MARK: 1. Balances

    @Test func accountBalancesAndNetWorth() {
        #expect(view.account(DemoAccountID.giro).balance == 241_836)
        #expect(view.account(DemoAccountID.giro).overdraftLimit == 200_000)
        #expect(view.account(DemoAccountID.tagesgeld).balance == 1_205_000)
        #expect(view.account(DemoAccountID.visa).balance == -38_412)
        #expect(view.account(DemoAccountID.depot).balance == 4_891_240)
        #expect(view.account(DemoAccountID.paypal).balance == 6_190)
        #expect(view.netWorth == 6_305_854)
        #expect(view.snapshot.accounts.count == 5)
    }

    @Test func netWorthOnOctober31() {
        #expect(view.netWorth(on: day(2026, 10, 31)) == 6_185_436)
        #expect(view.netWorth - view.netWorth(on: day(2026, 10, 31)) == 120_418)   // "+1.204,18 € since October"
    }

    @Test func runningBalancesNeverBreakTheOverdraft() {
        for id in [DemoAccountID.giro, DemoAccountID.tagesgeld, DemoAccountID.paypal] {
            for (row, balance) in view.running(id) {
                let floor = view.account(id).overdraftLimit.map { -$0 } ?? 0
                #expect(balance >= floor, "\(id) \(row.bookingDate) \(row.shortName) \(balance)")
            }
        }
    }

    // MARK: 2. Girokonto rows as drawn

    @Test func girokontoDrawnRowsAndRunningBalances() {
        let rows = view.running(giro).reversed()
        let expected: [(LocalDate, String, Int, Int)] = [
            (day(2026, 11, 11), "REWE", -6_348, 241_836),
            (day(2026, 11, 10), "Lieferando", -2_790, 248_184),
            (day(2026, 11, 9), "dm-drogerie markt", -1_845, 250_974),
            (day(2026, 11, 7), "Deutsche Bahn", -4_990, 252_819),
            (day(2026, 11, 5), "Stadtwerke Köln", -8_600, 257_809),
            (day(2026, 11, 3), "Urban Sports Club", -6_400, 266_409),
            (day(2026, 11, 1), "Miete Wohnbau Ehrenfeld eG", -112_000, 272_809),
            (day(2026, 11, 1), "KVB Deutschlandticket", -5_800, 384_809),
            (day(2026, 11, 1), "HUK-COBURG", -3_870, 390_609),
            (day(2026, 10, 27), "Gehalt Rheinwerk Design GmbH", 384_000, 394_479),
            (day(2026, 10, 24), "REWE", -5_216, 10_479),
        ]
        let actual = Array(rows.prefix(expected.count))
        #expect(actual.count == expected.count)
        for (entry, want) in zip(actual, expected) {
            #expect(entry.row.bookingDate == want.0, "\(want.1)")
            #expect(entry.row.shortName == want.1)
            #expect(entry.row.amount == want.2, "\(want.1)")
            #expect(entry.balance == want.3, "\(want.1) balance")
        }
    }

    @Test func girokontoClosingBalanceAndNovemberTotal() {
        #expect(view.balance(giro, on: day(2026, 10, 31)) == 394_479)
        let november = view.transactions(giro).filter { $0.bookingDate.year == 2026 && $0.bookingDate.month == 11 }
        #expect(november.count == 9)
        #expect(november.reduce(0) { $0 + $1.amount } == -152_643)
        // No other Girokonto booking between the 24th and 31st of October besides the salary.
        let lateOctober = view.transactions(giro).filter { $0.bookingDate > day(2026, 10, 24) && $0.bookingDate <= day(2026, 10, 31) }
        #expect(lateOctober.map(\.shortName) == ["Gehalt Rheinwerk Design GmbH"])
    }

    @Test func girokontoHas148RowsInNinetyDays() {
        let rows = view.transactions(giro).filter { $0.bookingDate >= day(2026, 8, 14) && $0.bookingDate <= day(2026, 11, 12) }
        #expect(rows.count == 148)
        #expect(view.transactions(giro).contains { $0.bookingDate == day(2026, 8, 14) } || rows.first!.bookingDate > day(2026, 8, 13))
    }

    @Test func salaryOnThe27th() {
        let salaries = view.transactions(giro).filter { $0.kind == .salary }
        #expect(salaries.count == 22)   // January 2025 to October 2026
        for s in salaries {
            #expect(s.bookingDate.day == 27)
            #expect(s.amount == 384_000)
        }
    }

    @Test func historyStartsOnJanuaryFirst2025() {
        let all = view.snapshot.transactions
        #expect(all.map(\.bookingDate).min()! >= day(2025, 1, 1))
        #expect(all.map(\.bookingDate).min()! <= day(2025, 1, 5))
        #expect(all.map(\.bookingDate).max()! <= day(2026, 11, 12))
        #expect(view.snapshot.depotValueHistory.first?.date == day(2025, 1, 1))
        #expect(view.snapshot.depotValueHistory.last?.date == day(2026, 11, 12))
    }

    // MARK: 3. Overview figures

    @Test func novemberSpendingPerCategory() {
        let from = day(2026, 11, 1), to = day(2026, 11, 12)
        #expect(view.spending(from: from, to: to, category: "Housing") == 120_600)
        #expect(view.spending(from: from, to: to, category: "Groceries") == 31_845)
        #expect(view.spending(from: from, to: to, category: "Leisure & eating out") == 17_665)
        #expect(view.spending(from: from, to: to, category: "Mobility") == 17_260)
        #expect(view.spending(from: from, to: to, category: "Insurance & contracts") == 3_870)
        #expect(view.spending(from: from, to: to, category: "Health & drugstore") == 0)
        #expect(view.spending(from: from, to: to, category: "Other") == 0)
        #expect(view.spending(from: from, to: to) == 191_240)
    }

    @Test func novemberSpendingOutsideGirokonto() {
        func sum(_ account: String, _ category: String) -> Int {
            view.transactions(account).filter {
                $0.bookingDate.year == 2026 && $0.bookingDate.month == 11 && view.category($0) == category
            }.reduce(0) { $0 - $1.amount }
        }
        #expect(sum(DemoAccountID.visa, "Groceries") == 12_052)
        #expect(sum(DemoAccountID.visa, "Leisure & eating out") == 4_471)
        #expect(sum(DemoAccountID.visa, "Mobility") == 6_470)
        #expect(sum(DemoAccountID.paypal, "Groceries") == 11_600)
        #expect(sum(DemoAccountID.paypal, "Leisure & eating out") == 4_004)
    }

    @Test func meanSpendingOfElevenCompleteMonths() {
        var total = 0
        for index in 0..<11 {
            let month = 12 + index
            total += view.monthSpending(2025 + (month - 1) / 12, (month - 1) % 12 + 1)
        }
        #expect(total == 11 * 248_000)
        #expect(total / 11 == 248_000)
        #expect(191_240 * 100 / 248_000 == 77)
    }

    @Test func monthlyVariationWithinFifteenPercent() {
        for index in 0..<11 {
            let month = 12 + index
            let spent = view.monthSpending(2025 + (month - 1) / 12, (month - 1) % 12 + 1)
            #expect(abs(spent - 248_000) <= 248_000 * 15 / 100 + 1, "month \(month) = \(spent)")
        }
    }

    @Test func comingUpRowsAndProjection() throws {
        let contracts = view.profile.contracts
        func contract(_ id: String) throws -> DemoContract { try #require(contracts.first { $0.id == id }) }
        let rows: [(LocalDate, Int)] = [
            (day(2026, 11, 15), -view.profile.savingsPlan.monthlyAmount),
            (try contract("contract-telekom").nextDebit, try contract("contract-telekom").monthlyAmount),
            (try contract("contract-ard").nextDebit, try contract("contract-ard").monthlyAmount),
            (day(2026, 11, 20), view.account(DemoAccountID.visa).balance),   // DKB Visa statement
            (try contract("income-gehalt").nextDebit, try contract("income-gehalt").monthlyAmount),
            (try contract("contract-miete").nextDebit, try contract("contract-miete").monthlyAmount),
        ]
        #expect(rows.map(\.0) == [day(2026, 11, 15), day(2026, 11, 15), day(2026, 11, 15), day(2026, 11, 20),
                                  day(2026, 11, 27), day(2026, 12, 1)])
        #expect(rows.map(\.1) == [-50_000, -4_495, -1_836, -38_412, 384_000, -112_000])
        #expect(view.account(DemoAccountID.giro).balance + rows.reduce(0) { $0 + $1.1 } == 419_093)
    }

    @Test func attentionItems() throws {
        let attention = try view.profile.insights.filter { $0.kind == .attention }.sorted { $0.sortOrder < $1.sortOrder }
            .map { try $0.payload(as: AttentionPayload.self) }
        #expect(attention.count == 3)
        #expect(attention[0].title == "6 transactions without category")
        #expect(attention[0].detail == "Since 03.11., mostly Amazon and PayPal")
        #expect(attention[0].target == "suggestions")
        #expect(attention[1].title == "Spotify raises its price")
        #expect(attention[1].detail == "10,99\u{00A0}€ → 11,99\u{00A0}€ from December")
        #expect(attention[2].title == "HUK-COBURG Kfz notice deadline")
        #expect(attention[2].detail == "Cancel or switch by 30.11.")
    }

    // MARK: 4. Depot

    @Test func depotHoldingsAndTotals() throws {
        let holdings = view.snapshot.holdings
        let funds = holdings.filter { $0.security != nil }
        let cash = try #require(holdings.first { $0.security == nil })
        #expect(funds.count == 3)
        #expect(cash.value == 354_690)
        #expect(funds.reduce(0) { $0 + $1.value } + cash.value == 4_891_240)
        #expect(holdings.reduce(0) { $0 + $1.costBasis } == 4_159_418)
        #expect(4_891_240 - 4_159_418 == 731_822)
        let byISIN = Dictionary(uniqueKeysWithValues: funds.map { ($0.security!.isin, $0) })
        #expect(byISIN["IE00B4L5Y983"]?.quantity == 182)
        #expect(byISIN["IE00B4L5Y983"]?.price == 10_845)
        #expect(byISIN["IE00B4L5Y983"]?.value == 1_973_790)
        #expect(byISIN["IE00BK5BQT80"]?.quantity == 118)
        #expect(byISIN["IE00BK5BQT80"]?.value == 1_558_780)
        #expect(byISIN["IE00BKM4GZ66"]?.quantity == 290)
        #expect(byISIN["IE00BKM4GZ66"]?.value == 1_003_980)
        // Per-fund cost bases sum to the cost basis without cash.
        #expect(funds.reduce(0) { $0 + $1.costBasis } == 4_159_418 - 354_690)
        let weights = view.profile.fundRegionWeights
        #expect(weights.count == 3)
        for w in weights { #expect(w.northAmerica + w.europe + w.emergingMarkets + w.japanPacific == 1_000) }
    }

    @Test func depotValueHistoryFollowsTheDrawnPolyline() throws {
        let history = view.snapshot.depotValueHistory
        let byDate = Dictionary(uniqueKeysWithValues: history.map { ($0.date, $0.value) })
        // One value per day, no gaps, from 01.01.2025 to 12.11.2026.
        #expect(history.count == (day(2026, 11, 12) - day(2025, 1, 1)) + 1)
        for (date, value) in DemoDepot.vertices() {
            #expect(byDate[date] == value, "vertex \(date)")
        }
        #expect(byDate[day(2025, 11, 12)] == 3_790_000)
        #expect(byDate[day(2026, 11, 12)] == 4_891_240)
        // y-axis 38.000 – 50.000 over the last year.
        let lastYear = history.filter { $0.date >= day(2025, 11, 12) }.map(\.value)
        #expect(lastYear.min()! >= 3_700_000)
        #expect(lastYear.max()! <= 5_000_000)
        #expect(byDate[day(2026, 10, 31)] != nil)
    }

    @Test func savingsPlan() {
        let plan = view.profile.savingsPlan
        #expect(plan.monthlyAmount == 50_000)
        #expect(plan.items.map(\.amount) == [30_000, 20_000])
        #expect(plan.items.map(\.sharePercent) == [60, 40])
        #expect(plan.dayOfMonth == 15)
        #expect(plan.nextExecution == day(2026, 11, 15))
    }

    // MARK: 5. Standing orders

    @Test func standingOrders() {
        let orders = view.snapshot.standingOrders
        #expect(orders.count == 6)
        let active = orders.filter { $0.status == .active && $0.rhythm == .monthly }
        #expect(active.count == 4)
        #expect(active.reduce(0) { $0 + $1.amount } == -196_000)
        func order(_ recipient: String) -> BankStandingOrder { orders.first { $0.recipient == recipient }! }
        #expect(order("ETF-Sparplan ING Depot").nextExecution == day(2026, 11, 15))
        #expect(order("ETF-Sparplan ING Depot").amount == -50_000)
        #expect(order("Jonas Weber").rhythm == .once)
        #expect(order("Jonas Weber").nextExecution == day(2026, 11, 20))
        #expect(order("Jonas Weber").amount == -12_000)
        #expect(order("Tagesgeld Sparen").nextExecution == day(2026, 11, 28))
        #expect(order("Miete Wohnbau Ehrenfeld eG").nextExecution == day(2026, 12, 1))
        #expect(order("Mia Hoffmann").amount == -4_000)
        #expect(order("Mia Hoffmann").dayOfMonth == 1)
        #expect(order("Fitnessstudio Altvertrag").status == .paused)
        #expect(order("Fitnessstudio Altvertrag").nextExecution == nil)
        #expect(order("Fitnessstudio Altvertrag").amount == -2_990)
    }

    // MARK: 6. Contracts

    @Test func contracts() {
        let contracts = view.profile.contracts.filter { $0.kind == .contract }
        #expect(contracts.count == 8)
        #expect(contracts.reduce(0) { $0 + $1.monthlyAmount } == -144_100)
        func group(_ name: String) -> Int { contracts.filter { $0.groupName == name }.reduce(0) { $0 + $1.monthlyAmount } }
        #expect(group("Housing") == -122_436)
        #expect(group("Insurance") == -3_870)
        #expect(group("Communication & media") == -5_594)
        #expect(group("Mobility & sport") == -12_200)
        let spotify = contracts.first { $0.provider == "Spotify" }!
        #expect(spotify.accountID == DemoAccountID.paypal)
        #expect(spotify.priceChangeAmount == -1_199)
        #expect(spotify.priceChangeStart == day(2026, 12, 1))
        let huk = contracts.first { $0.provider == "HUK-COBURG Kfz" }!
        #expect(huk.noticeDeadline == day(2026, 11, 30))
        #expect(huk.renewalDate == day(2027, 1, 1))
        #expect(huk.nextDebit == day(2026, 12, 1))
        #expect(contracts.first { $0.provider == "KVB Deutschlandticket" }!.nextDebit == day(2026, 12, 1))
    }
}
