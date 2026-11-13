import SwiftUI

/// The four columns of a budget row, `grid-cols-[minmax(140px,0.8fr)_minmax(0,1.2fr)_140px_120px]`
/// with a 24 pt column gap. Children are centred vertically in the proposed height.
struct BudgetsColumnsLayout: Layout {
    static let gap: CGFloat = 24
    static let spentColumn: CGFloat = 140
    static let remainingColumn: CGFloat = 120

    /// The two flexible columns for a row of `width` points.
    static func flexibleColumns(width: CGFloat) -> (category: CGFloat, bar: CGFloat) {
        let free = max(0, width - spentColumn - remainingColumn - gap * 3)
        let category = max(140, free * 0.8 / 2.0)
        return (min(category, free), max(0, free - min(category, free)))
    }

    private func widths(_ width: CGFloat) -> [CGFloat] {
        let flexible = Self.flexibleColumns(width: width)
        return [flexible.category, flexible.bar, Self.spentColumn, Self.remainingColumn]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let columns = widths(width)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() where index < columns.count {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: columns[index], height: nil)).height)
        }
        return CGSize(width: width, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = widths(bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() where index < columns.count {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: columns[index], height: nil))
            x += columns[index] + Self.gap
        }
    }
}

/// The screen's two parts, `flex-row flex-wrap` with `flex-[999_1_560px]` and `flex-[1_1_320px]`:
/// side by side while both bases fit, else stacked. Side by side both stretch to the taller part or
/// to `minimumHeight` (the visible height), so the side panel's rule runs the full height.
struct BudgetsColumnsWrap: Layout {
    var minimumHeight: CGFloat

    static let mainBasis: CGFloat = 560
    static let sideBasis: CGFloat = 320

    private func sideBySide(_ width: CGFloat) -> Bool { width >= Self.mainBasis + Self.sideBasis }

    private func widths(_ width: CGFloat) -> (main: CGFloat, side: CGFloat) {
        guard sideBySide(width) else { return (width, width) }
        let free = width - Self.mainBasis - Self.sideBasis
        return (Self.mainBasis + free * 999 / 1000, Self.sideBasis + free / 1000)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (Self.mainBasis + Self.sideBasis)
        guard subviews.count == 2 else { return CGSize(width: width, height: 0) }
        let w = widths(width)
        let main = subviews[0].sizeThatFits(ProposedViewSize(width: w.main, height: nil)).height
        let side = subviews[1].sizeThatFits(ProposedViewSize(width: w.side, height: nil)).height
        let height = sideBySide(width) ? max(main, side, minimumHeight) : main + side
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let w = widths(bounds.width)
        let main = subviews[0].sizeThatFits(ProposedViewSize(width: w.main, height: nil)).height
        if sideBySide(bounds.width) {
            let side = subviews[1].sizeThatFits(ProposedViewSize(width: w.side, height: nil)).height
            let height = max(main, side, minimumHeight, bounds.height)
            subviews[0].place(
                at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: w.main, height: height))
            subviews[1].place(
                at: CGPoint(x: bounds.minX + w.main, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: w.side, height: height))
        } else {
            let side = subviews[1].sizeThatFits(ProposedViewSize(width: w.side, height: nil)).height
            subviews[0].place(
                at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: w.main, height: main))
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + main), anchor: .topLeading,
                proposal: ProposedViewSize(width: w.side, height: side))
        }
    }
}
