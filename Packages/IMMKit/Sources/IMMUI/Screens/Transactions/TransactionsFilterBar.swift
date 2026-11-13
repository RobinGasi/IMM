import IMMDesign
import IMMLedger
import SwiftUI

/// All / Income / Spending, the period select, the category select and the transaction count.
/// `compact` is the variant beside the inspector (small controls, no separator).
struct TransactionsFilterBar: View {
    @Bindable var model: TransactionsModel
    let compact: Bool
    let count: Int
    let categories: [TransactionCategory]
    let padding: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: compact ? 12 : 8) {
                ToggleGroup(selection: $model.filter.direction, options: Self.directionOptions, size: compact ? .sm : .default)
                if !compact {
                    VerticalRule()
                        .padding(.horizontal, 8)
                }
                SelectTrigger(
                    selection: $model.filter.period, options: Self.periodOptions, size: compact ? .sm : .default,
                    width: compact ? 150 : 140)
                SelectTrigger(
                    selection: $model.filter.category, options: categoryOptions, size: compact ? .sm : .default,
                    width: compact ? 150 : 160)
                Spacer(minLength: 8)
                Text(verbatim: TransactionText.count(count))
                    .immFont(IMMFont.small.tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, padding)
            // Controls are centred in the bar: 10 above and below the 28 px row; 12 around the 24 px row
            // beside the inspector (the bar is 48 px including its rule).
            .frame(height: compact ? 47 : 48)
            Rule()
        }
    }

    static var directionOptions: [IMMOption<TransactionDirection>] {
        [
            IMMOption(.all, Text("All", bundle: .module)),
            IMMOption(.income, Text("Income", bundle: .module)),
            IMMOption(.spending, Text("Spending", bundle: .module)),
        ]
    }

    static var periodOptions: [IMMOption<TransactionPeriod>] {
        [
            IMMOption(.last30Days, Text("Last 30 days", bundle: .module)),
            IMMOption(.last90Days, Text("Last 90 days", bundle: .module)),
            IMMOption(.thisMonth, Text("This month", bundle: .module)),
            IMMOption(.lastMonth, Text("Last month", bundle: .module)),
            IMMOption(.thisYear, Text("This year", bundle: .module)),
            IMMOption(.allTime, Text("All time", bundle: .module)),
        ]
    }

    private var categoryOptions: [IMMOption<TransactionCategoryFilter>] {
        var options = [IMMOption<TransactionCategoryFilter>(.all, Text("All categories", bundle: .module))]
        options += categories.map { IMMOption(.category($0.id), verbatim: $0.name) }
        options.append(IMMOption(.uncategorised, Text("Without category", bundle: .module)))
        return options
    }
}
