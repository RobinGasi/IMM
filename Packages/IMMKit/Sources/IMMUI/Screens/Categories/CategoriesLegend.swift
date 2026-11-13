import IMMDesign
import SwiftUI

/// Items at their natural width, wrapped onto new lines (`flex-wrap` with `gap-x`/`gap-y`). The first
/// baseline is the first item's, so a legend lines up with a heading beside it.
struct CategoriesWrapLayout: Layout {
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat
    var alignment: HorizontalAlignment = .leading

    private func lines(width: CGFloat, subviews: Subviews) -> [[Int]] {
        var lines: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.isEmpty ? size.width : used + columnSpacing + size.width
            if !current.isEmpty && needed > width {
                lines.append(current)
                current = [index]
                used = size.width
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width }
            + columnSpacing * CGFloat(max(0, subviews.count - 1))
        let width = proposal.width ?? natural
        let rows = lines(width: width, subviews: subviews)
        let heights = rows.map { row in row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0 }
        let widest = rows.map { row in
            row.reduce(CGFloat(0)) { $0 + subviews[$1].sizeThatFits(.unspecified).width } + columnSpacing * CGFloat(row.count - 1)
        }.max() ?? 0
        return CGSize(
            width: proposal.width == nil ? natural : min(width, max(widest, 0)),
            height: heights.reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(width: bounds.width, subviews: subviews) {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            let height = sizes.map(\.height).max() ?? 0
            var x = bounds.minX
            for (offset, index) in row.enumerated() {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + height / 2), anchor: .leading, proposal: ProposedViewSize(sizes[offset]))
                x += sizes[offset].width + columnSpacing
            }
            y += height + rowSpacing
        }
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline, let first = subviews.first else { return nil }
        let size = first.sizeThatFits(.unspecified)
        let dimensions = first.dimensions(in: ProposedViewSize(size))
        return (bounds.minY + (lines(width: bounds.width, subviews: subviews).first.map { row in
            row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? size.height
        } ?? size.height) / 2) - size.height / 2 + dimensions[guide]
    }
}

/// The 12 px category legend: dot, 6 px, name.
struct CategoriesLegend: View {
    let items: [(name: String, color: Color)]

    var body: some View {
        CategoriesWrapLayout(columnSpacing: 16, rowSpacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    LegendDot(item.color)
                    Text(verbatim: item.name)
                        .immFont(.small)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }
}
