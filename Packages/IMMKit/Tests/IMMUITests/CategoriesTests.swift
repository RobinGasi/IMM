import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct CategoriesTests {
    private let nbsp = "\u{00A0}"

    private func snapshot() throws -> CategoriesSnapshot {
        try DemoVaultFixture.shared().store.database.read(CategoriesQueries.snapshot)
    }

    // MARK: Comparison with the design

    @Test func desktopMatchesDesign() async throws {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .categories)
        let size = CGSize(width: 1440, height: 900)
        let value = try await assertMatchesDesign(
            MainWindowView().environment(model), slug: "app-5-categories-desktop", size: size, settle: 0.4,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        print("CATEGORIES app-5-categories-desktop mismatch \(value)")
    }

    /// Month and Quarter have no artboard: they render without a reference and are written next to the diffs for review.
    @Test(arguments: [CategoriesPeriod.month, .quarter]) func otherPeriodsRender(period: CategoriesPeriod) async throws {
        let snapshot = try snapshot()
        let size = CGSize(width: 1024, height: 720)
        let view = CategoriesLayout(snapshot: snapshot, period: .constant(period))
            .environment(\.immWindowWidth, size.width)
            .background(Color.white)
        let rep = try await ScreenRenderer.render(view, size: size, settle: 0.3)
        let image = try rep.requireCGImage()
        #expect(image.width == 1024 && image.height == 720)
        try FileManager.default.createDirectory(at: RepoPaths.diffOutput, withIntermediateDirectories: true)
        try DesignDiff.writePNG(image, to: RepoPaths.diffOutput.appendingPathComponent("categories-\(period)-1024.png"))
    }

    // MARK: Figures (equal to `imm-demo-report` `categories.*`)

    @Test func headerFigures() throws {
        let s = try snapshot()
        #expect(s.today == LocalDate(year: 2026, month: 11, day: 12))
        #expect(s.monthlyAverage == 248_000)
        #expect(CategoriesFormat.euros(s.monthlyAverage) == "2.480\(nbsp)€")
        #expect(CategoriesFormat.euros(s.salary, sign: .always) == "+3.840\(nbsp)€")
        let left = try #require(s.leftAfterAverage)
        #expect(CategoriesFormat.euros(left.amount) == "1.360\(nbsp)€")
        #expect(left.percent == 35)
        #expect(s.rulesCount == 34)
        let peak = try #require(s.mostExpensiveMonth)
        #expect(DateFormats.monthName(peak.start) == "March")
        #expect(CategoriesFormat.euros(peak.total) == "2.847\(nbsp)€")
        #expect(s.months.count == 12)
        #expect(s.months.map(\.label) == ["Dec", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov"])
        #expect(s.months.map(\.isPartial) == Array(repeating: false, count: 11) + [true])
    }

    @Test func categoriesAndMerchants() throws {
        let s = try snapshot()
        #expect(s.categories.map(\.name) == [
            "Housing", "Groceries", "Mobility", "Leisure & eating out", "Insurance & contracts", "Health & drugstore", "Other",
        ])
        #expect(s.categories.map(\.colorToken) == [
            "chart-1", "chart-5", "chart-3", "chart-2", "chart-4", "muted-foreground", "input",
        ])
        #expect(s.categories.allSatisfy { (1...3).contains($0.merchants.count) })
    }

    @Test func yearTable() throws {
        let table = try snapshot().table(for: .year)
        #expect(table.rows.map(\.amount) == [120_600, 31_845, 17_260, 17_665, 3_870, 0, 0])
        #expect(table.rows.map(\.average) == [120_600, 37_236, 15_545, 28_873, 11_642, 3_591, 30_513])
        #expect(table.rows.map(\.yearTotal) == [1_447_200, 441_445, 188_260, 335_265, 131_930, 39_500, 335_640])
        #expect(table.rows.map(\.sharePermille) == [486, 150, 63, 116, 47, 14, 123])
        #expect(table.rows.map { CategoriesFormat.share($0.sharePermille) } == [
            "48,6 %", "15,0 %", "6,3 %", "11,6 %", "4,7 %", "1,4 %", "12,3 %",
        ])
        #expect(table.amountTotal == 191_240)
        #expect(table.averageTotal == 248_000)
        #expect(table.rows.reduce(0) { $0 + $1.average } == table.averageTotal)
        #expect(table.yearTotal == 2_919_240)
        #expect(CategoriesFormat.euros(-table.amountTotal) == "−1.912\(nbsp)€")
        #expect(CategoriesFormat.euros(-table.yearTotal) == "−29.192\(nbsp)€")
        // Whole euros as drawn on the artboard.
        #expect(table.rows.map { CategoriesFormat.euros(-$0.average) } == [
            "−1.206\(nbsp)€", "−372\(nbsp)€", "−155\(nbsp)€", "−289\(nbsp)€", "−116\(nbsp)€", "−36\(nbsp)€", "−305\(nbsp)€",
        ])
        #expect(table.rows.map { CategoriesFormat.euros(-$0.yearTotal) } == [
            "−14.472\(nbsp)€", "−4.414\(nbsp)€", "−1.883\(nbsp)€", "−3.353\(nbsp)€", "−1.319\(nbsp)€", "−395\(nbsp)€", "−3.356\(nbsp)€",
        ])
        #expect(CategoriesFormat.euros(0) == "0\(nbsp)€")
    }

    @Test func monthTable() throws {
        let table = try snapshot().table(for: .month)
        #expect(table.amountTotal == 191_240)
        #expect(table.rows.map(\.sharePermille) == [631, 167, 90, 92, 20, 0, 0])
        #expect(table.rows.map { CategoriesFormat.share($0.sharePermille) }.first == "63,1 %")
    }

    @Test func quarterTable() throws {
        let s = try snapshot()
        #expect(s.quarterStart == LocalDate(year: 2026, month: 10, day: 1))
        let table = s.table(for: .quarter)
        #expect(table.rows.map(\.amount) == [241_200, 71_945, 44_060, 66_265, 15_170, 6_600, 24_000])
        #expect(table.amountTotal == 469_240)
        #expect(table.rows.map(\.sharePermille) == [514, 153, 94, 141, 32, 14, 51])
    }

    @Test func stackedSeries() throws {
        let s = try snapshot()
        let ids = Dictionary(uniqueKeysWithValues: s.categories.map { ($0.name, $0.id) })
        func cents(_ month: Int, _ name: String) -> Int { s.months[month].byCategory[ids[name]!] ?? 0 }
        // December.
        #expect(cents(0, "Housing") == 120_600)
        #expect(cents(0, "Groceries") == 44_000)
        #expect(cents(0, "Other") == 41_600)
        #expect(s.months[0].total == 268_500)
        // March, the most expensive month.
        #expect(s.months[3].total == 284_700)
        #expect(cents(3, "Other") == 89_900)
        // November so far.
        #expect(cents(11, "Groceries") == 31_845)
        #expect(cents(11, "Insurance & contracts") == 3_870)
        #expect(s.months[11].total == 191_240)
        #expect(s.months[11].end == s.today)
        // Every bar equals the spending definition for its month.
        let store = try DemoVaultFixture.shared().store
        let october = try store.database.read {
            try LedgerDefinitions.totalSpending($0, from: LocalDate(year: 2026, month: 10, day: 1), through: LocalDate(year: 2026, month: 10, day: 31))
        }
        #expect(s.months[10].total == october)
        #expect(october == 278_000)
    }

    @Test func columnWidths() {
        // 1440 pt window: table 1124.6 pt wide, 8 pt padding each side.
        let widths = CategoriesColumns.columnWidths(for: 1108.6)
        #expect(abs(widths[0] - 467.9) < 0.2)
        #expect(widths[1...3] == [96, 104, 96])
        #expect(abs(widths[4] - 280.7) < 0.2)
        // Narrow: the share column keeps its 140 pt minimum.
        let narrow = CategoriesColumns.columnWidths(for: 700)
        #expect(narrow[4] == 140)
        #expect(abs(narrow.reduce(0, +) + 64 - 700) < 0.001)
    }
}
