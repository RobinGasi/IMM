import IMMDesign
import SwiftUI

/// Net worth, this month's spending against the average, the uncategorised count and the newest bookings.
struct OverviewView: View {
    @Environment(CompanionModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.syncStatus.needsAttention {
                    SyncStatusLine(status: model.syncStatus)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(IMMColor.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if let overview = model.overview {
                    netWorth(overview)
                    spending(overview)
                    if overview.uncategorisedCount > 0 {
                        uncategorised(overview.uncategorisedCount)
                    }
                    recent(overview)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(IMMColor.background)
        .refreshable { await model.syncNow() }
        .navigationTitle(Text("Overview", bundle: .module))
    }

    private func netWorth(_ overview: CompanionOverview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Net worth", bundle: .module)
                .immFont(CompanionFont.footnoteSemibold)
                .foregroundStyle(IMMColor.mutedForeground)
            Text(verbatim: CompanionFormat.money(overview.netWorth))
                .immFont(CompanionFont.hero)
                .foregroundStyle(IMMColor.foreground)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private func spending(_ overview: CompanionOverview) -> some View {
        let spent = abs(overview.spentThisMonth)
        let average = abs(overview.averageMonthlySpending)
        let ratio = average > 0 ? min(1, Double(spent) / Double(average)) : 0
        let over = average > 0 && spent > average
        return VStack(alignment: .leading, spacing: 12) {
            Text("Spent this month", bundle: .module)
                .immFont(CompanionFont.footnoteSemibold)
                .foregroundStyle(IMMColor.mutedForeground)
            Text(verbatim: CompanionFormat.money(spent))
                .immFont(CompanionFont.title.tabular)
                .foregroundStyle(IMMColor.foreground)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(IMMColor.border)
                    Capsule()
                        .fill(over ? IMMColor.warning : IMMColor.primary)
                        .frame(width: max(6, proxy.size.width * ratio))
                }
            }
            .frame(height: 6)
            Text(verbatim: String(localized: "Average month: \(CompanionFormat.money(average))", bundle: .module))
                .immFont(CompanionFont.footnote)
                .foregroundStyle(IMMColor.mutedForeground)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IMMColor.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func uncategorised(_ count: Int) -> some View {
        let text =
            count == 1
            ? String(localized: "1 uncategorised transaction", bundle: .module)
            : String(localized: "\(count) uncategorised transactions", bundle: .module)
        return NavigationLink {
            TransactionsView(uncategorisedOnly: true)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tag")
                    .foregroundStyle(IMMColor.accentForeground)
                    .frame(width: 32, height: 32)
                    .background(IMMColor.accent, in: Circle())
                Text(verbatim: text)
                    .immFont(CompanionFont.calloutMedium)
                    .foregroundStyle(IMMColor.foreground)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            .padding(12)
            .background(IMMColor.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recent(_ overview: CompanionOverview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent bookings", bundle: .module)
                .immFont(CompanionFont.footnoteSemibold)
                .foregroundStyle(IMMColor.mutedForeground)
                .padding(.bottom, 8)
            if overview.recent.isEmpty {
                Text("No bookings yet.", bundle: .module)
                    .immFont(CompanionFont.callout)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .padding(.vertical, 12)
            }
            ForEach(Array(overview.recent.enumerated()), id: \.element.id) { index, transaction in
                if index > 0 { Divider() }
                NavigationLink {
                    TransactionDetailView(transactionID: transaction.id)
                } label: {
                    TransactionRow(transaction: transaction)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview("Overview") {
    NavigationStack { OverviewView() }
        .environment(CompanionModel.preview(.ready))
}
