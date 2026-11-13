import IMMDesign
import IMMLedger
import SwiftUI

/// The Overview: net worth with its chart and "Needs attention", then Accounts, Spent and Coming up.
///
/// Both rows reflow with the window width alone (no breakpoints): the first wraps like a flex row
/// (chart column 520 pt basis, attention column 340 pt basis), the second is an auto-fit grid of
/// columns at least 300 pt wide. The shell scrolls the screen when it does not fit.
///
/// `SyncAwareOverview` (Screens/Sync) swaps `OverviewLayout` for the Sync failed layout while
/// `model.bank.syncState` is `.failed`; the section views take plain values and are reused there.
public struct OverviewScreen: View {
    @Environment(AppModel.self) private var model
    @State private var overview = OverviewModel()

    public init() {}

    public var body: some View {
        Group {
            if let snapshot = overview.snapshot {
                SyncAwareOverview(snapshot: snapshot)
            } else {
                Color.clear
            }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await overview.follow(ledger: ledger)
        }
    }
}

/// The normal layout (no sync failure).
struct OverviewLayout: View {
    let snapshot: OverviewSnapshot

    @Environment(\.immWindowWidth) private var windowWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            FlexWrapLayout(columnSpacing: 40, rowSpacing: 32) {
                OverviewNetWorthSection(snapshot: snapshot)
                    .flexItem(basis: 520, grow: 999)
                OverviewAttentionSection(attention: snapshot.attention)
                    .flexItem(basis: 340, grow: 1)
            }
            .padding(.bottom, 33)
            .overlay(alignment: .bottom) { Rule() }

            AutoFitGridLayout(minimumColumnWidth: 300, columnSpacing: 40, rowSpacing: 40) {
                OverviewAccountsSection(
                    groups: snapshot.accountGroups, netWorth: snapshot.netWorth, lastSyncedAt: snapshot.lastSyncedAt)
                OverviewSpentSection(snapshot: snapshot)
                OverviewComingUpSection(snapshot: snapshot)
            }
        }
        .padding(.horizontal, IMMLayout.contentPadding(windowWidth: windowWidth))
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
