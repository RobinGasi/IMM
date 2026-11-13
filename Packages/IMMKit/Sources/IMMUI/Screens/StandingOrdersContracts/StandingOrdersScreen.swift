import IMMBanking
import IMMDesign
import IMMLedger
import SwiftUI

/// Standing orders: what leaves the Girokonto in the next 30 days (hero and timeline), then the table of
/// orders with a monthly total per account. Only "New standing order" acts (it opens the transfer panel
/// with the standing-order execution); the orders themselves can only be viewed.
public struct StandingOrdersScreen: View {
    @Environment(AppModel.self) private var model
    @State private var orders = StandingOrdersModel()

    public init() {}

    public var body: some View {
        Group {
            if let snapshot = orders.snapshot {
                StandingOrdersLayout(snapshot: snapshot) {
                    let first = snapshot.today.adding(months: 1).firstOfMonth
                    model.openNewTransfer(TransferDraft(execution: .standingOrder(firstExecution: first)))
                }
            } else {
                Color.clear
            }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await orders.follow(ledger: ledger)
        }
    }
}

/// Column template of the orders table: recipient `1fr`, purpose `0.8fr`, rhythm 150, next 104, amount 112, status 92.
private let orderColumns: [SOCColumn] = [.fr(1), .fr(0.8), .fixed(150), .fixed(104), .fixed(112), .fixed(92)]

struct StandingOrdersLayout: View {
    let snapshot: StandingOrdersSnapshot
    let newOrder: () -> Void

    @Environment(\.immWindowWidth) private var windowWidth

    private var padding: CGFloat { IMMLayout.contentPadding(windowWidth: windowWidth) }
    private var gap: CGFloat { IMMLayout.clamp(12, fraction: 0.012, of: windowWidth, maximum: 16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            ForEach(Array(snapshot.sections.enumerated()), id: \.element.id) { index, section in
                sectionHeader(section, isPrimary: index == 0)
                table(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Hero

    private var hero: some View {
        FlexWrapLayout(columnSpacing: 48, rowSpacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Leaving \(snapshot.primaryAccountName) by \(DateFormats.dayMonthYear(snapshot.horizon))", bundle: .module)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .frame(height: 17, alignment: .top)
                Text(verbatim: MoneyFormatter.string(snapshot.leaving))
                    .immFont(IMMFont.amountHero.sized(IMMLayout.heroFontSize(windowWidth: windowWidth)))
                    .foregroundStyle(IMMColor.foreground)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: 40)
                caption
            }
            .padding(.top, 5)
            .frame(maxWidth: 420, alignment: .leading)
            .flexItem(basis: 260, grow: 1)

            StandingOrdersTimeline(snapshot: snapshot)
                .frame(height: 124)
                .flexItem(basis: 720, grow: 999)
        }
        .padding(EdgeInsets(top: 24, leading: padding, bottom: 20, trailing: padding))
        .padding(.bottom, 1)
        .overlay(alignment: .bottom) { Rule() }
    }

    private var caption: some View {
        let base = Text("Standing orders and direct debits.", bundle: .module)
        let text: Text
        if let salary = snapshot.salary {
            text = base + Text(verbatim: " ") + Text("Salary", bundle: .module) + Text(verbatim: " ")
                + Text(verbatim: MoneyFormatter.string(salary.amount, sign: .always))
                .foregroundStyle(IMMColor.credit)
                + Text(verbatim: " ") + Text("arrives on \(DateFormats.dayMonth(salary.date))", bundle: .module)
        } else {
            text = base
        }
        // 12/18: SwiftUI lays Geist 12 out 15 pt high, so 3 pt between lines gives the 18 pt pitch.
        return text
            .font(IMMFont.small.font)
            .lineSpacing(3)
            .foregroundStyle(IMMColor.mutedForeground)
            .padding(.top, 1)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Section header and table

    @ViewBuilder
    private func sectionHeader(_ section: StandingOrderSection, isPrimary: Bool) -> some View {
        let title = HStack(spacing: 12) {
            Text("From \(section.accountName)", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
            Text(section.orders.count == 1 ? "1 order" : "\(section.orders.count) orders", bundle: .module)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
                .lineLimit(1)
        }
        let note = Text("Changes are sent to your bank and confirmed with pushTAN.", bundle: .module)
            .immFont(.small)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
        let button = Button(action: newOrder) {
            HStack(spacing: 4) {
                IMMIcon("plus", size: IMMButtonStyle.Size.default.iconSize)
                Text("New standing order", bundle: .module)
            }
        }
        .immButtonStyle(.default)

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 12)
                if isPrimary {
                    note
                    button
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                if isPrimary {
                    HStack(spacing: 12) {
                        note
                        button
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 20, leading: padding, bottom: 12, trailing: padding))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(_ section: StandingOrderSection) -> some View {
        VStack(spacing: 0) {
            tableHeader
            ForEach(section.orders) { order in
                StandingOrderRow(order: order, gap: gap, padding: padding)
            }
            totalRow(section)
        }
    }

    private var tableHeader: some View {
        SOCColumnGrid(columns: orderColumns, spacing: gap) {
            headerCell(Text("Recipient", bundle: .module))
            headerCell(Text("Purpose", bundle: .module))
            headerCell(Text("Rhythm", bundle: .module))
            headerCell(Text("Next execution ↓", bundle: .module))
            headerCell(Text("Amount", bundle: .module), alignment: .trailing)
            headerCell(Text("Status", bundle: .module))
        }
        .padding(.horizontal, padding)
        .frame(height: 32)
        .overlay(alignment: .top) { Rule() }
        .overlay(alignment: .bottom) { Rule() }
    }

    private func headerCell(_ title: Text, alignment: Alignment = .leading) -> some View {
        title
            .immFont(.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func totalRow(_ section: StandingOrderSection) -> some View {
        SOCColumnGrid(columns: orderColumns, spacing: gap) {
            Text("Monthly total", bundle: .module)
                .immFont(IMMFont.bodySemibold.withLineHeight(18))
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(
                section.activeCount == 1
                    ? "1 active standing order · one-off and paused not included"
                    : "\(section.activeCount) active standing orders · one-off and paused not included",
                bundle: .module
            )
            .immFont(.small)
            .foregroundStyle(IMMColor.mutedForeground)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .socColumns(1..<4)
            Text(verbatim: MoneyFormatter.string(section.monthlyTotal))
                .immFont(IMMFont.bodySemibold.withLineHeight(18).tabular)
                .foregroundStyle(IMMColor.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .socColumns(4..<5)
        }
        .padding(.horizontal, padding)
        .padding(.bottom, 3)
        .frame(height: 44)
        .overlay(alignment: .bottom) { DoubleRule() }
    }
}

/// One order of the table: 48 px high, `muted` on hover, a 1 px rule below.
private struct StandingOrderRow: View {
    let order: StandingOrderItem
    let gap: CGFloat
    let padding: CGFloat

    var body: some View {
        let paused = order.status == .paused
        let secondary = IMMColor.mutedForeground
        DataRow(height: 48, bleed: 0) {
            SOCColumnGrid(columns: orderColumns, spacing: gap) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: order.recipient)
                        .immFont(IMMFont.bodyMedium.withLineHeight(18))
                        .foregroundStyle(paused ? secondary : IMMColor.foreground)
                        .lineLimit(1)
                    Text(verbatim: soFormattedIBAN(order.iban))
                        .immFont(.mono)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: order.purpose)
                    .immFont(IMMFont.body.withLineHeight(18))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: rhythmText)
                    .immFont(IMMFont.body.withLineHeight(18))
                    .foregroundStyle(paused ? secondary : IMMColor.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: order.nextExecution.map(DateFormats.dayMonthYear) ?? "—")
                    .immFont(IMMFont.body.withLineHeight(18).tabular)
                    .foregroundStyle(paused ? secondary : IMMColor.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: MoneyFormatter.string(order.amount))
                    .immFont(IMMFont.body.withLineHeight(18).tabular)
                    .foregroundStyle(paused ? secondary : IMMColor.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                statusBadge
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, padding)
        }
        .overlay(alignment: .bottom) { Rule() }
    }

    private var rhythmText: String {
        switch order.rhythm {
        case .once:
            return String(localized: "Once", bundle: .module)
        case .monthly:
            let day = soOrdinal(order.dayOfMonth ?? order.nextExecution?.day ?? 1)
            return String(localized: "Monthly on the \(day)", bundle: .module)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch order.status {
        case .active: Badge(Text("Active", bundle: .module), variant: .outline)
        case .scheduled: Badge(Text("Scheduled", bundle: .module), variant: .secondary)
        case .paused: Badge(Text("Paused", bundle: .module), variant: .ghost)
        }
    }
}

/// `DE13 5001 0517 5419 2837 46`: the IBAN in groups of four.
func soFormattedIBAN(_ iban: String) -> String {
    let compact = iban.filter { !$0.isWhitespace }
    var out = ""
    for (index, character) in compact.enumerated() {
        if index > 0 && index % 4 == 0 { out.append(" ") }
        out.append(character)
    }
    return out
}

/// `1st`, `2nd`, `3rd`, `15th`.
func soOrdinal(_ number: Int) -> String {
    let tens = number % 100
    if (11...13).contains(tens) { return "\(number)th" }
    switch number % 10 {
    case 1: return "\(number)st"
    case 2: return "\(number)nd"
    case 3: return "\(number)rd"
    default: return "\(number)th"
    }
}
