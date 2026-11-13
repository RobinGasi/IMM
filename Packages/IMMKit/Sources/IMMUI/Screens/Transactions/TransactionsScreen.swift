import IMMDesign
import IMMLedger
import SwiftUI

/// Transactions of one account or of all accounts: summary with balance chart, filters, the table, and
/// the inspector for the selected row. Opening a row switches to the inspector layout (no summary, no
/// balance column); "Close inspector" clears the selection.
public struct TransactionsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.transactionsSeed) private var seed

    public init() {}

    public var body: some View {
        let scope = Self.scope(of: model.route)
        TransactionsContent(scope: scope, seed: seed)
            .id(scope)
    }

    private static func scope(of route: MainRoute) -> TransactionScope {
        guard case .transactions(let scope) = route else { return .all }
        switch scope {
        case .all: return .all
        case .account(let id): return .account(id)
        }
    }
}

/// Initial state of the screen; tests inject it with `.environment(\.transactionsSeed, …)`.
struct TransactionsSeed {
    var period: TransactionPeriod = .last90Days
    var direction: TransactionDirection = .all
    var category: TransactionCategoryFilter = .all
    var selection: String?
}

private struct TransactionsSeedKey: EnvironmentKey {
    static let defaultValue: TransactionsSeed? = nil
}

extension EnvironmentValues {
    var transactionsSeed: TransactionsSeed? {
        get { self[TransactionsSeedKey.self] }
        set { self[TransactionsSeedKey.self] = newValue }
    }
}

private struct TransactionsContent: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.immWindowWidth) private var windowWidth
    @State private var tx: TransactionsModel

    init(scope: TransactionScope, seed: TransactionsSeed?) {
        let filter = TransactionFilter(
            scope: scope, period: seed?.period ?? .last90Days, direction: seed?.direction ?? .all,
            category: seed?.category ?? .all)
        _tx = State(initialValue: TransactionsModel(filter: filter, selection: seed?.selection))
    }

    var body: some View {
        let selected = tx.selectedItem
        HStack(spacing: 0) {
            Group {
                if let snapshot = tx.snapshot {
                    ListColumn(tx: tx, snapshot: snapshot, inspectorOpen: selected != nil, windowWidth: windowWidth)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let selected {
                let category = tx.snapshot?.categories.first { $0.id == selected.categoryID }
                TransactionInspector(
                    item: selected, category: category, categories: tx.snapshot?.categories ?? [], rule: tx.ruleInfo,
                    windowWidth: windowWidth,
                    onClose: { tx.clearSelection() },
                    onCategory: { new in edit { try tx.setCategory(new, of: selected.id, ledger: $0) } },
                    onNote: { new in edit { try tx.setNote(new, of: selected.id, ledger: $0) } },
                    onRule: { on in edit { try tx.setRule(on, ledger: $0) } }
                )
                .frame(width: IMMLayout.inspectorWidth(windowWidth: windowWidth))
                .frame(maxHeight: .infinity)
                .immSlideInRight()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IMMColor.background)
        .task(id: tx.filter) {
            guard let ledger = appModel.ledger else { return }
            await tx.observe(ledger)
        }
        .task(id: tx.selectedItem.map { "\($0.id)|\($0.categoryID ?? "")" }) {
            guard let ledger = appModel.ledger else { return }
            await tx.loadRuleInfo(ledger)
        }
        .onAppear { consumePendingSelection() }
        .onChange(of: appModel.pendingTransactionSelection) { consumePendingSelection() }
        .onExitCommand { tx.clearSelection() }
    }

    /// Runs a ledger edit; a failure (the database closed under us) is shown to the user.
    private func edit(_ body: (LedgerStore) throws -> Void) {
        guard let ledger = appModel.ledger else { return }
        do { try body(ledger) } catch { EditFailureAlert.show(error) }
    }

    private func consumePendingSelection() {
        guard let id = appModel.pendingTransactionSelection else { return }
        appModel.pendingTransactionSelection = nil
        tx.requestSelection(id)
    }
}

/// Everything left of the inspector.
private struct ListColumn: View {
    @Bindable var tx: TransactionsModel
    let snapshot: TransactionListSnapshot
    let inspectorOpen: Bool
    let windowWidth: CGFloat

    var body: some View {
        let padding = IMMLayout.contentPadding(windowWidth: windowWidth)
        let mode: TransactionRowsBuilder.Mode = inspectorOpen ? .inspector : .list
        let rows = TransactionRowsBuilder.rows(for: snapshot, mode: mode)
        let layout = TransactionRowsBuilder.tableLayout(for: snapshot, mode: mode)

        VStack(spacing: 0) {
            if !inspectorOpen {
                TransactionsSummary(snapshot: snapshot, windowWidth: windowWidth)
            }
            TransactionsFilterBar(
                model: tx, compact: inspectorOpen, count: snapshot.items.count, categories: snapshot.categories,
                padding: padding)
            TransactionTableHeader(layout: layout, horizontalPadding: padding)
            region(rows: rows, layout: layout, padding: padding)
        }
    }

    /// The table and, beside the inspector, the total. Beside the inspector the table is as tall as its
    /// rows (up to the free height) and the total sits right below the last row, as drawn; a long list
    /// scrolls with the total pinned underneath. One structure for both layouts keeps the table view alive
    /// when the inspector opens.
    private func region(rows: [TransactionTableRow], layout: TransactionTableLayout, padding: CGFloat) -> some View {
        GeometryReader { proxy in
            let showsFooter = inspectorOpen && !rows.isEmpty
            let footerHeight: CGFloat = showsFooter ? 56 : 0
            let content = TransactionTableMetrics.contentHeight(of: rows)
            let available = max(0, proxy.size.height - footerHeight)
            let tableHeight = inspectorOpen ? min(content, available) : proxy.size.height
            VStack(spacing: 0) {
                TransactionTable(rows: rows, layout: layout, selection: $tx.selection, horizontalPadding: padding)
                    .frame(height: tableHeight)
                if showsFooter {
                    ListFooter(snapshot: snapshot, width: proxy.size.width, padding: padding)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .overlay(alignment: .top) {
                if rows.isEmpty { EmptyList() }
            }
        }
    }
}

private struct EmptyList: View {
    var body: some View {
        Text("No transactions match these filters.", bundle: .module)
            .immFont(.body)
            .foregroundStyle(IMMColor.mutedForeground)
            .padding(.top, 40)
    }
}

/// "Spent in November so far · 01.–12.11.2026 · −1.526,43", beside the inspector.
private struct ListFooter: View {
    let snapshot: TransactionListSnapshot
    let width: CGFloat
    let padding: CGFloat

    var body: some View {
        let columns = TransactionColumns(layout: .inspector, contentWidth: width - 2 * padding)
        let total = snapshot.items.reduce(0) { $0 + $1.amount }
        HStack(spacing: columns.gap) {
            Color.clear.frame(width: columns.date, height: 1)
            Text(verbatim: TransactionText.footerLabel(snapshot))
                .immFont(IMMFont.bodySemibold.withLineHeight(16))
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .frame(width: columns.payee, alignment: .leading)
            Text(verbatim: TransactionText.footerRange(snapshot))
                .immFont(IMMFont.small.tabular)
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
                .frame(width: columns.category, alignment: .leading)
            Text(verbatim: MoneyFormatter.string(total, sign: .negativeOnly, symbol: false))
                .immFont(IMMFont.bodySemibold.withLineHeight(16).tabular)
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .frame(width: columns.amount, alignment: .trailing)
        }
        .padding(.top, 1)
        .padding(.bottom, 3)
        .frame(height: 40)
        .overlay(alignment: .top) { Rule() }
        .overlay(alignment: .bottom) { DoubleRule() }
        .padding(.horizontal, padding)
        .padding(.top, 16)
    }
}
