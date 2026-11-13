import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct TransactionsTests {
    // MARK: Helpers

    private let nbsp = "\u{00A0}"

    private func accountID(_ store: LedgerStore, name: String) throws -> String {
        try store.database.read { db in
            try #require(try AccountRecord.live().filter(Column("name") == name).fetchOne(db)).id
        }
    }

    private func snapshot(
        _ store: LedgerStore, scope: TransactionScope, period: TransactionPeriod = .last90Days,
        direction: TransactionDirection = .all, category: TransactionCategoryFilter = .all
    ) throws -> TransactionListSnapshot {
        let filter = TransactionFilter(scope: scope, period: period, direction: direction, category: category)
        return try store.database.read { try TransactionQueries.snapshot($0, filter: filter) }
    }

    private func reweID(_ store: LedgerStore) throws -> String {
        let giro = try accountID(store, name: "Girokonto")
        let all = try snapshot(store, scope: .account(giro), period: .thisMonth)
        return try #require(all.items.first { $0.shortName == "REWE" }).id
    }

    private func render(
        slug: String, size: CGSize, scope: (LedgerStore) throws -> AccountScope,
        appearance: NSAppearance.Name = .aqua, seed: ((LedgerStore) throws -> TransactionsSeed)? = nil
    ) async throws -> Double {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .transactions(try scope(fixture.store)))
        let seedValue = try seed?(fixture.store)
        let value = try await assertMatchesDesign(
            MainWindowView().environment(model), slug: slug, size: size, appearance: appearance, settle: 0.4,
            environment: {
                var view = AnyView($0.environment(\.immWindowWidth, size.width))
                if let seedValue { view = AnyView(view.environment(\.transactionsSeed, seedValue)) }
                return view
            })
        print("TRANSACTIONS \(slug) mismatch \(value)")
        return value
    }

    // MARK: Comparison with the design

    @Test func listMatchesDesign() async throws {
        _ = try await render(
            slug: "app-2-transactions-desktop", size: CGSize(width: 1440, height: 900),
            scope: { .account(try accountID($0, name: "Girokonto")) })
    }

    @Test func darkListMatchesDesign() async throws {
        _ = try await render(
            slug: "dark-2-transactions-desktop", size: CGSize(width: 1440, height: 900),
            scope: { .account(try accountID($0, name: "Girokonto")) }, appearance: .darkAqua)
    }

    @Test func compactListMatchesDesign() async throws {
        _ = try await render(
            slug: "compact-2-transactions-desktop", size: CGSize(width: 1024, height: 720),
            scope: { .account(try accountID($0, name: "Girokonto")) })
    }

    @Test func detailMatchesDesign() async throws {
        _ = try await render(
            slug: "app-3-transaction-detail-desktop", size: CGSize(width: 1440, height: 900),
            scope: { .account(try accountID($0, name: "Girokonto")) },
            seed: { TransactionsSeed(period: .thisMonth, selection: try reweID($0)) })
    }

    @Test func allTransactionsMatchesDesign() async throws {
        _ = try await render(
            slug: "states-all-transactions-desktop", size: CGSize(width: 1440, height: 900), scope: { _ in .all })
    }

    // MARK: Queries

    @Test func girokontoListCarriesTheAnchorFigures() throws {
        let store = try DemoVaultFixture.shared().store
        let giro = try accountID(store, name: "Girokonto")
        let list = try snapshot(store, scope: .account(giro))

        #expect(list.items.count == 148)
        #expect(MoneyFormatter.string(list.balance) == "2.418,36\(nbsp)€")
        #expect(MoneyFormatter.string(list.balance + list.overdraftLimit) == "4.418,36\(nbsp)€")
        #expect(list.chart.paydays.map { DateFormats.dayMonth($0.date) } == ["27.08.", "27.09.", "27.10."])
        #expect(DateFormats.dayMonth(list.chart.start) == "14.08.")

        // Newest row: REWE with the account balance.
        let newest = try #require(list.items.first)
        #expect(newest.shortName == "REWE")
        #expect(newest.counterpartyName == "REWE Markt GmbH")
        #expect(MoneyFormatter.string(newest.amount) == "−63,48\(nbsp)€")
        #expect(newest.balanceAfter == list.balance)
        #expect(newest.isNew)

        // November: nine bookings, total −1.526,43, closing balance of October 3.944,79.
        let november = try #require(list.months.first)
        #expect(DateFormats.monthYear(november.first) == "November 2026")
        #expect(MoneyFormatter.string(november.total) == "−1.526,43\(nbsp)€")
        #expect(november.previousClosing == 394_479)
        #expect(list.items.filter { $0.bookingDate.firstOfMonth == november.first }.count == 9)

        // The chart ends at today's balance.
        #expect(list.chart.points.last?.value == list.balance)
    }

    @Test func tableRowsFollowTheDesign() throws {
        let store = try DemoVaultFixture.shared().store
        let giro = try accountID(store, name: "Girokonto")
        let list = try snapshot(store, scope: .account(giro))
        let rows = TransactionRowsBuilder.rows(for: list, mode: .list)

        guard case .monthHeader(_, let title, let total) = rows[0] else {
            Issue.record("first row is not a month header")
            return
        }
        #expect(title == "November 2026")
        #expect(total == "−1.526,43\(nbsp)€")
        guard case .transaction(let first) = rows[1] else {
            Issue.record("second row is not a transaction")
            return
        }
        #expect(first.payee == "REWE")
        #expect(first.date == "11.11.")
        #expect(first.amount == "−63,48\(nbsp)€")
        #expect(first.balance == "2.418,36\(nbsp)€")
        #expect(first.categoryName == "Groceries")
        #expect(first.isNew)
        guard case .closingBalance(_, let label, let amount, let date) = rows[10] else {
            Issue.record("row 10 is not the closing balance: \(rows[10])")
            return
        }
        #expect(label == "Closing balance 31.10.2026")
        #expect(amount == "3.944,79\(nbsp)€")
        #expect(date == "31.10.")

        // Inspector layout: no totals, amounts without the currency sign, one month only.
        let narrow = try snapshot(store, scope: .account(giro), period: .thisMonth)
        let inspectorRows = TransactionRowsBuilder.rows(for: narrow, mode: .inspector)
        #expect(inspectorRows.count == 9)
        guard case .transaction(let rewe) = inspectorRows[0] else {
            Issue.record("first inspector row is not a transaction")
            return
        }
        #expect(rewe.amount == "−63,48")
        #expect(TransactionText.footerLabel(narrow) == "Spent in November so far")
        #expect(TransactionText.footerRange(narrow) == "01.\u{2013}12.11.2026")
    }

    @Test func allTransactionsSumTheFourAccountsWithoutDepot() throws {
        let store = try DemoVaultFixture.shared().store
        let list = try snapshot(store, scope: .all)
        #expect(MoneyFormatter.string(list.balance) == "14.146,14\(nbsp)€")
        #expect(list.summedAccountCount == 4)
        #expect(list.excludesDepot)
        let rows = TransactionRowsBuilder.rows(for: list, mode: .list)
        // No balance column, no closing balances, account name as the second line.
        #expect(TransactionRowsBuilder.tableLayout(for: list, mode: .list) == .list(showsBalance: false))
        #expect(!rows.contains { if case .closingBalance = $0 { return true } else { return false } })
        guard case .transaction(let first) = rows[1] else {
            Issue.record("second row is not a transaction")
            return
        }
        #expect(first.secondary == "Visa Card" || first.secondary == "Girokonto" || first.secondary == "Wallet")
        let nov = try snapshot(store, scope: .all, period: .thisMonth)
        let direct = try store.database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT SUM(amount) FROM ledger_transaction
                WHERE deleted_at IS NULL AND booking_date BETWEEN '2026-11-01' AND '2026-11-12'
                """) ?? 0
        }
        #expect(nov.months.first?.total == direct)
    }

    @Test func incomeFilterShowsOnlyPositiveRows() throws {
        let store = try DemoVaultFixture.shared().store
        let giro = try accountID(store, name: "Girokonto")
        let income = try snapshot(store, scope: .account(giro), direction: .income)
        #expect(!income.items.isEmpty)
        #expect(income.items.allSatisfy { $0.amount > 0 })
        #expect(income.items.contains { $0.kind == .salary })

        let spending = try snapshot(store, scope: .account(giro), direction: .spending)
        #expect(!spending.items.isEmpty)
        #expect(spending.items.allSatisfy { $0.amount < 0 })
        #expect(income.items.count + spending.items.count == 148)

        // The rows the table gets for Income are all positive too.
        let rows = TransactionRowsBuilder.rows(for: income, mode: .list)
        let data = rows.compactMap { row -> TransactionRowData? in
            if case .transaction(let d) = row { return d } else { return nil }
        }
        #expect(data.allSatisfy { $0.isPositive && $0.amount.hasPrefix("+") })
    }

    @Test func periodAndCategoryFiltersNarrowTheList() throws {
        let store = try DemoVaultFixture.shared().store
        let giro = try accountID(store, name: "Girokonto")
        let november = try snapshot(store, scope: .account(giro), period: .thisMonth)
        #expect(november.items.count == 9)
        #expect(november.items.allSatisfy { $0.bookingDate.month == 11 && $0.bookingDate.year == 2026 })
        let october = try snapshot(store, scope: .account(giro), period: .lastMonth)
        #expect(october.items.allSatisfy { $0.bookingDate.month == 10 })
        let all = try snapshot(store, scope: .account(giro), period: .allTime)
        #expect(all.items.count > 148)
        let last30 = try snapshot(store, scope: .account(giro), period: .last30Days)
        #expect(last30.items.count < 148 && !last30.items.isEmpty)

        let groceries = try store.database.read { db in
            try #require(try CategoryRecord.live().filter(Column("name") == "Groceries").fetchOne(db)).id
        }
        let filtered = try snapshot(store, scope: .account(giro), period: .thisMonth, category: .category(groceries))
        #expect(filtered.items.map(\.shortName) == ["REWE", "dm-drogerie markt"])
        let uncategorised = try snapshot(store, scope: .all, period: .thisMonth, category: .uncategorised)
        #expect(uncategorised.items.count >= 6)
        #expect(uncategorised.items.allSatisfy { $0.categoryID == nil })
    }

    // MARK: Inspector

    @Test func selectingReweShowsItInTheInspectorModel() async throws {
        let store = try DemoVaultFixture.shared().store
        let giro = try accountID(store, name: "Girokonto")
        let id = try reweID(store)
        let model = TransactionsModel(filter: TransactionFilter(scope: .account(giro)))
        let task = Task { await model.observe(store) }
        defer { task.cancel() }
        for _ in 0..<100 where model.snapshot == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.snapshot != nil)
        #expect(model.selectedItem == nil)

        model.selection = id
        let item = try #require(model.selectedItem)
        #expect(item.counterpartyName == "REWE Markt GmbH")
        #expect(MoneyFormatter.string(item.amount) == "−63,48\(nbsp)€")
        #expect(TransactionText.detailSubtitle(item) == "Card payment · Wed 11.11.2026, 18:42")
        #expect(item.bookingText == "Kartenzahlung")
        #expect(item.creditorID == "DE79ZZZ00000110925")

        await model.loadRuleInfo(store)
        let rule = try #require(model.ruleInfo)
        #expect(rule.ruleExists)
        #expect(rule.earlierCount > 0)

        model.clearSelection()
        #expect(model.selectedItem == nil)
    }

    @Test func deepLinkWidensTheFilterWhenTheRowIsHidden() async throws {
        let store = try DemoVaultFixture.shared().store
        let giro = try accountID(store, name: "Girokonto")
        // A booking older than 90 days.
        let all = try snapshot(store, scope: .account(giro), period: .allTime)
        let old = try #require(all.items.last)
        let model = TransactionsModel(filter: TransactionFilter(scope: .account(giro)))
        let task = Task { await model.observe(store) }
        defer { task.cancel() }
        for _ in 0..<100 where model.snapshot == nil { try await Task.sleep(for: .milliseconds(20)) }
        model.requestSelection(old.id)
        // The current list lacks the row: the model widens the filter; the screen's `.task(id: filter)`
        // restarts the observation, which the test does by hand.
        #expect(model.filter.period == .allTime)
        task.cancel()
        let restart = Task { await model.observe(store) }
        defer { restart.cancel() }
        for _ in 0..<100 where model.selection == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.selection == old.id)
        #expect(model.selectedItem?.id == old.id)
    }
}
