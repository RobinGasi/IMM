import Foundation
import GRDB
import IMMLedger
@testable import IMMUI
import Testing

@MainActor
@Suite(.serialized) struct ManualAccountFlowTests {
    private func setupModel() async throws -> ScenarioWorld {
        let world = ScenarioWorld()
        try await world.model.createVault(at: world.vaultURL, password: ScenarioWorld.password, enableTouchID: false)
        #expect(world.model.phase == .needsBank)
        world.model.lockOnSleep = false
        return world
    }

    @Test func creatingTheFirstManualAccountFinishesOnboarding() async throws {
        let world = try await setupModel()
        defer { world.finish() }
        let model = world.model

        let id = try await model.createManualAccount(
            ManualAccountInput(name: "Haushaltskasse", kind: .giro, openingBalance: 125_000))
        #expect(id.hasPrefix("manual-"))
        #expect(model.phase == .ready)

        let shown = await world.eventually {
            model.sidebar.snapshot.accounts.count == 1 && model.sidebar.snapshot.netWorth == 125_000
        }
        #expect(shown)
        let row = try #require(model.sidebar.snapshot.accounts.first)
        #expect(row.id == id && row.name == "Haushaltskasse" && row.kind == .giro)
        #expect(row.value == 125_000 && row.currency == "EUR" && row.syncStatus == .never)

        let manual = await model.manualAccounts()
        #expect(manual.map(\.id) == [id])
        #expect(manual.first?.isManual == true)
    }

    @Test func bookingsMoveNetWorthAndDeletingTakesThemBack() async throws {
        let world = try await setupModel()
        defer { world.finish() }
        let model = world.model
        let id = try await model.createManualAccount(
            ManualAccountInput(name: "Bargeld", kind: .wallet, openingBalance: 10_000))
        let day = LocalDate(Date())

        let expense = try await model.addManualBooking(
            ManualBookingInput(accountID: id, bookingDate: day, amount: -2_550, counterparty: "Markt", purpose: "Gemüse"))
        let income = try await model.addManualBooking(
            ManualBookingInput(accountID: id, bookingDate: day, amount: 1_000, counterparty: "Lena", purpose: "Zurück"))
        let moved = await world.eventually { model.sidebar.snapshot.netWorth == 10_000 - 2_550 + 1_000 }
        #expect(moved)
        #expect(model.sidebar.snapshot.accounts.first?.value == 8_450)

        try await model.deleteManualBooking(id: expense)
        let reversed = await world.eventually { model.sidebar.snapshot.netWorth == 11_000 }
        #expect(reversed)
        try await model.deleteManualBooking(id: income)
        let back = await world.eventually { model.sidebar.snapshot.netWorth == 10_000 }
        #expect(back)
        #expect(model.phase == .ready)
    }

    @Test func manualAccountsAreSeparatedFromBankAccountsAndBankRowsAreRefused() async throws {
        let world = ScenarioWorld()
        defer { world.finish() }
        let model = world.model
        try await world.createReadyVault()
        let loaded = await world.eventually { model.sidebar.snapshot.accounts.count == 5 }
        #expect(loaded)
        #expect(await model.manualAccounts().isEmpty)

        let id = try await model.createManualAccount(
            ManualAccountInput(name: "Cash", kind: .wallet, openingBalance: 2_000))
        #expect(model.phase == .ready)
        #expect(await model.manualAccounts().map(\.id) == [id])
        let sorted = await world.eventually { model.sidebar.snapshot.accounts.last?.id == id }
        #expect(sorted)

        // No bank login: the sync loop only visits accounts of a login, so a manual account is never fetched.
        let ledger = try #require(model.ledger)
        let (exists, login) = try await ledger.database.read { db -> (Bool, String?) in
            let exists = try Int.fetchOne(db, sql: "SELECT 1 FROM account WHERE id = ?", arguments: [id]) != nil
            let login = try String.fetchOne(db, sql: "SELECT bank_login_id FROM account WHERE id = ?", arguments: [id])
            return (exists, login)
        }
        #expect(exists)
        #expect(login == nil)

        let bankAccount = try await world.accountID("Girokonto")
        await #expect(throws: ManualLedgerError.notManual(id: bankAccount)) {
            try await model.addManualBooking(
                ManualBookingInput(accountID: bankAccount, bookingDate: LocalDate(Date()), amount: -100, counterparty: "x"))
        }
    }
}
