import IMMDesign
import IMMLedger
import SwiftUI

/// Geometry and labels of the performance chart for one range, in the design's 716 × 176 box.
///
/// The y-axis has four grid lines 45.7 pt apart starting 8 pt from the top. Their values are a whole
/// number of euros apart (a step from 1, 2, 4, 5 × 10ⁿ): the smallest step for which four lines from a
/// rounded-up maximum cover the minimum (for 12.11.2025 – 12.11.2026 that is 50.000 … 38.000).
struct DepotChartModel {
    struct Tick: Hashable {
        var euros: Int
        var y: CGFloat
    }

    struct XLabel: Hashable {
        enum Position: Hashable { case leading, trailing, at(CGFloat) }
        var text: String
        var position: Position
    }

    static let boxHeight: CGFloat = 176
    static let firstLine: CGFloat = 8
    static let lineSpacing: CGFloat = 45.7
    /// The design's viewBox is 716 wide and keeps the line 4 units from both sides.
    static let viewBoxWidth: CGFloat = 716
    static let plotInset: CGFloat = 4

    let points: [DepotPoint]
    let range: DepotRange
    let top: Int
    let step: Int

    /// nil without at least two points.
    init?(points: [DepotPoint], range: DepotRange) {
        guard points.count >= 2, let low = points.map(\.value).min(), let high = points.map(\.value).max() else { return nil }
        self.points = points
        self.range = range
        let lowEuros = Double(low) / 100
        let highEuros = Double(high) / 100
        let (top, step) = Self.axis(low: lowEuros, high: highEuros)
        self.top = top
        self.step = step
    }

    /// Smallest step such that `top - 3 × step` is not more than 15 % of a step above the minimum.
    static func axis(low: Double, high: Double) -> (top: Int, step: Int) {
        var magnitude = 1
        while magnitude <= 10_000_000 {
            for factor in [1, 2, 4, 5] {
                let step = factor * magnitude
                let unit = max(1, step / 2)
                let top = Int((high / Double(unit)).rounded(.up)) * unit
                let bottom = top - 3 * step
                if Double(bottom) <= low + 0.15 * Double(step) { return (top, step) }
            }
            magnitude *= 10
        }
        return (Int(high.rounded(.up)), max(1, Int((high - low).rounded(.up))))
    }

    var ticks: [Tick] {
        (0..<4).map { index in
            Tick(euros: top - index * step, y: Self.firstLine + CGFloat(index) * Self.lineSpacing)
        }
    }

    /// Vertical position of a value in the 176 pt box.
    func y(_ cents: Int) -> CGFloat {
        let span = Self.lineSpacing * 3
        return Self.firstLine + (CGFloat(top) - CGFloat(cents) / 100) / CGFloat(3 * step) * span
    }

    /// Share of the box width of the date `date` between the first and the last point.
    func fraction(of date: LocalDate) -> CGFloat {
        guard let first = points.first?.date, let last = points.last?.date, last > first else { return 0 }
        return CGFloat(date - first) / CGFloat(last - first)
    }

    /// Horizontal position of a fraction of the range in a box of `width`.
    static func x(fraction: CGFloat, width: CGFloat) -> CGFloat {
        (plotInset + (viewBoxWidth - 2 * plotInset) * fraction) / viewBoxWidth * width
    }

    func plotPoints(width: CGFloat) -> [CGPoint] {
        points.map { CGPoint(x: Self.x(fraction: fraction(of: $0.date), width: width), y: y($0.value)) }
    }

    /// Labels under the chart: the first day, calendar months or weeks inside the range, and "Today".
    var xLabels: [XLabel] {
        guard let first = points.first?.date, let last = points.last?.date else { return [] }
        var labels = [XLabel(text: DateFormats.dayMonthYear(first), position: .leading)]
        var inside: [(LocalDate, String)] = []
        switch range {
        case .oneMonth:
            for days in [7, 14, 21] {
                let date = first.adding(days: days)
                inside.append((date, DateFormats.dayMonth(date)))
            }
        case .sixMonths:
            inside = Self.monthMarks(from: first, to: last, every: 1).map { ($0, Self.monthLabel($0, withYear: false)) }
        case .oneYear:
            inside = Self.monthMarks(from: first, to: last, every: 3).map { ($0, Self.monthLabel($0, withYear: false)) }
        case .max:
            inside = Self.monthMarks(from: first, to: last, every: 6).map { ($0, Self.monthLabel($0, withYear: true)) }
        }
        for (date, text) in inside {
            let f = fraction(of: date)
            guard f > 0.08, f < 0.9 else { continue }
            labels.append(XLabel(text: text, position: .at(Self.x(fraction: f, width: 1))))
        }
        labels.append(XLabel(text: String(localized: "Today", bundle: .module), position: .trailing))
        return labels
    }

    /// The 5th of the calendar months after `first` up to `last` (the design sets a month's label
    /// a few days into the month); with `every` > 1 only months whose number is 2 modulo 3
    /// (Feb May Aug Nov) or 1 modulo 6 (Jan Jul).
    private static func monthMarks(from first: LocalDate, to last: LocalDate, every: Int) -> [LocalDate] {
        var result: [LocalDate] = []
        var month = first.firstOfMonth.adding(months: 1)
        while month.adding(days: 4) <= last {
            let aligned: Bool
            switch every {
            case 1: aligned = true
            case 3: aligned = month.month % 3 == 2
            default: aligned = month.month % every == 1
            }
            if aligned { result.append(month.adding(days: 4)) }
            month = month.adding(months: 1)
        }
        return result
    }

    private static func monthLabel(_ date: LocalDate, withYear: Bool) -> String {
        let name = String(DateFormats.monthName(date).prefix(3))
        return withYear ? "\(name) \(date.year)" : name
    }

    /// `50.000` (whole euros, German grouping).
    static func axisText(_ euros: Int) -> String {
        let digits = Array(String(abs(euros)))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(".") }
            out.append(digit)
        }
        return euros < 0 ? "\u{2212}" + out : out
    }
}

/// The performance chart: grid lines, soft area, a 1.75 pt line that draws itself, an end dot,
/// month labels under it and the value axis on the right.
struct DepotChart: View {
    let model: DepotChartModel

    private let boxHeight = DepotChartModel.boxHeight

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                plot
                labels
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            axis
        }
    }

    private var plot: some View {
        GeometryReader { proxy in
            let points = model.plotPoints(width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                GridLines(ys: model.ticks.map(\.y))
                    .stroke(IMMColor.border, lineWidth: 1)
                DepotAreaShape(points: points, bottom: boxHeight)
                    .fill(IMMColor.primary.opacity(0.06))
                    .immFadeIn(duration: 0.4, delay: 0.3)
                DrawnStroke(DepotLineShape(points: points), color: IMMColor.primary, lineWidth: 1.75, duration: 0.7)
                if let last = points.last {
                    Circle()
                        .fill(IMMColor.primary)
                        .frame(width: 6, height: 6)
                        .position(x: last.x, y: last.y)
                        .immFadeIn(duration: 0.2, delay: 0.6)
                }
            }
        }
        .frame(height: boxHeight)
        .accessibilityElement()
        .accessibilityLabel(Text("Depot value over time", bundle: .module))
        .accessibilityValue(Text(verbatim: AccessibilitySummary.series(
            startLabel: model.points.first.map { DateFormats.dayMonthYear($0.date) } ?? "",
            endLabel: model.points.last.map { DateFormats.dayMonthYear($0.date) } ?? "",
            values: model.points.map(\.value))))
    }

    private var labels: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.xLabels.enumerated()), id: \.offset) { _, label in
                    Text(verbatim: label.text)
                        .immFont(IMMFont.caption.tabular)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .fixedSize()
                        .alignmentGuide(.leading) { dimensions in
                            switch label.position {
                            case .leading: return 0
                            case .trailing: return dimensions.width - proxy.size.width
                            case .at(let unit): return -unit * proxy.size.width
                            }
                        }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }

    private var axis: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(model.ticks, id: \.self) { tick in
                Text(verbatim: DepotChartModel.axisText(tick.euros))
                    .immFont(IMMFont.caption.tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .fixedSize()
                    .offset(y: (tick.y - 8).rounded())
            }
        }
        .frame(width: 56, height: boxHeight, alignment: .topTrailing)
        .accessibilityHidden(true)
    }
}

private struct GridLines: Shape {
    let ys: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for y in ys {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

private struct DepotLineShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

private struct DepotAreaShape: Shape {
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
