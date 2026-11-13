import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct SuggestionsTests {
    private let nbsp = "\u{00A0}"

    @Test func desktopMatchesDesign() async throws {
        let size = CGSize(width: 1440, height: 900)
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .suggestions)
        let value = try await assertMatchesDesign(
            MainWindowView().environment(model), slug: "app-11-suggestions-desktop", size: size, settle: 0.4,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        print("SUGGESTIONS app-11-suggestions-desktop mismatch \(value)")
    }

    @Test func snapshotCarriesTheDesignedRows() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(SuggestionsQueries.snapshot)

        #expect(snapshot.rows.count == 6)
        #expect(snapshot.sureCount == 3)
        #expect(snapshot.rows.map { DateFormats.dayMonth($0.date) } == ["10.11.", "08.11.", "07.11.", "06.11.", "04.11.", "03.11."])
        #expect(snapshot.rows.map(\.payee) == [
            "Amazon EU S.a.r.l.", "PayPal *Etsy", "Apotheke am Neumarkt", "SumUp *Kiosk Ehrenfeld",
            "Bargeldauszahlung Sparkasse", "Überweisung Jonas Weber",
        ])
        #expect(snapshot.rows.map { MoneyFormatter.string($0.amount, sign: .always) } == [
            "−34,99\(nbsp)€", "−22,50\(nbsp)€", "−12,80\(nbsp)€", "−6,40\(nbsp)€", "−100,00\(nbsp)€", "+45,00\(nbsp)€",
        ])
        #expect(snapshot.rows.map(\.suggestedCategory) == [
            "Other", "Other", "Health & drugstore", "Leisure & eating out", "Other", "Income",
        ])
        #expect(snapshot.rows.map(\.colorToken) == ["input", "input", "muted-foreground", "chart-2", "input", "credit"])
        #expect(snapshot.rows.map(\.confidenceLabel) == ["Sure", "Likely", "Sure", "Check this", "Sure", "Likely"])
        #expect(snapshot.rows.map(\.accountName) == ["Visa Card", "Wallet", "Visa Card", "Visa Card", "Visa Card", "Wallet"])
        #expect(snapshot.rows.map(\.sourceNumber) == [1, 2, nil, nil, nil, 3])
        #expect(snapshot.rows.map(\.preselected) == [true, false, true, false, true, false])

        // The six rows are exactly the ledger's uncategorised rows.
        let uncategorised = try store.database.read { try LedgerDefinitions.uncategorisedCount($0) }
        #expect(uncategorised == snapshot.rows.count)
    }

    @Test func snapshotCarriesNoticesAndSources() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(SuggestionsQueries.snapshot)

        #expect(snapshot.notices.map(\.variant) == [.doubleCharge, .newRule])
        #expect(snapshot.notices.map(\.text) == [
            "Possible double charge: Urban Sports Club −64,00\(nbsp)€ on 03.10. and 04.10.",
            "New rule: file every ‘SumUp *Kiosk’ payment under Leisure & eating out",
        ])
        #expect(snapshot.notices.map(\.actionTitle) == ["Compare payments", "Create rule"])
        let giro = try store.database.read { db in
            try #require(try AccountRecord.live().filter(Column("name") == "Girokonto").fetchOne(db)).id
        }
        #expect(snapshot.notices.first?.accountID == giro)

        #expect(snapshot.sources.map(\.number) == [1, 2, 3, 4, 4])
        #expect(snapshot.sources.map(\.dateText) == ["14.10.2026", "09.11.2025", "31.10.2026", "03.10.2026", "04.10.2026"])
        #expect(snapshot.sources.map(\.label) == [
            "Amazon EU S.a.r.l., latest of 12 filed under Other", "PayPal *Etsy, filed under Other",
            "Lieferando, order for two", "Urban Sports Club, monthly membership",
            "Urban Sports Club, same amount one day later",
        ])
        #expect(snapshot.sources.compactMap(\.amount).map { MoneyFormatter.string($0) } == [
            "−27,49\(nbsp)€", "−31,00\(nbsp)€", "−90,00\(nbsp)€", "−64,00\(nbsp)€", "−64,00\(nbsp)€",
        ])
    }

    @Test func rowOpensItsTransactionInItsAccount() throws {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .suggestions)
        let snapshot = try fixture.store.database.read(SuggestionsQueries.snapshot)
        let row = try #require(snapshot.rows.first)

        model.showTransaction(id: row.id, accountID: row.accountID)

        #expect(model.pendingTransactionSelection == row.id)
        if case .transactions(.account(let id)) = model.route {
            #expect(id == row.accountID)
        } else {
            Issue.record("route is \(model.route)")
        }
    }
}
