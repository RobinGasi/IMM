import SwiftUI

/// The middle cell of a suggestion row: a `display: flex; flex-wrap: wrap; align-items: center`
/// line of three items (payee and purpose, suggested category, reason).
///
/// Items are put on a line while their bases and the column gaps fit; each line then distributes the
/// free space by `grow` (or removes the overflow by `shrink × basis`). Items on a line are centred
/// vertically.
struct SuggestionCellLayout: Layout {
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat = 4
    var bases: [CGFloat]
    var grows: [CGFloat]
    var shrinks: [CGFloat]

    private struct Arrangement {
        var lines: [[Int]] = []
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
        var lineHeights: [CGFloat] = []
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        var arrangement = Arrangement()
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
            let free = width - line.reduce(0) { $0 + bases[$1] } - gaps
            if free >= 0 {
                let growSum = line.reduce(0) { $0 + grows[$1] }
                for index in line {
                    arrangement.widths[index] = bases[index] + (growSum > 0 ? free * grows[index] / growSum : 0)
                }
            } else {
                let weightSum = line.reduce(0) { $0 + shrinks[$1] * bases[$1] }
                for index in line {
                    let share = weightSum > 0 ? free * shrinks[index] * bases[index] / weightSum : 0
                    arrangement.widths[index] = max(0, bases[index] + share)
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
        let width = proposal.width ?? (bases.reduce(0, +) + columnSpacing * CGFloat(max(0, subviews.count - 1)))
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
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (lineHeight - arrangement.heights[index]) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(width: arrangement.widths[index], height: arrangement.heights[index]))
                x += arrangement.widths[index] + columnSpacing
            }
            y += lineHeight + rowSpacing
        }
    }
}

/// A text followed by a small link (`Reason [1]`): `display: flex; align-items: flex-end; gap: 4px`
/// where the text may shrink but not grow. A text that fits keeps its natural width (the link follows
/// it); a text that wraps fills the space left of the link, which then sits at the trailing edge.
struct TextWithLinkLayout: Layout {
    var spacing: CGFloat = 4

    private func textWidth(in width: CGFloat, text ideal: CGSize, link: CGSize) -> CGFloat {
        min(ideal.width, max(0, width - link.width - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let link = subviews[1].sizeThatFits(.unspecified)
        let ideal = subviews[0].sizeThatFits(.unspecified)
        guard let width = proposal.width else {
            return CGSize(width: ideal.width + spacing + link.width, height: max(ideal.height, link.height))
        }
        let text = subviews[0].sizeThatFits(
            ProposedViewSize(width: textWidth(in: width, text: ideal, link: link), height: nil))
        return CGSize(width: width, height: max(text.height, link.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let link = subviews[1].sizeThatFits(.unspecified)
        let ideal = subviews[0].sizeThatFits(.unspecified)
        let width = textWidth(in: bounds.width, text: ideal, link: link)
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - text.height), anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: text.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + width + spacing, y: bounds.maxY - link.height), anchor: .topLeading,
            proposal: ProposedViewSize(width: link.width, height: link.height))
    }
}
