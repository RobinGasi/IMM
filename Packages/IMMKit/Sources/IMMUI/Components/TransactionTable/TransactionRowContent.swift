import IMMDesign
import Observation
import SwiftUI

/// Pointer and selection state of one table row; AppKit writes it, the SwiftUI cell reads it.
@MainActor @Observable
final class RowInteraction {
    var isHovered = false
    var isPressed = false
    var isSelected = false

    func reset() {
        isHovered = false
        isPressed = false
        isSelected = false
    }
}

extension IMMFont {
    fileprivate static let cell = IMMFont.body.withLineHeight(16)
    fileprivate static let cellTabular = IMMFont.body.withLineHeight(16).tabular
    fileprivate static let cellMedium = IMMFont.bodyMedium.withLineHeight(16)
    fileprivate static let cellMediumTabular = IMMFont.bodyMedium.withLineHeight(16).tabular
    fileprivate static let cellSemibold = IMMFont.bodySemibold.withLineHeight(16).tabular
    fileprivate static let cellSmall = IMMFont.small
    fileprivate static let cellSmallTabular = IMMFont.small.tabular
    fileprivate static let groupLabel = IMMFont.captionSemibold.tabular
}

/// Root of every hosted cell: one SwiftUI view per row, laid out on the resolved columns.
struct TransactionCellRoot: View {
    let row: TransactionTableRow
    let layout: TransactionTableLayout
    let columns: TransactionColumns
    let padding: CGFloat
    let interaction: RowInteraction
    let disableMotion: Bool

    var body: some View {
        Group {
            switch row {
            case .monthHeader(_, let title, let total):
                MonthHeaderRowView(title: title, total: total, columns: columns, padding: padding)
            case .transaction(let data):
                TransactionDataRowView(
                    data: data, layout: layout, columns: columns, padding: padding, interaction: interaction)
            case .closingBalance(_, let label, let amount, let date):
                ClosingBalanceRowView(
                    label: label, amount: amount, date: date, columns: columns, padding: padding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.immDisableMotion, disableMotion)
    }
}

// MARK: Month header

private struct MonthHeaderRowView: View {
    let title: String
    let total: String?
    let columns: TransactionColumns
    let padding: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: columns.leading, height: 1)
            Text(verbatim: title)
                .lineLimit(1)
                .frame(width: columns.labelSpan, alignment: .leading)
            Color.clear.frame(width: columns.gap, height: 1)
            Text(verbatim: total ?? "")
                .lineLimit(1)
                .frame(width: columns.amount, alignment: .trailing)
        }
        .immFont(.groupLabel)
        .foregroundStyle(IMMColor.mutedForeground)
        .padding(.horizontal, padding)
        .padding(.bottom, 4)
        .frame(height: TransactionTableMetrics.monthHeaderHeight, alignment: .bottomLeading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Closing balance

private struct ClosingBalanceRowView: View {
    let label: String
    let amount: String
    let date: String?
    let columns: TransactionColumns
    let padding: CGFloat

    var body: some View {
        let labelWidth = columns.payee + columns.gap + columns.category
            + (columns.hasBalance ? columns.gap + columns.amount : 0)
        let lastWidth = columns.hasBalance ? columns.balance : columns.amount
        HStack(spacing: columns.gap) {
            if columns.leading > 0 {
                Color.clear.frame(width: columns.leading - columns.gap, height: 1)
            }
            Text(verbatim: date ?? "")
                .immFont(.cellTabular.weighted(.regular))
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
                .frame(width: columns.date, alignment: .leading)
            Text(verbatim: label)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            Text(verbatim: amount)
                .lineLimit(1)
                .frame(width: lastWidth, alignment: .trailing)
        }
        .immFont(.cellSemibold)
        .foregroundStyle(IMMColor.foreground)
        .padding(.horizontal, padding)
        .padding(.top, 1)
        .padding(.bottom, 3)
        .frame(height: TransactionTableMetrics.rowHeight)
        .overlay(alignment: .top) { Rule() }
        .overlay(alignment: .bottom) { DoubleRule() }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Transaction row

private struct TransactionDataRowView: View {
    let data: TransactionRowData
    let layout: TransactionTableLayout
    let columns: TransactionColumns
    let padding: CGFloat
    let interaction: RowInteraction

    @Environment(\.immDisableMotion) private var disableMotion

    private var isInspector: Bool { layout == .inspector }
    private var isSelected: Bool { interaction.isSelected }
    private var isHighlighted: Bool { interaction.isSelected || interaction.isPressed }

    private var fill: Color {
        if isHighlighted { return IMMColor.accent }
        return interaction.isHovered ? IMMColor.muted : Color.clear
    }

    private var primaryText: Color {
        isHighlighted ? IMMColor.accentForeground : IMMColor.foreground
    }

    private var secondaryText: Color {
        isSelected ? IMMColor.accentForeground : IMMColor.mutedForeground
    }

    var body: some View {
        HStack(spacing: columns.gap) {
            if columns.hasMarker {
                marker
            }
            dateCell
            payeeCell
            categoryCell
            amountCell
            if columns.hasBalance {
                balanceCell
            }
        }
        .padding(.horizontal, padding)
        .padding(.bottom, 1)
        .frame(height: TransactionTableMetrics.rowHeight)
        .background { Rectangle().fill(fill) }
        .overlay(alignment: .bottom) { Rule() }
        .overlay(alignment: .topTrailing) {
            if isInspector && isSelected {
                IMMIcon("chevron-right", size: 12, color: IMMColor.accentForeground)
                    .padding(.top, 16)
                    .padding(.trailing, 6)
            }
        }
        .animation(disableMotion ? nil : Motion.ease(0.12), value: interaction.isHovered)
        .animation(disableMotion ? nil : Motion.ease(0.12), value: isHighlighted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityText: String {
        [
            data.payee, data.secondary, data.date, data.categoryName,
            data.amount,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    private var marker: some View {
        ZStack(alignment: .leading) {
            if data.isNew {
                Circle().fill(IMMColor.primary).frame(width: 6, height: 6)
            }
        }
        .frame(width: 12, alignment: .leading)
    }

    private var dateCell: some View {
        Text(verbatim: data.date)
            .immFont(isInspector ? .cellSmallTabular : .cellTabular)
            .foregroundStyle(secondaryText)
            .lineLimit(1)
            .frame(width: columns.date, alignment: .leading)
    }

    private var payeeCell: some View {
        VStack(alignment: .leading, spacing: isInspector ? 1 : 0) {
            Text(verbatim: data.payee)
                .immFont(.cellMedium)
                .foregroundStyle(primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if let secondary = data.secondary {
                Text(verbatim: secondary)
                    .immFont(.cellSmall)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: columns.payee, alignment: .leading)
    }

    private var categoryCell: some View {
        HStack(spacing: 8) {
            if let name = data.categoryName {
                LegendDot(IMMColor.named(data.categoryColorToken ?? "muted-foreground"))
                Text(verbatim: name)
                    .immFont(isInspector ? .cellSmall : .cell)
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Circle()
                    .fill(IMMColor.background)
                    .overlay { Circle().strokeBorder(IMMColor.mutedForeground, lineWidth: 1) }
                    .frame(width: 8, height: 8)
                Text("Without category", bundle: .module)
                    .immFont(isInspector ? .cellSmall : .cell)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: columns.category, alignment: .leading)
    }

    private var amountCell: some View {
        Text(verbatim: data.amount)
            .immFont(data.isPositive ? .cellMediumTabular : .cellTabular)
            .foregroundStyle(data.isPositive ? IMMColor.credit : primaryText)
            .lineLimit(1)
            .frame(width: columns.amount, alignment: .trailing)
    }

    private var balanceCell: some View {
        Text(verbatim: data.balance ?? "")
            .immFont(.cellTabular)
            .foregroundStyle(secondaryText)
            .lineLimit(1)
            .frame(width: columns.balance, alignment: .trailing)
    }
}

// MARK: Column header

/// The column header row that sits above the table in the design (Date, Payee and purpose,
/// Category, Amount, Balance). Use the same `horizontalPadding` as the table.
public struct TransactionTableHeader: View {
    private let layout: TransactionTableLayout
    private let horizontalPadding: CGFloat

    public init(layout: TransactionTableLayout, horizontalPadding: CGFloat) {
        self.layout = layout
        self.horizontalPadding = horizontalPadding
    }

    public var body: some View {
        GeometryReader { proxy in
            let columns = TransactionColumns(
                layout: layout, contentWidth: proxy.size.width - 2 * horizontalPadding)
            HStack(spacing: columns.gap) {
                if columns.hasMarker {
                    Color.clear.frame(width: 12, height: 1)
                }
                Text("Date", bundle: .module)
                    .frame(width: columns.date, alignment: .leading)
                Text("Payee and purpose", bundle: .module)
                    .frame(width: columns.payee, alignment: .leading)
                Text("Category", bundle: .module)
                    .lineLimit(1)
                    .frame(width: columns.category, alignment: .leading)
                Text("Amount", bundle: .module)
                    .frame(width: columns.amount, alignment: .trailing)
                if columns.hasBalance {
                    Text("Balance", bundle: .module)
                        .frame(width: columns.balance, alignment: .trailing)
                }
            }
            .immFont(.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .padding(.horizontal, horizontalPadding)
            .frame(width: proxy.size.width, height: layout.headerHeight, alignment: .leading)
            .overlay(alignment: .bottom) { Rule() }
        }
        .frame(height: layout.headerHeight)
        .accessibilityHidden(true)
    }
}
