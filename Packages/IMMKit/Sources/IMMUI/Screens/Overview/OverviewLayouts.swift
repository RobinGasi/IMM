import SwiftUI

/// CSS `flex: <grow> <shrink> <basis>px` of one child of `FlexWrapLayout`.
struct FlexItemValue: Sendable {
    var basis: CGFloat
    var grow: CGFloat
    var shrink: CGFloat
}

private struct FlexItemKey: LayoutValueKey {
    static let defaultValue = FlexItemValue(basis: 0, grow: 0, shrink: 1)
}

extension View {
    /// Flex sizing for a child of `FlexWrapLayout` (`flex-[grow_shrink_basis]`).
    func flexItem(basis: CGFloat, grow: CGFloat = 0, shrink: CGFloat = 1) -> some View {
        layoutValue(key: FlexItemKey.self, value: FlexItemValue(basis: basis, grow: grow, shrink: shrink))
    }
}

/// A horizontal `display: flex; flex-wrap: wrap; align-items: flex-start` container.
///
/// Children are put on a line while the sum of their bases and the column gaps fits the width; every
/// line then distributes the free space by `grow` (or removes the overflow by `shrink × basis`, never
/// below zero width). There are no breakpoints: the window width alone decides how the sections reflow.
struct FlexWrapLayout: Layout {
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
        let values = subviews.map { $0[FlexItemKey.self] }

        var current: [Int] = []
        var used: CGFloat = 0
        for index in subviews.indices {
            let basis = values[index].basis
            let needed = current.isEmpty ? basis : used + columnSpacing + basis
            if !current.isEmpty && needed > width {
                arrangement.lines.append(current)
                current = [index]
                used = basis
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
            let basisSum = line.reduce(0) { $0 + values[$1].basis }
            let free = width - basisSum - gaps
            if free >= 0 {
                let growSum = line.reduce(0) { $0 + values[$1].grow }
                for index in line {
                    let share = growSum > 0 ? free * values[index].grow / growSum : 0
                    arrangement.widths[index] = values[index].basis + share
                }
            } else {
                let weightSum = line.reduce(0) { $0 + values[$1].shrink * values[$1].basis }
                for index in line {
                    let weight = values[index].shrink * values[index].basis
                    let share = weightSum > 0 ? free * weight / weightSum : 0
                    arrangement.widths[index] = max(0, values[index].basis + share)
                }
            }
            var lineHeight: CGFloat = 0
            for index in line {
                let height = subviews[index]
                    .sizeThatFits(ProposedViewSize(width: arrangement.widths[index], height: nil)).height
                arrangement.heights[index] = height
                lineHeight = max(lineHeight, height)
            }
            arrangement.lineHeights.append(lineHeight)
        }
        return arrangement
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1[FlexItemKey.self].basis } + columnSpacing * CGFloat(max(0, subviews.count - 1))
        let arrangement = arrange(width: width, subviews: subviews)
        let height = arrangement.lineHeights.reduce(0, +) + rowSpacing * CGFloat(max(0, arrangement.lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (lineIndex, line) in arrangement.lines.enumerated() {
            var x = bounds.minX
            for index in line {
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: arrangement.widths[index], height: arrangement.heights[index]))
                x += arrangement.widths[index] + columnSpacing
            }
            y += arrangement.lineHeights[lineIndex] + rowSpacing
        }
    }
}

/// `display: grid; grid-template-columns: repeat(auto-fit, minmax(<minimum>px, 1fr)); align-items: start`.
///
/// As many equal columns as fit with `columnSpacing` between them (at least one, at most one per child).
struct AutoFitGridLayout: Layout {
    var minimumColumnWidth: CGFloat
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat

    private func columns(width: CGFloat, count: Int) -> Int {
        let fit = Int(((width + columnSpacing) / (minimumColumnWidth + columnSpacing)).rounded(.down))
        return max(1, min(fit, count))
    }

    private func rows(width: CGFloat, subviews: Subviews) -> (columns: Int, columnWidth: CGFloat, rowHeights: [CGFloat]) {
        guard !subviews.isEmpty else { return (1, width, []) }
        let columns = columns(width: width, count: subviews.count)
        let columnWidth = (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            var rowHeight: CGFloat = 0
            for offset in 0..<columns where index + offset < subviews.count {
                let size = subviews[index + offset].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
                rowHeight = max(rowHeight, size.height)
            }
            heights.append(rowHeight)
            index += columns
        }
        return (columns, columnWidth, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minimumColumnWidth * CGFloat(subviews.count) + columnSpacing * CGFloat(max(0, subviews.count - 1)))
        let layout = rows(width: width, subviews: subviews)
        let height = layout.rowHeights.reduce(0, +) + rowSpacing * CGFloat(max(0, layout.rowHeights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        var index = 0
        for rowHeight in layout.rowHeights {
            for offset in 0..<layout.columns where index + offset < subviews.count {
                let x = bounds.minX + CGFloat(offset) * (layout.columnWidth + columnSpacing)
                subviews[index + offset].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: layout.columnWidth, height: nil))
            }
            y += rowHeight + rowSpacing
            index += layout.columns
        }
    }
}
