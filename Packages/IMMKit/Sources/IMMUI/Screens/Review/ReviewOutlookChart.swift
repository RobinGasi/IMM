import IMMDesign
import IMMLedger
import SwiftUI

/// The outlook chart: the Girokonto balance by day with its likely range shaded.
///
/// 184 pt high; the horizontal gridlines sit at multiples of 2.000 € with the axis labels 8 pt right of
/// the plot, the axis starts at 0 € and ends 500 € above the next multiple over the highest value. The
/// line and the band are drawn in a 180 × 100 box stretched to the plot (as the design's
/// `preserveAspectRatio="none"` SVG), so stroke widths scale with it.
struct ReviewOutlookChart: View {
    let outlook: ReviewOutlookFigures

    private static let height: CGFloat = 184
    private static let gridStep = 200_000
    private static let box = CGSize(width: 180, height: 100)

    private var points: [ReviewForecastPoint] { outlook.points }

    /// Top of the axis in minor units.
    private var axisTop: Int {
        let highest = max(points.map(\.high).max() ?? 0, outlook.todayBalance)
        return (highest + Self.gridStep - 1) / Self.gridStep * Self.gridStep + 50_000
    }

    /// Share of the plot height measured from the top.
    private func fraction(_ value: Int) -> CGFloat {
        let clamped = max(0, min(axisTop, value))
        return CGFloat(axisTop - clamped) / CGFloat(axisTop)
    }

    private func unitX(_ index: Int) -> CGFloat {
        points.count > 1 ? Self.box.width * CGFloat(index) / CGFloat(points.count - 1) : 0
    }

    private func unitY(_ value: Int) -> CGFloat { fraction(value) * Self.box.height }

    private var linePath: Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: unitX(index), y: unitY(point.expected))
            index == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }

    private var bandPath: Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: unitX(index), y: unitY(point.high))
            index == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        for (index, point) in points.enumerated().reversed() {
            path.addLine(to: CGPoint(x: unitX(index), y: unitY(point.low)))
        }
        path.closeSubpath()
        return path
    }

    private func index(of date: LocalDate) -> Int? { points.firstIndex { $0.date == date } }

    var body: some View {
        VStack(spacing: 6) {
            plot
                .frame(height: Self.height)
                .accessibilityElement()
                .accessibilityLabel(Text("Forecast of the account balance", bundle: .module))
                .accessibilityValue(Text(verbatim: AccessibilitySummary.series(
                    startLabel: points.first.map { DateFormats.dayMonthYear($0.date) } ?? "",
                    endLabel: points.last.map { DateFormats.dayMonthYear($0.date) } ?? "",
                    values: points.map(\.expected))))
            axisLabels
        }
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let scale = CGAffineTransform(scaleX: width / Self.box.width, y: height / Self.box.height)
            let line = linePath.strokedPath(StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)).applying(scale)
            ZStack(alignment: .topLeading) {
                ForEach(Array(gridValues.enumerated()), id: \.offset) { _, value in
                    Rectangle().fill(IMMColor.border).frame(height: 1).offset(y: fraction(value) * height)
                }
                Rectangle().fill(IMMColor.border).frame(height: 1).offset(y: height - 1)
                ForEach(Array((gridValues + [0]).enumerated()), id: \.offset) { _, value in
                    Text(verbatim: Self.axisText(value))
                        .immFont(IMMFont.caption.tabular)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .frame(width: 44, alignment: .trailing)
                        .offset(x: width + 8, y: fraction(value) * height - 8)
                }

                bandPath.applying(scale)
                    .fill(IMMColor.primary.opacity(0.14))
                    .immFadeIn(duration: 0.3, delay: 0.3)
                line
                    .fill(IMMColor.primary)
                    .immMotion(.draw, duration: 0.6)

                if let first = points.first, let last = points.last {
                    dot.offset(x: -4.5, y: unitY(first.expected) / Self.box.height * height - 4.5)
                    dot.offset(x: width - 4.5, y: unitY(last.expected) / Self.box.height * height - 4.5)
                    todayLabel(first)
                        .offset(y: fraction(first.expected) * height - 26)
                }
                if let salary = salaryPoint {
                    placed(salaryLabel, anchor: 1, x: width * salary.x - 10, y: fraction(salary.value) * height - 4)
                }
                if let low = lowestPoint {
                    placed(lowestLabel, anchor: 0.5, x: width * low.x, y: fraction(low.value) * height + 6)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
        }
    }

    /// Puts `label` at (`x`, `y`) with `anchor` × its width to the left of `x`; as an overlay of a clear
    /// view it does not change the size of the plot.
    private func placed<Label: View>(_ label: Label, anchor: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Color.clear.overlay(alignment: .topLeading) {
            label
                .alignmentGuide(.leading) { $0.width * anchor }
                .offset(x: x, y: y)
        }
    }

    private var gridValues: [Int] {
        Array(stride(from: Self.gridStep, through: axisTop, by: Self.gridStep).reversed())
    }

    private static func axisText(_ minor: Int) -> String {
        MoneyFormatter.string(minor).replacingOccurrences(of: ",00", with: "")
    }

    private var dot: some View {
        Circle()
            .fill(IMMColor.primary)
            .overlay(Circle().strokeBorder(IMMColor.background, lineWidth: 2))
            .frame(width: 9, height: 9)
    }

    private func todayLabel(_ first: ReviewForecastPoint) -> some View {
        var text = AttributedString(String(localized: "Today ", bundle: .module))
        var amount = AttributedString(MoneyFormatter.string(outlook.todayBalance))
        amount.foregroundColor = IMMColor.foreground
        amount.font = IMMFont.captionSemibold.tabular.font
        text += amount
        return Text(text)
            .immFont(IMMFont.caption.tabular)
            .foregroundStyle(IMMColor.mutedForeground)
            .fixedSize()
    }

    private var salaryPoint: (x: CGFloat, value: Int)? {
        guard let i = index(of: outlook.salaryDate), points.count > 1 else { return nil }
        return (CGFloat(i) / CGFloat(points.count - 1), points[i].expected)
    }

    private var salaryLabel: some View {
        var text = AttributedString(DateFormats.dayMonth(outlook.salaryDate) + " Gehalt ")
        var amount = AttributedString(MoneyFormatter.string(outlook.salaryAmount, sign: .always))
        amount.foregroundColor = IMMColor.credit
        amount.font = IMMFont.captionSemibold.tabular.font
        text += amount
        return Text(text)
            .immFont(IMMFont.caption.tabular)
            .foregroundStyle(IMMColor.mutedForeground)
            .fixedSize()
    }

    /// The label sits under the lower edge of the band at the lowest day.
    private var lowestPoint: (x: CGFloat, value: Int)? {
        guard let i = index(of: outlook.lowestDate), points.count > 1 else { return nil }
        return (CGFloat(i) / CGFloat(points.count - 1), points[i].low)
    }

    private var lowestLabel: some View {
        Text(verbatim: outlook.lowestText)
            .immFont(IMMFont.caption.tabular)
            .foregroundStyle(IMMColor.mutedForeground)
            .fixedSize()
    }

    // MARK: Date axis

    /// First day, every 7th day while at least a week from the end, last day.
    private var axisLabels: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let last = max(points.count - 1, 1)
            ZStack(alignment: .topLeading) {
                ForEach(Array(tickIndices.enumerated()), id: \.offset) { _, i in
                    let x = width * CGFloat(i) / CGFloat(last)
                    placed(
                        Text(verbatim: DateFormats.dayMonth(points[i].date))
                            .immFont(IMMFont.caption.tabular)
                            .foregroundStyle(IMMColor.mutedForeground)
                            .fixedSize(),
                        anchor: i == 0 ? 0 : (i == last ? 1 : 0.5), x: x, y: 0)
                }
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }

    private var tickIndices: [Int] {
        guard points.count > 1 else { return points.isEmpty ? [] : [0] }
        let last = points.count - 1
        var indices = [0]
        var next = 7
        while next < last - 3 {
            indices.append(next)
            next += 7
        }
        indices.append(last)
        return indices
    }
}
