import IMMDesign
import IMMLedger
import SwiftUI

/// The stacked bar chart: 12 months, one segment per category (Housing at the bottom), a dashed
/// average line, y axis in euros and the month names below. The running month is drawn at half
/// opacity with a hatch. Bars grow from the baseline (`grow-y`, 450 ms, 30 ms per month).
struct CategoriesChart: View {
    let snapshot: CategoriesSnapshot
    /// Months outside the selected period are dimmed; nil dims nothing.
    var highlighted: Set<LocalDate>?

    static let plotHeight: CGFloat = 240
    /// Distance from the top of the plot to the baseline.
    static let baseline: CGFloat = 232
    /// Distance from the top of the plot to the top gridline.
    static let topLine: CGFloat = 8

    private var maxValue: Int {
        max(snapshot.months.map(\.total).max() ?? 0, snapshot.monthlyAverage)
    }

    /// Euros between two gridlines: whole thousands, or steps of 500 once the bars outgrow 3.000 €.
    private var step: Int {
        let third = Double(maxValue) / 100 / 3
        return max(1000, Int((third / 500).rounded(.up)) * 500)
    }

    /// Points per minor unit.
    private var scale: CGFloat {
        (Self.baseline - Self.topLine) / CGFloat(3 * step * 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                axis
                plot
            }
            .frame(height: Self.plotHeight)
            HStack(spacing: 0) {
                ForEach(snapshot.months) { month in
                    Text(verbatim: label(month))
                        .immFont(IMMFont.caption.withLineHeight(14))
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, 56)
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Monthly spending by category, \(DateFormats.monthYear(snapshot.months[0].start)) to \(DateFormats.monthYear(snapshot.currentMonth.start))", bundle: .module))
    }

    private func label(_ month: CategoriesMonth) -> String {
        month.isPartial ? String(localized: "\(month.label) \u{00B7} so far", bundle: .module) : month.label
    }

    // MARK: Axis

    private var axis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array((0...3).reversed()), id: \.self) { index in
                Text(verbatim: CategoriesFormat.euros(index * step * 100))
                    .immFont(IMMFont.caption.tabular.withLineHeight(14))
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
                    .fixedSize()
                if index > 0 { Spacer(minLength: 0) }
            }
        }
        .padding(.vertical, 1)
        .frame(width: 44, height: Self.plotHeight, alignment: .trailing)
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            let columnWidth = proxy.size.width / CGFloat(max(snapshot.months.count, 1))
            let barWidth = min(columnWidth / 2, 44)
            let lineY = (Self.baseline - CGFloat(snapshot.monthlyAverage) * scale).rounded()
            ZStack(alignment: .topLeading) {
                gridline(y: Self.topLine)
                gridline(y: Self.topLine + (Self.baseline - Self.topLine) / 3)
                gridline(y: Self.topLine + (Self.baseline - Self.topLine) * 2 / 3)

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(snapshot.months.enumerated()), id: \.element.id) { index, month in
                        bar(month, width: barWidth, index: index)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: Self.baseline, alignment: .bottom)

                AverageLine()
                    .stroke(IMMColor.foreground, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(height: 1)
                    .offset(y: lineY)
                Text("Average \(CategoriesFormat.euros(snapshot.monthlyAverage))", bundle: .module)
                    .immFont(IMMFont.captionSemibold.tabular.withLineHeight(14))
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(y: lineY - 17)

                Rectangle().fill(IMMColor.input).frame(height: 1).offset(y: Self.baseline)
            }
            .frame(width: proxy.size.width, height: Self.plotHeight, alignment: .topLeading)
        }
        .frame(height: Self.plotHeight)
    }

    private func gridline(y: CGFloat) -> some View {
        Rectangle().fill(IMMColor.border).frame(height: 1).offset(y: y)
    }

    private func bar(_ month: CategoriesMonth, width: CGFloat, index: Int) -> some View {
        let dimmed = highlighted.map { !$0.contains(month.start) } ?? false
        return VStack(spacing: 1.4) {
            // Top to bottom: the last category first, so the first category (Housing) ends up at the bottom.
            ForEach(Array(snapshot.categories.reversed())) { category in
                Rectangle()
                    .fill(IMMColor.named(category.colorToken))
                    .frame(height: CGFloat(month.byCategory[category.id] ?? 0) * scale)
            }
        }
        .opacity(month.isPartial ? 0.5 : 1)
        .overlay {
            if month.isPartial { Hatch() }
        }
        .frame(width: width)
        .opacity(dimmed ? 0.35 : 1)
        .animation(.easeOut(duration: 0.12), value: dimmed)
        .immGrowY(duration: 0.45, delay: 0.03 * Double(min(index, 10)))
    }
}

private struct AverageLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// `repeating-linear-gradient(45deg, background 0 2px, transparent 2px 5px)`: stripes of the
/// background colour running from the top left to the bottom right, 5 pt apart along the gradient.
private struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            let color = IMMColor.background
            // Distance along the gradient (up and to the right) is (x + h − y) / √2.
            let period = 5.0 * 2.0.squareRoot()
            let width = 2.0 * 2.0.squareRoot()
            let total = size.width + size.height
            var offset = 0.0
            while offset < total {
                // The band where `x − y + h` lies in [offset, offset + width]: a parallelogram.
                var band = Path()
                let h = size.height
                band.move(to: CGPoint(x: offset - h, y: 0))
                band.addLine(to: CGPoint(x: offset + width - h, y: 0))
                band.addLine(to: CGPoint(x: offset + width, y: h))
                band.addLine(to: CGPoint(x: offset, y: h))
                band.closeSubpath()
                context.fill(band, with: .color(color))
                offset += period
            }
        }
        .allowsHitTesting(false)
    }
}
