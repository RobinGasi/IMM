import Foundation
import IMMLedger
import Observation

/// Which period the table and the hero figure summarise. The chart always shows the 12 months.
enum CategoriesPeriod: Hashable, Sendable {
    case month, quarter, year
}

/// Holds the Categories figures and follows the open ledger with a `ValueObservation`.
@MainActor @Observable
final class CategoriesModel {
    private(set) var snapshot: CategoriesSnapshot?

    /// Reads once, then re-reads whenever a table behind the snapshot changes. Returns when the
    /// surrounding task is cancelled or the database is closed (a lock).
    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(CategoriesQueries.snapshot) { snapshot = initial }
        do {
            for try await value in CategoriesQueries.observe(in: ledger) {
                snapshot = value
            }
        } catch {
            // Locked or closed: keep the last values; the shell leaves this screen.
        }
    }
}

/// One table row of one period. Amounts are positive minor units.
struct CategoriesRow: Identifiable, Hashable {
    var id: String
    var name: String
    var colorToken: String
    var merchants: String
    /// Spending in the running month, the quarter so far or the 12 months' average, by period (first numeric column).
    var amount: Int
    /// Mean monthly spending of the complete months.
    var average: Int
    /// Spending over the 12 months, the running month included.
    var yearTotal: Int
    /// Share of the period's base in permille (486 = 48,6 %).
    var sharePermille: Int
}

struct CategoriesTableData: Hashable {
    var rows: [CategoriesRow]
    var amountTotal: Int
    var averageTotal: Int
    var yearTotal: Int
}

extension CategoriesSnapshot {
    /// The table for one period.
    ///
    /// - Year: columns "This month", "Monthly average", "Year total"; share of the monthly average.
    /// - Month: the same columns; share of this month's spending.
    /// - Quarter: "This quarter" in the first column; share of the quarter's spending.
    func table(for period: CategoriesPeriod) -> CategoriesTableData {
        let amount: (CategoriesCategory) -> Int
        let base: (CategoriesCategory) -> Int
        let baseTotal: Int
        let amountTotal: Int
        switch period {
        case .year:
            amount = { thisMonth(of: $0.id) }
            base = { average(of: $0.id) }
            baseTotal = monthlyAverage
            amountTotal = thisMonthTotal
        case .month:
            amount = { thisMonth(of: $0.id) }
            base = amount
            baseTotal = thisMonthTotal
            amountTotal = thisMonthTotal
        case .quarter:
            amount = { thisQuarter(of: $0.id) }
            base = amount
            baseTotal = thisQuarterTotal
            amountTotal = thisQuarterTotal
        }
        let rows = categories.map { category in
            CategoriesRow(
                id: category.id, name: category.name, colorToken: category.colorToken,
                merchants: category.merchants.joined(separator: ", "), amount: amount(category),
                average: average(of: category.id), yearTotal: yearTotal(of: category.id),
                sharePermille: CategoriesFormat.permille(base(category), of: baseTotal))
        }
        return CategoriesTableData(rows: rows, amountTotal: amountTotal, averageTotal: monthlyAverage, yearTotal: yearTotal)
    }
}

enum CategoriesFormat {
    /// Whole euros, rounded half away from zero, as the design prints them: `−1.206 €`, `0 €`.
    /// Pass spending as a negative number.
    static func euros(_ minorUnits: Int, sign: MoneySign = .negativeOnly) -> String {
        let whole = (minorUnits.magnitude + 50) / 100
        let signed = minorUnits < 0 ? -Int(whole) : Int(whole)
        let text = MoneyFormatter.string(signed * 100, sign: sign == .always ? .always : .negativeOnly)
        // "…,00 €" → "… €"
        let parts = text.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { return text }
        return String(parts[0]) + "\u{00A0}€"
    }

    enum MoneySign { case negativeOnly, always }

    /// `value / total` in permille, rounded half away from zero; 0 without a total.
    static func permille(_ value: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return (value * 2000 + total) / (2 * total)
    }

    /// `48,6 %`
    static func share(_ permille: Int) -> String {
        "\(permille / 10),\(permille % 10) %"
    }
}
