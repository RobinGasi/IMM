import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct AskInvoiceTests {
    private let nbsp = "\u{00A0}"

    private func render(slug: String, panel: Panel? = nil, route: MainRoute) async throws -> Double {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: route)
        model.panel = panel
        let size = CGSize(width: 1440, height: 900)
        let value = try await assertMatchesDesign(
            MainWindowView().environment(model), slug: slug, size: size, settle: 0.4,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        print("ASKINVOICE \(slug) mismatch \(value)")
        return value
    }

    // MARK: Comparison with the design

    /// The artboard draws a simplified Overview (net worth and account list only) behind the panel; the app
    /// shows the real Overview, which has its own comparison test. So the content pane around the panel is
    /// painted over in both images; sidebar, toolbar, scrim and the panel itself are compared.
    @Test func askMatchesDesign() async throws {
        let slug = "app-10-ask-desktop"
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .overview)
        model.panel = .ask
        let size = CGSize(width: 1440, height: 900)
        let rep = try await ScreenRenderer.render(
            MainWindowView().environment(model), size: size, settle: 0.4,
            environment: { AnyView($0.environment(\.immWindowWidth, size.width)) })
        let rendered = try rep.requireCGImage()
        let reference = try DesignReference.image(slug: slug)

        // Content pane minus the panel (x 360…1080, y 72…618).
        let pane = CGRect(x: 252, y: 56, width: 1188, height: 844)
        let panel = CGRect(x: 360, y: 72, width: 720, height: 546)
        let mask = [
            CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: panel.minY - pane.minY),
            CGRect(x: pane.minX, y: panel.minY, width: panel.minX - pane.minX, height: panel.height),
            CGRect(x: panel.maxX, y: panel.minY, width: pane.maxX - panel.maxX, height: panel.height),
            CGRect(x: pane.minX, y: panel.maxY, width: pane.width, height: pane.maxY - panel.maxY),
        ]
        let unmasked = try DesignDiff.mismatch(reference, rendered).fraction
        let result = try DesignDiff.mismatch(try paint(reference, over: mask), try paint(rendered, over: mask))
        try DesignDiff.record(slug: slug, fraction: result.fraction, diff: result.diff, rendered: rendered)
        print("ASKINVOICE \(slug) mismatch \(result.fraction) (\(unmasked) with the Overview behind the panel)")
        #expect(result.fraction <= DesignThresholds.limit, "\(slug) mismatch \(result.fraction) exceeds \(DesignThresholds.limit)")
    }

    /// `image` with `rects` (top-left origin, pixels) filled with one flat colour.
    private func paint(_ image: CGImage, over rects: [CGRect]) throws -> CGImage {
        let width = image.width, height = image.height
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw DesignDiffError.imageConversionFailed }
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        for rect in rects {
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        guard let result = context.makeImage() else { throw DesignDiffError.imageConversionFailed }
        return result
    }

    @Test func payInvoiceMatchesDesign() async throws {
        _ = try await render(slug: "app-13-pay-invoice-desktop", route: .payInvoice)
    }

    // MARK: Data

    @Test func askAnswerCarriesTheDesignedFigures() throws {
        let store = try DemoVaultFixture.shared().store
        let answer = try #require(try store.database.read(AskQueries.answer))
        #expect(answer.question == "How much did we spend on eating out since June?")
        #expect(answer.headline == "Leisure & eating out, 01.06.–12.11.2026")
        #expect(MoneyFormatter.string(answer.total) == "−1.782,65\(nbsp)€")
        #expect(answer.confidenceLabel == "Sure")
        #expect(answer.summary == "About 321\(nbsp)€ a month, 14 % more than the same months last year")
        #expect(answer.monthly.map(\.label) == ["Jun", "Jul", "Aug", "Sep", "Oct", "Nov"])
        #expect(answer.monthly.map { Int((Double($0.amount) / 100).rounded()) } == [240, 300, 280, 300, 486, 177])
        #expect(answer.monthly.map(\.partial) == [false, false, false, false, false, true])
        #expect(answer.monthlyCaption == "€ per month · Nov so far")
        #expect(answer.groups.map(\.name) == ["Lieferando", "Café Fassbender", "Restaurants, bars and other"])
        #expect(answer.groups.map(\.countText) == ["25 orders", "11 visits", "39 payments"])
        #expect(answer.groups.map { MoneyFormatter.string($0.amount) } == [
            "−506,62\(nbsp)€", "−204,65\(nbsp)€", "−1.071,38\(nbsp)€",
        ])
        #expect(answer.groups.reduce(0) { $0 + $1.amount } == answer.total)
        #expect(answer.totalLabel == "Total since 01.06.")
        #expect(answer.transactionCount == 75)
        #expect(answer.actions == ["Set a 170\(nbsp)€ monthly budget", "Compare with 2025", "Pay an invoice from a PDF"])
    }

    @Test func payInvoiceSnapshotListsTheSources() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(PayInvoiceQueries.snapshot)
        #expect(DateFormats.dayMonthYear(snapshot.today) == "12.11.2026")
        #expect(snapshot.sources.map(\.name) == ["Girokonto", "Tagesgeld"])
        #expect(snapshot.sources.map { MoneyFormatter.string($0.balance) } == ["2.418,36\(nbsp)€", "12.050,00\(nbsp)€"])
        #expect(IBAN.isValid(InvoiceSample.iban))
    }

    @Test func formReadsTheDesignedValues() throws {
        let store = try DemoVaultFixture.shared().store
        let snapshot = try store.database.read(PayInvoiceQueries.snapshot)
        var form = InvoiceForm()
        #expect(form.amountMinor == 64_000)
        let order = try #require(form.order(snapshot: snapshot))
        #expect(order.recipient == "Schreinerei Kaiser GmbH")
        #expect(order.iban == "DE09370501980012665543")
        #expect(order.amount == 64_000)
        #expect(order.purpose == "Rechnung 2026-118")
        #expect(order.execution == .onDate(LocalDate(year: 2026, month: 11, day: 26)))
        #expect(order.fromAccount == snapshot.sources.first?.id)
        // The balance after the payment, as printed under "From".
        #expect(MoneyFormatter.string(try #require(snapshot.sources.first).balance - 64_000) == "1.778,36\(nbsp)€")

        form.execution = .today
        #expect(form.order(snapshot: snapshot)?.execution == .now)
        form.amount = "0,00"
        #expect(form.order(snapshot: snapshot) == nil)
        form.amount = "640,00"
        form.iban = "DE00 1234"
        #expect(form.order(snapshot: snapshot) == nil)
        form.iban = InvoiceSample.iban
        form.amount = "1.234,50"
        #expect(form.amountMinor == 123_450)
        form.amount = "abc"
        #expect(form.amountMinor == nil)
    }

    // MARK: Behaviour

    @Test func schedulingBooksAStandingOrderAndShowsStandingOrders() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .payInvoice)
        let snapshot = try await fixture.store.database.read(PayInvoiceQueries.snapshot)
        let order = try #require(InvoiceForm().order(snapshot: snapshot))
        let before = try await fixture.store.database.read { try StandingOrderRecord.live().fetchCount($0) }

        model.submitInvoicePayment(order)
        // The demo connector approves after 3 s.
        for _ in 0..<80 {
            if model.route == .standingOrders { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.route == .standingOrders)
        if case .tan(.booked)? = model.panel {} else { Issue.record("TAN sheet is not in the booked phase: \(String(describing: model.panel))") }
        let after = try await fixture.store.database.read { try StandingOrderRecord.live().fetchCount($0) }
        #expect(after == before + 1)
    }
}
