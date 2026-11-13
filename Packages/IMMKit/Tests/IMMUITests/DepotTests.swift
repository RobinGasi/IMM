import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct DepotTests {
    private func render(slug: String, size: CGSize) async throws -> Double {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .depot)
        return try await assertMatchesDesign(
            MainWindowView().environment(model), slug: slug, size: size,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
    }

    @Test func desktopMatchesDesign() async throws {
        let value = try await render(slug: "app-9-depot-desktop", size: CGSize(width: 1440, height: 900))
        print("DEPOT app-9-depot-desktop mismatch \(value)")
    }

    @Test func compactMatchesDesign() async throws {
        let value = try await render(slug: "compact-9-depot-desktop", size: CGSize(width: 1024, height: 720))
        print("DEPOT compact-9-depot-desktop mismatch \(value)")
    }

    @Test func snapshotCarriesTheAnchorFigures() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try #require(try store.database.read(DepotQueries.snapshot))

        #expect(MoneyFormatter.string(snapshot.value) == "48.912,40\u{00A0}€")
        #expect(MoneyFormatter.string(snapshot.costBasis) == "41.594,18\u{00A0}€")
        #expect(MoneyFormatter.string(snapshot.gain, sign: .always) == "+7.318,22\u{00A0}€")
        #expect(DepotText.percent(snapshot.gain, snapshot.costBasis, signed: true) == "+17,6 %")
        #expect(MoneyFormatter.string(snapshot.cash) == "3.546,90\u{00A0}€")
        let yesterday = try #require(snapshot.valueYesterday)
        #expect(DepotText.percent(snapshot.value - yesterday, yesterday, signed: true) == "+0,1 %")

        // Holdings: three funds, then the cash account.
        #expect(snapshot.fundCount == 3)
        #expect(snapshot.holdings.map(\.name) == [
            "iShares Core MSCI World", "Vanguard FTSE All-World", "iShares Core MSCI EM IMI", "Verrechnungskonto, uninvested",
        ])
        #expect(snapshot.holdings.map { DepotText.quantity($0.quantityMicro) }.prefix(3) == ["182", "118", "290"])
        #expect(snapshot.holdings.map { MoneyFormatter.string($0.price) }.prefix(3) == [
            "108,45\u{00A0}€", "132,10\u{00A0}€", "34,62\u{00A0}€",
        ])
        #expect(snapshot.holdings.map { MoneyFormatter.string($0.value) } == [
            "19.737,90\u{00A0}€", "15.587,80\u{00A0}€", "10.039,80\u{00A0}€", "3.546,90\u{00A0}€",
        ])
        #expect(snapshot.holdings.compactMap { holding in
            holding.gain.map { DepotText.percent($0, holding.costBasis, signed: true) }
        } == ["+19,2 %", "+17,9 %", "+21,4 %"])
        #expect(snapshot.holdings.map { DepotText.percent($0.value, snapshot.value) } == ["40,4 %", "31,9 %", "20,5 %", "7,3 %"])
        #expect(snapshot.holdings.last?.isCash == true)
        #expect(snapshot.holdings.last?.gain == nil)

        // Allocation by region.
        #expect(snapshot.regions.map(\.name) == ["North America", "Europe", "Emerging markets", "Japan & Pacific"])
        #expect(snapshot.regions.map(\.colorToken) == ["chart-1", "chart-2", "chart-3", "chart-4"])
        #expect(snapshot.regions.map { DepotText.percent($0.value, snapshot.value) } == ["49,9 %", "10,7 %", "23,7 %", "8,4 %"])

        // Savings plan.
        let plan = try #require(snapshot.savingsPlan)
        #expect(MoneyFormatter.string(plan.amount) == "500,00\u{00A0}€")
        #expect(DepotText.ordinal(plan.dayOfMonth) == "15th")
        #expect(plan.nextExecution.map(DateFormats.dayMonthYear) == "15.11.2026")
        #expect(plan.sourceAccount == "Girokonto, Sparkasse KölnBonn")
        #expect(plan.items.map(\.name) == ["iShares Core MSCI World", "Vanguard FTSE All-World"])
        #expect(plan.items.map { MoneyFormatter.string($0.amount) } == ["300,00\u{00A0}€", "200,00\u{00A0}€"])
        #expect(plan.items.map { DepotText.wholePercent($0.amount, plan.amount) } == ["60 %", "40 %"])
    }

    @Test func rangesCoverTheHistory() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try #require(try store.database.read(DepotQueries.snapshot))

        #expect(snapshot.points(in: .oneYear).count == 366)
        #expect(snapshot.points(in: .sixMonths).count == 185)
        #expect(snapshot.points(in: .oneMonth).count == 32)
        #expect(snapshot.points(in: .max).count == 681)
        let year = snapshot.points(in: .oneYear)
        #expect(DateFormats.dayMonthYear(year[0].date) == "12.11.2025")
        #expect(MoneyFormatter.string(snapshot.value - year[0].value, sign: .always) == "+11.012,40\u{00A0}€")

        // 12 debits of 500,00 € since 12.11.2025 (15.11.2025 … 15.10.2026).
        let plan = try #require(snapshot.savingsPlan)
        #expect(plan.debitCount(after: year[0].date, through: snapshot.today) == 12)
    }

    @Test func oneYearAxisRunsFrom50000To38000() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try #require(try store.database.read(DepotQueries.snapshot))
        let chart = try #require(DepotChartModel(points: snapshot.points(in: .oneYear), range: .oneYear))

        #expect(chart.ticks.map(\.euros) == [50_000, 46_000, 42_000, 38_000])
        for (tick, expected) in zip(chart.ticks, [8, 53.7, 99.4, 145.1]) {
            #expect(abs(tick.y - CGFloat(expected)) < 0.001)
        }
        #expect(chart.ticks.map { DepotChartModel.axisText($0.euros) } == ["50.000", "46.000", "42.000", "38.000"])
        // The last point sits where the design draws the end dot.
        let end = try #require(chart.plotPoints(width: 716).last)
        #expect(abs(end.x - 712) < 0.01)
        #expect(abs(end.y - 20.4) < 0.5)
        #expect(chart.xLabels.map(\.text) == ["12.11.2025", "Feb", "May", "Aug", "Today"])

        let max = try #require(DepotChartModel(points: snapshot.points(in: .max), range: .max))
        #expect(max.xLabels.map(\.text) == ["01.01.2025", "Jul 2025", "Jan 2026", "Jul 2026", "Today"])
        let month = try #require(DepotChartModel(points: snapshot.points(in: .oneMonth), range: .oneMonth))
        #expect(month.xLabels.count == 5)
        #expect(month.ticks.count == 4)
    }
}
