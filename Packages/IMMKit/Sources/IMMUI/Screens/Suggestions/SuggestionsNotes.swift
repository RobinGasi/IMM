import IMMDesign
import IMMLedger
import SwiftUI

/// "Also noticed": a possible double charge (button leads to the account's transactions) and a rule
/// suggestion (button leads to Categories; creating the rule itself is not available yet).
struct SuggestionsNoticed: View {
    let notices: [SuggestionNotice]

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Also noticed", bundle: .module)
                .immFont(.titleMD.withLineHeight(22))
                .foregroundStyle(IMMColor.foreground)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 1)
                .overlay(alignment: .bottom) { Rule() }
            ForEach(notices) { notice in
                row(notice)
            }
        }
    }

    private func row(_ notice: SuggestionNotice) -> some View {
        HStack(spacing: 16) {
            text(notice)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let title = notice.actionTitle {
                    Button {
                        open(notice)
                    } label: {
                        Text(verbatim: title)
                    }
                    .immButtonStyle(.outline, size: .sm)
                }
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(8)
        .padding(.bottom, 1)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rule() }
    }

    @ViewBuilder
    private func text(_ notice: SuggestionNotice) -> some View {
        let label = Text(verbatim: notice.text)
            .immFont(.body)
            .foregroundStyle(notice.variant == .doubleCharge ? IMMColor.warning : IMMColor.foreground)
            .fixedSize(horizontal: false, vertical: true)
        if let number = notice.sourceNumber {
            TextWithLinkLayout(spacing: 4) {
                label
                SourceLink(number: number)
            }
        } else {
            label
        }
    }

    private func open(_ notice: SuggestionNotice) {
        switch notice.variant {
        case .doubleCharge:
            model.navigate(to: .transactions(notice.accountID.map(AccountScope.account) ?? .all))
        case .newRule:
            model.navigate(to: .categories)
        }
    }
}

/// "Sources": the numbered transactions behind the reasons. A number repeats only on its first line.
struct SuggestionsSources: View {
    let sources: [SuggestionSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sources", bundle: .module)
                .immFont(IMMFont.captionSemibold.withLineHeight(16.5))
                .foregroundStyle(IMMColor.mutedForeground)
                .padding(.bottom, 5)
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                HStack(spacing: 12) {
                    Group {
                        if index == 0 || sources[index - 1].number != source.number {
                            Text(verbatim: "[\(source.number)]")
                                .immFont(IMMFont.small.weighted(.medium).withLineHeight(20))
                                .foregroundStyle(IMMColor.primary)
                        } else {
                            Color.clear.frame(height: 20)
                        }
                    }
                    .frame(width: 28, alignment: .leading)
                    Text(verbatim: source.dateText)
                        .immFont(IMMFont.small.tabular.withLineHeight(20))
                        .foregroundStyle(IMMColor.mutedForeground)
                        .frame(width: 80, alignment: .leading)
                    Text(verbatim: source.label)
                        .immFont(IMMFont.small.withLineHeight(20))
                        .foregroundStyle(IMMColor.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: source.amount.map { MoneyFormatter.string($0) } ?? "")
                        .immFont(IMMFont.small.tabular.withLineHeight(20))
                        .foregroundStyle(IMMColor.foreground)
                        .frame(width: 104, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: 760, alignment: .leading)
    }
}
