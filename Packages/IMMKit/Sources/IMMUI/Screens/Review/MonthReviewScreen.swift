import IMMDesign
import IMMLedger
import SwiftUI

/// The month review (October review): the stored sentences, the figures of the month computed from
/// the ledger next to the six-month average, the findings with their bars, the cited sources, the
/// outlook chart and the suggested next steps. No model runs; "Worked out on this Mac" is the design's chip.
public struct MonthReviewScreen: View {
    @Environment(AppModel.self) private var model
    @State private var review = ReviewModel()

    public init() {}

    public var body: some View {
        Group {
            if let snapshot = review.snapshot {
                ReviewLayout(snapshot: snapshot)
            } else {
                Color.clear
            }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await review.follow(ledger: ledger)
        }
    }
}

private struct ReviewLayout: View {
    let snapshot: ReviewSnapshot

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            header
            ReviewColumns {
                leftColumn
                rightColumn
            }
        }
        .padding(.top, 28)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: snapshot.headline)
                    .immFont(.titleXLMedium)
                    .foregroundStyle(IMMColor.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
                HStack(spacing: 6) {
                    IMMIcon("cpu", size: 13)
                    Text("Worked out on this Mac", bundle: .module)
                        .immFont(.small)
                }
                .foregroundStyle(IMMColor.mutedForeground)
            }
            .immRiseIn(duration: 0.4)
            Spacer(minLength: 0)
            Button {} label: {
                HStack(spacing: 4) {
                    IMMIcon("file", size: 12)
                    Text("Export as PDF", bundle: .module)
                }
            }
            .immButtonStyle(.outline, leadingIcon: true)
            .inertControl()
        }
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 32) {
            ledgerTable
            findings
            sources
        }
        .padding(.trailing, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var monthName: String { DateFormats.monthName(snapshot.month) }

    private var ledgerTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(monthName) in the ledger", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    Text(verbatim: monthName).frame(width: 128, alignment: .trailing)
                    Text("6-month average", bundle: .module).frame(width: 128, alignment: .trailing)
                }
                .immFont(IMMFont.captionSemibold.withLineHeight(18))
                .foregroundStyle(IMMColor.mutedForeground)
                .padding(.bottom, 6)
                tableRow(
                    Text("Income", bundle: .module),
                    month: MoneyFormatter.string(snapshot.income, sign: .always), monthColor: IMMColor.credit,
                    average: MoneyFormatter.string(snapshot.incomeAverage, sign: .always))
                tableRow(
                    Text("Spending", bundle: .module),
                    month: MoneyFormatter.string(-snapshot.spending), monthColor: IMMColor.foreground,
                    average: MoneyFormatter.string(-snapshot.spendingAverage))
                tableRow(
                    Text("Saved", bundle: .module),
                    month: MoneyFormatter.string(snapshot.saved), monthColor: IMMColor.foreground,
                    average: MoneyFormatter.string(snapshot.savedAverage), isTotal: true)
            }
        }
    }

    private func tableRow(_ label: Text, month: String, monthColor: Color, average: String, isTotal: Bool = false) -> some View {
        let font = isTotal ? IMMFont.bodySemibold.withLineHeight(18).tabular : IMMFont.body.withLineHeight(18).tabular
        return VStack(spacing: 0) {
            Rule()
            HStack(spacing: 0) {
                label
                    .immFont(font)
                    .foregroundStyle(IMMColor.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: month)
                    .immFont(font)
                    .foregroundStyle(monthColor)
                    .frame(width: 128, alignment: .trailing)
                Text(verbatim: average)
                    .immFont(IMMFont.body.withLineHeight(18).tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .frame(width: 128, alignment: .trailing)
            }
            .padding(.vertical, 7)
            if isTotal { DoubleRule() }
        }
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("What changed", bundle: .module)
                    .immFont(.titleMD)
                    .foregroundStyle(IMMColor.foreground)
                Badge(Text("Sure", bundle: .module))
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(IMMColor.mutedForeground)
                        .frame(width: 14, height: 6)
                    Text(verbatim: monthName)
                    Rectangle().fill(IMMColor.foreground).frame(width: 2, height: 10).padding(.leading, 6)
                    Text("6-month average", bundle: .module)
                }
                .immFont(.caption)
                .foregroundStyle(IMMColor.mutedForeground)
            }
            VStack(spacing: 0) {
                ForEach(Array(snapshot.findings.enumerated()), id: \.element.id) { index, finding in
                    ReviewFindingRowView(finding: finding, scale: snapshot.barScale)
                        .immRiseIn(duration: 0.3, delay: 0.12 + 0.06 * Double(index))
                }
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources", bundle: .module)
                .immFont(.captionSemibold)
                .foregroundStyle(IMMColor.mutedForeground)
            VStack(spacing: 0) {
                ForEach(Array(snapshot.sources.enumerated()), id: \.element.id) { index, source in
                    DataRow(height: 28, bleed: 0, action: { open(source) }) {
                        HStack(spacing: 12) {
                            Text(verbatim: "[\(source.number)]")
                                .immFont(IMMFont.caption.withLineHeight(16))
                                .foregroundStyle(IMMColor.primary)
                                .frame(width: 24, alignment: .leading)
                            Text(verbatim: source.dateText)
                                .foregroundStyle(IMMColor.mutedForeground)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(width: 100, alignment: .leading)
                            Text(verbatim: source.label)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: MoneyFormatter.string(source.amount))
                                .frame(width: 84, alignment: .trailing)
                        }
                        .immFont(IMMFont.small.tabular)
                    }
                    .overlay(alignment: .top) { Rule() }
                    .overlay(alignment: .bottom) { if index == snapshot.sources.count - 1 { Rule() } }
                }
            }
        }
    }

    /// A source with cited payments opens the first one in the Transactions inspector.
    private func open(_ source: ReviewSourceRow) {
        guard let first = source.transactions.first else { return }
        model.showTransaction(id: first.id, accountID: first.accountID)
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 32) {
            outlook
            steps
        }
        .padding(.leading, 33)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            Rectangle().fill(IMMColor.border).frame(width: 1)
        }
    }

    private var outlook: some View {
        let outlook = snapshot.outlook
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("\(DateFormats.monthName(outlook.endDate)) outlook", bundle: .module)
                        .immFont(.titleMD)
                        .foregroundStyle(IMMColor.foreground)
                    Badge(Text("Likely", bundle: .module), variant: .outline)
                }
                Text(
                    "\(outlook.accountName) balance from \(DateFormats.dayMonth(outlook.startDate)) to \(DateFormats.dayMonthYear(outlook.endDate)), based on your recurring payments",
                    bundle: .module
                )
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
            }
            VStack(alignment: .leading, spacing: 6) {
                ReviewOutlookChart(outlook: outlook)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: outlook.rangeText)
                        .immFont(IMMFont.bodySemibold.withLineHeight(18).tabular)
                        .foregroundStyle(IMMColor.foreground)
                    Text(verbatim: outlook.rentText + " " + String(localized: "Shaded: the likely range.", bundle: .module))
                        .immFont(IMMFont.small.withLineHeight(17).tabular)
                        .foregroundStyle(IMMColor.mutedForeground)
                }
                .padding(.top, 8)
            }
            .padding(.trailing, 52)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggested next steps", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
                .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(snapshot.steps.enumerated()), id: \.element.id) { index, step in
                    ReviewFlexRow(columnSpacing: 16, rowSpacing: 8) {
                        stepText(step).reviewFlex(basis: 240, grow: 1)
                        stepButton(step).reviewFlex()
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .top) { Rule() }
                    .overlay(alignment: .bottom) { if index == snapshot.steps.count - 1 { Rule() } }
                }
            }
        }
    }

    private func stepText(_ step: ReviewStepRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: step.title)
                .immFont(IMMFont.body.withLineHeight(18))
                .foregroundStyle(IMMColor.foreground)
                .fixedSize(horizontal: false, vertical: true)
            reviewMarkedText(step.detail, markers: step.sourceNumber.map { [$0] } ?? [])
                .immFont(IMMFont.small.withLineHeight(17))
                .foregroundStyle(IMMColor.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stepButton(_ step: ReviewStepRow) -> some View {
        if let transfer = step.transfer {
            Button {
                model.openNewTransfer(TransferDraft(
                    fromAccount: transfer.fromAccountID, recipient: transfer.recipient, iban: transfer.iban,
                    amountMinor: transfer.amount))
            } label: {
                Text(verbatim: step.actionTitle)
            }
            .immButtonStyle(.default)
        } else {
            Button {} label: {
                Text(verbatim: step.actionTitle)
            }
            .immButtonStyle(.outline)
            .inertControl()
        }
    }
}

/// One finding: number, coloured dot with the stored sentence, bar against the six-month average
/// marker and the difference. A click goes to Categories.
private struct ReviewFindingRowView: View {
    let finding: ReviewFindingRow
    let scale: Int

    @Environment(AppModel.self) private var model

    private var color: Color { IMMColor.named(finding.colorToken) }

    var body: some View {
        DataRow(bleed: 8, action: { model.navigate(to: .categories) }) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: String(finding.number))
                    .immFont(IMMFont.small.withLineHeight(18).tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .frame(width: 16, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                ReviewFlexRow(columnSpacing: 12, rowSpacing: 8) {
                    text.reviewFlex(basis: 260, grow: 1)
                    bar.reviewFlex(basis: 112)
                    Text(verbatim: finding.deltaText)
                        .immFont(IMMFont.body.withLineHeight(18).tabular)
                        .foregroundStyle(IMMColor.foreground)
                        .frame(width: 64, alignment: .trailing)
                        .reviewFlex(basis: 64)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(verbatim: finding.title)
                    .immFont(IMMFont.bodySemibold.withLineHeight(18))
                    .foregroundStyle(IMMColor.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            reviewMarkedText(finding.detail, markers: finding.sourceNumbers)
                .immFont(IMMFont.small.withLineHeight(17))
                .foregroundStyle(IMMColor.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bar: some View {
        let width: CGFloat = 112
        let fraction = min(1, CGFloat(finding.monthAmount) / CGFloat(max(scale, 1)))
        let marker = min(1, CGFloat(finding.averageAmount) / CGFloat(max(scale, 1)))
        return RoundedRectangle(cornerRadius: 3, style: .continuous).fill(IMMColor.muted)
            .frame(width: width, height: 6)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color)
                    .frame(width: width * fraction, height: 6)
                    .immGrowX(duration: 0.4, delay: 0.2)
            }
            .overlay(alignment: .topLeading) {
                Rectangle().fill(IMMColor.foreground)
                    .frame(width: 2, height: 12)
                    .offset(x: width * marker, y: -3)
            }
    }
}

/// A stored sentence followed by its source markers `[1] [2]` in the primary colour (11 pt).
private func reviewMarkedText(_ sentence: String, markers: [Int]) -> Text {
    var text = AttributedString(sentence)
    for number in markers {
        var marker = AttributedString(" [\(number)]")
        marker.font = IMMFont.caption.font
        marker.foregroundColor = IMMColor.primary
        text += marker
    }
    return Text(text)
}
