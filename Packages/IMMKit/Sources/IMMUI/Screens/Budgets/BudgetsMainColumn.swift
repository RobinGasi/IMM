import IMMDesign
import IMMLedger
import SwiftUI

/// The hero (left to spend, overall bar, legend) and the table of budgets.
struct BudgetsMainColumn: View {
    let snapshot: BudgetsSnapshot

    @Environment(\.immWindowWidth) private var windowWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
                .padding(.bottom, 28)
            table
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Hero

    private var hero: some View {
        let size = IMMLayout.heroFontSize(windowWidth: windowWidth)
        let left = snapshot.leftToSpend
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 24) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(verbatim: MoneyFormatter.string(abs(left)))
                        .immFont(IMMFont.amountHero.sized(size, lineHeight: size * 1.2))
                        .foregroundStyle(left < 0 ? IMMColor.destructive : IMMColor.foreground)
                        .lineLimit(1)
                    Text(left < 0 ? "over budget this month" : "left to spend this month", bundle: .module)
                        .immFont(IMMFont.bodyLG.withLineHeight(22))
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                }
                .frame(height: size * 1.2)
                .layoutPriority(1)
                Spacer(minLength: 0)
                Button {
                } label: {
                    HStack(spacing: 4) {
                        IMMIcon("plus", size: IMMButtonStyle.Size.default.iconSize)
                        Text("New budget", bundle: .module)
                    }
                }
                .immButtonStyle(.default, leadingIcon: true)
                .inertControl()
            }
            BudgetsPaceBar(
                value: snapshot.totalFraction, pace: snapshot.paceFraction,
                tint: snapshot.totalSpent > snapshot.totalLimit ? IMMColor.destructive : IMMColor.primary,
                growDuration: 0.6, growDelay: 0)
            HStack(alignment: .top, spacing: 16) {
                Text(
                    "Spent \(MoneyFormatter.string(snapshot.totalSpent)) of \(MoneyFormatter.string(snapshot.totalLimit))",
                    bundle: .module)
                Spacer(minLength: 0)
                Text(
                    "Marker shows expected spending by today, day \(snapshot.dayOfMonth) of \(snapshot.daysInMonth)",
                    bundle: .module)
            }
            .immFont(IMMFont.small.tabular)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .frame(height: 16)
        }
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                BudgetsRowView(row: row, pace: snapshot.paceFraction, index: index)
            }
            total
        }
    }

    private var header: some View {
        BudgetsColumnsLayout {
            Text("Category", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
            Text("Spent this month", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
            Text("Spent / limit", bundle: .module).frame(maxWidth: .infinity, alignment: .trailing)
            Text("Remaining", bundle: .module).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .immFont(.captionSemibold)
        .foregroundStyle(IMMColor.mutedForeground)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rule() }
    }

    private var total: some View {
        let overText: Text = switch snapshot.overCount {
        case 0: Text("No budget over its limit", bundle: .module)
        case 1: Text("1 of \(snapshot.rows.count) budgets over its limit", bundle: .module)
        default: Text("\(snapshot.overCount) of \(snapshot.rows.count) budgets over their limit", bundle: .module)
        }
        return BudgetsColumnsLayout {
            Text("Total \(DateFormats.monthName(snapshot.today))", bundle: .module)
                .immFont(.bodySemibold)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            overText
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            (Text(verbatim: MoneyFormatter.string(snapshot.totalSpent, symbol: false) + " ")
                .font(IMMFont.bodySemibold.tabular.font)
                + Text(verbatim: "/ " + MoneyFormatter.string(snapshot.totalLimit, symbol: false))
                .font(IMMFont.body.tabular.font)
                .foregroundColor(IMMColor.mutedForeground))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: MoneyFormatter.string(snapshot.leftToSpend))
                .immFont(IMMFont.bodySemibold.tabular)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(IMMColor.foreground)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 44)
        .overlay(alignment: .top) { Rule() }
        .overlay(alignment: .bottom) { DoubleRule() }
    }
}

/// One budget: category with its colour, pace bar, `spent / limit` and what remains.
struct BudgetsRowView: View {
    let row: BudgetRow
    let pace: Double
    let index: Int

    var body: some View {
        DataRow(height: 44, bleed: 0) {
            BudgetsColumnsLayout {
                HStack(spacing: 8) {
                    LegendDot(IMMColor.named(row.colorToken))
                    Text(verbatim: row.categoryName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                BudgetsPaceBar(
                    value: row.fraction, pace: pace, tint: row.isOver ? IMMColor.destructive : IMMColor.primary,
                    growDuration: 0.45, growDelay: 0.15 + 0.04 * Double(index))
                Text(verbatim: "\(MoneyFormatter.string(row.spent, symbol: false)) / \(MoneyFormatter.string(row.limit, symbol: false))")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                remaining
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .immFont(IMMFont.body.tabular)
            .padding(.horizontal, 8)
        }
        .overlay(alignment: .bottom) { Rule() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var remaining: some View {
        if row.isOver {
            Text("Over by \(MoneyFormatter.string(-row.remaining))", bundle: .module)
                .immFont(IMMFont.bodyMedium.tabular)
                .foregroundStyle(IMMColor.destructive)
                .immFadeIn(duration: 0.2, delay: 0.5)
        } else {
            Text(verbatim: MoneyFormatter.string(row.remaining))
        }
    }
}

/// A 4 px `Progress` in a 14 px row with the pace marker: a 2 × 14 tick at `pace` of the width.
struct BudgetsPaceBar: View {
    let value: Double
    let pace: Double
    var tint: Color = IMMColor.primary
    var growDuration: Double
    var growDelay: Double

    var body: some View {
        ProgressBar(value: value, tint: tint, growDelay: growDelay, growDuration: growDuration)
            .frame(height: 14)
            .overlay {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(IMMColor.mutedForeground)
                        .frame(width: 2, height: 14)
                        .offset(x: proxy.size.width * pace)
                }
            }
            .frame(height: 14)
    }
}
