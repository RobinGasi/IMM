import IMMDesign
import IMMLedger
import SwiftUI

/// Chooses the Overview layout for the sync state: the Sync failed layout while `model.bank.syncState`
/// is `.failed`, the normal one otherwise. While a retry runs the failed layout stays on screen (the
/// toolbar and the sidebar show the spinner), so "Retry now" does not flash the normal Overview.
struct SyncAwareOverview: View {
    let snapshot: OverviewSnapshot

    @Environment(AppModel.self) private var model
    @State private var retained: [AccountSyncFailure]?

    private var failures: [AccountSyncFailure]? {
        switch model.bank.syncState {
        case .failed(let failures): return failures.isEmpty ? nil : failures
        case .syncing: return retained
        case .idle: return nil
        }
    }

    var body: some View {
        Group {
            if let failures {
                SyncFailedOverviewLayout(snapshot: snapshot, failures: failures)
            } else {
                OverviewLayout(snapshot: snapshot)
            }
        }
        .onChange(of: model.bank.syncState, initial: true) { _, state in
            switch state {
            case .failed(let failures): retained = failures
            case .idle: retained = nil
            case .syncing: break
            }
        }
    }
}

/// The Overview while at least one bank could not be updated (`Errors / 1 Sync failed`, without the
/// PIN sheet): a banner row per failed bank, the net worth with its caveat, and the accounts with a
/// status column. No chart, no Needs attention, Spent or Coming up.
struct SyncFailedOverviewLayout: View {
    let snapshot: OverviewSnapshot
    let failures: [AccountSyncFailure]

    @Environment(AppModel.self) private var model
    @Environment(\.immWindowWidth) private var windowWidth

    private var banks: [BankSyncFailure] { SyncState.failed(failures).byBank }

    private var lastSynced: [String: Date] {
        Dictionary(
            model.sidebar.snapshot.accounts.compactMap { account in account.lastSyncedAt.map { (account.id, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let lastSynced = self.lastSynced
        let failedByAccount = Dictionary(failures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        VStack(alignment: .leading, spacing: 32) {
            BannerGroup {
                ForEach(Array(banks.enumerated()), id: \.element.id) { index, bank in
                    SyncFailureBanner(
                        failure: bank, isFirst: index == 0, riseDelay: Double(index) * 0.06,
                        since: bank.accountNames.isEmpty ? nil : sinceDate(of: bank, lastSynced: lastSynced))
                }
            }

            HeroAmount(
                label: Text("Net worth, all \(snapshot.accountCount) accounts", bundle: .module),
                amount: MoneyFormatter.string(snapshot.netWorth),
                caption: Text(
                    verbatim: SyncText.balanceCaption(
                        count: failures.count, oldest: failures.compactMap { lastSynced[$0.id] }.min(), now: now)),
                size: IMMLayout.heroFontSize(windowWidth: windowWidth))

            accounts(failedByAccount: failedByAccount, lastSynced: lastSynced, now: now)
                .frame(maxWidth: 600, alignment: .leading)
        }
        .padding(.horizontal, IMMLayout.contentPadding(windowWidth: windowWidth))
        .padding(.top, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sinceDate(of bank: BankSyncFailure, lastSynced: [String: Date]) -> Date? {
        failures.filter { $0.loginID == bank.loginID }.compactMap { lastSynced[$0.id] }.min()
    }

    private func accounts(failedByAccount: [String: AccountSyncFailure], lastSynced: [String: Date], now: Date) -> some View {
        let updated = snapshot.accountGroups.flatMap(\.accounts).filter { account in
            guard failedByAccount[account.id] == nil, let date = lastSynced[account.id] else { return false }
            return Calendar.current.isDate(date, inSameDayAs: now)
        }.count
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                Text("Accounts", bundle: .module),
                detail: Text(verbatim: SyncText.updatedCount(updated: updated, total: snapshot.accountCount)))
            VStack(spacing: 0) {
                ForEach(snapshot.accountGroups) { group in
                    Text(verbatim: group.bankName)
                        .immFont(.captionSemibold)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(group.accounts) { account in
                        row(
                            account,
                            status: SyncText.status(
                                for: failedByAccount[account.id], lastSyncedAt: lastSynced[account.id], now: now))
                    }
                }
                TotalRow(Text("Total", bundle: .module), amount: MoneyFormatter.string(snapshot.netWorth))
                    .padding(.top, 8)
            }
        }
    }

    private func row(_ account: OverviewAccount, status: SyncText.RowStatus) -> some View {
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
                Text(verbatim: status.text)
                    .immFont(.small)
                    .foregroundStyle(status.isWarning ? IMMColor.warning : IMMColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
                OverviewAmount(text: MoneyFormatter.string(account.value))
            }
        }
    }
}

/// One banner row for one bank that could not be updated.
struct SyncFailureBanner: View {
    let failure: BankSyncFailure
    let isFirst: Bool
    let riseDelay: Double
    /// Oldest `last_synced_at` among this bank's failed accounts.
    let since: Date?

    @Environment(AppModel.self) private var model

    var body: some View {
        switch failure.reason {
        case .pinRejected:
            Banner(tone: .destructive, icon: "circle-alert", isFirst: isFirst, riseDelay: riseDelay) {
                Text(message(
                    strong: String(localized: "\(failure.bankName) rejected your PIN.", bundle: .module),
                    rest: " " + notUpdatedText(), restMuted: false))
            } actions: {
                Button { model.openSettings() } label: { Text("Why this happens", bundle: .module) }
                    .immButtonStyle(.ghost, size: .sm)
                Button { model.panel = .pin } label: { Text("Enter new PIN", bundle: .module) }
                    .immButtonStyle(.default, size: .sm)
            }
        case .maintenance(let until):
            retryBanner(
                lead: String(localized: "\(failure.bankName) is under maintenance until \(SyncText.clock(until)). ", bundle: .module),
                hint: String(localized: "Press Retry now when it is back.", bundle: .module))
        case .offline:
            retryBanner(
                lead: String(localized: "\(failure.bankName) couldn't be reached. ", bundle: .module),
                hint: String(localized: "Check your connection, then press Retry now.", bundle: .module))
        case .other(let reason):
            retryBanner(
                lead: String(localized: "\(failure.bankName) couldn't be updated. ", bundle: .module), hint: reason)
        }
    }

    private func retryBanner(lead: String, hint: String) -> some View {
        Banner(tone: .warning, icon: "clock", isFirst: isFirst, riseDelay: riseDelay) {
            Text(message(strong: nil, rest: lead, restMuted: false, hint: hint))
        } actions: {
            Button { model.bank.sync() } label: { Text("Retry now", bundle: .module) }
                .immButtonStyle(.ghost, size: .sm)
        }
    }

    private func notUpdatedText() -> String {
        let names = SyncText.list(failure.accountNames)
        let moment = since.map { SyncText.moment($0) }
        switch (failure.accountNames.count, moment) {
        case (1, let moment?): return String(localized: "\(names) wasn't updated since \(moment).", bundle: .module)
        case (_, let moment?): return String(localized: "\(names) weren't updated since \(moment).", bundle: .module)
        case (1, nil): return String(localized: "\(names) wasn't updated.", bundle: .module)
        default: return String(localized: "\(names) weren't updated.", bundle: .module)
        }
    }

    /// `strong` in semibold, `rest` in the body colour and `hint` muted, all 13/20.
    private func message(strong: String?, rest: String, restMuted: Bool, hint: String? = nil) -> AttributedString {
        var result = AttributedString()
        if let strong {
            var part = AttributedString(strong)
            part.font = IMMFont.bodySemibold.font
            result += part
        }
        var middle = AttributedString(rest)
        middle.font = IMMFont.body.font
        middle.foregroundColor = restMuted ? IMMColor.mutedForeground : IMMColor.foreground
        result += middle
        if let hint {
            var part = AttributedString(hint)
            part.font = IMMFont.body.font
            part.foregroundColor = IMMColor.mutedForeground
            result += part
        }
        return result
    }
}
