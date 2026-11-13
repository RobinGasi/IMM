import IMMDesign
import IMMLedger
import SwiftUI

/// Categories: the average monthly spending and what it leaves of the salary, the stacked bar chart of
/// 12 months, and the table of categories with their shares.
///
/// The chart always shows the 12 months; the tabs choose the period the hero figure and the table
/// summarise (Year as designed; Month and Quarter use the same columns for the running month and
/// the calendar quarter so far, and dim the other bars).
public struct CategoriesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var categories = CategoriesModel()
    @State private var period: CategoriesPeriod = .year

    public init() {}

    public var body: some View {
        Group {
            if let snapshot = categories.snapshot {
                CategoriesLayout(snapshot: snapshot, period: $period)
            } else {
                Color.clear
            }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await categories.follow(ledger: ledger)
        }
    }
}

struct CategoriesLayout: View {
    let snapshot: CategoriesSnapshot
    @Binding var period: CategoriesPeriod

    @Environment(\.immWindowWidth) private var windowWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                header
                chartSection
                CategoriesTable(period: period, data: snapshot.table(for: period))
            }
            // `margin-top: auto`: the footer sits at the bottom edge when the content is shorter than the window.
            Spacer(minLength: 28)
            footer
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
        .padding(.horizontal, IMMLayout.contentPadding(windowWidth: windowWidth))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: CategoriesFormat.euros(heroAmount))
                        .immFont(IMMFont.amountHero.sized(heroSize, lineHeight: heroSize * 1.2))
                        .foregroundStyle(IMMColor.foreground)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: heroSize * 1.2)
                    heroLabel
                        .immFont(.body)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                }
                comparison
                    .immFont(IMMFont.body.tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SegmentedTabs(selection: $period, options: [
                IMMOption(.month, Text("Month", bundle: .module)),
                IMMOption(.quarter, Text("Quarter", bundle: .module)),
                IMMOption(.year, Text("Year", bundle: .module)),
            ])
        }
    }

    private var heroSize: CGFloat { IMMLayout.heroFontSize(windowWidth: windowWidth) }

    private var heroAmount: Int {
        switch period {
        case .year: snapshot.monthlyAverage
        case .month: snapshot.thisMonthTotal
        case .quarter: snapshot.thisQuarterTotal
        }
    }

    private var heroLabel: Text {
        switch period {
        case .year: Text("average monthly spending", bundle: .module)
        case .month: Text("spent in \(DateFormats.monthName(snapshot.today)) so far", bundle: .module)
        case .quarter: Text("spent this quarter so far", bundle: .module)
        }
    }

    private var comparison: Text {
        switch period {
        case .year:
            guard let left = snapshot.leftAfterAverage else {
                return Text("Monthly average of the last 11 complete months", bundle: .module)
            }
            let salary = Text(verbatim: CategoriesFormat.euros(snapshot.salary, sign: .always)).foregroundColor(IMMColor.credit)
            return Text("Salary \(salary) leaves you \(CategoriesFormat.euros(left.amount)) a month, \(left.percent) % of what comes in", bundle: .module)
        case .month:
            let percent = CategoriesFormat.permille(snapshot.thisMonthTotal, of: snapshot.monthlyAverage)
            let average = CategoriesFormat.euros(snapshot.monthlyAverage)
            return Text("\((percent + 5) / 10) % of your monthly average of \(average)", bundle: .module)
        case .quarter:
            let from = DateFormats.dayMonth(snapshot.quarterStart)
            let to = DateFormats.dayMonth(snapshot.today)
            let average = CategoriesFormat.euros(snapshot.monthlyAverage)
            return Text("\(from) \u{2013} \(to) \u{00B7} your monthly average is \(average)", bundle: .module)
        }
    }

    // MARK: Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    heading
                    Spacer(minLength: 0)
                    legend
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    legend
                }
            }
            CategoriesChart(snapshot: snapshot, highlighted: highlightedMonths)
        }
    }

    private var heading: some View {
        Group {
            if let peak = snapshot.mostExpensiveMonth {
                Text(
                    "\(DateFormats.monthName(peak.start)) was the most expensive month at \(CategoriesFormat.euros(peak.total))",
                    bundle: .module)
            } else {
                Text("Spending by month", bundle: .module)
            }
        }
        .immFont(.titleMD)
        .foregroundStyle(IMMColor.foreground)
        .lineLimit(1)
        .fixedSize()
    }

    private var legend: some View {
        CategoriesLegend(items: snapshot.categories.map { ($0.name, IMMColor.named($0.colorToken)) })
    }

    private var highlightedMonths: Set<LocalDate>? {
        switch period {
        case .year: nil
        case .month: [snapshot.currentMonth.start]
        case .quarter: Set(snapshot.months.filter { $0.start >= snapshot.quarterStart }.map(\.start))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Group {
                if snapshot.rulesCount == 1 {
                    Text("1 rule files your transactions automatically", bundle: .module)
                } else {
                    Text("\(snapshot.rulesCount) rules file your transactions automatically", bundle: .module)
                }
            }
            .immFont(.small)
            .foregroundStyle(IMMColor.mutedForeground)
            Button {} label: { Text("Edit rules", bundle: .module) }
                .immButtonStyle(.outline, size: .sm)
                .inertControl()
        }
        .frame(height: 24)
    }
}
