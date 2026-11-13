import IMMDesign
import IMMLedger
import SwiftUI

/// The right column: the savings plan and the allocation by region, behind a 1 px left rule.
///
/// The two sections are `flex: 1 1 240px` with a 40 pt column gap and a 28 pt row gap: side by side
/// when the column is wide enough, stacked otherwise.
struct DepotAside: View {
    let snapshot: DepotSnapshot

    var body: some View {
        FlexWrapLayout(columnSpacing: 40, rowSpacing: 28) {
            if let plan = snapshot.savingsPlan {
                DepotSavingsPlanSection(plan: plan)
                    .flexItem(basis: 240, grow: 1)
            }
            DepotAllocationSection(snapshot: snapshot)
                .flexItem(basis: 240, grow: 1)
        }
        .padding(.leading, 33)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            Rectangle().fill(IMMColor.border).frame(width: 1)
        }
    }
}

struct DepotSavingsPlanSection: View {
    let plan: DepotSavingsPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Savings plan", bundle: .module)
                    .immFont(.titleMD)
                    .foregroundStyle(IMMColor.foreground)
                Text(
                    "\(MoneyFormatter.string(plan.amount)) monthly on the \(DepotText.ordinal(plan.dayOfMonth))",
                    bundle: .module
                )
                .immFont(IMMFont.body.tabular)
                .foregroundStyle(IMMColor.foreground)
            }
            VStack(spacing: 0) {
                ForEach(plan.items) { item in
                    HStack(spacing: 8) {
                        Text(verbatim: item.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: DepotText.wholePercent(item.amount, plan.amount))
                            .foregroundStyle(IMMColor.mutedForeground)
                            .frame(width: 40, alignment: .trailing)
                        Text(verbatim: MoneyFormatter.string(item.amount))
                            .frame(width: 72, alignment: .trailing)
                    }
                    .immFont(IMMFont.body.tabular)
                    .foregroundStyle(IMMColor.foreground)
                    .frame(height: 28)
                    .overlay(alignment: .bottom) { Rule() }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if let next = plan.nextExecution {
                    (Text("Next execution ", bundle: .module)
                        + Text(verbatim: DateFormats.dayMonthYear(next)).foregroundStyle(IMMColor.foreground))
                        .lineLimit(1)
                }
                if !plan.sourceAccount.isEmpty {
                    Text("Debited from \(plan.sourceAccount)", bundle: .module)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .immFont(IMMFont.small.tabular)
            .foregroundStyle(IMMColor.mutedForeground)
            Button {
            } label: {
                Text("Edit savings plan", bundle: .module)
            }
            .immButtonStyle(.outline)
            .inertControl(String(localized: "Not available in this version", bundle: .module))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DepotAllocationSection: View {
    let snapshot: DepotSnapshot

    private var slices: [(name: String, color: Color, value: Int)] {
        var result = snapshot.regions.map { (name: $0.name, color: IMMColor.named($0.colorToken), value: $0.value) }
        if snapshot.hasCash {
            result.append((name: String(localized: "Cash", bundle: .module), color: IMMColor.mutedForeground, value: snapshot.cash))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allocation by region", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
            bar
            VStack(spacing: 4) {
                ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                    HStack(spacing: 8) {
                        LegendDot(slice.color)
                        Text(verbatim: slice.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: DepotText.percent(slice.value, snapshot.value))
                            .immFont(IMMFont.small.tabular)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .immFont(.small)
                    .foregroundStyle(IMMColor.foreground)
                }
            }
            Text("Estimated from each fund's country weights", bundle: .module)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
        }
    }

    /// 8 pt high, 2 pt between the slices; the last slice (cash) takes the rest.
    private var bar: some View {
        let slices = slices
        return GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(Array(slices.dropLast().enumerated()), id: \.offset) { _, slice in
                    Rectangle().fill(slice.color)
                        .frame(width: proxy.size.width * CGFloat(slice.value) / CGFloat(max(1, snapshot.value)))
                }
                if let last = slices.last {
                    Rectangle().fill(last.color)
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: IMMRadius.sm, style: .continuous))
        .immGrowX(duration: 0.5)
        .accessibilityHidden(true)
    }
}
