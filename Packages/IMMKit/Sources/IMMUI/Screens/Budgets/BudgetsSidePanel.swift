import IMMDesign
import IMMLedger
import SwiftUI

/// "Fixed costs" and the roll-over setting.
struct BudgetsSidePanel: View {
    let snapshot: BudgetsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            fixedCosts
            rollover
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var fixedCosts: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fixed costs", bundle: .module)
                    .immFont(IMMFont.titleMD.withLineHeight(22))
                Text("Rent, electricity and contracts leave by standing order, so they stay outside your budgets.", bundle: .module)
                    .immFont(IMMFont.small.withLineHeight(17))
                    .foregroundStyle(IMMColor.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(snapshot.fixedCosts) { cost in
                    HStack(spacing: 8) {
                        LegendDot(IMMColor.named(cost.colorToken))
                        Text(verbatim: cost.label)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: MoneyFormatter.string(cost.amount, symbol: false))
                            .immFont(IMMFont.body.tabular)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .frame(height: 32)
                    .help(Text(verbatim: members(of: cost)))
                }
                HStack(spacing: 8) {
                    Text("Excluded this month", bundle: .module)
                        .padding(.leading, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: MoneyFormatter.string(snapshot.fixedCostsTotal))
                        .immFont(IMMFont.bodySemibold.tabular)
                        .frame(width: 96, alignment: .trailing)
                }
                .immFont(.bodySemibold)
                .frame(height: 36)
                .overlay(alignment: .top) { Rule() }
                .overlay(alignment: .bottom) { DoubleRule() }
            }
            .immFont(.body)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// Tooltip of a grouped fixed cost: its parts, one per line.
    private func members(of cost: FixedCostRow) -> String {
        cost.members.map { "\($0.label)  \(MoneyFormatter.string($0.amount))" }.joined(separator: "\n")
    }

    private var rollover: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Roll over unused amounts", bundle: .module)
                    .immFont(.bodyMedium)
                Group {
                    if snapshot.rolloverEnabled {
                        Text(
                            "What is left in each budget on \(DateFormats.dayMonth(snapshot.monthEnd)) is added to its \(DateFormats.monthName(snapshot.nextMonth)) limit.",
                            bundle: .module)
                    } else {
                        Text(
                            "What is left in each budget on \(DateFormats.dayMonth(snapshot.monthEnd)) is not carried over to \(DateFormats.monthName(snapshot.nextMonth)).",
                            bundle: .module)
                    }
                }
                .immFont(IMMFont.small.withLineHeight(17))
                .foregroundStyle(IMMColor.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Shown, not editable.
            IMMSwitch(isOn: .constant(snapshot.rolloverEnabled))
                .inertControl()
                .padding(.top, 2)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}
