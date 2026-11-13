import SwiftUI

/// `flex: <grow> 1 <basis>px` of one child of `ReviewFlexRow`; a nil basis is the child's own width.
private struct ReviewFlexKey: LayoutValueKey {
    static let defaultValue = ReviewFlexItem(basis: nil, grow: 0)
}

struct ReviewFlexItem: Sendable {
    var basis: CGFloat?
    var grow: CGFloat
}

extension View {
    func reviewFlex(basis: CGFloat? = nil, grow: CGFloat = 0) -> some View {
        layoutValue(key: ReviewFlexKey.self, value: ReviewFlexItem(basis: basis, grow: grow))
    }
}

/// `display: flex; flex-wrap: wrap; align-items: center`: children wrap by their bases and are
/// centred vertically inside their line; free space goes to the children that grow.
struct ReviewFlexRow: Layout {
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat

    private struct Arrangement {
        var lines: [[Int]] = []
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
        var lineHeights: [CGFloat] = []
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        var arrangement = Arrangement()
        let bases = subviews.map { subview -> CGFloat in
            subview[ReviewFlexKey.self].basis ?? subview.sizeThatFits(.unspecified).width
        }
        let grows = subviews.map { $0[ReviewFlexKey.self].grow }

        var current: [Int] = []
        var used: CGFloat = 0
        for index in subviews.indices {
            let needed = current.isEmpty ? bases[index] : used + columnSpacing + bases[index]
            if !current.isEmpty && needed > width {
                arrangement.lines.append(current)
                current = [index]
                used = bases[index]
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { arrangement.lines.append(current) }

        arrangement.widths = Array(repeating: 0, count: subviews.count)
        arrangement.heights = Array(repeating: 0, count: subviews.count)
        for line in arrangement.lines {
            let gaps = columnSpacing * CGFloat(line.count - 1)
            let basisSum = line.reduce(0) { $0 + bases[$1] }
            let free = width - basisSum - gaps
            let growSum = line.reduce(0) { $0 + grows[$1] }
            for index in line {
                if free >= 0 {
                    arrangement.widths[index] = bases[index] + (growSum > 0 ? free * grows[index] / growSum : 0)
                } else {
                    // Shrink in proportion to the basis, never below zero.
                    arrangement.widths[index] = max(0, bases[index] + (basisSum > 0 ? free * bases[index] / basisSum : 0))
                }
            }
            var lineHeight: CGFloat = 0
            for index in line {
                let height = subviews[index].sizeThatFits(ProposedViewSize(width: arrangement.widths[index], height: nil)).height
                arrangement.heights[index] = height
                lineHeight = max(lineHeight, height)
            }
            arrangement.lineHeights.append(lineHeight)
        }
        return arrangement
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) {
            $0 + ($1[ReviewFlexKey.self].basis ?? $1.sizeThatFits(.unspecified).width)
        } + columnSpacing * CGFloat(max(0, subviews.count - 1))
        let arrangement = arrange(width: width, subviews: subviews)
        let height = arrangement.lineHeights.reduce(0, +) + rowSpacing * CGFloat(max(0, arrangement.lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (lineIndex, line) in arrangement.lines.enumerated() {
            var x = bounds.minX
            let lineHeight = arrangement.lineHeights[lineIndex]
            for index in line {
                let height = arrangement.heights[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (lineHeight - height) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(width: arrangement.widths[index], height: height))
                x += arrangement.widths[index] + columnSpacing
            }
            y += lineHeight + rowSpacing
        }
    }
}

/// `grid-template-columns: minmax(0, 1.12fr) minmax(0, 1fr); align-items: start`, where the second
/// column stretches to the row height (so its left border runs the full height).
struct ReviewColumns: Layout {
    var firstWeight: CGFloat = 1.12
    var secondWeight: CGFloat = 1

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let first = total * firstWeight / (firstWeight + secondWeight)
        return (first, total - first)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let total = proposal.width ?? 1000
        let (first, second) = widths(total)
        let height = max(
            subviews[0].sizeThatFits(ProposedViewSize(width: first, height: nil)).height,
            subviews[1].sizeThatFits(ProposedViewSize(width: second, height: nil)).height)
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (first, second) = widths(bounds.width)
        let firstHeight = subviews[0].sizeThatFits(ProposedViewSize(width: first, height: nil)).height
        let secondHeight = subviews[1].sizeThatFits(ProposedViewSize(width: second, height: nil)).height
        let rowHeight = max(firstHeight, secondHeight)
        subviews[0].place(
            at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: first, height: firstHeight))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + first, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: second, height: rowHeight))
    }
}
