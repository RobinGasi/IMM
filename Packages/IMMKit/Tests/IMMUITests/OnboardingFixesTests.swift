import Foundation
import IMMBanking
import IMMVault
@testable import IMMUI
import Testing

private final class BundleAnchor {}

private let unavailable = BankError.bankRejected(code: 0, message: "Connecting to banks is not available yet.")

@MainActor
@Suite struct OnboardingFixesTests {
    // MARK: Connector

    @Test func defaultConnectorWithoutProductIDIsTheDemoBankInDebugBuilds() {
        // The test bundle has no `IMMFinTSProductID`.
        let connector = AppModel.makeDefaultConnector(bundle: Bundle(for: BundleAnchor.self))
        #if DEBUG
        #expect(connector.id == DemoConnector.connectorID)
        #else
        #expect(connector.id == NoBankConnector.connectorID)
        #endif
    }

    @Test func noBankConnectorHasNoBanksAndRefusesEverythingElse() async throws {
        let connector = NoBankConnector()
        #expect(connector.id == "none")
        #expect(connector.id == NoBankConnector.connectorID)
        #expect(!connector.supportsPayments)
        #expect(try await connector.searchBanks("Sparkasse").isEmpty)

        let bank = BankDirectoryEntry(name: "Sparkasse KölnBonn", city: "Köln", bankCode: "37050198", protocolLabel: "FinTS")
        let credentials = BankCredentials(loginName: "lena", pin: "12345678", tanMethod: "pushTAN")
        await #expect(throws: unavailable) {
            _ = try await connector.signIn(bank: bank, credentials: credentials, onApproval: { _ in })
        }

        let session = BankSession(
            id: "s", connectorID: NoBankConnector.connectorID, bank: bank, loginName: "lena", tanMethod: "pushTAN",
            signedInAt: Date())
        await #expect(throws: unavailable) { _ = try await connector.accounts(session) }
        await #expect(throws: unavailable) { _ = try await connector.fetch(session, accounts: [], since: Date()) }
        let order = PaymentOrder(
            fromAccount: "a", recipient: "r", iban: "DE02120300000000202051", amount: 100, purpose: "p",
            execution: .now, instant: false)
        await #expect(throws: unavailable) {
            _ = try await connector.submit(order, session: session, onApproval: { _ in })
        }
    }

    @Test func bankAccessFollowsTheConnector() {
        let defaults = UserDefaults(suiteName: "dev.gasi.imm.onboarding-fixes.\(UUID().uuidString)") ?? .standard
        func model(_ connector: any BankConnector) -> AppModel {
            AppModel(
                biometricStore: ScenarioBiometricStore(availability: .available), pinStore: ScenarioPINStore(),
                bookmarks: VaultBookmarks(defaults: defaults, securityScoped: false),
                connector: connector, defaults: defaults, autoStart: false)
        }
        #expect(!model(NoBankConnector()).bankAccessAvailable)
        #expect(model(DemoConnector(delay: .zero)).bankAccessAvailable)
    }

    // MARK: Back on Add bank

    /// The Back button of `AddBankScreen` calls `model.abandonNewDatabase()`.
    @Test func backClosesAndForgetsTheEmptyDatabaseAndShowsCreateVault() async throws {
        let world = ScenarioWorld()
        defer { world.finish() }
        let bookmarks = VaultBookmarks(defaults: world.defaults, securityScoped: false)
        try await world.model.createVault(at: world.vaultURL, password: ScenarioWorld.password, enableTouchID: false)
        #expect(world.model.phase == AppModel.Phase.needsBank)
        #expect(world.model.vaultURL != nil)
        #expect(bookmarks.lastVaultPath != nil)

        world.model.abandonNewDatabase()

        #expect(world.model.phase == AppModel.Phase.noVault)
        #expect(world.model.vaultURL == nil)
        #expect(world.model.ledger == nil)
        #expect(bookmarks.lastVaultPath == nil)
        #expect(bookmarks.resolveLastVault() == nil)
    }

    // MARK: Sync under NoBankConnector

    @Test func syncLeavesLoginsOfAnotherConnectorAlone() async throws {
        let world = ScenarioWorld()
        defer { world.finish() }
        // Data imported by the demo bank of an older version.
        try await world.createReadyVault()
        world.model.lock(.manual)

        let relaunched = AppModel(
            biometricStore: world.biometrics, pinStore: world.pins,
            bookmarks: VaultBookmarks(defaults: world.defaults, securityScoped: false),
            connector: NoBankConnector(), defaults: world.defaults, autoStart: false)
        defer { relaunched.lock(.manual) }
        relaunched.openExisting(at: world.vaultURL)
        try await relaunched.unlock(password: ScenarioWorld.password)
        #expect(relaunched.phase == AppModel.Phase.ready)

        await relaunched.bank.sync().value

        switch relaunched.bank.syncState {
        case .idle: break
        default: Issue.record(Comment(rawValue: "sync under NoBankConnector ended as \(String(describing: relaunched.bank.syncState))"))
        }
    }
}
