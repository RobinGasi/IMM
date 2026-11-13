import IMMDesign
import IMMLedger
import SwiftUI

/// Balance block and balance chart above the list (hidden while the inspector is open).
struct TransactionsSummary: View {
    let snapshot: TransactionListSnapshot
    let windowWidth: CGFloat

    /// 18 above, the chart column (84 plot, 6 gap, 16 axis) and 14 below, plus the 1 px rule.
    static let height: CGFloat = 18 + 106 + 14 + 1

    var body: some View {
        let padding = IMMLayout.contentPadding(windowWidth: windowWidth)
        let gap = IMMLayout.clamp(24, fraction: 0.033, of: windowWidth, maximum: 48)
        VStack(spacing: 0) {
            GeometryReader { proxy in
                // flex: `1 1 220` beside `999 1 480`: the balance block keeps 220 plus a thousandth of the
                // free space, the chart takes the rest.
                let inner = max(0, proxy.size.width - 2 * padding)
                let free = max(0, inner - gap - 220 - 480)
                let blockWidth = 220 + free / 1000
                HStack(alignment: .bottom, spacing: gap) {
                    BalanceBlock(snapshot: snapshot, windowWidth: windowWidth)
                        .frame(width: blockWidth, alignment: .leading)
                    BalanceChart(chart: snapshot.chart)
                        .frame(width: max(0, inner - gap - blockWidth))
                }
                .padding(.horizontal, padding)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
            }
            .frame(height: Self.height - 1)
            Rule()
        }
    }
}

private struct BalanceBlock: View {
    let snapshot: TransactionListSnapshot
    let windowWidth: CGFloat

    private var caption: String? {
        switch snapshot.filter.scope {
        case .all:
            let count = snapshot.summedAccountCount
            return snapshot.excludesDepot
                ? String(localized: "\(count) accounts, without Depot", bundle: .module)
                : String(localized: "\(count) accounts", bundle: .module)
        case .account:
            if snapshot.overdraftLimit > 0 {
                let available = MoneyFormatter.string(snapshot.balance + snapshot.overdraftLimit)
                return String(localized: "Available \(available) incl. overdraft", bundle: .module)
            }
            return snapshot.balanceNote
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Balance today, \(DateFormats.dayMonthYear(snapshot.today))", bundle: .module)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
            Text(verbatim: MoneyFormatter.string(snapshot.balance))
                .immFont(IMMFont.amountHero.sized(IMMLayout.heroFontSize(windowWidth: windowWidth)))
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .fixedSize()
            Text(verbatim: caption ?? " ")
                .immFont(IMMFont.small.tabular)
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
        }
        .padding(.bottom, 19)
    }
}

/// The 90-day balance curve with the payday labels underneath.
struct BalanceChart: View {
    let chart: TransactionChart

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChartPlot(chart: chart)
                .frame(height: 84)
            AxisLabels(chart: chart)
                .frame(height: 16)
        }
    }
}

/// Geometry of the plot: the design's 760×92 viewBox, stretched to the available size.
struct ChartGeometry {
    let chart: TransactionChart
    let size: CGSize

    private var low: Double { Double(min(0, chart.minValue)) }
    private var high: Double { Double(max(chart.maxValue, Int(low) + 1)) }
    private var scale: Double { size.height / 92 }

    var baselineY: Double { 91.5 * scale }

    func point(_ point: TransactionChart.Point) -> CGPoint {
        let share = (Double(point.value) - low) / max(high - low, 1)
        return CGPoint(x: point.x * size.width, y: (91.5 - share * 85.4) * scale)
    }

    var line: Path {
        var path = Path()
        for (index, p) in chart.points.enumerated() {
            let cg = point(p)
            if index == 0 { path.move(to: cg) } else { path.addLine(to: cg) }
        }
        return path
    }

    var area: Path {
        var path = line
        guard let last = chart.points.last, let first = chart.points.first else { return path }
        path.addLine(to: CGPoint(x: point(last).x, y: baselineY))
        path.addLine(to: CGPoint(x: point(first).x, y: baselineY))
        path.closeSubpath()
        return path
    }
}

private struct LineShape: Shape {
    let geometry: ChartGeometry
    func path(in rect: CGRect) -> Path { geometry.line }
}

private struct ChartPlot: View {
    let chart: TransactionChart

    var body: some View {
        GeometryReader { proxy in
            let geometry = ChartGeometry(chart: chart, size: proxy.size)
            ZStack(alignment: .topLeading) {
                geometry.area.fill(IMMColor.primary.opacity(0.08))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.baselineY))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: geometry.baselineY))
                }
                .stroke(IMMColor.border, lineWidth: 1)
                DrawnStroke(
                    LineShape(geometry: geometry), color: IMMColor.primary, lineWidth: 1.5, lineCap: .butt,
                    lineJoin: .round, delay: 0)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Balance over the last 90 days", bundle: .module))
        .accessibilityValue(Text(verbatim: AccessibilitySummary.series(
            startLabel: DateFormats.dayMonthYear(chart.start), endLabel: DateFormats.dayMonthYear(chart.end),
            values: chart.points.map(\.value))))
    }
}

private struct AxisLabels: View {
    let chart: TransactionChart

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                label(DateFormats.dayMonth(chart.start))
                ForEach(visiblePaydays(width: width), id: \.date) { payday in
                    PaydayLabel(text: DateFormats.dayMonth(payday.date), x: payday.x * width)
                }
                label(String(localized: "Today", bundle: .module))
                    .frame(width: width, height: 16, alignment: .trailing)
            }
        }
        .accessibilityHidden(true)
    }

    private func visiblePaydays(width: CGFloat) -> [TransactionChart.Payday] {
        chart.paydays.filter { $0.x * width > 48 && $0.x * width < width - 48 }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .immFont(IMMFont.caption.tabular)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A label centred on `x` (the design's `translateX(-50%)`).
private struct PaydayLabel: View {
    let text: String
    let x: CGFloat

    var body: some View {
        Text(verbatim: text)
            .immFont(IMMFont.caption.tabular)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .fixedSize()
            .alignmentGuide(.leading) { $0.width / 2 - x }
    }
}
