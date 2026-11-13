import AppKit
import GRDB
import IMMBanking
import IMMDesign
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

// MARK: - Backdrops

/// The static list the artboards show under the panels (they draw a simplified list, not the full
/// Transactions screen). The sidebar, toolbar and panel host are the real ones.
private enum TransferBackdrop {
    case threeColumnList
    case balanceList

    struct Row {
        var date: String
        var shortDate: String
        var payee: String
        var detail: String
        var category: String
        var color: Color
        var amount: String
        var balance: String
    }

    static let rows: [Row] = [
        Row(date: "11.11.2026", shortDate: "11.11.", payee: "REWE", detail: "Kartenzahlung · REWE Markt GmbH, Venloer Str.",
            category: "Groceries", color: IMMColor.chart5, amount: "−63,48 €", balance: "2.418,36 €"),
        Row(date: "10.11.2026", shortDate: "10.11.", payee: "Lieferando", detail: "Lieferando.de Bestellung 4KX9-22T · Pizzeria Ehrenfeld",
            category: "Leisure & eating out", color: IMMColor.chart2, amount: "−27,90 €", balance: "2.481,84 €"),
        Row(date: "09.11.2026", shortDate: "09.11.", payee: "dm-drogerie markt", detail: "Kartenzahlung · dm Köln Ehrenfeld, Venloer Str.",
            category: "Groceries", color: IMMColor.chart5, amount: "−18,45 €", balance: "2.509,74 €"),
        Row(date: "07.11.2026", shortDate: "07.11.", payee: "Deutsche Bahn", detail: "DB Fernverkehr · Köln Hbf – Frankfurt (Main) Hbf",
            category: "Mobility", color: IMMColor.chart3, amount: "−49,90 €", balance: "2.528,19 €"),
        Row(date: "05.11.2026", shortDate: "05.11.", payee: "Stadtwerke Köln Strom", detail: "Abschlag Strom 11/2026 · Lastschrift",
            category: "Housing", color: IMMColor.chart1, amount: "−86,00 €", balance: "2.578,09 €"),
    ]
}

private struct BackdropListView: View {
    let kind: TransferBackdrop
    @Environment(\.immWindowWidth) private var width

    var body: some View {
        let padding = IMMLayout.contentPadding(windowWidth: width)
        VStack(spacing: 0) {
            switch kind {
            case .threeColumnList: simple
            case .balanceList: detailed
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .padding(.horizontal, padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IMMColor.background)
    }

    // MARK: App / 4 New transfer

    private var simple: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Date").frame(width: 88, alignment: .leading)
                Text("Payee").frame(maxWidth: .infinity, alignment: .leading)
                Text("Category").frame(width: 200, alignment: .leading)
                Text("Amount").frame(width: 120, alignment: .trailing)
            }
            .immFont(.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .frame(height: 28)
            .overlay(alignment: .bottom) { Rule() }
            ForEach(Array(TransferBackdrop.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    Text(verbatim: row.date).foregroundStyle(IMMColor.mutedForeground).frame(width: 88, alignment: .leading)
                    Text(verbatim: row.payee).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    HStack(spacing: 8) {
                        Circle().fill(row.color).frame(width: 8, height: 8)
                        Text(verbatim: row.category).foregroundStyle(IMMColor.mutedForeground).lineLimit(1)
                    }
                    .frame(width: 200, alignment: .leading)
                    Text(verbatim: row.amount).frame(width: 120, alignment: .trailing)
                }
                .immFont(IMMFont.body.tabular)
                .foregroundStyle(IMMColor.foreground)
                .frame(height: 40)
                .overlay(alignment: .bottom) { Rule() }
            }
        }
    }

    // MARK: Errors / 2 TAN expired and the transfer states

    private var detailed: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Date").frame(width: 52, alignment: .leading)
                Text("Payee and purpose").frame(maxWidth: .infinity, alignment: .leading)
                Text("Category").frame(maxWidth: .infinity, alignment: .leading)
                Text("Amount").frame(width: 112, alignment: .trailing)
                Text("Balance").frame(width: 112, alignment: .trailing)
            }
            .immFont(.captionSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .frame(height: 28)
            .overlay(alignment: .bottom) { Rule() }
            ForEach(Array(TransferBackdrop.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    Text(verbatim: row.shortDate).foregroundStyle(IMMColor.mutedForeground).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: row.payee.replacingOccurrences(of: "Stadtwerke Köln Strom", with: "Stadtwerke Köln"))
                            .immFont(.bodyMedium.withLineHeight(16))
                        Text(verbatim: row.detail).immFont(.small).foregroundStyle(IMMColor.mutedForeground)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Circle().fill(row.color).frame(width: 8, height: 8)
                        Text(verbatim: row.category).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: row.amount).frame(width: 112, alignment: .trailing)
                    Text(verbatim: row.balance).foregroundStyle(IMMColor.mutedForeground).frame(width: 112, alignment: .trailing)
                }
                .immFont(IMMFont.body.withLineHeight(16).tabular)
                .foregroundStyle(IMMColor.foreground)
                .frame(height: 44)
                .overlay(alignment: .bottom) { Rule() }
            }
        }
    }
}

/// Real sidebar, toolbar and panel host over the artboards' static list.
private struct TransferPanelWindow: View {
    let model: AppModel
    let backdrop: TransferBackdrop

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let sidebarWidth = IMMLayout.sidebarWidth(windowWidth: width)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    SidebarView().frame(width: sidebarWidth)
                    VStack(spacing: 0) {
                        ToolbarView()
                        BackdropListView(kind: backdrop)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                PanelHost(windowSize: proxy.size, sidebarWidth: sidebarWidth)
            }
            .environment(\.immWindowWidth, width)
        }
        .background(IMMColor.background)
        .environment(model)
    }
}

// MARK: - Tests

@MainActor
@Suite(.serialized) struct TransferTests {
    private let size = CGSize(width: 1440, height: 900)

    private func local(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: hour, minute: minute)) ?? Date()
    }

    private func accountID(_ store: LedgerStore, name: String) throws -> String {
        try store.database.read { db in
            try #require(try AccountRecord.live().filter(Column("name") == name).fetchOne(db)).id
        }
    }

    private func jonasDraft() -> TransferDraft {
        TransferDraft(
            recipient: "Jonas Weber", iban: "DE89 3704 0044 0532 0130 00", amountMinor: 12_000,
            purpose: "Konzertkarten Dezember", execution: .now, instant: true)
    }

    private func jonasOrder(from account: String) -> PaymentOrder {
        jonasDraft().order(fromAccount: account)
    }

    private func render(
        slug: String, backdrop: TransferBackdrop, panel: (String) -> Panel,
        settle: TimeInterval = 0.5
    ) async throws -> Double {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        let giro = try accountID(fixture.store, name: "Girokonto")
        model.navigate(to: .transactions(.account(giro)))
        model.panel = panel(giro)
        let window = TransferPanelWindow(model: model, backdrop: backdrop)
        let value = try await assertMatchesDesign(
            window, slug: slug, size: size, settle: settle,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        print("TRANSFER \(slug) mismatch \(value)")
        return value
    }

    // MARK: Comparison with the design

    @Test func newTransferMatchesDesign() async throws {
        _ = try await render(
            slug: "app-4-new-transfer-desktop", backdrop: .threeColumnList,
            panel: { _ in .newTransfer(jonasDraft()) })
    }

    @Test func waitingMatchesDesign() async throws {
        _ = try await render(
            slug: "states-transfer-waiting-desktop", backdrop: .balanceList,
            panel: { giro in .tan(.waiting(sentAt: local(14, 31), order: jonasOrder(from: giro))) })
    }

    @Test func bookedMatchesDesign() async throws {
        _ = try await render(
            slug: "states-transfer-booked-desktop", backdrop: .balanceList,
            panel: { giro in .tan(.booked(sentAt: local(14, 31), at: local(14, 32), order: jonasOrder(from: giro))) })
    }

    @Test func expiredMatchesDesign() async throws {
        _ = try await render(
            slug: "errors-2-tan-expired-desktop", backdrop: .balanceList,
            panel: { giro in .tan(.expired(sentAt: local(8, 36), expiredAt: local(8, 41), order: jonasOrder(from: giro))) })
    }

    @Test func realWindowRendersTheSheet() async throws {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        let giro = try accountID(fixture.store, name: "Girokonto")
        model.navigate(to: .transactions(.account(giro)))
        model.panel = .newTransfer(jonasDraft())
        let rep = try await ScreenRenderer.render(
            MainWindowView().environment(model), size: size, settle: 0.5,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        #expect(rep.pixelsWide == 1440)
    }

    // MARK: Form rules

    @Test func amountParsingFollowsGermanInput() {
        #expect(TransferInput.amount("120,00") == 12_000)
        #expect(TransferInput.amount("1.200,5") == 120_050)
        #expect(TransferInput.amount("120") == 12_000)
        #expect(TransferInput.amount("1200.50") == 120_050)
        #expect(TransferInput.amount("1.200") == 120_000)
        #expect(TransferInput.amount("0,00") == 0)
        #expect(TransferInput.amount("") == nil)
        #expect(TransferInput.amount("12,345") == nil)
        #expect(TransferInput.amount("abc") == nil)
        #expect(TransferInput.date("20.11.2026") == LocalDate(year: 2026, month: 11, day: 20))
        #expect(TransferInput.date("31.11.2026") == nil)
    }

    @Test func sendNeedsValidIBANRecipientAndAmount() {
        let form = TransferFormModel(seed: jonasDraft())
        form.fromAccount = "giro"
        #expect(form.canSend)
        #expect(form.sendTitle == "Send 120,00 €")
        #expect(form.bankDescription == "Commerzbank Köln · COBADEFFXXX")

        form.amountText = "75,5"
        #expect(form.sendTitle == "Send 75,50 €")
        form.amountText = ""
        #expect(!form.canSend)
        #expect(form.sendTitle == "Send")
        form.amountText = "0,00"
        #expect(!form.canSend)
        form.amountText = "120,00"
        #expect(form.canSend)

        form.iban = "DE89 3704 0044 0532 0130 01"
        #expect(!form.ibanIsValid)
        #expect(form.showsIBANError)
        #expect(!form.canSend)
        form.iban = "DE89 3704 0044 0532 0130 00"
        #expect(form.canSend)

        form.recipient = "   "
        #expect(!form.canSend)
        form.recipient = "Jonas Weber"
        #expect(form.canSend)

        form.select(.onDate)
        form.dateText = "garbage"
        #expect(!form.canSend)
        form.dateText = "20.11.2026"
        #expect(form.canSend)
        #expect(form.draft.execution == .onDate(LocalDate(year: 2026, month: 11, day: 20)))
        #expect(!form.draft.instant)
    }

    @Test func formFillsTheIBANOfASavedRecipient() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(TransferQueries.snapshot)
        #expect(snapshot.sources.map(\.name) == ["Girokonto", "Tagesgeld"])
        #expect(snapshot.today == LocalDate(year: 2026, month: 11, day: 12))

        let form = TransferFormModel(seed: nil)
        form.apply(snapshot)
        #expect(form.fromAccount == snapshot.sources.first?.id)
        #expect(form.instant)
        #expect(!form.canSend)

        form.recipient = "Jonas Weber"
        form.recipientEdited()
        #expect(form.iban == "DE89 3704 0044 0532 0130 00")
        #expect(form.showsSavedRecipientHint)
        #expect(form.ibanIsValid)
    }

    // MARK: Booking

    @Test func sendingTheDesignedTransferBooksIt() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        let giro = try accountID(fixture.store, name: "Girokonto")
        let before = try await fixture.store.database.read { try #require(try AccountRecord.fetchOne($0, key: giro)).balance }
        #expect(before == 241_836)

        let form = TransferFormModel(seed: jonasDraft())
        form.apply(try await fixture.store.database.read(TransferQueries.snapshot))
        #expect(form.canSend)
        let task = model.bank.submit(form.draft)
        await task.value

        guard case .tan(.booked(_, _, let order)) = model.panel else {
            Issue.record("Expected the booked TAN phase, got \(String(describing: model.panel))")
            return
        }
        #expect(order.amount == 12_000)
        let (balance, row) = try await fixture.store.database.read { db -> (Int, TransactionRecord?) in
            let balance = try #require(try AccountRecord.fetchOne(db, key: giro)).balance
            let row = try TransactionRecord.live()
                .filter(Column("account_id") == giro && Column("counterparty_name") == "Jonas Weber")
                .fetchOne(db)
            return (balance, row)
        }
        #expect(MoneyFormatter.string(balance) == "2.298,36\u{00A0}€")
        #expect(row?.amount == -12_000)
        #expect(row?.purpose == "Konzertkarten Dezember")
        #expect(row?.counterpartyIban == "DE89370400440532013000")
    }

    // MARK: New standing order

    private func standingOrderDraft() -> TransferDraft {
        var draft = jonasDraft()
        draft.recipient = "Verein Ehrenfeld e.V."
        draft.iban = "DE89 3704 0044 0532 0130 00"
        draft.amountMinor = 2_500
        draft.purpose = "Mitgliedsbeitrag"
        draft.execution = .standingOrder(firstExecution: LocalDate(year: 2026, month: 12, day: 1))
        draft.instant = false
        return draft
    }

    @Test func standingOrderDraftSelectsTheModeAndShowsTheDateRow() async throws {
        let form = TransferFormModel(seed: TransferDraft(execution: .standingOrder(firstExecution: LocalDate(year: 2026, month: 12, day: 1))))
        #expect(form.mode == .standingOrder)
        #expect(form.dateText == "01.12.2026")
        #expect(!form.instant)
        #expect(form.dateIsValid)
        #expect(form.execution == .standingOrder(firstExecution: LocalDate(year: 2026, month: 12, day: 1)))
        #expect(!form.canSend)

        // The panel draws the date row ("First on") in this mode and the instant row only for "Now".
        let fixture = try DemoVaultFixture.shared()
        let giro = try accountID(fixture.store, name: "Girokonto")
        let standing = try await panelPixels(fixture, giro: giro, draft: TransferDraft(execution: .standingOrder(firstExecution: LocalDate(year: 2026, month: 12, day: 1))))
        let now = try await panelPixels(fixture, giro: giro, draft: TransferDraft())
        #expect(standing != now)
        // The label column of that row ("First on") is drawn only in the dated modes: "Now" shows the
        // instant switch there, whose label sits in the other column.
        #expect(standing.textPixelCount(in: PanelPixels.firstOnLabel) > 20)
        #expect(now.textPixelCount(in: PanelPixels.firstOnLabel) == 0)
    }

    @Test func newStandingOrderIsBookedAndDoneShowsTheStandingOrders() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        // As the Standing orders screen opens it.
        model.navigate(to: .standingOrders)
        let first = LocalDate(year: 2026, month: 12, day: 1)
        model.openNewTransfer(TransferDraft(execution: .standingOrder(firstExecution: first)))
        guard case .newTransfer(let seed) = model.panel else {
            Issue.record("panel is \(String(describing: model.panel))")
            return
        }
        #expect(seed?.execution == .standingOrder(firstExecution: first))

        let giro = try accountID(fixture.store, name: "Girokonto")
        let countBefore = try await fixture.store.database.read { try StandingOrderRecord.live().fetchCount($0) }
        let balanceBefore = try await fixture.store.database.read { try #require(try AccountRecord.fetchOne($0, key: giro)).balance }

        let form = TransferFormModel(seed: standingOrderDraft())
        form.apply(try await fixture.store.database.read(TransferQueries.snapshot))
        #expect(form.mode == .standingOrder)
        #expect(form.canSend)
        await model.bank.submit(form.draft).value

        guard case .tan(.booked(_, _, let order)) = model.panel else {
            Issue.record("Expected the booked TAN phase, got \(String(describing: model.panel))")
            return
        }
        #expect(order.execution == .standingOrder(firstExecution: first))
        let (orders, balanceAfter) = try await fixture.store.database.read { db in
            (try StandingOrderRecord.live().filter(Column("recipient") == "Verein Ehrenfeld e.V.").fetchAll(db),
             try #require(try AccountRecord.fetchOne(db, key: giro)).balance)
        }
        #expect(try await fixture.store.database.read { try StandingOrderRecord.live().fetchCount($0) } == countBefore + 1)
        let row = try #require(orders.first)
        #expect(row.amount == -2_500)
        #expect(row.rhythm == .monthly)
        #expect(row.nextExecution == first)
        #expect(row.accountId == giro)
        // Nothing is debited until the order runs.
        #expect(balanceAfter == balanceBefore)

        model.finishTransfer(order)
        #expect(model.panel == nil)
        #expect(model.route == .standingOrders)
    }

    @Test func doneAfterANormalTransferShowsTheSourceAccount() throws {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        let order = jonasOrder(from: "giro-1")
        model.panel = .tan(.booked(sentAt: Date(), at: Date(), order: order))
        model.finishTransfer(order)
        #expect(model.panel == nil)
        #expect(model.route == .transactions(.account("giro-1")))
    }

    // MARK: Helpers

    /// The window with the New transfer panel open on `draft`, as pixels.
    private func panelPixels(_ fixture: DemoVaultFixture, giro: String, draft: TransferDraft) async throws -> PanelPixels {
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .transactions(.account(giro)))
        model.panel = .newTransfer(draft)
        let rep = try await ScreenRenderer.render(
            MainWindowView().environment(model), size: size, settle: 0.7,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        return PanelPixels(rep: rep)
    }
}

/// Pixels of a rendered window with a small helper to count text pixels in a region.
private struct PanelPixels: Equatable {
    let rep: NSBitmapImageRep

    /// Label column of the row below "Execute" in the 560 px panel (x 440 + 24 … 560 + 96 - 4, y 372…398).
    static let firstOnLabel = CGRect(x: 470, y: 372, width: 92, height: 26)

    func textPixelCount(in region: CGRect) -> Int {
        var count = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.brightnessComponent < 0.75 { count += 1 }
            }
        }
        return count
    }

    static func == (lhs: PanelPixels, rhs: PanelPixels) -> Bool {
        lhs.rep.tiffRepresentation == rhs.rep.tiffRepresentation
    }
}
