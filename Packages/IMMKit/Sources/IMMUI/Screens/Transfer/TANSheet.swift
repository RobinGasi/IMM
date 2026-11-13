import IMMBanking
import IMMDesign
import IMMLedger
import SwiftUI

/// The TAN sheet under the toolbar (520 wide; `PanelHost` adds dim, background, radius, shadow and
/// motion): order summary, three-step progress and the actions of the current `TANPhase`.
public struct TANSheet: View {
    @Environment(AppModel.self) private var model
    @State private var source: TransferSource?
    /// When the request left for the bank, remembered across phases (the booked phase only carries
    /// the booking time).
    @State private var sentAt: Date?

    public init() {}

    public var body: some View {
        if case .tan(let phase) = model.panel {
            content(phase)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onChange(of: phase, initial: true) { _, newPhase in
                switch newPhase {
                case .waiting(let sent, _), .expired(let sent, _, _): sentAt = sent
                case .booked(let sent, _, _): sentAt = sent
                case .failed: break
                }
            }
            .task(id: phase.order.fromAccount) {
                guard let ledger = model.ledger else { return }
                let id = phase.order.fromAccount
                source = try? await ledger.database.read { try TransferQueries.source($0, id: id) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(TANText.title(phase)))
        }
    }

    // MARK: Layout

    private func content(_ phase: TANPhase) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(phase)
            summary(phase.order)
            progress(phase)
            message(phase)
            actions(phase)
            if TANText.showsNotificationHint(phase) {
                VStack(spacing: 0) {
                    Rule()
                    Text("Didn't get a notification? Open S-pushTAN on your iPhone and pull to refresh.", bundle: .module)
                        .immFont(.small)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .padding(EdgeInsets(top: 12, leading: 0, bottom: 16, trailing: 0))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 0, trailing: 24))
            }
        }
    }

    private func header(_ phase: TANPhase) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TANText.title(phase))
                .immFont(.titleLG)
                .foregroundStyle(IMMColor.foreground)
            Text(TANText.subtitle(account: source))
                .immFont(IMMFont.body.withLineHeight(18))
                .foregroundStyle(IMMColor.mutedForeground)
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))
        .accessibilityElement(children: .combine)
    }

    private func summary(_ order: PaymentOrder) -> some View {
        VStack(spacing: 0) {
            Rule()
            summaryRow("To") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: order.recipient)
                        .immFont(IMMFont.bodyMedium.withLineHeight(18))
                        .foregroundStyle(IMMColor.foreground)
                    Text(verbatim: IBAN.formatted(order.iban))
                        .immFont(.mono)
                        .foregroundStyle(IMMColor.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            summaryRow("Amount") {
                Text(verbatim: MoneyFormatter.string(order.amount, currency: order.currency))
                    .immFont(IMMFont.bodySemibold.withLineHeight(18).tabular)
                    .foregroundStyle(IMMColor.foreground)
            }
            if !order.purpose.isEmpty {
                summaryRow("Purpose") {
                    Text(verbatim: order.purpose)
                        .immFont(IMMFont.body.withLineHeight(18))
                        .foregroundStyle(IMMColor.foreground)
                }
            }
            summaryRow("Type") {
                Text(TANText.type(order))
                    .immFont(IMMFont.body.withLineHeight(18))
                    .foregroundStyle(IMMColor.foreground)
            }
        }
        .padding(.horizontal, 24)
    }

    private func summaryRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title, bundle: .module)
                    .immFont(IMMFont.small.withLineHeight(18))
                    .foregroundStyle(IMMColor.mutedForeground)
                    .frame(width: 88, alignment: .leading)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            Rule()
        }
    }

    // MARK: Progress

    private func progress(_ phase: TANPhase) -> some View {
        let times = TANText.times(phase, sentAt: sentAt)
        return VStack(alignment: .leading, spacing: 10) {
            TANStepper(state: TANStepper.Stage(phase))
            HStack(alignment: .top, spacing: 12) {
                stepLabel(title: Text("Sent to bank", bundle: .module), detail: times.sent, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                stepLabel(
                    title: Text(TANText.approvalTitle(phase)), detail: TANText.approvalDetail(phase, times: times),
                    alignment: .center, titleColor: TANText.approvalColor(phase))
                    .frame(maxWidth: .infinity, alignment: .center)
                stepLabel(
                    title: Text("Booked", bundle: .module), detail: TANText.bookedDetail(phase, times: times),
                    alignment: .trailing, titleColor: TANText.bookedColor(phase),
                    titleWeight: TANText.bookedIsDone(phase) ? .medium : .regular)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 0, trailing: 24))
        .accessibilityElement(children: .combine)
    }

    private func stepLabel(
        title: Text, detail: Text?, alignment: HorizontalAlignment, titleColor: Color = IMMColor.foreground,
        titleWeight: IMMFont.Weight = .medium
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            title
                .immFont(IMMFont.small.weighted(titleWeight))
                .foregroundStyle(titleColor)
            if let detail {
                detail
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
    }

    // MARK: Message and actions

    private func message(_ phase: TANPhase) -> some View {
        let lines = TANText.message(phase, account: source)
        return VStack(alignment: .leading, spacing: 2) {
            Text(lines.first)
                .immFont(IMMFont.bodyMedium.withLineHeight(19))
                .foregroundStyle(IMMColor.foreground)
            Text(lines.second)
                .immFont(IMMFont.body.withLineHeight(19))
                .foregroundStyle(IMMColor.mutedForeground)
        }
        .padding(EdgeInsets(top: 16, leading: 24, bottom: 0, trailing: 24))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actions(_ phase: TANPhase) -> some View {
        switch phase {
        case .waiting:
            HStack(spacing: 8) { cancelButton }
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 0, trailing: 24))
        case .booked(_, _, let order):
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    done(order)
                } label: {
                    Text("Done", bundle: .module)
                }
                .immButtonStyle(.default)
                .keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
        case .expired(_, _, let order), .failed(_, let order):
            HStack(spacing: 8) {
                cancelButton
                Spacer(minLength: 0)
                Button {
                    model.openSettings()
                } label: {
                    Text("Change TAN method", bundle: .module)
                }
                .immButtonStyle(.outline)
                Button {
                    model.bank.submit(order)
                } label: {
                    Text("Send a new request", bundle: .module)
                }
                .immButtonStyle(.default)
                .keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 0, trailing: 24))
        }
    }

    private var cancelButton: some View {
        Button {
            model.closePanel()
        } label: {
            Text("Cancel transfer", bundle: .module)
        }
        .immButtonStyle(.ghost)
        .padding(.leading, -8)
    }

    private func done(_ order: PaymentOrder) {
        model.finishTransfer(order)
    }
}

extension AppModel {
    /// "Done" on the booked TAN sheet: closes it. A booked transfer shows the source account's list, a
    /// scheduled payment or standing order the Standing orders.
    func finishTransfer(_ order: PaymentOrder) {
        closePanel()
        switch order.execution {
        case .now: navigate(to: .transactions(.account(order.fromAccount)))
        case .onDate, .standingOrder: navigate(to: .standingOrders)
        }
    }
}

// MARK: - Progress indicator

/// The three-step line: sent, approved, booked.
struct TANStepper: View {
    enum Stage: Equatable {
        /// Step 2 spinning.
        case waiting
        /// All three steps done.
        case booked
        /// Step 2 failed (expired or rejected).
        case failed

        init(_ phase: TANPhase) {
            switch phase {
            case .waiting: self = .waiting
            case .booked: self = .booked
            case .expired, .failed: self = .failed
            }
        }
    }

    let state: Stage
    @Environment(\.immDisableMotion) private var disableMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            checkCircle
            solidLine.padding(.horizontal, 6)
            middle
            if state == .booked {
                solidLine.padding(.horizontal, 6)
                checkCircle
            } else {
                DashedLine().padding(.horizontal, 6)
                emptyCircle
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 20)
    }

    private var checkCircle: some View {
        Circle().fill(IMMColor.primary)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(IMMColor.primaryForeground)
            }
    }

    private var solidLine: some View {
        Rectangle().fill(IMMColor.primary).frame(height: 2)
    }

    private var emptyCircle: some View {
        Circle().strokeBorder(IMMColor.border, lineWidth: 1.5)
            .background(Circle().fill(IMMColor.background))
            .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private var middle: some View {
        switch state {
        case .waiting:
            spinner
        case .booked:
            checkCircle
        case .failed:
            Circle().fill(IMMColor.destructive)
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(IMMColor.background)
                }
                .immPopIn(duration: 0.16, delay: 0.28)
        }
    }

    /// Ring with a quarter arc that turns once a second.
    private var spinner: some View {
        TimelineView(.animation(paused: disableMotion || reduceMotion)) { context in
            let turn = (disableMotion || reduceMotion) ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8
            ZStack {
                Circle().stroke(IMMColor.border, lineWidth: 2)
                Circle().trim(from: 0, to: 0.25)
                    .stroke(IMMColor.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90 + turn * 360))
            }
            .padding(1)
            .frame(width: 20, height: 20)
        }
    }
}

/// `border-t-2 border-dashed` between step 2 and 3.
private struct DashedLine: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(IMMColor.border, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
        }
        .frame(height: 2)
    }
}

// MARK: - Texts

/// Wording of the sheet per phase and order.
enum TANText {
    static func title(_ phase: TANPhase) -> String {
        switch phase {
        case .waiting, .expired: return String(localized: "Confirm in S-pushTAN", bundle: .module)
        case .booked(_, _, let order):
            return order.execution == .now
                ? String(localized: "Transfer booked", bundle: .module)
                : String(localized: "Payment scheduled", bundle: .module)
        case .failed: return String(localized: "Transfer not sent", bundle: .module)
        }
    }

    static func subtitle(account: TransferSource?) -> String {
        guard let account else { return String(localized: "From your account", bundle: .module) }
        let name = account.name
        let bank = account.bankName
        return String(localized: "From \(name) at \(bank)", bundle: .module)
    }

    /// "Instant payment", "SEPA transfer", "Standing order" or "Scheduled for 20.11.2026".
    static func type(_ order: PaymentOrder) -> String {
        switch order.execution {
        case .now:
            return order.instant
                ? String(localized: "Instant payment", bundle: .module)
                : String(localized: "SEPA transfer", bundle: .module)
        case .onDate(let date):
            let text = DateFormats.dayMonthYear(date)
            return String(localized: "Scheduled for \(text)", bundle: .module)
        case .standingOrder(let first):
            let text = DateFormats.dayMonthYear(first)
            return String(localized: "Standing order, first on \(text)", bundle: .module)
        }
    }

    // MARK: Step labels

    struct Times {
        var sent: Text?
        var expires: Date?
        var approved: Date?
        var booked: Date?
        var expired: Date?
    }

    static func times(_ phase: TANPhase, sentAt: Date?) -> Times {
        switch phase {
        case .waiting(let sent, _):
            return Times(sent: clock(sent), expires: sent.addingTimeInterval(300))
        case .booked(let sent, let at, _):
            return Times(sent: clock(sent), approved: at, booked: at)
        case .expired(let sent, let expiredAt, _):
            return Times(sent: clock(sent), expired: expiredAt)
        case .failed:
            return Times(sent: sentAt.map(clock))
        }
    }

    private static func clock(_ date: Date) -> Text {
        Text(verbatim: ShellText.time(date))
    }

    static func approvalTitle(_ phase: TANPhase) -> String {
        switch phase {
        case .waiting: return String(localized: "Waiting for approval", bundle: .module)
        case .booked: return String(localized: "Approved on iPhone", bundle: .module)
        case .expired: return String(localized: "Approve on iPhone", bundle: .module)
        case .failed: return String(localized: "Request failed", bundle: .module)
        }
    }

    static func approvalDetail(_ phase: TANPhase, times: Times) -> Text? {
        switch phase {
        case .waiting:
            guard let expires = times.expires else { return nil }
            let time = ShellText.time(expires)
            return Text(String(localized: "Expires \(time)", bundle: .module))
        case .booked:
            return times.approved.map { Text(verbatim: ShellText.time($0)) }
        case .expired:
            guard let expired = times.expired else { return nil }
            let time = ShellText.time(expired)
            return Text(String(localized: "Expired \(time)", bundle: .module))
        case .failed:
            return nil
        }
    }

    static func approvalColor(_ phase: TANPhase) -> Color {
        switch phase {
        case .expired, .failed: return IMMColor.destructive
        case .waiting, .booked: return IMMColor.foreground
        }
    }

    static func bookedIsDone(_ phase: TANPhase) -> Bool {
        if case .booked = phase { return true }
        return false
    }

    static func bookedColor(_ phase: TANPhase) -> Color {
        bookedIsDone(phase) ? IMMColor.foreground : IMMColor.mutedForeground
    }

    static func bookedDetail(_ phase: TANPhase, times: Times) -> Text? {
        if let booked = times.booked { return Text(verbatim: ShellText.time(booked)) }
        return Text("Not started", bundle: .module)
    }

    static func showsNotificationHint(_ phase: TANPhase) -> Bool {
        switch phase {
        case .waiting, .expired: return true
        case .booked, .failed: return false
        }
    }

    // MARK: Message

    static func message(_ phase: TANPhase, account: TransferSource?) -> (first: String, second: String) {
        switch phase {
        case .waiting:
            return (
                String(localized: "Open S-pushTAN on your phone and approve this transfer.", bundle: .module),
                String(localized: "The request stays valid for 5 minutes.", bundle: .module))
        case .booked(_, _, let order):
            let amount = MoneyFormatter.string(order.amount, currency: order.currency)
            let recipient = order.recipient
            switch order.execution {
            case .now:
                let name = account?.name ?? String(localized: "account", bundle: .module)
                return (
                    String(localized: "\(amount) is on its way to \(recipient).", bundle: .module),
                    String(localized: "The payment appears in your \(name) as soon as the bank books it.", bundle: .module))
            case .onDate(let date), .standingOrder(let date):
                let day = DateFormats.dayMonthYear(date)
                return (
                    String(localized: "\(amount) to \(recipient) is scheduled for \(day).", bundle: .module),
                    String(localized: "You'll find it under Standing orders.", bundle: .module))
            }
        case .expired:
            return (
                String(localized: "The approval request expired after 5 minutes.", bundle: .module),
                String(localized: "Nothing was sent — your money is still in your account.", bundle: .module))
        case .failed(let message, _):
            return (message, String(localized: "Nothing was sent — your money is still in your account.", bundle: .module))
        }
    }
}
