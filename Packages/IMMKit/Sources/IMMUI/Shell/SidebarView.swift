import IMMDesign
import IMMLedger
import SwiftUI

/// The sidebar of the main window: width `clamp(212, 17.5 %, 252)` (set by `MainWindowView`), 56 px header
/// that holds the real window buttons, navigation, and the net-worth footer.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.sidebar.snapshot
        VStack(spacing: 0) {
            Color.clear
                .frame(height: IMMLayout.toolbarHeight)
                .background(WindowDragArea())
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    navigation(snapshot)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            SidebarFooter(snapshot: snapshot)
        }
        .frame(maxHeight: .infinity)
        .background(IMMColor.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(IMMColor.sidebarBorder).frame(width: 1)
        }
    }

    @ViewBuilder
    private func navigation(_ snapshot: SidebarSnapshot) -> some View {
        let route = model.route
        SidebarRow(
            icon: "layout-dashboard", title: String(localized: "Overview", bundle: .module), trailing: nil,
            isActive: route == .overview
        ) { model.navigate(to: .overview) }

        SidebarRow(
            icon: "list", title: String(localized: "All transactions", bundle: .module),
            trailing: snapshot.newCount > 0 ? String(localized: "\(snapshot.newCount) new", bundle: .module) : nil,
            isActive: route == .transactions(.all)
        ) { model.navigate(to: .transactions(.all)) }

        SidebarRow(
            icon: "check-check", title: String(localized: "Suggestions", bundle: .module),
            trailing: snapshot.uncategorisedCount > 0 ? String(snapshot.uncategorisedCount) : nil,
            isActive: route == .suggestions
        ) { model.navigate(to: .suggestions) }

        SidebarRow(
            icon: "book-open",
            title: String(localized: "\(DateFormats.monthName(ShellText.previousMonthEnd(snapshot.today))) review", bundle: .module),
            trailing: nil, isActive: route == .monthReview
        ) { model.navigate(to: .monthReview) }

        ForEach(groups(snapshot.accounts), id: \.bankName) { group in
            VStack(alignment: .leading, spacing: 1) {
                SidebarSectionHeader(title: group.bankName)
                ForEach(group.accounts) { account in
                    SidebarRow(
                        icon: Self.icon(for: account.kind), title: Self.displayName(account),
                        trailing: MoneyFormatter.string(account.value, currency: account.currency),
                        isActive: Self.isActive(account, route: route,
                                                payingFrom: snapshot.accounts.first { $0.kind == .giro }?.id)
                    ) {
                        model.navigate(to: account.kind == .depot ? .depot : .transactions(.account(account.id)))
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 1) {
            SidebarSectionHeader(title: String(localized: "Planning", bundle: .module))
            SidebarRow(
                icon: "target", title: String(localized: "Budgets", bundle: .module), trailing: nil,
                isActive: route == .budgets
            ) { model.navigate(to: .budgets) }
            SidebarRow(
                icon: "repeat-2", title: String(localized: "Standing orders", bundle: .module), trailing: nil,
                isActive: route == .standingOrders
            ) { model.navigate(to: .standingOrders) }
            SidebarRow(
                icon: "file-text", title: String(localized: "Contracts", bundle: .module), trailing: nil,
                isActive: route == .contracts
            ) { model.navigate(to: .contracts) }
            SidebarRow(
                icon: "pie-chart", title: String(localized: "Categories", bundle: .module), trailing: nil,
                isActive: route == .categories
            ) { model.navigate(to: .categories) }
            SidebarRow(
                icon: "receipt", title: String(localized: "Tax return \(String(snapshot.today.year))", bundle: .module),
                trailing: nil, isActive: route == .taxReturn
            ) { model.navigate(to: .taxReturn) }
        }
    }

    private struct AccountGroup {
        var bankName: String
        var accounts: [SidebarAccount]
    }

    /// Accounts grouped by bank, in order of first appearance.
    private func groups(_ accounts: [SidebarAccount]) -> [AccountGroup] {
        var result: [AccountGroup] = []
        for account in accounts {
            if let index = result.firstIndex(where: { $0.bankName == account.bankName }) {
                result[index].accounts.append(account)
            } else {
                result.append(AccountGroup(bankName: account.bankName, accounts: [account]))
            }
        }
        return result
    }

    private static func icon(for kind: AccountKind) -> String {
        switch kind {
        case .giro: return "landmark"
        case .savings: return "piggy-bank"
        case .creditCard: return "credit-card"
        case .depot: return "trending-up"
        case .wallet: return "wallet"
        }
    }

    /// The row label without a repeated bank prefix ("PayPal Wallet" under "PayPal" reads "Wallet").
    private static func displayName(_ account: SidebarAccount) -> String {
        let prefix = account.bankName + " "
        if !account.bankName.isEmpty, account.name.hasPrefix(prefix) {
            return String(account.name.dropFirst(prefix.count))
        }
        return account.name
    }

    /// Pay invoice is drawn with the first giro account highlighted: the invoice is paid from it.
    private static func isActive(_ account: SidebarAccount, route: MainRoute, payingFrom: String?) -> Bool {
        if account.kind == .depot { return route == .depot }
        if route == .payInvoice { return account.id == payingFrom }
        return route == .transactions(.account(account.id))
    }
}

/// `pt 16, pr 8, pb 4, pl 8`, 11 px semibold muted. The design's line height is 16.5 px (1.5 × 11), so the
/// header is 36.5 px tall.
private struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .immFont(.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .frame(height: 16.5)
            .padding(EdgeInsets(top: 16, leading: 8, bottom: 4, trailing: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One 28 px navigation row: hover `accent`, pressed and active `sidebar-accent`, 120 ms ease.
private struct SidebarRow: View {
    let icon: String
    let title: String
    let trailing: String?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The label is drawn by the style so it can react to hover and press.
            Color.clear.frame(height: 28)
        }
        .buttonStyle(SidebarRowButtonStyle(icon: icon, title: title, trailing: trailing, isActive: isActive))
        .focusEffectDisabled()
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: trailing ?? ""))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct SidebarRowButtonStyle: ButtonStyle {
    let icon: String
    let title: String
    let trailing: String?
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        SidebarRowBody(pressed: configuration.isPressed, icon: icon, title: title, trailing: trailing, isActive: isActive)
    }
}

private struct SidebarRowBody: View {
    let pressed: Bool
    let icon: String
    let title: String
    let trailing: String?
    let isActive: Bool

    @Environment(\.immDisableMotion) private var disableMotion
    @State private var hovering = false

    var body: some View {
        let background: Color = hovering ? IMMColor.accent : (pressed || isActive ? IMMColor.sidebarAccent : Color.clear)
        let foreground: Color = hovering
            ? IMMColor.accentForeground
            : (pressed || isActive ? IMMColor.sidebarAccentForeground : IMMColor.sidebarForeground)
        HStack(spacing: 8) {
            IMMIcon(icon, size: 16, color: IMMColor.mutedForeground)
            Text(verbatim: title)
                .immFont(.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(verbatim: trailing)
                    .immFont(IMMFont.small.tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous).fill(background))
        .contentShape(RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous))
        .onHover { hovering = $0 }
        .animation(disableMotion ? nil : Motion.ease(0.12), value: hovering)
        .animation(disableMotion ? nil : Motion.ease(0.12), value: pressed)
    }
}

/// Net worth and the sync line: `pt 14, px 18, pb 16`, 1 px rule above.
private struct SidebarFooter: View {
    let snapshot: SidebarSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Net worth", bundle: .module)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
                Spacer(minLength: 8)
                Text(verbatim: MoneyFormatter.string(snapshot.netWorth))
                    .immFont(IMMFont.titleMDTight.tabular)
                    .foregroundStyle(IMMColor.sidebarForeground)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            SyncLine(snapshot: snapshot)
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
        .overlay(alignment: .top) {
            Rectangle().fill(IMMColor.sidebarBorder).frame(height: 1)
        }
    }
}

/// Refresh icon and text; opens Settings. Warning colour when accounts were not updated.
/// While sync over Tailscale is on and the bank sync is idle and healthy the line shows the Tailscale sync state
/// instead (artboard "Sidebar footer — sync status"); it wraps.
private struct SyncLine: View {
    @Environment(AppModel.self) private var model
    let snapshot: SidebarSnapshot
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let line = ShellText.syncLine(snapshot: snapshot, state: model.bank.syncState, now: context.date)
            let peer = line.isWarning || model.bank.syncState.isSyncing
                ? nil : SyncFooterLine.make(sync: model.sync, now: context.date)
            Button {
                model.openSettings()
            } label: {
                if let peer {
                    peerLabel(peer)
                } else {
                    HStack(spacing: 6) {
                        SpinningIcon(name: "refresh", size: 12, spinning: model.bank.syncState.isSyncing)
                        Text(verbatim: line.text)
                            .immFont(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(line.isWarning ? IMMColor.warning : (hovering ? IMMColor.foreground : IMMColor.mutedForeground))
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovering = $0 }
            .animation(Motion.ease(0.12), value: hovering)
            .accessibilityLabel(Text(verbatim: peer?.text ?? line.text))
        }
    }

    /// `items-start gap-1.5 text-[11px] leading-[14px]`: a 14 px high icon cell, then the wrapping text.
    private func peerLabel(_ line: SyncFooterLine) -> some View {
        let icon: String
        switch line.icon {
        case .synced: icon = "refresh"
        case .waiting: icon = "clock"
        case .paused: icon = "triangle-alert"
        }
        return HStack(alignment: .top, spacing: 6) {
            IMMIcon(icon, size: 12).frame(height: 14)
            Text(verbatim: line.text)
                .immFont(IMMFont.caption.withLineHeight(14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(line.isWarning ? IMMColor.warning : (hovering ? IMMColor.foreground : IMMColor.mutedForeground))
        .contentShape(Rectangle())
    }
}
