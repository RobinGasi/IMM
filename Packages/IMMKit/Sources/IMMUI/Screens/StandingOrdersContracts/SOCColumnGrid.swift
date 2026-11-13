import SwiftUI

/// One column of a `SOCColumnGrid`: CSS `<n>px` or `minmax(0, <n>fr)`.
enum SOCColumn: Sendable {
    case fixed(CGFloat)
    case fr(CGFloat)
}

private struct SOCSpanKey: LayoutValueKey {
    static let defaultValue: Range<Int>? = nil
}

extension View {
    /// Puts the child into columns `start ..< end` (`col-[start_/_end]`, zero based, end exclusive).
    func socColumns(_ range: Range<Int>) -> some View {
        layoutValue(key: SOCSpanKey.self, value: range)
    }
}

/// A single grid row: `display: grid; grid-template-columns: …; column-gap: …; align-items: center`.
///
/// Children fill the columns in order unless they name their columns with `socColumns`. Every child
/// gets the width of its columns; the row is as high as its highest child.
struct SOCColumnGrid: Layout {
    var columns: [SOCColumn]
    var spacing: CGFloat

    private func widths(for width: CGFloat) -> [CGFloat] {
        var fixed: CGFloat = spacing * CGFloat(max(columns.count - 1, 0))
        var weights: CGFloat = 0
        for column in columns {
            switch column {
            case .fixed(let value): fixed += value
            case .fr(let weight): weights += weight
            }
        }
        let free = max(width - fixed, 0)
        return columns.map { column in
            switch column {
            case .fixed(let value): return value
            case .fr(let weight): return weights > 0 ? free * weight / weights : 0
            }
        }
    }

    private func assignments(_ subviews: Subviews) -> [Range<Int>] {
        var next = 0
        return subviews.map { subview in
            let range = subview[SOCSpanKey.self] ?? next..<(next + 1)
            next = range.upperBound
            return range
        }
    }

    private func span(_ range: Range<Int>, widths: [CGFloat]) -> (x: CGFloat, width: CGFloat) {
        var x: CGFloat = 0
        for index in 0..<min(range.lowerBound, widths.count) { x += widths[index] + spacing }
        let upper = min(range.upperBound, widths.count)
        var width: CGFloat = 0
        if upper > range.lowerBound {
            width = widths[range.lowerBound..<upper].reduce(0, +) + spacing * CGFloat(upper - range.lowerBound - 1)
        }
        return (x, width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let columnWidths = widths(for: width)
        var height: CGFloat = 0
        for (subview, range) in zip(subviews, assignments(subviews)) {
            let w = span(range, widths: columnWidths).width
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnWidths = widths(for: bounds.width)
        for (subview, range) in zip(subviews, assignments(subviews)) {
            let (x, w) = span(range, widths: columnWidths)
            let size = subview.sizeThatFits(ProposedViewSize(width: w, height: nil))
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: w, height: size.height))
        }
    }
}
