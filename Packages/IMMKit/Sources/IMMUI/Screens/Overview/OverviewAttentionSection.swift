import IMMDesign
import IMMLedger
import SwiftUI

/// "Needs attention": the stored attention insights. A row with an action title carries its own
/// button; the others are links as a whole and end in a chevron.
struct OverviewAttentionSection: View {
    let attention: [OverviewAttention]

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                Text("Needs attention", bundle: .module),
                detail: attention.count == 1
                    ? Text("1 item", bundle: .module)
                    : Text("\(attention.count) items", bundle: .module))
            VStack(spacing: 0) {
                ForEach(Array(attention.enumerated()), id: \.element.id) { index, item in
                    row(item, isLast: index == attention.count - 1)
                }
            }
            .padding(.top, 8)
        }
    }

    private func destination(_ item: OverviewAttention) -> MainRoute {
        item.target == "suggestions" ? .suggestions : .contracts
    }

    @ViewBuilder
    private func row(_ item: OverviewAttention, isLast: Bool) -> some View {
        if let actionTitle = item.actionTitle {
            AttentionRowContent(item: item, hasRule: !isLast) {
                Button {
                    model.navigate(to: destination(item))
                } label: {
                    Text(verbatim: actionTitle)
                }
                .immButtonStyle(.outline, size: .sm)
                .frame(width: 88, alignment: .trailing)
            }
            .overviewRowRule(!isLast)
            .overviewHoverSurface()
        } else {
            DataRow(action: { model.navigate(to: destination(item)) }) {
                AttentionRowContent(item: item, hasRule: !isLast) {
                    IMMIcon("chevron-right", size: 16, color: IMMColor.mutedForeground)
                        .frame(width: 24, alignment: .trailing)
                }
            }
            .overviewRowRule(!isLast)
        }
    }
}

/// Icon, two text lines and a trailing control; 10 pt above and below, 1 pt reserved for the rule.
private struct AttentionRowContent<Trailing: View>: View {
    let item: OverviewAttention
    let hasRule: Bool
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            IMMIcon(Self.icon(for: item), size: 16, color: IMMColor.mutedForeground)
                .padding(.top, 2)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: item.title)
                    .immFont(.bodyMedium)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                detail
                    .immFont(item.actionTitle == nil ? IMMFont.small.tabular : IMMFont.small)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 10)
        .padding(.bottom, hasRule ? 1 : 0)
    }

    /// A date at the end of the detail (`Cancel or switch by 30.11.`) is a deadline: red, medium.
    private var detail: Text {
        let text = item.detail
        var attributed = AttributedString(text)
        if let range = text.range(of: #"\d{2}\.\d{2}\.$"#, options: .regularExpression),
           let target = Range(range, in: attributed) {
            attributed[target].font = IMMFont.smallMedium.tabular.font
            attributed[target].foregroundColor = IMMColor.destructive
        }
        return Text(attributed)
    }

    private static func icon(for item: OverviewAttention) -> String {
        switch item.id {
        case "attention-uncategorised": return "tag"
        case "attention-price-increase": return "trending-up"
        case "attention-notice-deadline": return "calendar"
        default: return item.target == "suggestions" ? "tag" : "circle-alert"
        }
    }
}
