import IMMDesign
import IMMLedger
import SwiftUI

/// The 30-day axis beside the hero: today on the left, the horizon on the right, one tick per day.
/// Debits hang below the axis (height by amount), the salary stands above it, month starts get a taller
/// tick with the month name. Everything is positioned by `days since today / 30` of the inner width.
struct StandingOrdersTimeline: View {
    let snapshot: StandingOrdersSnapshot

    private let axisY: CGFloat = 40
    private let barWidth: CGFloat = 6
    private let maxBarHeight: CGFloat = 40
    private let minBarHeight: CGFloat = 6
    private let salaryBarHeight: CGFloat = 18

    private var labelFont: IMMFont { IMMFont.caption.withLineHeight(14).tabular }

    private func fraction(_ date: LocalDate) -> CGFloat {
        CGFloat(date - snapshot.today) / CGFloat(StandingOrdersQueries.timelineDays)
    }

    private func barHeight(_ amount: Int, largest: Int) -> CGFloat {
        guard largest > 0 else { return minBarHeight }
        return max(minBarHeight, (CGFloat(abs(amount)) / CGFloat(largest) * maxBarHeight).rounded())
    }

    /// Delay of the bar of the `rank`-th event on the axis (debits and the salary, by date).
    private func delay(_ date: LocalDate) -> Double {
        var dates = snapshot.timeline.map(\.date)
        if let salary = snapshot.salary { dates.append(salary.date) }
        dates.sort()
        return Double(dates.firstIndex(of: date) ?? 0) * 0.04
    }

    /// First days of months inside the axis (excluding today): they carry the month marker, not a tick.
    private var monthStarts: [LocalDate] {
        (1...StandingOrdersQueries.timelineDays)
            .map { snapshot.today.adding(days: $0) }
            .filter { $0.day == 1 }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - 24, 0)
            let largest = snapshot.timeline.map { abs($0.amount) }.max() ?? 0
            ZStack(alignment: .topLeading) {
                // Axis, ticks and month markers.
                Rectangle().fill(IMMColor.border).frame(width: width, height: 1).offset(y: axisY)
                ticks(width: width)
                ForEach(monthStarts, id: \.self) { date in
                    let x = width * fraction(date)
                    Rectangle().fill(IMMColor.mutedForeground).frame(width: 1, height: 20).offset(x: x - 0.5, y: 30)
                    Text(verbatim: DateFormats.monthName(date))
                        .immFont(labelFont)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .fixedSize()
                        .offset(x: x + 5, y: 19)
                }

                today
                salary(width: width)

                ForEach(snapshot.timeline) { day in
                    let x = width * fraction(day.date)
                    Rectangle()
                        .fill(IMMColor.foreground)
                        .frame(width: barWidth, height: barHeight(day.amount, largest: largest))
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                        .modifier(TimelineGrow(anchor: .top, delay: delay(day.date)))
                        .offset(x: x - barWidth / 2, y: 44)
                    centered(
                        Text(verbatim: MoneyFormatter.string(day.amount, symbol: false))
                            .immFont(labelFont.weighted(.semibold))
                            .foregroundStyle(IMMColor.foreground),
                        x: x, top: 93)
                    centered(
                        Text(verbatim: DateFormats.dayMonth(day.date))
                            .immFont(labelFont)
                            .foregroundStyle(IMMColor.mutedForeground),
                        x: x, top: 108)
                }

                Text(verbatim: DateFormats.dayMonth(snapshot.horizon))
                    .immFont(labelFont)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .fixedSize()
                    .frame(width: width, height: 14, alignment: .trailing)
                    .offset(y: 108)
            }
            .frame(width: width, height: 124, alignment: .topLeading)
            .padding(.horizontal, 12)
        }
    }

    /// A label of 14 px line height centred on `x` at `top`.
    private func centered(_ text: some View, x: CGFloat, top: CGFloat) -> some View {
        text.fixedSize().frame(height: 14).position(x: x, y: top + 7)
    }

    private func ticks(width: CGFloat) -> some View {
        let starts = Set(monthStarts.map { $0 - snapshot.today })
        return ZStack(alignment: .topLeading) {
            ForEach(Array((1...StandingOrdersQueries.timelineDays).filter { !starts.contains($0) }), id: \.self) { day in
                Rectangle()
                    .fill(IMMColor.mutedForeground)
                    .frame(width: 1, height: 6)
                    .offset(x: width * CGFloat(day) / CGFloat(StandingOrdersQueries.timelineDays) - 0.5, y: 37)
            }
        }
        .opacity(0.5)
    }

    private var today: some View {
        ZStack(alignment: .topLeading) {
            Text("Today \(DateFormats.dayMonth(snapshot.today))", bundle: .module)
                .immFont(labelFont.weighted(.semibold))
                .foregroundStyle(IMMColor.primary)
                .fixedSize()
                .offset(x: -6, y: 3)
            Rectangle().fill(IMMColor.primary).frame(width: 2, height: 20).offset(x: -1, y: 20)
            Circle().fill(IMMColor.primary).frame(width: 8, height: 8).offset(x: -4, y: 36)
        }
        .immFadeIn(duration: 0.2)
    }

    @ViewBuilder
    private func salary(width: CGFloat) -> some View {
        if let salary = snapshot.salary {
            let x = width * fraction(salary.date)
            centered(
                Text(verbatim: MoneyFormatter.string(salary.amount, sign: .always, symbol: false))
                    .immFont(labelFont.weighted(.semibold))
                    .foregroundStyle(IMMColor.credit),
                x: x, top: 3)
            Rectangle()
                .fill(IMMColor.credit)
                .frame(width: barWidth, height: salaryBarHeight)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .modifier(TimelineGrow(anchor: .bottom, delay: delay(salary.date)))
                .offset(x: x - barWidth / 2, y: 22)
        }
    }
}

/// `grow-y`: scaleY 0 → 1 over 300 ms, from the top (debits) or the bottom (salary).
private struct TimelineGrow: ViewModifier {
    let anchor: UnitPoint
    let delay: Double

    @Environment(\.immDisableMotion) private var disableMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: disableMotion || reduceMotion || started ? 1 : 0.0001, anchor: anchor)
            .onAppear {
                guard !(disableMotion || reduceMotion), !started else { return }
                withAnimation(Motion.animation(.growY, delay: delay)) { started = true }
            }
    }
}
