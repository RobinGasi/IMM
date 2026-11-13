import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct ReviewTaxTests {
    private let nbsp = "\u{00A0}"

    private func render(slug: String, size: CGSize, route: MainRoute, appearance: NSAppearance.Name = .aqua) async throws -> Double {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: route)
        let value = try await assertMatchesDesign(
            MainWindowView().environment(model), slug: slug, size: size, appearance: appearance, settle: 0.4,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        print("REVIEWTAX \(slug) mismatch \(value)")
        return value
    }

    // MARK: Comparison with the design

    @Test func octoberReviewMatchesDesign() async throws {
        _ = try await render(slug: "app-12-october-review-desktop", size: CGSize(width: 1440, height: 900), route: .monthReview)
    }

    @Test func taxReturnMatchesDesign() async throws {
        _ = try await render(slug: "app-14-tax-return-desktop", size: CGSize(width: 1440, height: 900), route: .taxReturn)
    }

    // MARK: Figures

    private func euro(_ minor: Int, sign: MoneyFormatter.Sign = .negativeOnly) -> String {
        MoneyFormatter.string(minor, sign: sign)
    }

    @Test func reviewFiguresComeFromTheLedger() throws {
        let store = try DemoVaultFixture.shared().store
        let review = try #require(try store.database.read(ReviewQueries.snapshot))

        #expect(DateFormats.monthName(review.month) == "October")
        #expect(DateFormats.dayMonthYear(review.closedOn) == "31.10.2026")
        #expect(euro(review.income, sign: .always) == "+3.840,00\(nbsp)€")
        #expect(euro(-review.spending) == "−2.780,00\(nbsp)€")
        #expect(euro(review.saved) == "1.060,00\(nbsp)€")
        #expect(euro(review.incomeAverage, sign: .always) == "+3.850,29\(nbsp)€")
        #expect(euro(-review.spendingAverage) == "−2.398,74\(nbsp)€")
        #expect(euro(review.savedAverage) == "1.451,55\(nbsp)€")
        #expect(review.headline.hasPrefix("October closed with 1.060,00\(nbsp)€ saved"))

        // Findings: stored sentences, category colours and deltas worked out from the ledger.
        #expect(review.findings.map(\.number) == [1, 2, 3])
        #expect(review.findings.map(\.colorToken) == ["chart-2", "chart-3", "chart-5"])
        #expect(review.findings.map(\.deltaText) == ["+201\(nbsp)€", "+138\(nbsp)€", "+26\(nbsp)€"])
        #expect(review.findings.map { $0.monthAmount / 100 } == [486, 268, 401])
        #expect(review.findings.map { $0.averageAmount / 100 } == [285, 130, 375])
        #expect(review.barScale == 50_000)
        #expect(review.findings.first?.title == "Eating out: 486\(nbsp)€ vs 285\(nbsp)€ average")

        // Sources: amounts are the sums of the cited rows.
        #expect(review.sources.map { euro($0.amount) } == [
            "−171,60\(nbsp)€", "−57,72\(nbsp)€", "−199,80\(nbsp)€", "−401,00\(nbsp)€",
        ])
        #expect(review.sources.allSatisfy { !$0.transactions.isEmpty })
        #expect(review.sources.map(\.label).first == "Lieferando, 6 orders")

        // Outlook and steps.
        #expect(euro(review.outlook.todayBalance) == "2.418,36\(nbsp)€")
        #expect(review.outlook.accountName == "Girokonto")
        #expect(DateFormats.dayMonth(review.outlook.startDate) == "12.11.")
        #expect(DateFormats.dayMonth(review.outlook.endDate) == "30.11.")
        #expect(review.outlook.points.count == 19)
        #expect(review.outlook.points.first?.expected == review.outlook.todayBalance)
        #expect(review.outlook.rangeText == "Likely 4.300–4.600 € on 30.11.")
        #expect(review.outlook.lowestText == "Lowest 1.011\(nbsp)€ on 26.11.")
        #expect(review.steps.count == 2)
        #expect(review.steps.map(\.actionTitle) == ["Prepare transfer", "Set reminder"])
        let transfer = try #require(review.steps.first?.transfer)
        #expect(transfer.amount == 100_000)
        #expect(transfer.recipient == "Tagesgeld")
        #expect(IBAN.isValid(transfer.iban))
        #expect(review.steps.last?.transfer == nil)
    }

    @Test func reviewDeltasEqualTheStoredText() throws {
        let store = try DemoVaultFixture.shared().store
        let review = try #require(try store.database.read(ReviewQueries.snapshot))
        let stored = try store.database.read { db -> [String] in
            let insight = try #require(try InsightRecord.live().filter(Column("kind") == InsightKind.review.rawValue).fetchOne(db))
            let payload = try #require(JSONSerialization.jsonObject(with: Data(insight.payload.utf8)) as? [String: Any])
            return (payload["findings"] as? [[String: Any]] ?? []).compactMap { $0["deltaText"] as? String }
        }
        #expect(review.findings.map(\.deltaText) == stored)
    }

    @Test func taxFiguresComeFromTheLedger() throws {
        let store = try DemoVaultFixture.shared().store
        let tax = try #require(try store.database.read(TaxQueries.snapshot))

        #expect(tax.year == 2026)
        #expect(euro(tax.total) == "2.607,62\(nbsp)€")
        #expect(tax.itemCount == 8)
        #expect(tax.formCount == 4)
        #expect(tax.needsReceiptCount == 3)
        #expect(tax.withReceiptCount == 4)
        #expect(tax.accountNames == ["Girokonto", "Visa Card"])
        #expect(tax.groups.map(\.form) == [
            "Anlage N — Werbungskosten", "Haushaltsnahe Dienstleistungen (§ 35a)", "Sonderausgaben — Spenden",
            "Vorsorgeaufwendungen",
        ])
        #expect(tax.groups.map { euro($0.total) } == [
            "1.384,32\(nbsp)€", "640,00\(nbsp)€", "120,00\(nbsp)€", "463,30\(nbsp)€",
        ])
        #expect(tax.groups.map(\.rows.count) == [3, 1, 2, 2])
        #expect(tax.rows.map { euro($0.amount) } == [
            "−899,00\(nbsp)€", "−244,00\(nbsp)€", "−241,32\(nbsp)€", "−640,00\(nbsp)€", "−60,00\(nbsp)€",
            "−60,00\(nbsp)€", "−425,70\(nbsp)€", "−37,60\(nbsp)€",
        ])
        #expect(tax.rows.map { DateFormats.dayMonth($0.date) } == [
            "14.03.", "02.01.", "21.09.", "18.06.", "20.04.", "10.10.", "01.01.", "02.01.",
        ])
        #expect(tax.rows.allSatisfy { $0.firstTransaction != nil })
        #expect(tax.rows[1].why == "Mostly business trips [1]")
        #expect(tax.footnotes.first?.hasPrefix("[1] 4 of 7 Deutsche Bahn tickets") == true)
        #expect(tax.footnotes.count == 2)
    }

    @Test func taxRowsOpenTheirPaymentInTheTransactionsInspector() throws {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        let tax = try #require(try fixture.store.database.read(TaxQueries.snapshot))
        let row = try #require(tax.rows.first { $0.payee == "Apple Store" })
        let cited = try #require(row.firstTransaction)
        #expect(cited.accountName == "Visa Card" || cited.accountName == "Girokonto")

        model.showTransaction(id: cited.id, accountID: cited.accountID)

        #expect(model.pendingTransactionSelection == cited.id)
        if case .transactions(.account(let id)) = model.route {
            #expect(id == cited.accountID)
        } else {
            Issue.record("Route is not the cited account's transactions: \(model.route)")
        }
    }
}
