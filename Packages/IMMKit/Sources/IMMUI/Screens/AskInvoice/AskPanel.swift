import IMMDesign
import IMMLedger
import Observation
import SwiftUI

/// Holds the stored answer and follows the open ledger.
@MainActor @Observable
final class AskModel {
    private(set) var answer: AskAnswer?

    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(AskQueries.answer) { answer = initial }
        do {
            for try await value in AskQueries.observe(in: ledger) {
                answer = value
            }
        } catch {
            // Locked or closed: keep the last answer; the shell removes the panel.
        }
    }
}

/// The Ask panel (⌘K): the one designed question with its stored answer. The panel shell (dim, 720 pt
/// width, top 72, corner radius, shadow, pop-in) is `PanelHost`. No model runs and nothing can be typed:
/// the field shows the question read-only.
public struct AskPanel: View {
    @Environment(AppModel.self) private var model
    @State private var ask = AskModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            AskHeader(question: ask.answer?.question ?? "")
            if let answer = ask.answer {
                AskAnswerBody(answer: answer, showAll: showAll)
                AskActions(actions: answer.actions) { index in open(action: index) }
                AskPrivacyFooter()
            }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await ask.follow(ledger: ledger)
        }
    }

    private func showAll() {
        model.closePanel()
        model.navigate(to: .transactions(.all))
    }

    /// Follow-up buttons in stored order: budget, comparison, invoice.
    private func open(action index: Int) {
        let route: MainRoute
        switch index {
        case 0: route = .budgets
        case 1: route = .categories
        default: route = .payInvoice
        }
        model.closePanel()
        model.navigate(to: route)
    }
}

// MARK: - Header

private struct AskHeader: View {
    let question: String

    var body: some View {
        HStack(spacing: 10) {
            IMMIcon("search", size: 16, color: IMMColor.mutedForeground)
            Text(verbatim: question)
                .immFont(.bodyLG)
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Question", bundle: .module))
                .accessibilityValue(Text(verbatim: question))
            Kbd("esc")
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rule() }
    }
}

// MARK: - Answer

private struct AskAnswerBody: View {
    let answer: AskAnswer
    let showAll: () -> Void

    @Environment(\.immWindowWidth) private var windowWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .bottom, spacing: 32) {
                headline
                    .frame(maxWidth: .infinity, alignment: .leading)
                AskMonthlyChart(months: answer.monthly, caption: answer.monthlyCaption)
            }
            AskWhereItWent(answer: answer)
            sources
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .immRiseIn(duration: 0.26, delay: 0.16)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: answer.headline)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
            HStack(spacing: 10) {
                Text(verbatim: MoneyFormatter.string(answer.total))
                    .immFont(IMMFont.amountHero.sized(IMMLayout.heroFontSize(windowWidth: windowWidth)))
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .fixedSize()
                Badge(verbatim: answer.confidenceLabel, variant: .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: answer.summary)
                    .immFont(.body)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                AskFootnote(number: answer.summarySourceNumber)
            }
        }
    }

    private var sources: some View {
        HStack(spacing: 12) {
            Text("Sources", bundle: .module)
                .immFont(.captionSemibold)
                .foregroundStyle(IMMColor.mutedForeground)
            Text("\(answer.transactionCount) transactions", bundle: .module)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            AskShowAllButton(action: showAll)
        }
        .frame(height: 24)
    }
}

/// `[1]`: a source footnote. The design has no target for it.
private struct AskFootnote: View {
    let number: Int
    @State private var hovering = false

    var body: some View {
        Text(verbatim: "[\(number)]")
            .immFont(IMMFont.caption.tabular)
            .foregroundStyle(IMMColor.primary)
            .underline(hovering, color: IMMColor.primary)
            .onHover { hovering = $0 }
            .inertControl()
    }
}

private struct AskShowAllButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("Show all", bundle: .module)
                    .immFont(.smallMedium)
                IMMIcon("chevron-down", size: 14)
            }
            .foregroundStyle(IMMColor.primary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: IMMRadius.sm, style: .continuous)
                    .fill(hovering ? IMMColor.muted : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -6)
        .onHover { hovering = $0 }
    }
}

// MARK: - Monthly chart

private struct AskMonthlyChart: View {
    let months: [AskMonthBar]
    let caption: String

    private static let maxBarHeight: CGFloat = 64

    var body: some View {
        let top = max(1, months.map(\.amount).max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                    let height = (CGFloat(month.amount) / CGFloat(top) * Self.maxBarHeight).rounded()
                    VStack(spacing: 4) {
                        Text(verbatim: String(Int((Double(month.amount) / 100).rounded())))
                            .immFont(IMMFont.caption.withLineHeight(14).tabular)
                            .foregroundStyle(IMMColor.mutedForeground)
                            .lineLimit(1)
                            .fixedSize()
                        UnevenRoundedRectangle(
                            topLeadingRadius: IMMRadius.sm, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                            topTrailingRadius: IMMRadius.sm, style: .continuous
                        )
                        .fill(month.partial ? IMMColor.chart2.opacity(0.35) : IMMColor.chart2)
                        .frame(width: 20, height: height)
                        .immGrowY(duration: 0.3, delay: 0.22 + 0.03 * Double(index))
                    }
                    .frame(width: 28)
                }
            }
            Rectangle().fill(IMMColor.border).frame(height: 1)
            HStack(spacing: 8) {
                ForEach(months) { month in
                    Text(verbatim: month.label)
                        .immFont(IMMFont.caption.withLineHeight(14))
                        .foregroundStyle(IMMColor.mutedForeground)
                        .frame(width: 28)
                }
            }
            Text(verbatim: caption)
                .immFont(IMMFont.caption.withLineHeight(14))
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: caption))
        .accessibilityValue(Text(verbatim: months.map { "\($0.label) \(Int((Double($0.amount) / 100).rounded()))" }.joined(separator: ", ")))
    }
}

// MARK: - Where it went

private struct AskWhereItWent: View {
    let answer: AskAnswer

    private static let countWidth: CGFloat = 96
    private static let noteWidth: CGFloat = 24
    private static let amountWidth: CGFloat = 112

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Where it went", bundle: .module)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Count", bundle: .module)
                    .frame(width: Self.countWidth, alignment: .leading)
                Color.clear.frame(width: Self.noteWidth, height: 1)
                Text("Amount", bundle: .module)
                    .frame(width: Self.amountWidth, alignment: .trailing)
            }
            .immFont(.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .frame(height: 24)

            ForEach(answer.groups) { group in
                HStack(spacing: 12) {
                    Text(verbatim: group.name)
                        .immFont(.body)
                        .foregroundStyle(IMMColor.foreground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: group.countText)
                        .immFont(IMMFont.small.tabular)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                        .frame(width: Self.countWidth, alignment: .leading)
                    AskFootnote(number: group.sourceNumber)
                        .frame(width: Self.noteWidth, alignment: .leading)
                    Text(verbatim: MoneyFormatter.string(group.amount))
                        .immFont(IMMFont.body.tabular)
                        .foregroundStyle(IMMColor.foreground)
                        .frame(width: Self.amountWidth, alignment: .trailing)
                }
                .frame(height: 36)
                .overlay(alignment: .bottom) { Rule() }
            }

            TotalRow {
                Text(verbatim: answer.totalLabel)
                    .immFont(.bodySemibold)
                    .foregroundStyle(IMMColor.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(answer.transactionCount) payments", bundle: .module)
                    .immFont(IMMFont.small.tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .frame(width: Self.countWidth, alignment: .leading)
                Color.clear.frame(width: Self.noteWidth, height: 1)
                Text(verbatim: MoneyFormatter.string(answer.total))
                    .immFont(IMMFont.bodySemibold.tabular)
                    .foregroundStyle(IMMColor.foreground)
                    .frame(width: Self.amountWidth, alignment: .trailing)
            }
        }
    }
}

// MARK: - Actions and footer

private struct AskActions: View {
    let actions: [String]
    let open: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, title in
                Button { open(index) } label: { Text(verbatim: title) }
                    .immButtonStyle(.outline, size: .sm)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rule() }
    }
}

private struct AskPrivacyFooter: View {
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                IMMIcon("cpu", size: 14)
                Text("Worked out on this Mac", bundle: .module)
            }
            Spacer(minLength: 0)
            Text("Nothing left this Mac", bundle: .module)
        }
        .immFont(.caption)
        .foregroundStyle(IMMColor.mutedForeground)
        .padding(.horizontal, 24)
        .frame(height: 36)
        .overlay(alignment: .top) { Rule() }
    }
}
