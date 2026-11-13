import IMMDesign
import IMMLedger
import SwiftUI

/// `grid-template-columns: minmax(0,1fr) 96px 104px 96px minmax(140px,0.6fr)`, `gap-x: 16`, five cells per row.
struct CategoriesColumns: Layout {
    static let fixedWidths: [CGFloat] = [96, 104, 96]
    static let gap: CGFloat = 16

    /// Widths of the five columns for a row `width` wide.
    static func columnWidths(for width: CGFloat) -> [CGFloat] {
        let free = max(0, width - gap * 4 - fixedWidths.reduce(0, +))
        var last = max(140, free * 0.6 / 1.6)
        last = min(last, free)
        let first = max(0, free - last)
        return [first] + fixedWidths + [last]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let widths = Self.columnWidths(for: width)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() where index < widths.count {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = Self.columnWidths(for: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() where index < widths.count {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + Self.gap
        }
    }
}

/// The table: header, one row per category, the total with its double rule.
struct CategoriesTable: View {
    let period: CategoriesPeriod
    let data: CategoriesTableData

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(data.rows.enumerated()), id: \.element.id) { index, row in
                CategoriesRowView(row: row, index: index)
            }
            total
        }
    }

    private var amountTitle: Text {
        switch period {
        case .quarter: Text("This quarter", bundle: .module)
        case .month, .year: Text("This month", bundle: .module)
        }
    }

    private var shareTitle: Text {
        switch period {
        case .year: Text("Share of average", bundle: .module)
        case .month: Text("Share of month", bundle: .module)
        case .quarter: Text("Share of quarter", bundle: .module)
        }
    }

    private var header: some View {
        CategoriesColumns {
            headerCell(Text("Category", bundle: .module), alignment: .leading)
            headerCell(amountTitle, alignment: .trailing)
            headerCell(Text("Monthly average", bundle: .module), alignment: .trailing)
            headerCell(Text("Year total", bundle: .module), alignment: .trailing)
            headerCell(shareTitle, alignment: .leading).padding(.leading, 24)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rule() }
    }

    private func headerCell(_ title: Text, alignment: Alignment) -> some View {
        title
            .immFont(IMMFont.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var total: some View {
        CategoriesColumns {
            HStack(spacing: 8) {
                Color.clear.frame(width: 8, height: 1)
                Text("Total spending", bundle: .module)
                    .immFont(.bodySemibold)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            totalAmount(-data.amountTotal)
            totalAmount(-data.averageTotal)
            totalAmount(-data.yearTotal)
            Text(verbatim: "100 %")
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(width: 44, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 24)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .overlay(alignment: .bottom) { DoubleRule() }
    }

    private func totalAmount(_ value: Int) -> some View {
        Text(verbatim: CategoriesFormat.euros(value))
            .immFont(IMMFont.bodySemibold.tabular)
            .foregroundStyle(IMMColor.foreground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A category row (38 px): colour dot, name, payees, three amounts and the share bar. Hover `muted`,
/// pressed `accent`; the drill-down into a category is not designed, so the row has no action.
struct CategoriesRowView: View {
    let row: CategoriesRow
    let index: Int

    var body: some View {
        DataRow(height: 38, bleed: 0) {
            CategoriesColumns {
                HStack(spacing: 8) {
                    LegendDot(IMMColor.named(row.colorToken))
                    Text(verbatim: row.name)
                        .immFont(.body)
                        .lineLimit(1)
                        .fixedSize()
                    Text(verbatim: row.merchants)
                        .immFont(.small)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                amount(-row.amount)
                amount(-row.average)
                amount(-row.yearTotal)
                HStack(spacing: 12) {
                    CategoriesShareBar(
                        fraction: Double(row.sharePermille) / 1000, color: IMMColor.named(row.colorToken),
                        delay: 0.25 + 0.04 * Double(index))
                    Text(verbatim: CategoriesFormat.share(row.sharePermille))
                        .immFont(.small)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.leading, 24)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
        }
        .overlay(alignment: .bottom) { Rule() }
    }

    private func amount(_ value: Int) -> some View {
        Text(verbatim: CategoriesFormat.euros(value))
            .immFont(IMMFont.body.tabular)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// 6 px track in `border` with a coloured fill of `fraction` of the width, rounded 3, `grow-x` 400 ms.
struct CategoriesShareBar: View {
    let fraction: Double
    let color: Color
    let delay: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                IMMColor.border
                Rectangle()
                    .fill(color)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
                    .immGrowX(duration: 0.4, delay: delay)
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }
}
