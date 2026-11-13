import SwiftUI

/// The top row of the Depot: the performance column (`flex: 999 1 560px`) and the aside
/// (`flex: 1 1 320px`), 32 pt apart, `align-items: stretch`.
///
/// On one line while both bases and the gap fit the width, otherwise the aside wraps below the
/// performance column at full width. On one line both children get the line's height, so the aside's
/// left border runs as far as the taller of the two.
struct DepotTopRowLayout: Layout {
    var spacing: CGFloat = 32
    var leadingBasis: CGFloat = 560
    var trailingBasis: CGFloat = 320

    private struct Arrangement {
        var oneLine: Bool
        var leadingWidth: CGFloat
        var trailingWidth: CGFloat
        var leadingHeight: CGFloat
        var trailingHeight: CGFloat
        var lineHeight: CGFloat
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        let oneLine = width >= leadingBasis + spacing + trailingBasis
        if oneLine {
            let free = width - leadingBasis - spacing - trailingBasis
            let leadingGrow: CGFloat = 999
            let trailingGrow: CGFloat = 1
            let leadingWidth = leadingBasis + free * leadingGrow / (leadingGrow + trailingGrow)
            let trailingWidth = width - spacing - leadingWidth
            let leadingHeight = subviews[0].sizeThatFits(ProposedViewSize(width: leadingWidth, height: nil)).height
            let trailingHeight = subviews[1].sizeThatFits(ProposedViewSize(width: trailingWidth, height: nil)).height
            return Arrangement(
                oneLine: true, leadingWidth: leadingWidth, trailingWidth: trailingWidth,
                leadingHeight: leadingHeight, trailingHeight: trailingHeight, lineHeight: max(leadingHeight, trailingHeight))
        }
        let leadingHeight = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let trailingHeight = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return Arrangement(
            oneLine: false, leadingWidth: width, trailingWidth: width, leadingHeight: leadingHeight,
            trailingHeight: trailingHeight, lineHeight: 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? leadingBasis + spacing + trailingBasis
        let a = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: a.oneLine ? a.lineHeight : a.leadingHeight + spacing + a.trailingHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let a = arrange(width: bounds.width, subviews: subviews)
        if a.oneLine {
            subviews[0].place(
                at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: a.leadingWidth, height: a.lineHeight))
            subviews[1].place(
                at: CGPoint(x: bounds.minX + a.leadingWidth + spacing, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: a.trailingWidth, height: a.lineHeight))
        } else {
            subviews[0].place(
                at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: a.leadingWidth, height: a.leadingHeight))
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + a.leadingHeight + spacing), anchor: .topLeading,
                proposal: ProposedViewSize(width: a.trailingWidth, height: a.trailingHeight))
        }
    }
}

/// First column and number of columns a child of `DepotTableRowLayout` occupies.
private struct DepotColumnKey: LayoutValueKey {
    static let defaultValue = (start: 0, span: 1)
}

extension View {
    /// `grid-column: <start + 1> / span <span>` in a `DepotTableRowLayout`.
    func depotColumn(_ start: Int, span: Int = 1) -> some View {
        layoutValue(key: DepotColumnKey.self, value: (start: start, span: span))
    }
}

/// One row of the holdings table: `grid-cols-[minmax(0,1fr)_80px_96px_120px_88px_minmax(120px,0.6fr)]`,
/// `gap-x-4`, `px-3`, children centred vertically.
struct DepotTableRowLayout: Layout {
    static let padding: CGFloat = 12
    static let gap: CGFloat = 16
    static let fixed: [CGFloat] = [80, 96, 120, 88]

    /// Widths of the six tracks inside a row of `total` points.
    static func columns(total: CGFloat) -> [CGFloat] {
        let inner = total - 2 * padding
        let free = max(0, inner - fixed.reduce(0, +) - 5 * gap)
        let last = max(120, free * 0.6 / 1.6)
        let first = max(0, free - last)
        return [first] + fixed + [last]
    }

    private func frames(width: CGFloat) -> [CGRect] {
        let widths = Self.columns(total: width)
        var x = Self.padding
        var frames: [CGRect] = []
        for w in widths {
            frames.append(CGRect(x: x, y: 0, width: w, height: 0))
            x += w + Self.gap
        }
        return frames
    }

    private func span(_ subview: LayoutSubview, frames: [CGRect]) -> (x: CGFloat, width: CGFloat) {
        let column = subview[DepotColumnKey.self]
        let start = min(column.start, frames.count - 1)
        let end = min(start + column.span - 1, frames.count - 1)
        return (frames[start].minX, frames[end].maxX - frames[start].minX)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let frames = frames(width: width)
        var height: CGFloat = 0
        for subview in subviews {
            let s = span(subview, frames: frames)
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: s.width, height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(width: bounds.width)
        for subview in subviews {
            let s = span(subview, frames: frames)
            let height = subview.sizeThatFits(ProposedViewSize(width: s.width, height: nil)).height
            subview.place(
                at: CGPoint(x: bounds.minX + s.x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: s.width, height: height))
        }
    }
}
