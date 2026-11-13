import IMMDesign
import IMMLedger
import SwiftUI

/// "Accounts": rows grouped by bank with the grey detail text, and the total.
struct OverviewAccountsSection: View {
    let groups: [OverviewAccountGroup]
    let netWorth: Int
    let lastSyncedAt: Date?

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                Text("Accounts", bundle: .module),
                detail: model.bank.syncState.isSyncing
                    ? Text("Syncing…", bundle: .module)
                    : Text(verbatim: overviewSyncedText(lastSyncedAt)))
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    Text(verbatim: group.bankName)
                        .immFont(.captionSemibold)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(group.accounts) { account in
                        row(account)
                    }
                }
                TotalRow(Text("Total", bundle: .module), amount: MoneyFormatter.string(netWorth))
                    .padding(.top, 8)
            }
            .padding(.top, 8)
        }
    }

    private func row(_ account: OverviewAccount) -> some View {
        DataRow(height: 32, action: {
            model.navigate(to: account.kind == .depot ? .depot : .transactions(.account(account.id)))
        }) {
            HStack(spacing: 12) {
                Text(verbatim: account.name)
                    .immFont(.body)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                detail(account.detail)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 120, alignment: .trailing)
                OverviewAmount(text: MoneyFormatter.string(account.value))
            }
        }
    }

    @ViewBuilder
    private func detail(_ detail: OverviewAccountDetail) -> some View {
        switch detail {
        case .none:
            Color.clear.frame(height: 16)
        case .iban(let text):
            Text(verbatim: text).immFont(.mono).foregroundStyle(IMMColor.mutedForeground)
        case .statement(let text):
            Text(verbatim: text).immFont(IMMFont.small.tabular).foregroundStyle(IMMColor.mutedForeground)
        case .holdings(let securities, let allETFs, let hasCash):
            Text(verbatim: Self.holdingsText(securities: securities, allETFs: allETFs, hasCash: hasCash))
                .immFont(IMMFont.small.tabular)
                .foregroundStyle(IMMColor.mutedForeground)
        }
    }

    static func holdingsText(securities: Int, allETFs: Bool, hasCash: Bool) -> String {
        switch (allETFs, hasCash) {
        case (true, true): return String(localized: "\(securities) ETFs and cash", bundle: .module)
        case (true, false): return String(localized: "\(securities) ETFs", bundle: .module)
        case (false, true): return String(localized: "\(securities) holdings and cash", bundle: .module)
        case (false, false): return String(localized: "\(securities) holdings", bundle: .module)
        }
    }
}
