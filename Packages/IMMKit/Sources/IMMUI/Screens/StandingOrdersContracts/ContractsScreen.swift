import IMMDesign
import IMMLedger
import SwiftUI

/// Contracts: fixed costs per month, the price-change and notice-deadline banners, and the contracts
/// grouped by kind with a total. "Show payments" opens the paying account's transactions; adding a
/// contract, setting a reminder and the row chevrons have no designed target and are inert.
public struct ContractsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var contracts = ContractsModel()

    public init() {}

    public var body: some View {
        Group {
            if let snapshot = contracts.snapshot {
                ContractsLayout(snapshot: snapshot) { accountID in
                    model.navigate(to: .transactions(accountID.map { .account($0) } ?? .all))
                }
            } else {
                Color.clear
            }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await contracts.follow(ledger: ledger)
        }
    }
}

/// Contract `1fr`, account 120, rhythm 90, next debit 104, notice `0.7fr`, per month 112, chevron 24.
private let contractColumns: [SOCColumn] = [.fr(1), .fixed(120), .fixed(90), .fixed(104), .fr(0.7), .fixed(112), .fixed(24)]

struct ContractsLayout: View {
    let snapshot: ContractsSnapshot
    let showPayments: (String?) -> Void

    @Environment(\.immWindowWidth) private var windowWidth

    private var padding: CGFloat { IMMLayout.contentPadding(windowWidth: windowWidth) }
    private var gap: CGFloat { IMMLayout.clamp(10, fraction: 0.0112, of: windowWidth, maximum: 16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            hero
            if !snapshot.priceNotices.isEmpty || !snapshot.deadlineNotices.isEmpty {
                notices
            }
            table
        }
        .padding(EdgeInsets(top: 24, leading: padding, bottom: 24, trailing: padding))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Hero

    private var hero: some View {
        let figures = VStack(alignment: .leading, spacing: 4) {
            Text("Fixed costs per month, \(snapshot.count) contracts", bundle: .module)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(height: 16)
            Text(verbatim: MoneyFormatter.string(-snapshot.monthlyTotal))
                .immFont(IMMFont.amountHero.sized(IMMLayout.heroFontSize(windowWidth: windowWidth)))
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .frame(height: 40)
            yearLine.frame(height: 16)
        }
        let add = Button {} label: {
            HStack(spacing: 4) {
                IMMIcon("plus", size: IMMButtonStyle.Size.default.iconSize)
                Text("Add contract manually", bundle: .module)
            }
        }
        .immButtonStyle(.outline, leadingIcon: true)
        .inertControl()

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 24) {
                figures
                Spacer(minLength: 24)
                add
            }
            VStack(alignment: .leading, spacing: 16) {
                figures
                add
            }
        }
    }

    private var yearLine: some View {
        let year = MoneyFormatter.string(snapshot.yearlyTotal)
        let text: Text
        if let share = snapshot.salaryShare {
            text = Text("\(year) a year, \(share) % of your net salary", bundle: .module)
        } else {
            text = Text("\(year) a year", bundle: .module)
        }
        return text
            .immFont(IMMFont.small.tabular)
            .foregroundStyle(IMMColor.mutedForeground)
    }

    // MARK: Notices

    private var notices: some View {
        let rows: [NoticeRow] = snapshot.priceNotices.map(NoticeRow.price) + snapshot.deadlineNotices.map(NoticeRow.deadline)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                notice(row)
                    .overlay(alignment: .bottom) {
                        if index < rows.count - 1 { Rule() }
                    }
                    .immRiseIn(duration: 0.3, delay: Double(index) * 0.06)
            }
        }
        .padding(1)
        .overlay(
            RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous).strokeBorder(IMMColor.border, lineWidth: 1))
    }

    private func notice(_ row: NoticeRow) -> some View {
        HStack(spacing: 12) {
            IMMIcon(row.icon, size: 16)
                .foregroundStyle(row.isDeadline ? IMMColor.destructive : IMMColor.mutedForeground)
            VStack(alignment: .leading, spacing: 0) {
                row.title
                    .immFont(IMMFont.bodyMedium.withLineHeight(18))
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                row.detail
                    .immFont(IMMFont.small.tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch row {
            case .price(let notice):
                Button { showPayments(notice.accountID) } label: { Text("Show payments", bundle: .module) }
                    .immButtonStyle(.outline, size: .sm)
            case .deadline:
                Button {} label: { Text("Set reminder", bundle: .module) }
                    .immButtonStyle(.outline, size: .sm)
                    .inertControl()
            }
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
        .frame(minHeight: 52)
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            SOCColumnGrid(columns: contractColumns, spacing: gap) {
                headerCell(Text("Contract", bundle: .module))
                headerCell(Text("Account", bundle: .module))
                headerCell(Text("Rhythm", bundle: .module))
                headerCell(Text("Next debit", bundle: .module))
                headerCell(Text("Notice period", bundle: .module))
                headerCell(Text("Per month", bundle: .module), alignment: .trailing)
                Color.clear.frame(height: 1)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .overlay(alignment: .bottom) { Rule() }

            ForEach(snapshot.groups) { group in
                groupHeader(group)
                ForEach(group.contracts) { contract in
                    ContractRow(contract: contract, today: snapshot.today, gap: gap)
                }
            }
            totalRow
        }
    }

    private func headerCell(_ title: Text, alignment: Alignment = .leading) -> some View {
        title
            .immFont(.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func groupHeader(_ group: ContractGroup) -> some View {
        SOCColumnGrid(columns: contractColumns, spacing: gap) {
            Text(verbatim: group.name)
                .immFont(.smallMedium.weighted(.semibold))
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .socColumns(0..<5)
            Text(verbatim: MoneyFormatter.string(group.subtotal))
                .immFont(IMMFont.small.weighted(.semibold).tabular)
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .socColumns(5..<6)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .frame(height: 32, alignment: .bottom)
    }

    private var totalRow: some View {
        SOCColumnGrid(columns: contractColumns, spacing: gap) {
            Text("Fixed costs per month", bundle: .module)
                .immFont(IMMFont.bodySemibold.withLineHeight(18))
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .socColumns(0..<3)
            Text("\(MoneyFormatter.string(-snapshot.yearlyTotal)) a year", bundle: .module)
                .immFont(IMMFont.body.withLineHeight(18).tabular)
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .socColumns(3..<5)
            Text(verbatim: MoneyFormatter.string(snapshot.monthlyTotal))
                .immFont(IMMFont.bodySemibold.withLineHeight(18).tabular)
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .socColumns(5..<6)
        }
        .padding(.horizontal, 8)
        .padding(EdgeInsets(top: 1, leading: 0, bottom: 3, trailing: 0))
        .frame(height: 44)
        .overlay(alignment: .top) { Rule() }
        .overlay(alignment: .bottom) { DoubleRule() }
    }
}

private enum NoticeRow: Identifiable {
    case price(ContractPriceNotice)
    case deadline(ContractDeadlineNotice)

    var id: String {
        switch self {
        case .price(let notice): return "price-" + notice.id
        case .deadline(let notice): return "deadline-" + notice.id
        }
    }

    var isDeadline: Bool {
        if case .deadline = self { return true }
        return false
    }

    var icon: String { isDeadline ? "calendar" : "trending-up" }

    var title: Text {
        switch self {
        case .price(let notice):
            let amount = MoneyFormatter.string(notice.newAmount)
            return Text("\(notice.provider) raises the price to \(amount) from \(DateFormats.monthName(notice.start))", bundle: .module)
        case .deadline(let notice):
            let deadline = Text(verbatim: DateFormats.dayMonthYear(notice.deadline)).foregroundStyle(IMMColor.destructive)
            if let renewal = notice.renewalDate {
                return Text("\(notice.provider) renews \(DateFormats.dayMonthYear(renewal)) — cancel by ", bundle: .module) + deadline
            }
            return Text("\(notice.provider) — cancel by ", bundle: .module) + deadline
        }
    }

    var detail: Text {
        switch self {
        case .price(let notice):
            let more = notice.newAmount - notice.oldAmount
            let monthly = MoneyFormatter.string(more)
            let yearly = MoneyFormatter.string(more * 12)
            var text = String(localized: "\(monthly) more a month, \(yearly) more a year.", bundle: .module)
            if !notice.paidFrom.isEmpty {
                text += " " + String(localized: "Paid from \(notice.paidFrom).", bundle: .module)
            }
            return Text(verbatim: text)
        case .deadline(let notice):
            let amount = MoneyFormatter.string(notice.renewalAmount)
            let thing = notice.groupName == "Insurance"
                ? String(localized: "policy", bundle: .module) : String(localized: "contract", bundle: .module)
            return Text(
                "\(notice.daysLeft) days left to give notice. Otherwise the \(thing) runs another year at \(amount).",
                bundle: .module)
        }
    }
}

/// One contract: 40 px high, `muted` on hover, a 1 px rule above. The chevron has no designed target.
private struct ContractRow: View {
    let contract: ContractItem
    let today: LocalDate
    let gap: CGFloat

    var body: some View {
        let muted = IMMColor.mutedForeground
        let urgent = contract.noticeDeadline.map { $0 >= today } ?? false
        DataRow(height: 40, bleed: 0) {
            SOCColumnGrid(columns: contractColumns, spacing: gap) {
                HStack(spacing: 8) {
                    Text(verbatim: contract.provider)
                        .lineLimit(1)
                    if let change = contract.priceChange {
                        Text("\(MoneyFormatter.string(change.newAmount)) from \(DateFormats.monthName(change.start))", bundle: .module)
                            .immFont(.small)
                            .foregroundStyle(muted)
                            .lineLimit(1)
                    }
                }
                .immFont(IMMFont.body.withLineHeight(18))
                .foregroundStyle(IMMColor.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: contract.accountName)
                    .immFont(IMMFont.body.withLineHeight(18))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: rhythmText)
                    .immFont(IMMFont.body.withLineHeight(18))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: contract.nextDebit.map(DateFormats.dayMonthYear) ?? "—")
                    .immFont(IMMFont.body.withLineHeight(18).tabular)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: contract.noticeText)
                    .immFont(IMMFont.body.withLineHeight(18))
                    .foregroundStyle(urgent ? IMMColor.destructive : muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: MoneyFormatter.string(contract.monthlyAmount))
                    .immFont(IMMFont.body.withLineHeight(18).tabular)
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                IMMIcon("chevron-right", size: 16)
                    .foregroundStyle(muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 8)
        }
        .overlay(alignment: .top) { Rule() }
    }

    private var rhythmText: String {
        switch contract.rhythm {
        case .monthly: return String(localized: "Monthly", bundle: .module)
        case .quarterly: return String(localized: "Quarterly", bundle: .module)
        case .yearly: return String(localized: "Yearly", bundle: .module)
        }
    }
}
