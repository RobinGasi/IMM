import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct StandingOrdersContractsTests {
    private let nbsp = "\u{00A0}"

    private func render(slug: String, route: MainRoute, size: CGSize = CGSize(width: 1440, height: 900)) async throws -> Double {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: route)
        let value = try await assertMatchesDesign(
            MainWindowView().environment(model), slug: slug, size: size, settle: 0.4,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        print("STANDINGORDERS-CONTRACTS \(slug) mismatch \(value)")
        return value
    }

    // MARK: Comparison with the design

    @Test func standingOrdersMatchesDesign() async throws {
        _ = try await render(slug: "app-7-standing-orders-desktop", route: .standingOrders)
    }

    @Test func contractsMatchesDesign() async throws {
        _ = try await render(slug: "app-8-contracts-desktop", route: .contracts)
    }

    // MARK: Figures

    @Test func standingOrdersCarryTheDemoFigures() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(StandingOrdersQueries.snapshot)

        #expect(snapshot.bankName == "Sparkasse KölnBonn")
        #expect(snapshot.primaryAccountName == "Girokonto")
        #expect(DateFormats.dayMonthYear(snapshot.horizon) == "12.12.2026")
        #expect(MoneyFormatter.string(snapshot.leaving) == "−2.390,01\(nbsp)€")
        #expect(snapshot.sections.count == 1)
        let section = try #require(snapshot.sections.first)
        #expect(section.orders.count == 6)
        #expect(section.activeCount == 4)
        #expect(MoneyFormatter.string(section.monthlyTotal) == "−1.960,00\(nbsp)€")
        #expect(section.orders.map(\.recipient) == [
            "ETF-Sparplan ING Depot", "Jonas Weber", "Tagesgeld Sparen", "Miete Wohnbau Ehrenfeld eG",
            "Mia Hoffmann", "Fitnessstudio Altvertrag",
        ])
        #expect(section.orders.map(\.status) == [.active, .scheduled, .active, .active, .active, .paused])
        #expect(section.orders.last?.nextExecution == nil)

        #expect(snapshot.timeline.map { DateFormats.dayMonth($0.date) } == ["15.11.", "20.11.", "28.11.", "01.12.", "03.12.", "05.12."])
        #expect(snapshot.timeline.map { MoneyFormatter.string($0.amount, symbol: false) } == [
            "−563,31", "−120,00", "−300,00", "−1.256,70", "−64,00", "−86,00",
        ])
        let salary = try #require(snapshot.salary)
        #expect(MoneyFormatter.string(salary.amount, sign: .always) == "+3.840,00\(nbsp)€")
        #expect(DateFormats.dayMonth(salary.date) == "27.11.")
    }

    @Test func contractsCarryTheDemoFigures() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(ContractsQueries.snapshot)

        #expect(snapshot.count == 8)
        #expect(MoneyFormatter.string(snapshot.monthlyTotal) == "−1.441,00\(nbsp)€")
        #expect(MoneyFormatter.string(snapshot.yearlyTotal) == "17.292,00\(nbsp)€")
        #expect(snapshot.salaryShare == 38)
        #expect(snapshot.groups.map(\.name) == ["Housing", "Insurance", "Communication & media", "Mobility & sport"])
        #expect(snapshot.groups.map { MoneyFormatter.string($0.subtotal) } == [
            "−1.224,36\(nbsp)€", "−38,70\(nbsp)€", "−55,94\(nbsp)€", "−122,00\(nbsp)€",
        ])
        let spotify = try #require(snapshot.priceNotices.first)
        #expect(spotify.provider == "Spotify")
        #expect(spotify.paidFrom == "PayPal Wallet")
        #expect(spotify.newAmount - spotify.oldAmount == 100)
        let huk = try #require(snapshot.deadlineNotices.first)
        #expect(huk.provider == "HUK-COBURG Kfz")
        #expect(huk.daysLeft == 18)
        #expect(DateFormats.dayMonthYear(try #require(huk.renewalDate)) == "01.01.2027")
        #expect(MoneyFormatter.string(huk.renewalAmount) == "464,40\(nbsp)€")
    }

    // MARK: Booked standing orders appear

    @Test func aBookedStandingOrderShowsUpInTheTimelineAndTable() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let store = fixture.store
        let giro = try await store.database.read { db in
            try #require(try AccountRecord.live().filter(Column("kind") == AccountKind.giro.rawValue).fetchOne(db)).id
        }
        let before = try await store.database.read(StandingOrdersQueries.snapshot)
        let first = before.today.adding(days: 10)
        try await store.database.write { db in
            try store.writer.insert(
                StandingOrderRecord(
                    accountId: giro, recipient: "Neue Dauer", iban: "DE89370400440532013000", purpose: "Test",
                    amount: -5000, rhythm: .monthly, dayOfMonth: first.day, nextExecution: first, status: .active),
                in: db)
        }
        let after = try await store.database.read(StandingOrdersQueries.snapshot)

        #expect(after.sections[0].orders.count == before.sections[0].orders.count + 1)
        #expect(after.sections[0].orders.contains { $0.recipient == "Neue Dauer" })
        #expect(after.leaving == before.leaving - 5000)
        #expect(after.timeline.contains { $0.date == first && $0.items.contains("Neue Dauer") })
        #expect(after.sections[0].monthlyTotal == before.sections[0].monthlyTotal - 5000)
    }

    @Test func ordinalsAndIBANGroups() {
        #expect(soOrdinal(1) == "1st")
        #expect(soOrdinal(2) == "2nd")
        #expect(soOrdinal(3) == "3rd")
        #expect(soOrdinal(11) == "11th")
        #expect(soOrdinal(15) == "15th")
        #expect(soOrdinal(28) == "28th")
        #expect(soFormattedIBAN("DE13500105175419283746") == "DE13 5001 0517 5419 2837 46")
    }
}
