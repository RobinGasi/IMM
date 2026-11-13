import IMMDesign
import IMMLedger
import SwiftUI

/// The tax return: possible deductions grouped by form, from the stored `tax` insight and the ledger
/// rows it cites. Rows open their payment in the Transactions inspector. The screen fills the detail area
/// (`MainRoute.managesOwnScrolling`): header and tabs are fixed and the rows scroll. The check boxes and the two
/// export buttons would change or leave the data and are inert; the tabs filter the list.
public struct TaxReturnScreen: View {
    @Environment(AppModel.self) private var model
    @State private var tax = TaxModel()

    public init() {}

    public var body: some View {
        Group {
            if let snapshot = tax.snapshot {
                TaxLayout(snapshot: snapshot)
            } else {
                Color.clear
            }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await tax.follow(ledger: ledger)
        }
    }
}

private enum TaxTab: Hashable {
    case all, needsReceipt, excluded
}

/// Column widths of the design's grid `20px 64px 1fr 1fr 120px 104px`, 16 pt apart.
private enum TaxColumns {
    static let check: CGFloat = 20
    static let date: CGFloat = 64
    static let receipt: CGFloat = 120
    static let amount: CGFloat = 104
    static let spacing: CGFloat = 16
    static let side: CGFloat = 32
}

private struct TaxLayout: View {
    let snapshot: TaxSnapshot

    @State private var tab: TaxTab = .all

    private var visibleGroups: [TaxGroupRows] {
        switch tab {
        case .all:
            return snapshot.groups
        case .needsReceipt:
            return snapshot.groups.compactMap { group in
                let rows = group.rows.filter { $0.receipt == .needed }
                return rows.isEmpty ? nil : TaxGroupRows(form: group.form, rows: rows)
            }
        case .excluded:
            return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaxHeader(snapshot: snapshot)
            tabsRow
            // Header and tabs stay put; the rows scroll under them, as drawn.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    TaxColumnHeader()
                    if tab == .excluded {
                        Text("Nothing is excluded.", bundle: .module)
                            .immFont(.small)
                            .foregroundStyle(IMMColor.mutedForeground)
                            .padding(.horizontal, TaxColumns.side)
                            .padding(.vertical, 16)
                    } else {
                        groups
                        TaxTotalRow(groups: visibleGroups)
                    }
                    footnotes
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tabsRow: some View {
        HStack(spacing: 16) {
            SegmentedTabs(selection: $tab, options: [
                IMMOption(.all, Text("All", bundle: .module)),
                IMMOption(.needsReceipt, Text("Needs receipt (\(snapshot.needsReceiptCount))", bundle: .module)),
                IMMOption(.excluded, Text("Excluded", bundle: .module)),
            ])
            Spacer(minLength: 0)
            Text(verbatim: summary)
                .immFont(IMMFont.small.tabular)
                .foregroundStyle(IMMColor.mutedForeground)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .padding(.horizontal, TaxColumns.side)
    }

    /// `8 items from Girokonto and Visa Card, 4 with receipts`
    private var summary: String {
        let names = snapshot.accountNames
        let list: String
        switch names.count {
        case 0: list = ""
        case 1: list = names[0]
        default: list = names.dropLast().joined(separator: ", ") + " " + String(localized: "and", bundle: .module) + " " + (names.last ?? "")
        }
        return String(localized: "\(snapshot.itemCount) items from \(list), \(snapshot.withReceiptCount) with receipts", bundle: .module)
    }

    private var groups: some View {
        let offsets = groupOffsets
        return VStack(spacing: 0) {
            ForEach(Array(visibleGroups.enumerated()), id: \.element.id) { groupIndex, group in
                VStack(spacing: 0) {
                    TaxGroupHeader(group: group)
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { rowIndex, row in
                        TaxRowView(row: row)
                            .immRiseIn(duration: 0.26, delay: 0.03 * Double(offsets[groupIndex] + rowIndex))
                    }
                }
            }
        }
    }

    /// Index of the first row of every visible group over all visible rows (staggers the entrance).
    private var groupOffsets: [Int] {
        var offsets: [Int] = []
        var total = 0
        for group in visibleGroups {
            offsets.append(total)
            total += group.rows.count
        }
        return offsets
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: snapshot.footnotes.joined(separator: " "))
            Text(verbatim: snapshot.disclaimer)
        }
        .immFont(.small)
        .foregroundStyle(IMMColor.mutedForeground)
        .frame(maxWidth: 960, alignment: .leading)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .padding(.horizontal, TaxColumns.side)
    }
}

// MARK: Header

private struct TaxHeader: View {
    let snapshot: TaxSnapshot

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 24) {
                figures
                Spacer(minLength: 0)
                buttons
            }
            VStack(alignment: .leading, spacing: 16) {
                figures
                buttons
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 17)
        .padding(.horizontal, TaxColumns.side)
        .overlay(alignment: .bottom) { Rule() }
    }

    private var figures: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                IMMIcon("laptop", size: 12)
                Text("Worked out on this Mac", bundle: .module)
                    .immFont(IMMFont.captionSemibold.weighted(.medium))
            }
            .foregroundStyle(IMMColor.mutedForeground)
            Text(verbatim: MoneyFormatter.string(snapshot.total))
                .immFont(.display)
                .foregroundStyle(IMMColor.foreground)
                .frame(height: 38)
            Text(verbatim: snapshot.totalCaption)
                .immFont(IMMFont.body)
                .foregroundStyle(IMMColor.mutedForeground)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {} label: {
                Text("Share with tax advisor…", bundle: .module)
            }
            .immButtonStyle(.outline)
            .inertControl()
            Button {} label: {
                HStack(spacing: 4) {
                    IMMIcon("download", size: 14)
                    Text("Export for ELSTER (CSV + PDFs)", bundle: .module)
                }
            }
            .immButtonStyle(.default, leadingIcon: true)
            .inertControl()
        }
    }
}

private struct TaxColumnHeader: View {
    var body: some View {
        HStack(spacing: TaxColumns.spacing) {
            Color.clear.frame(width: TaxColumns.check, height: 0)
            Text("Date", bundle: .module).frame(width: TaxColumns.date, alignment: .leading)
            Text("Payee and purpose", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
            Text("Why it counts", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
            Text("Receipt", bundle: .module).frame(width: TaxColumns.receipt, alignment: .leading)
            Text("Amount", bundle: .module).frame(width: TaxColumns.amount, alignment: .trailing)
        }
        .immFont(.captionSemibold)
        .foregroundStyle(IMMColor.mutedForeground)
        .padding(.horizontal, TaxColumns.side)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rule() }
    }
}

// MARK: Groups and rows

private struct TaxGroupHeader: View {
    let group: TaxGroupRows

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: TaxColumns.spacing) {
                title
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: MoneyFormatter.string(group.total))
                    .immFont(IMMFont.bodySemibold.tabular)
                    .foregroundStyle(IMMColor.foreground)
                    .frame(width: TaxColumns.amount, alignment: .trailing)
                    .immFadeIn(duration: 0.2)
            }
            .frame(height: 21)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .padding(.horizontal, TaxColumns.side)
            Rule()
        }
    }

    /// `Anlage N — Werbungskosten` and, smaller and muted, `3 items`.
    private var title: some View {
        let count = group.rows.count == 1
            ? String(localized: "1 item", bundle: .module)
            : String(localized: "\(group.rows.count) items", bundle: .module)
        var text = AttributedString(group.form + " ")
        text.font = IMMFont.titleMD.font
        text.foregroundColor = IMMColor.foreground
        var detail = AttributedString("  " + count)
        detail.font = IMMFont.small.font
        detail.foregroundColor = IMMColor.mutedForeground
        text += detail
        return Text(text)
    }
}

private struct TaxRowView: View {
    let row: TaxRow

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                DataRow(bleed: 0, action: open) {
                    HStack(spacing: TaxColumns.spacing) {
                        Color.clear.frame(width: TaxColumns.check, height: 0)
                        Text(verbatim: DateFormats.dayMonth(row.date))
                            .immFont(IMMFont.body.tabular)
                            .frame(width: TaxColumns.date, alignment: .leading)
                        payee
                        Text(verbatim: row.why)
                            .immFont(.small)
                            .foregroundStyle(IMMColor.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Badge(Text(verbatim: row.receiptLabel), variant: row.receipt == .needed ? .warning : .secondary)
                            .frame(width: TaxColumns.receipt, alignment: .leading)
                        Text(verbatim: MoneyFormatter.string(row.amount))
                            .immFont(IMMFont.body.tabular)
                            .frame(width: TaxColumns.amount, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, TaxColumns.side)
                    .frame(minHeight: 42)
                }
                // Inert: shown checked, cannot be toggled.
                IMMCheckbox(isOn: .constant(true))
                    .inertControl()
                    .padding(.leading, TaxColumns.side)
            }
            Rule()
        }
    }

    private var payee: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: row.payee)
                .immFont(IMMFont.body.withLineHeight(18))
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 18)
            Text(verbatim: row.purpose)
                .immFont(IMMFont.small)
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open() {
        guard let first = row.firstTransaction else { return }
        model.showTransaction(id: first.id, accountID: first.accountID)
    }
}

private struct TaxTotalRow: View {
    let groups: [TaxGroupRows]

    private var rowCount: Int { groups.reduce(0) { $0 + $1.rows.count } }
    private var total: Int { groups.reduce(0) { $0 + $1.total } }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TaxColumns.spacing) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: MoneyFormatter.string(total))
                .immFont(IMMFont.bodySemibold.tabular)
                .foregroundStyle(IMMColor.foreground)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .frame(width: TaxColumns.amount, alignment: .trailing)
                .overlay(alignment: .top) { Rule() }
                .overlay(alignment: .bottom) { DoubleRule() }
                .padding(.bottom, 3)
        }
        .padding(.top, 10)
        .padding(.horizontal, TaxColumns.side)
    }

    /// `Possible deductions` and, regular and muted, `8 items on 4 forms`.
    private var label: some View {
        let items = rowCount == 1
            ? String(localized: "1 item", bundle: .module)
            : String(localized: "\(rowCount) items", bundle: .module)
        let forms = groups.count == 1
            ? String(localized: "1 form", bundle: .module)
            : String(localized: "\(groups.count) forms", bundle: .module)
        var text = AttributedString(String(localized: "Possible deductions", bundle: .module) + " ")
        text.font = IMMFont.bodySemibold.font
        text.foregroundColor = IMMColor.foreground
        var detail = AttributedString("  " + String(localized: "\(items) on \(forms)", bundle: .module))
        detail.font = IMMFont.body.font
        detail.foregroundColor = IMMColor.mutedForeground
        text += detail
        return Text(text)
    }
}
