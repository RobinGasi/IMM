import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct BudgetsTests {
    private let nbsp = "\u{00A0}"

    private func render(slug: String, size: CGSize) async throws -> Double {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .budgets)
        let value = try await assertMatchesDesign(
            MainWindowView().environment(model), slug: slug, size: size, settle: 0.4,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        print("BUDGETS \(slug) mismatch \(value)")
        return value
    }

    // MARK: Comparison with the design

    @Test func desktopMatchesDesign() async throws {
        _ = try await render(slug: "app-6-budgets-desktop", size: CGSize(width: 1440, height: 900))
    }

    @Test func compactMatchesDesign() async throws {
        _ = try await render(slug: "compact-6-budgets-desktop", size: CGSize(width: 1024, height: 720))
    }

    // MARK: Figures

    @Test func snapshotCarriesTheDrawnFigures() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(BudgetsQueries.snapshot)
        func money(_ value: Int, symbol: Bool = true) -> String { MoneyFormatter.string(value, symbol: symbol) }

        #expect(snapshot.today.iso == "2026-11-12")
        #expect(snapshot.rows.map(\.categoryName) == ["Groceries", "Mobility", "Leisure & eating out", "Health & drugstore", "Other"])
        #expect(snapshot.rows.map { money($0.spent, symbol: false) } == ["318,45", "172,60", "176,65", "0,00", "0,00"])
        #expect(snapshot.rows.map { money($0.limit, symbol: false) } == ["420,00", "220,00", "150,00", "60,00", "150,00"])
        #expect(snapshot.rows.map { money($0.remaining) } == [
            "101,55\(nbsp)€", "47,40\(nbsp)€", "−26,65\(nbsp)€", "60,00\(nbsp)€", "150,00\(nbsp)€",
        ])
        #expect(snapshot.rows.map(\.isOver) == [false, false, true, false, false])
        #expect(snapshot.overCount == 1)
        #expect(money(snapshot.totalSpent) == "667,70\(nbsp)€")
        #expect(money(snapshot.totalLimit) == "1.000,00\(nbsp)€")
        #expect(money(snapshot.leftToSpend) == "332,30\(nbsp)€")
        #expect((snapshot.totalFraction * 1000).rounded() / 10 == 66.8)
        #expect(snapshot.dayOfMonth == 12)
        #expect(snapshot.daysInMonth == 30)
        #expect(snapshot.daysLeft == 18)
        #expect(snapshot.paceFraction == 0.4)
        #expect(DateFormats.dayMonth(snapshot.monthEnd) == "30.11.")
        #expect(DateFormats.monthName(snapshot.nextMonth) == "December")
        #expect(snapshot.rolloverEnabled)
    }

    @Test func fixedCostsAreContractsOutsideTheBudgets() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(BudgetsQueries.snapshot)

        #expect(snapshot.fixedCosts.map(\.label) == ["Rent, Wohnbau Ehrenfeld", "Electricity, Stadtwerke Köln", "Contracts & insurance"])
        #expect(snapshot.fixedCosts.map { MoneyFormatter.string($0.amount, symbol: false) } == ["1.120,00", "86,00", "113,00"])
        #expect(snapshot.fixedCosts.map(\.colorToken) == ["chart-1", "chart-1", "chart-4"])
        #expect(MoneyFormatter.string(snapshot.fixedCostsTotal) == "1.319,00\(nbsp)€")
        let members = try #require(snapshot.fixedCosts.last).members
        #expect(members.map(\.label) == ["ARD ZDF Rundfunkbeitrag", "HUK-COBURG Kfz", "Telekom Deutschland", "Spotify"])
        #expect(members.map { MoneyFormatter.string($0.amount, symbol: false) } == ["18,36", "38,70", "44,95", "10,99"])
    }

    @Test func rolloverFollowsTheSetting() throws {
        let isolated = try DemoVaultFixture.makeIsolated()
        try isolated.store.setSetting(.rolloverEnabled, "0")
        #expect(try isolated.store.database.read(BudgetsQueries.snapshot).rolloverEnabled == false)
        try isolated.store.setSetting(.rolloverEnabled, "1")
        #expect(try isolated.store.database.read(BudgetsQueries.snapshot).rolloverEnabled)
    }

    @Test func housingProviderLabelsReadShort() {
        #expect(BudgetsQueries.label(forProvider: "Miete Wohnbau Ehrenfeld eG") == "Rent, Wohnbau Ehrenfeld")
        #expect(BudgetsQueries.label(forProvider: "Stadtwerke Köln Strom") == "Electricity, Stadtwerke Köln")
        #expect(BudgetsQueries.label(forProvider: "Spotify") == "Spotify")
    }
}
