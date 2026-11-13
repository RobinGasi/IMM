import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct OverviewTests {
    private func render(slug: String, size: CGSize) async throws -> Double {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .overview)
        return try await assertMatchesDesign(
            MainWindowView().environment(model), slug: slug, size: size,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
    }

    @Test func desktopMatchesDesign() async throws {
        let value = try await render(slug: "app-1-overview-desktop", size: CGSize(width: 1440, height: 900))
        print("OVERVIEW app-1-overview-desktop mismatch \(value)")
    }

    @Test func compactMatchesDesign() async throws {
        let value = try await render(slug: "compact-1-overview-desktop", size: CGSize(width: 1024, height: 720))
        print("OVERVIEW compact-1-overview-desktop mismatch \(value)")
    }

    @Test func snapshotCarriesTheAnchorFigures() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(OverviewQueries.snapshot)

        #expect(MoneyFormatter.string(snapshot.netWorth) == "63.058,54\u{00A0}€")
        #expect(snapshot.accountCount == 5)
        #expect(MoneyFormatter.string(snapshot.netWorthChange, sign: .always) == "+1.204,18\u{00A0}€")
        #expect(DateFormats.monthName(snapshot.previousMonthEnd) == "October")
        #expect(snapshot.netWorthSeries.count == 12)
        #expect(snapshot.netWorthSeries.map(\.label).first == "Dec")
        #expect(snapshot.netWorthSeries.map(\.label).last == "Nov")
        #expect(snapshot.netWorthSeries.last?.value == snapshot.netWorth)

        // Accounts by bank, in ledger order.
        #expect(snapshot.accountGroups.map(\.bankName) == ["Sparkasse KölnBonn", "DKB", "ING", "PayPal"])
        let values = snapshot.accountGroups.flatMap(\.accounts).map { MoneyFormatter.string($0.value) }
        #expect(values == ["2.418,36\u{00A0}€", "12.050,00\u{00A0}€", "−384,12\u{00A0}€", "48.912,40\u{00A0}€", "61,90\u{00A0}€"])
        let accounts = snapshot.accountGroups.flatMap(\.accounts)
        #expect(accounts.first { $0.name == "Depot" }?.detail == .holdings(securities: 3, allETFs: true, hasCash: true))
        #expect(accounts.first { $0.name == "Visa Card" }?.detail == .statement("Statement 20.11."))
        if case .iban(let short) = accounts.first(where: { $0.name == "Girokonto" })?.detail {
            #expect(short.hasSuffix(" \u{2026} 0827 51"))
        } else {
            Issue.record("Girokonto has no IBAN detail")
        }

        // Spent so far.
        #expect(MoneyFormatter.string(-snapshot.spentTotal) == "−1.912,40\u{00A0}€")
        #expect(snapshot.spending.map(\.name) == ["Housing", "Groceries", "Leisure & eating out", "Mobility", "Insurance & contracts"])
        #expect(snapshot.spending.map { MoneyFormatter.string(-$0.amount) } == [
            "−1.206,00\u{00A0}€", "−318,45\u{00A0}€", "−176,65\u{00A0}€", "−172,60\u{00A0}€", "−38,70\u{00A0}€",
        ])
        #expect(MoneyFormatter.string(snapshot.monthlyAverage) == "2.480,00\u{00A0}€")
        #expect(snapshot.averagePercent == 77)
        #expect(snapshot.daysToGo == 18)

        // Coming up and the projection.
        #expect(snapshot.upcomingAccountName == "Girokonto")
        #expect(DateFormats.dayMonth(snapshot.upcomingUntil) == "01.12.")
        #expect(snapshot.upcoming.count == 6)
        #expect(snapshot.upcoming.map { DateFormats.dayMonth($0.date) } == ["15.11.", "15.11.", "15.11.", "20.11.", "27.11.", "01.12."])
        #expect(snapshot.upcoming.map(\.amount) == [-50_000, -4_495, -1_836, -38_412, 384_000, -112_000])
        #expect(MoneyFormatter.string(snapshot.projectedBalance) == "4.190,93\u{00A0}€")

        // Needs attention: the three stored insights.
        #expect(snapshot.attention.count == 3)
        #expect(snapshot.attention.map(\.target) == ["suggestions", "contracts", "contracts"])
        #expect(snapshot.attention.first?.title == "6 transactions without category")
        #expect(snapshot.attention.first?.actionTitle == "Categorize")
        #expect(snapshot.attention.last?.detail == "Cancel or switch by 30.11.")
    }
}
