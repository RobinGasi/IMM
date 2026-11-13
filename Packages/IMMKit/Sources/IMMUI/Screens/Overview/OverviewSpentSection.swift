import IMMDesign
import IMMLedger
import SwiftUI

/// "Spent in <month>": a share bar per category (relative to the largest), the total and the
/// comparison with the monthly average.
struct OverviewSpentSection: View {
    let snapshot: OverviewSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                Text("Spent in \(DateFormats.monthName(snapshot.today))", bundle: .module),
                detail: Text(verbatim: range))
            VStack(spacing: 14) {
                ForEach(Array(snapshot.spending.enumerated()), id: \.element.id) { index, category in
                    row(category, index: index)
                }
            }
            .padding(.top, 16)
            TotalRow(Text("Spent so far", bundle: .module), amount: MoneyFormatter.string(-snapshot.spentTotal))
                .padding(.top, 16)
            if let footnote {
                Text(verbatim: footnote)
                    .immFont(IMMFont.small.tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .padding(.top, 8)
            }
        }
    }

    /// `1.–12.11.`
    private var range: String {
        let first = snapshot.spentFrom
        let today = snapshot.today
        return "\(first.day).\u{2013}" + DateFormats.dayMonth(today)
    }

    private var footnote: String? {
        guard let percent = snapshot.averagePercent else { return nil }
        let average = MoneyFormatter.string(snapshot.monthlyAverage)
        let days = snapshot.daysToGo
        if days == 1 {
            return String(localized: "\(percent) % of your monthly average of \(average), with 1 day to go", bundle: .module)
        }
        return String(localized: "\(percent) % of your monthly average of \(average), with \(days) days to go", bundle: .module)
    }

    private func row(_ category: OverviewSpending, index: Int) -> some View {
        let color = IMMColor.named(category.colorToken)
        let largest = snapshot.spending.map(\.amount).max() ?? 1
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                LegendDot(color)
                Text(verbatim: category.name)
                    .immFont(.body)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                OverviewAmount(text: MoneyFormatter.string(-category.amount))
            }
            ShareBar(
                fraction: Double(category.amount) / Double(max(largest, 1)), color: color,
                growDelay: 0.2 + 0.04 * Double(index), growDuration: 0.4)
                .padding(.leading, 16)
        }
    }
}
