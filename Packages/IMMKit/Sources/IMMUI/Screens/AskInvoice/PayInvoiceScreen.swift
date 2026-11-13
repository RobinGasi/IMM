import IMMBanking
import IMMDesign
import IMMLedger
import Observation
import SwiftUI

/// Pay an invoice from a PDF: the invoice page on the left with its five marked values, the form read
/// from it on the right. The invoice is drawn in SwiftUI from the values in `InvoiceSample`; no file is
/// read. "Schedule" sends the payment through `BankController.submit` (TAN sheet) and then shows
/// Standing orders, where the scheduled payment appears.
///
/// The screen fills the detail area (`MainRoute.managesOwnScrolling`): the form scrolls inside its
/// column and the footer stays at the bottom.
public struct PayInvoiceScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.immWindowWidth) private var windowWidth
    @State private var invoice = PayInvoiceModel()
    @State private var form = InvoiceForm()

    public init() {}

    public var body: some View {
        let asideWidth = IMMLayout.clamp(360, fraction: 0.32, of: windowWidth, maximum: 440)
        HStack(spacing: 0) {
            InvoicePane(windowWidth: windowWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            InvoiceInspector(form: $form, snapshot: invoice.snapshot, width: asideWidth, schedule: schedule, cancel: cancel)
                .frame(width: asideWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await invoice.follow(ledger: ledger)
        }
    }

    private func schedule() {
        guard let snapshot = invoice.snapshot, let order = form.order(snapshot: snapshot) else { return }
        model.submitInvoicePayment(order)
    }

    private func cancel() {
        model.navigate(to: .transactions(invoice.snapshot?.sources.first.map { .account($0.id) } ?? .all))
    }
}

// MARK: - Model

@MainActor @Observable
final class PayInvoiceModel {
    private(set) var snapshot: PayInvoiceSnapshot?

    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(PayInvoiceQueries.snapshot) { snapshot = initial }
        do {
            for try await value in PayInvoiceQueries.observe(in: ledger) {
                snapshot = value
            }
        } catch {
            // Locked or closed: keep the last values.
        }
    }
}

extension AppModel {
    /// Sends an invoice payment through the TAN sheet. Once it is booked, a scheduled payment shows
    /// Standing orders and an immediate one the source account's transactions; the sheet's Done button
    /// closes the sheet. Cancelling or a failed request leaves the invoice on screen.
    func submitInvoicePayment(_ order: PaymentOrder) {
        let task = bank.submit(order)
        Task { @MainActor in
            await task.value
            guard case .tan(.booked)? = panel else { return }
            switch order.execution {
            case .now: navigate(to: .transactions(.account(order.fromAccount)))
            case .onDate, .standingOrder: navigate(to: .standingOrders)
            }
        }
    }
}

// MARK: - Sample invoice (the "PDF")

enum InvoiceSample {
    static let company = "Schreinerei Kaiser GmbH"
    static let address = "Venloer Str. 211 · 50823 Köln"
    static let customer = ["Lena Hoffmann", "Köln"]
    static let number = "2026-118"
    static let date = "05.11.2026"
    static let lines = [("Einbau Regal Wohnzimmer", "520,00 €"), ("Material", "17,82 €")]
    static let subtotal = "537,82 €"
    static let vat = "102,18 €"
    static let totalMinor = 64_000
    static let dueDate = LocalDate(year: 2026, month: 11, day: 26)
    static let bankLine = "Bankverbindung: Sparkasse KölnBonn · BIC COLSDE33"
    static let iban = "DE09 3705 0198 0012 6655 43"
    static let bank = "Sparkasse KölnBonn · COLSDE33"
    static let purpose = "Rechnung 2026-118"
}

// MARK: - Form state

enum InvoiceExecution: Hashable {
    case due, today
}

struct InvoiceForm {
    var recipient = InvoiceSample.company
    var iban = InvoiceSample.iban
    var amount = MoneyFormatter.string(InvoiceSample.totalMinor, symbol: false)
    var purpose = InvoiceSample.purpose
    var execution = InvoiceExecution.due
    var fromAccount: String?

    /// Minor units of the amount field (German number format); nil when it is not a number.
    var amountMinor: Int? {
        let cleaned = amount.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Decimal(string: cleaned), value >= 0 else { return nil }
        return NSDecimalNumber(decimal: value * 100).rounding(accordingToBehavior: nil).intValue
    }

    func source(in snapshot: PayInvoiceSnapshot) -> PayInvoiceSource? {
        if let fromAccount, let match = snapshot.sources.first(where: { $0.id == fromAccount }) { return match }
        return snapshot.sources.first
    }

    var ibanIsValid: Bool { IBAN.isValid(iban) }

    func execute(on snapshot: PayInvoiceSnapshot) -> PaymentExecution {
        execution == .due ? .onDate(InvoiceSample.dueDate) : .now
    }

    /// The order for the connector; nil while the form is not sendable.
    func order(snapshot: PayInvoiceSnapshot) -> PaymentOrder? {
        guard let source = source(in: snapshot), let minor = amountMinor else { return nil }
        let draft = TransferDraft(
            fromAccount: source.id, recipient: recipient, iban: iban, amountMinor: minor, purpose: purpose,
            execution: execute(on: snapshot), instant: false)
        guard draft.isSendable else { return nil }
        return draft.order(fromAccount: source.id)
    }
}

// MARK: - Invoice page

private struct InvoicePane: View {
    let windowWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            // `w-[min(460px,100%)] aspect-[210/297]` inside 32 pt of padding.
            let pageWidth = min(460, max(0, proxy.size.width - 64))
            ZStack(alignment: .top) {
                IMMColor.muted
                InvoicePage(padding: IMMLayout.clamp(28, fraction: 0.03, of: windowWidth, maximum: 44))
                    .frame(width: pageWidth, height: pageWidth * 297.0 / 210.0)
                    .padding(.top, 32)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .clipped()
    }
}

/// One of the five values marked on the page: a 2 pt outline 3 pt away and a numbered tag on its left.
private struct InvoiceMark: ViewModifier {
    let number: Int
    let delay: Double

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .overlay(alignment: .leading) {
                InvoiceNumberTag(number: number)
                    .offset(x: -21)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .strokeBorder(IMMColor.primary, lineWidth: 2)
                    .padding(-5)
            }
            .immFadeIn(duration: 0.2, delay: delay)
    }
}

private extension View {
    func invoiceMark(_ number: Int, delay: Double) -> some View {
        modifier(InvoiceMark(number: number, delay: delay))
    }
}

/// The 14 × 14 numbered square.
private struct InvoiceNumberTag: View {
    let number: Int

    var body: some View {
        Text(verbatim: String(number))
            .immFont(.micro)
            .foregroundStyle(IMMColor.primaryForeground)
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: IMMRadius.sm, style: .continuous).fill(IMMColor.primary))
    }
}

private struct InvoicePage: View {
    let padding: CGFloat

    private static let h2 = IMMFont(name: "invoiceTitle", size: 17, lineHeight: 22, weight: .semibold)
    private static let small = IMMFont.caption
    private static let tabular = IMMFont.caption.tabular
    private static let semibold = IMMFont.captionSemibold

    private func text(_ value: String, _ font: IMMFont = small, muted: Bool = false) -> some View {
        Text(verbatim: value)
            .immFont(font)
            .foregroundStyle(muted ? IMMColor.mutedForeground : IMMColor.cardForeground)
            .lineLimit(1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            parties.padding(.top, 28)
            text("Rechnung", Self.h2).padding(.top, 28)
            table.padding(.top, 14)
            due.padding(.top, 22)
            Spacer(minLength: 0)
            bank
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IMMColor.card)
        .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            text(InvoiceSample.company, IMMFont.titleMDTight)
                .invoiceMark(1, delay: 0)
            text(InvoiceSample.address, muted: true)
        }
    }

    private var parties: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                text("Rechnung an", muted: true)
                ForEach(InvoiceSample.customer, id: \.self) { text($0) }
            }
            Spacer(minLength: 0)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                GridRow {
                    text("Rechnungsnr.", muted: true)
                    text(InvoiceSample.number, Self.tabular).invoiceMark(4, delay: 0.24)
                }
                GridRow {
                    text("Datum", muted: true)
                    text(InvoiceSample.date, Self.tabular)
                }
            }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack {
                text("Beschreibung", Self.semibold, muted: true)
                Spacer(minLength: 0)
                text("Betrag", Self.semibold, muted: true)
            }
            .padding(.vertical, 6)
            .padding(.bottom, 1) // `border-b` adds to the row's height
            .overlay(alignment: .bottom) { Rule() }

            ForEach(InvoiceSample.lines, id: \.0) { line in
                HStack(spacing: 16) {
                    text(line.0, Self.tabular)
                    Spacer(minLength: 0)
                    text(line.1, Self.tabular)
                }
                .padding(.vertical, 7)
                .padding(.bottom, 1)
                .overlay(alignment: .bottom) { Rule() }
            }

            HStack(spacing: 16) {
                text("Zwischensumme", Self.tabular, muted: true)
                Spacer(minLength: 0)
                text(InvoiceSample.subtotal, Self.tabular)
            }
            .padding(.top, 7)
            .padding(.bottom, 3)
            HStack(spacing: 16) {
                text("MwSt 19 %", Self.tabular, muted: true)
                Spacer(minLength: 0)
                text(InvoiceSample.vat, Self.tabular)
            }
            .padding(.top, 3)
            .padding(.bottom, 7)

            VStack(spacing: 0) {
                Rule()
                HStack(spacing: 16) {
                    text("Gesamtbetrag", Self.semibold)
                    Spacer(minLength: 0)
                    text(MoneyFormatter.string(InvoiceSample.totalMinor), IMMFont.bodySemibold.withLineHeight(18))
                        .invoiceMark(3, delay: 0.16)
                }
                .padding(.vertical, 8)
                DoubleRule()
            }
        }
    }

    private var due: some View {
        VStack(alignment: .leading, spacing: 2) {
            text("zahlbar bis \(DateFormats.dayMonthYear(InvoiceSample.dueDate))", Self.tabular)
                .invoiceMark(5, delay: 0.32)
            text("ohne Abzug auf das unten genannte Konto.", muted: true)
                .padding(.top, 4)
        }
    }

    private var bank: some View {
        VStack(alignment: .leading, spacing: 4) {
            text(InvoiceSample.bankLine, muted: true)
            text("IBAN \(InvoiceSample.iban)", IMMFont.monoSmall)
                .invoiceMark(2, delay: 0.08)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .overlay(alignment: .top) { Rule() }
    }
}

// MARK: - Inspector

private struct InvoiceInspector: View {
    @Binding var form: InvoiceForm
    let snapshot: PayInvoiceSnapshot?
    let width: CGFloat
    let schedule: () -> Void
    let cancel: () -> Void

    var body: some View {
        GeometryReader { proxy in
            // CSS `clamp(10px, 1.8vh, 16px)`; the window is the detail area plus the 56 pt toolbar.
            let gap = IMMLayout.clamp(10, fraction: 0.018, of: proxy.size.height + IMMLayout.toolbarHeight, maximum: 16)
            VStack(spacing: 0) {
                header
                ScrollView(.vertical) {
                    fields(gap: gap)
                        .padding(.top, gap)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
                footer
            }
        }
        .padding(.leading, 1)
        .background(IMMColor.background)
        .overlay(alignment: .leading) { IMMColor.border.frame(width: 1) }
        .clipped()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Read from the invoice", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
            Text("Each value is marked on the page with its number.", bundle: .module)
                .immFont(IMMFont.small.withLineHeight(18))
                .foregroundStyle(IMMColor.mutedForeground)
        }
        .padding(.top, 20)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ number: Int, _ title: Text, badge: some View) -> some View {
        HStack(spacing: 8) {
            InvoiceNumberTag(number: number)
            title
                .immFont(.smallMedium)
                .foregroundStyle(IMMColor.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            badge
        }
    }

    /// The aside's 1 pt left border and 24 pt side padding.
    private var innerWidth: CGFloat { width - 1 - 48 }

    private func fields(gap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            VStack(alignment: .leading, spacing: 6) {
                label(1, Text("Recipient", bundle: .module), badge: Badge(Text("Sure", bundle: .module)))
                IMMTextField(text: $form.recipient)
            }
            .immRiseIn(duration: 0.26, delay: 0.1)

            VStack(alignment: .leading, spacing: 6) {
                label(2, Text("IBAN", bundle: .module), badge: Badge(Text("Check this", bundle: .module), variant: .warning))
                IMMTextField(text: $form.iban, isError: !form.ibanIsValid, style: IMMFont.mono)
                ibanNotes
            }
            .immRiseIn(duration: 0.26, delay: 0.15)

            VStack(alignment: .leading, spacing: 6) {
                label(3, Text("Amount", bundle: .module), badge: Badge(Text("Sure", bundle: .module)))
                InputGroup(text: $form.amount, isError: form.amountMinor == nil, leading: { EmptyView() }) {
                    Text(verbatim: "€")
                }
                .multilineTextAlignment(.trailing)
            }
            .immRiseIn(duration: 0.26, delay: 0.2)

            VStack(alignment: .leading, spacing: 6) {
                label(4, Text("Purpose", bundle: .module), badge: Badge(Text("Sure", bundle: .module)))
                IMMTextField(text: $form.purpose)
            }
            .immRiseIn(duration: 0.26, delay: 0.25)

            VStack(alignment: .leading, spacing: 6) {
                label(5, Text("Execute on", bundle: .module), badge: Badge(Text("Likely", bundle: .module), variant: .outline))
                SelectTrigger(selection: $form.execution, options: executionOptions, width: innerWidth)
            }
            .immRiseIn(duration: 0.26, delay: 0.3)

            fromSection(gap: gap)
                .immRiseIn(duration: 0.26, delay: 0.35)
        }
    }

    private var executionOptions: [IMMOption<InvoiceExecution>] {
        let today = snapshot.map { DateFormats.dayMonthYear($0.today) } ?? ""
        return [
            IMMOption(.due, Text("\(DateFormats.dayMonthYear(InvoiceSample.dueDate)) (due date)", bundle: .module)),
            IMMOption(.today, Text("Today, \(today)", bundle: .module)),
        ]
    }

    @ViewBuilder
    private var ibanNotes: some View {
        if form.ibanIsValid {
            HStack(spacing: 6) {
                IMMIcon("check", size: 14, color: IMMColor.credit)
                Text(verbatim: IBAN.normalized(form.iban) == IBAN.normalized(InvoiceSample.iban)
                    ? InvoiceSample.bank : String(localized: "Valid IBAN", bundle: .module))
                    .immFont(IMMFont.small.tabular)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            HStack(alignment: .top, spacing: 6) {
                IMMIcon("triangle-alert", size: 14, color: IMMColor.warning)
                    .padding(.top, 1)
                Text("IBAN read from a PDF — compare it with the invoice.", bundle: .module)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 6) {
                IMMIcon("circle-alert", size: 14, color: IMMColor.destructive)
                Text("This is not a valid IBAN.", bundle: .module)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.destructive)
            }
        }
    }

    private func fromSection(gap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From", bundle: .module)
                .immFont(.smallMedium)
                .foregroundStyle(IMMColor.foreground)
            if let snapshot {
                SelectTrigger(
                    selection: Binding(
                        get: { form.source(in: snapshot)?.id ?? "" },
                        set: { form.fromAccount = $0 }),
                    options: snapshot.sources.map {
                        IMMOption($0.id, verbatim: "\($0.name) · \($0.bankName) · \(MoneyFormatter.string($0.balance))")
                    },
                    width: innerWidth)
                if let source = form.source(in: snapshot), let minor = form.amountMinor {
                    Text("Leaves \(MoneyFormatter.string(source.balance - minor)) at today's balance.", bundle: .module)
                        .immFont(IMMFont.small.tabular)
                        .foregroundStyle(IMMColor.mutedForeground)
                }
            }
        }
        .padding(.top, gap)
        .overlay(alignment: .top) { Rule() }
    }

    private var scheduleTitle: Text {
        guard let minor = form.amountMinor else { return Text("Schedule", bundle: .module) }
        let amount = MoneyFormatter.string(minor)
        if form.execution == .due {
            return Text("Schedule \(amount) for \(DateFormats.dayMonth(InvoiceSample.dueDate))", bundle: .module)
        }
        return Text("Pay \(amount) today", bundle: .module)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: cancel) { Text("Cancel", bundle: .module) }
                    .immButtonStyle(.outline)
                Button(action: schedule) { scheduleTitle }
                    .immButtonStyle(.default)
                    .disabled(snapshot.flatMap { form.order(snapshot: $0) } == nil)
            }
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    IMMIcon("cpu", size: 13)
                    Text("Worked out on this Mac", bundle: .module)
                        .immFont(.caption)
                }
                .foregroundStyle(IMMColor.mutedForeground)
                Spacer(minLength: 0)
                Text("You'll confirm with pushTAN.", bundle: .module)
                    .immFont(.small)
                    .foregroundStyle(IMMColor.mutedForeground)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .overlay(alignment: .top) { Rule() }
    }
}
