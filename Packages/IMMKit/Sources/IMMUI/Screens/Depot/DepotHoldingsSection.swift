import IMMDesign
import IMMLedger
import SwiftUI

/// "Holdings": header, one 48 pt row per fund and for the cash account, and the closing total.
struct DepotHoldingsSection: View {
    let snapshot: DepotSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Holdings", bundle: .module)
                    .immFont(.titleMD)
                    .foregroundStyle(IMMColor.foreground)
                Spacer(minLength: 12)
                Text(subtitle)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            VStack(spacing: 0) {
                header
                ForEach(Array(snapshot.holdings.enumerated()), id: \.element.id) { index, holding in
                    row(holding, index: index, isLast: index == snapshot.holdings.count - 1)
                }
                totalRow
            }
        }
    }

    private var subtitle: LocalizedStringKey {
        snapshot.hasCash
            ? "\(snapshot.fundCount) funds and the cash account"
            : "\(snapshot.fundCount) funds"
    }

    // MARK: Rows

    private static let body = IMMFont.body.tabular
    private static let bodyStrong = IMMFont.body.tabular.weighted(.semibold)

    private func trailing(_ text: Text, style: IMMFont = DepotHoldingsSection.body, color: Color = IMMColor.foreground, column: Int) -> some View {
        text
            .immFont(style)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .depotColumn(column)
    }

    private var header: some View {
        DepotTableRowLayout {
            Text("Name", bundle: .module)
                .immFont(.captionSemibold).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).depotColumn(0)
            trailing(Text("Quantity", bundle: .module), style: .captionSemibold, color: IMMColor.mutedForeground, column: 1)
            trailing(Text("Price", bundle: .module), style: .captionSemibold, color: IMMColor.mutedForeground, column: 2)
            trailing(Text("Value", bundle: .module), style: .captionSemibold, color: IMMColor.mutedForeground, column: 3)
            trailing(Text("Gain/loss", bundle: .module), style: .captionSemibold, color: IMMColor.mutedForeground, column: 4)
            Text("Weight", bundle: .module)
                .immFont(.captionSemibold).lineLimit(1)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading).depotColumn(5)
        }
        .foregroundStyle(IMMColor.mutedForeground)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rule() }
    }

    private func row(_ holding: DepotHolding, index: Int, isLast: Bool) -> some View {
        let dash = Text(verbatim: "\u{2013}")
        let muted = IMMColor.mutedForeground
        return DataRow(height: 48, bleed: 0) {
            DepotTableRowLayout {
                nameCell(holding).depotColumn(0)
                if holding.isCash {
                    trailing(dash, color: muted, column: 1)
                    trailing(dash, color: muted, column: 2)
                } else {
                    trailing(Text(verbatim: DepotText.quantity(holding.quantityMicro)), column: 1)
                    trailing(Text(verbatim: MoneyFormatter.string(holding.price)), column: 2)
                }
                trailing(Text(verbatim: MoneyFormatter.string(holding.value)), style: Self.bodyStrong, column: 3)
                if let gain = holding.gain {
                    trailing(
                        Text(verbatim: DepotText.percent(gain, holding.costBasis, signed: true)),
                        color: DepotText.color(gain), column: 4)
                } else {
                    trailing(dash, color: muted, column: 4)
                }
                DepotWeightCell(
                    value: holding.value, total: snapshot.value, isCash: holding.isCash, delay: Double(index) * 0.04)
                    .depotColumn(5)
            }
        }
        .overlay(alignment: .bottom) { if !(isLast && holding.isCash) { Rule() } }
    }

    private func nameCell(_ holding: DepotHolding) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if holding.isCash {
                    Text("Cash account", bundle: .module)
                } else {
                    Text(verbatim: holding.name)
                }
            }
            .immFont(.body)
            .foregroundStyle(IMMColor.foreground)
            .lineLimit(1)
            .truncationMode(.tail)
            if holding.isCash {
                Text(verbatim: holding.name)
                    .immFont(.caption)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let isin = holding.isin {
                Text(verbatim: isin)
                    .immFont(.monoSmall)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalRow: some View {
        let strong = Self.bodyStrong
        return DepotTableRowLayout {
            Text("Total depot value, \(DateFormats.dayMonthYear(snapshot.today))", bundle: .module)
                .immFont(strong)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .depotColumn(0, span: 3)
            trailing(Text(verbatim: MoneyFormatter.string(snapshot.value)), style: strong, column: 3)
            trailing(
                Text(verbatim: DepotText.percent(snapshot.gain, snapshot.costBasis, signed: true)),
                style: strong, color: DepotText.color(snapshot.gain), column: 4)
            Text(verbatim: "100 %")
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .depotColumn(5)
        }
        .foregroundStyle(IMMColor.foreground)
        .frame(height: 44)
        .overlay(alignment: .top) { Rule() }
        .overlay(alignment: .bottom) { DoubleRule() }
    }
}

/// The Weight column: a 4 pt bar (`border` track, filled from the left) and the share in 12 pt.
private struct DepotWeightCell: View {
    let value: Int
    let total: Int
    let isCash: Bool
    let delay: Double

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(IMMColor.border)
                    Rectangle()
                        .fill(isCash ? IMMColor.mutedForeground : IMMColor.primary)
                        .frame(width: proxy.size.width * CGFloat(value) / CGFloat(max(1, total)))
                        .immGrowX(duration: 0.4, delay: delay)
                }
            }
            .frame(height: 4)
            .clipShape(RoundedRectangle(cornerRadius: IMMRadius.sm, style: .continuous))
            Text(verbatim: DepotText.percent(value, total))
                .immFont(IMMFont.small.tabular)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.leading, 16)
    }
}
