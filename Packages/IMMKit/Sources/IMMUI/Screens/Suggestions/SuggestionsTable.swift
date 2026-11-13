import IMMDesign
import IMMLedger
import SwiftUI

/// Column widths of the table grid `[20px 52px 1fr 104px 132px]` and its gap `clamp(10, 1.1vw, 16)`.
private enum Columns {
    static let checkbox: CGFloat = 20
    static let date: CGFloat = 52
    static let amount: CGFloat = 104
    static let actions: CGFloat = 132

    static func gap(windowWidth: CGFloat) -> CGFloat {
        IMMLayout.clamp(10, fraction: 0.011, of: windowWidth, maximum: 16)
    }

    /// `clamp(196px, 18vw, 260px)`
    static func category(windowWidth: CGFloat) -> CGFloat {
        IMMLayout.clamp(196, fraction: 0.18, of: windowWidth, maximum: 260)
    }
}

/// The header, one row per suggestion and the footer ("Worked out on this Mac", "3 of 6 selected").
struct SuggestionsTable: View {
    let snapshot: SuggestionsSnapshot
    @Binding var selected: Set<String>
    /// Files the row under its suggested category.
    let onAccept: (SuggestionRow) -> Void
    /// Files the row under the chosen category.
    let onChange: (SuggestionRow, String) -> Void

    /// Selected rows that are still listed (accepted rows leave the list but not the selection set).
    private var selectedCount: Int { snapshot.rows.filter { selected.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SuggestionsHeaderRow()
            ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                SuggestionRowView(
                    row: row, index: index, categories: snapshot.categories, onAccept: onAccept, onChange: onChange,
                    isSelected: Binding(
                        get: { selected.contains(row.id) },
                        set: { on in
                            if on { selected.insert(row.id) } else { selected.remove(row.id) }
                        }))
            }
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                IMMIcon("cpu", size: 12, color: IMMColor.mutedForeground)
                Text("Worked out on this Mac", bundle: .module)
                    .immFont(.caption)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            Spacer(minLength: 0)
            Text("\(selectedCount) of \(snapshot.rows.count) selected", bundle: .module)
                .immFont(IMMFont.small.withLineHeight(18))
                .foregroundStyle(IMMColor.mutedForeground)
        }
        .padding(.top, 10)
        .padding(.horizontal, 8)
    }
}

private struct SuggestionsHeaderRow: View {
    @Environment(\.immWindowWidth) private var windowWidth

    var body: some View {
        let gap = Columns.gap(windowWidth: windowWidth)
        HStack(spacing: gap) {
            Color.clear.frame(width: Columns.checkbox, height: 1)
            heading(Text("Date", bundle: .module)).frame(width: Columns.date, alignment: .leading)
            SuggestionCellLayout(
                columnSpacing: gap, bases: [170, Columns.category(windowWidth: windowWidth), 170],
                grows: [1, 0, 1], shrinks: [1, 0, 1]
            ) {
                heading(Text("Payee and purpose", bundle: .module)).frame(maxWidth: .infinity, alignment: .leading)
                heading(Text("Suggested category", bundle: .module)).frame(maxWidth: .infinity, alignment: .leading)
                heading(Text("Why", bundle: .module)).frame(maxWidth: .infinity, alignment: .leading)
            }
            heading(Text("Amount", bundle: .module)).frame(width: Columns.amount, alignment: .trailing)
            Color.clear.frame(width: Columns.actions, height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 31)
        .padding(.bottom, 1)
        .overlay(alignment: .bottom) { Rule() }
    }

    private func heading(_ text: Text) -> some View {
        text.immFont(.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
    }
}

/// One suggestion: checkbox, date, payee and purpose, suggested category with its confidence badge,
/// the reason with its source number, the amount and the Accept / Change buttons. The row as a whole
/// opens the transaction in its account; the checkbox only marks the row, Accept files it under the
/// suggested category and Change opens a menu of categories.
private struct SuggestionRowView: View {
    let row: SuggestionRow
    let index: Int
    let categories: [TransactionCategory]
    let onAccept: (SuggestionRow) -> Void
    let onChange: (SuggestionRow, String) -> Void
    @Binding var isSelected: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.immWindowWidth) private var windowWidth

    var body: some View {
        let gap = Columns.gap(windowWidth: windowWidth)
        HStack(spacing: gap) {
                IMMCheckbox(isOn: $isSelected)
                    .frame(width: Columns.checkbox, alignment: .leading)
                Text(verbatim: DateFormats.dayMonth(row.date))
                    .immFont(IMMFont.body.tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .frame(width: Columns.date, alignment: .leading)
                    .allowsHitTesting(false)
                cell(gap: gap)
                    .allowsHitTesting(false)
                Text(verbatim: MoneyFormatter.string(row.amount, sign: .always))
                    .immFont(IMMFont.body.tabular)
                    .foregroundStyle(row.amount > 0 ? IMMColor.credit : IMMColor.foreground)
                    .lineLimit(1)
                    .frame(width: Columns.amount, alignment: .trailing)
                    .allowsHitTesting(false)
                HStack(spacing: 4) {
                    Button {
                        onAccept(row)
                    } label: {
                        Text("Accept", bundle: .module)
                    }
                    .immButtonStyle(.outline, size: .sm)
                    .disabled(row.suggestedCategoryID == nil)
                    Menu {
                        ForEach(categories) { category in
                            Button(category.name) { onChange(row, category.id) }
                        }
                    } label: {
                        Text("Change", bundle: .module)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .immButtonStyle(.ghost, size: .sm)
                    .fixedSize()
                }
                .frame(width: Columns.actions, alignment: .trailing)
        }
        .padding(8)
        .background {
            DataRow(bleed: 0, action: { model.showTransaction(id: row.id, accountID: row.accountID) }) {
                Color.clear
            }
            .clipShape(RoundedRectangle(cornerRadius: 4.32, style: .continuous))
            .accessibilityLabel(Text(verbatim: "\(row.payee), \(MoneyFormatter.string(row.amount))"))
        }
        .padding(.bottom, 1)
        .frame(minHeight: 53)
        .overlay(alignment: .bottom) { Rule() }
        .immRiseIn(duration: 0.3, delay: Double(index) * 0.04)
    }

    private func cell(gap: CGFloat) -> some View {
        SuggestionCellLayout(
            columnSpacing: gap, bases: [170, Columns.category(windowWidth: windowWidth), 170],
            grows: [1, 0, 1], shrinks: [1, 0, 1]
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: row.payee)
                    .immFont(.bodyMedium)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: row.purpose)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                LegendDot(IMMColor.named(row.colorToken))
                Text(verbatim: row.suggestedCategory)
                    .immFont(.body)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                badge
            }
            .frame(maxWidth: .infinity)

            reason
        }
    }

    private var badge: some View {
        let variant: Badge<Text>.Variant
        switch row.confidence {
        case .sure: variant = .secondary
        case .likely: variant = .outline
        case .check: variant = .warning
        }
        return Badge(verbatim: row.confidenceLabel, variant: variant)
            .immFadeIn(duration: 0.2, delay: 0.16 + Double(index) * 0.04)
    }

    private var reasonText: some View {
        Text(verbatim: row.reason)
            .immFont(.small)
            .foregroundStyle(IMMColor.mutedForeground)
    }

    @ViewBuilder
    private var reason: some View {
        if let number = row.sourceNumber {
            TextWithLinkLayout {
                reasonText
                    .fixedSize(horizontal: false, vertical: true)
                SourceLink(number: number)
            }
        } else {
            reasonText
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// `[4]`: a source number in the primary colour; underlined on hover.
struct SourceLink: View {
    let number: Int
    @State private var hovering = false

    var body: some View {
        Text(verbatim: "[\(number)]")
            .immFont(IMMFont.caption.weighted(.medium))
            .foregroundStyle(IMMColor.primary)
            .underline(hovering, color: IMMColor.primary)
            .onHover { hovering = $0 }
    }
}
