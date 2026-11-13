import IMMDesign
import IMMLedger
import SwiftUI

/// Budgets: what is left to spend this month, one row per budget with a pace marker, the total, and
/// the fixed costs beside them.
///
/// Like the design's flex-wrap row the two parts sit side by side while 560 + 320 pt fit and stack
/// below that (the compact window). The shell scrolls the screen when it does not fit.
public struct BudgetsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var budgets = BudgetsModel()
    @State private var viewportHeight: CGFloat = 0

    public init() {}

    public var body: some View {
        Group {
            if let snapshot = budgets.snapshot {
                BudgetsLayout(snapshot: snapshot, viewportHeight: viewportHeight)
            } else {
                Color.clear
            }
        }
        .background {
            // The visible height of the enclosing scroll view: the side panel's rule runs that far down.
            Color.clear
                .containerRelativeFrame(.vertical)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await budgets.follow(ledger: ledger)
        }
    }
}

/// The figures laid out: budget column and side panel.
struct BudgetsLayout: View {
    let snapshot: BudgetsSnapshot
    var viewportHeight: CGFloat = 0

    @Environment(\.immWindowWidth) private var windowWidth

    var body: some View {
        BudgetsColumnsWrap(minimumHeight: viewportHeight) {
            BudgetsMainColumn(snapshot: snapshot)
                .padding(.horizontal, IMMLayout.contentPadding(windowWidth: windowWidth))
                .padding(.top, 28)
                .padding(.bottom, 32)
            BudgetsSidePanel(snapshot: snapshot)
                .padding(.horizontal, IMMLayout.clamp(20, fraction: 0.022, of: windowWidth, maximum: 24))
                .padding(.vertical, 32)
                .overlay(alignment: .topLeading) {
                    // `shadow-[-1px_-1px_0_0_var(--border)]`: a rule along the top and left edge, outside the box.
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(IMMColor.border).frame(height: 1).frame(maxWidth: .infinity)
                        Rectangle().fill(IMMColor.border).frame(width: 1).frame(maxHeight: .infinity)
                    }
                    .offset(x: -1, y: -1)
                    .allowsHitTesting(false)
                }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
