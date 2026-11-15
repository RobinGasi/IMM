import IMMDesign
import SwiftUI

/// All accounts with their balance; a tap opens the account's transactions.
struct AccountsView: View {
    @Environment(CompanionModel.self) private var model

    var body: some View {
        List {
            ForEach(model.accounts) { account in
                NavigationLink {
                    TransactionsView(accountID: account.id)
                } label: {
                    AccountRow(account: account)
                }
                .listRowBackground(IMMColor.muted)
            }
        }
        .companionGroupedList()
        .overlay {
            if model.accounts.isEmpty {
                Text("No accounts yet.", bundle: .module)
                    .immFont(CompanionFont.callout)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
        }
        .refreshable { await model.syncNow() }
        .navigationTitle(Text("Accounts", bundle: .module))
    }
}

struct AccountRow: View {
    let account: CompanionAccount

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: CompanionFormat.symbol(forAccountKind: account.kind))
                .font(.system(size: 15))
                .foregroundStyle(IMMColor.accentForeground)
                .frame(width: 36, height: 36)
                .background(IMMColor.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account.name)
                    .immFont(CompanionFont.calloutMedium)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                Text(verbatim: account.subtitle)
                    .immFont(CompanionFont.footnote)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(verbatim: CompanionFormat.money(account.balance, currency: account.currency))
                .immFont(CompanionFont.amount)
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Accounts") {
    NavigationStack { AccountsView() }
        .environment(CompanionModel.preview(.ready))
}
