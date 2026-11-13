import IMMDesign
import IMMLedger
import SwiftUI

/// Value hero with the gain line, then "Performance" with the range tabs and the chart.
struct DepotPerformanceSection: View {
    let snapshot: DepotSnapshot

    @Environment(\.immWindowWidth) private var windowWidth
    @State private var range: DepotRange = .oneYear

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            valueBlock
            performance
        }
    }

    // MARK: Value

    private var valueBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Depot value", bundle: .module)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
            Text(verbatim: MoneyFormatter.string(snapshot.value))
                .immFont(IMMFont.amountHero.sized(IMMLayout.heroFontSize(windowWidth: windowWidth)))
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .fixedSize()
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                sinceText(
                    value: "\(MoneyFormatter.string(snapshot.gain, sign: .always)) (\(DepotText.percent(snapshot.gain, snapshot.costBasis, signed: true)))",
                    color: DepotText.color(snapshot.gain),
                    caption: String(localized: "since purchase", bundle: .module))
                if let yesterday = snapshot.valueYesterday, yesterday > 0 {
                    let change = snapshot.value - yesterday
                    sinceText(
                        value: DepotText.percent(change, yesterday, signed: true),
                        color: DepotText.color(change),
                        caption: String(localized: "today", bundle: .module))
                }
                Text(
                    "Cost basis \(MoneyFormatter.string(snapshot.costBasis))", bundle: .module)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            .immFont(IMMFont.body.tabular)
            .lineLimit(1)
        }
    }

    private func sinceText(value: String, color: Color, caption: String) -> some View {
        (Text(verbatim: value).font(IMMFont.bodySemibold.tabular.font).foregroundStyle(color)
            + Text(verbatim: " " + caption).foregroundStyle(IMMColor.mutedForeground))
    }

    // MARK: Performance

    private var rangePoints: [DepotPoint] { snapshot.points(in: range) }

    private var performance: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Performance", bundle: .module)
                        .immFont(.titleMD)
                        .foregroundStyle(IMMColor.foreground)
                    performanceCaption
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SegmentedTabs(
                    selection: $range,
                    options: DepotRange.allCases.map { IMMOption($0, verbatim: $0.rawValue) })
            }
            if let chart = DepotChartModel(points: rangePoints, range: range) {
                DepotChart(model: chart)
                    .id(range)
            } else {
                Color.clear.frame(height: DepotChartModel.boxHeight + 22)
            }
        }
    }

    @ViewBuilder
    private var performanceCaption: some View {
        if let first = rangePoints.first {
            let gain = snapshot.value - first.value
            let since = DateFormats.dayMonthYear(first.date)
            let paidIn = (snapshot.savingsPlan?.debitCount(after: first.date, through: snapshot.today) ?? 0)
                * (snapshot.savingsPlan?.amount ?? 0)
            let tail = paidIn > 0
                ? String(
                    localized: " since \(since), of which \(MoneyFormatter.string(paidIn)) paid in by the savings plan",
                    bundle: .module)
                : String(localized: " since \(since)", bundle: .module)
            (Text(verbatim: MoneyFormatter.string(gain, sign: .always)).foregroundStyle(DepotText.color(gain))
                + Text(verbatim: tail).foregroundStyle(IMMColor.mutedForeground))
                .immFont(IMMFont.small.tabular)
        }
    }
}
