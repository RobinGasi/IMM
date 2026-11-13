import IMMDesign
import IMMLedger
import SwiftUI

/// Net worth label, hero figure, change since last month and the 12-month chart.
struct OverviewNetWorthSection: View {
    let snapshot: OverviewSnapshot

    @Environment(\.immWindowWidth) private var windowWidth

    private var deltaColor: Color {
        snapshot.netWorthChange >= 0 ? IMMColor.credit : IMMColor.destructive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Net worth, all \(snapshot.accountCount) accounts", bundle: .module)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(verbatim: MoneyFormatter.string(snapshot.netWorth))
                    .immFont(IMMFont.amountHero.sized(IMMLayout.heroFontSize(windowWidth: windowWidth)))
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .fixedSize()
                Text(
                    "\(MoneyFormatter.string(snapshot.netWorthChange, sign: .always)) since \(DateFormats.monthName(snapshot.previousMonthEnd))",
                    bundle: .module
                )
                .immFont(IMMFont.body.tabular)
                .foregroundStyle(deltaColor)
                .lineLimit(1)
                .fixedSize()
            }
            .frame(height: 40, alignment: .top)
            .padding(.top, 4)
            OverviewNetWorthChart(series: snapshot.netWorthSeries)
                .padding(.top, 16)
        }
    }
}

/// The net-worth line: 152 pt high box inset 20 pt on both sides, soft area under a 1.75 pt line that
/// draws itself, an end dot that pops in, and 12 month labels centred under their points.
struct OverviewNetWorthChart: View {
    let series: [NetWorthPoint]

    private static let boxHeight: CGFloat = 152
    /// The design keeps the line 22.6 pt away from the top and the bottom of the box.
    private static let inset: CGFloat = 22.6

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let points = Self.points(series, size: proxy.size)
                ZStack(alignment: .topLeading) {
                    ChartAreaShape(points: points, bottom: proxy.size.height)
                        .fill(IMMColor.primary.opacity(0.07))
                        .immFadeIn(duration: 0.4, delay: 0.3)
                    DrawnStroke(ChartLineShape(points: points), color: IMMColor.primary, lineWidth: 1.75, duration: 0.7)
                    if let last = points.last {
                        Circle()
                            .fill(IMMColor.primary)
                            .frame(width: 7, height: 7)
                            .position(x: last.x, y: last.y)
                            .immPopIn(duration: 0.16, delay: 0.65)
                    }
                }
            }
            .frame(height: Self.boxHeight)
            .overviewRowRule()
            .padding(.horizontal, 20)
            .accessibilityElement()
            .accessibilityLabel(Text("Net worth over the last 12 months", bundle: .module))
            .accessibilityValue(Text(verbatim: AccessibilitySummary.series(
                startLabel: series.first?.label ?? "", endLabel: series.last?.label ?? "", values: series.map(\.value))))

            HStack(spacing: 0) {
                ForEach(Array(series.enumerated()), id: \.offset) { index, point in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(verbatim: point.label)
                        .immFont(.caption)
                        .foregroundStyle(index == series.count - 1 ? IMMColor.foreground : IMMColor.mutedForeground)
                        .frame(width: 40)
                }
            }
            .accessibilityHidden(true)
        }
    }

    static func points(_ series: [NetWorthPoint], size: CGSize) -> [CGPoint] {
        guard series.count > 1 else {
            return series.isEmpty ? [] : [CGPoint(x: size.width, y: size.height / 2)]
        }
        let values = series.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let span = Double(high - low)
        let plotHeight = size.height - 2 * inset
        return series.enumerated().map { index, point in
            let x = size.width * CGFloat(index) / CGFloat(series.count - 1)
            let fraction = span > 0 ? Double(high - point.value) / span : 0.5
            return CGPoint(x: x, y: inset + CGFloat(fraction) * plotHeight)
        }
    }
}

private struct ChartLineShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

private struct ChartAreaShape: Shape {
    let points: [CGPoint]
    let bottom: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: bottom))
        path.addLine(to: CGPoint(x: first.x, y: bottom))
        path.closeSubpath()
        return path
    }
}
