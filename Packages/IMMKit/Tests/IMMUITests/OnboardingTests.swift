import AppKit
import Foundation
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct OnboardingTests {
    private static let size = CGSize(width: 960, height: 640)
    private static var bank: BankDirectoryEntry { DemoConnector.directory[0] }

    private func previewModel() throws -> AppModel {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.setPreviewState(phase: .needsBank)
        return model
    }

    /// 08:41 today in the Mac's time zone, as "Confirmed in S-pushTAN at 08:41".
    private var confirmedAt: Date {
        Calendar.current.date(bySettingHour: 8, minute: 41, second: 0, of: Date()) ?? Date()
    }

    private func demoAccounts() async throws -> [BankAccount] {
        let connector = DemoConnector(delay: .zero)
        let session = try await connector.signIn(
            bank: Self.bank, credentials: BankCredentials(loginName: "lena.hoffmann", pin: "12345678", tanMethod: "pushTAN"),
            onApproval: { _ in })
        return try await connector.accounts(session)
    }

    private func render<V: View>(_ view: V, slug: String, model: AppModel) async throws -> Double {
        try await assertMatchesDesign(
            view.environment(model), slug: slug, size: Self.size,
            environment: { AnyView($0.environment(\.immWindowWidth, Self.size.width)) })
    }

    // MARK: Comparison with the artboards

    @Test func addBankMatchesDesign() async throws {
        let model = try previewModel()
        let banks = DemoConnector.directory
        let value = try await render(
            AddBankScreen(query: "Sparkasse Köln", banks: banks, selection: banks[0]),
            slug: "onboarding-2-add-bank-setup", model: model)
        print("ONBOARDING onboarding-2-add-bank-setup mismatch \(value)")
    }

    @Test func bankLoginConfirmedMatchesDesign() async throws {
        let model = try previewModel()
        model.bank.selectedBank = Self.bank
        model.bank.setPreviewState(signInState: .confirmed(at: confirmedAt, accounts: try await demoAccounts()))
        let value = try await render(
            BankLoginScreen(loginName: "lena.hoffmann", pin: ""),
            slug: "onboarding-3-bank-login-setup", model: model)
        print("ONBOARDING onboarding-3-bank-login-setup mismatch \(value)")
    }

    @Test func bankLoginBeforeSignInMatchesDesign() async throws {
        let model = try previewModel()
        model.bank.selectedBank = Self.bank
        let value = try await render(
            BankLoginScreen(), slug: "states-bank-login-before-sign-in-setup", model: model)
        print("ONBOARDING states-bank-login-before-sign-in-setup mismatch \(value)")
    }

    @Test func bankLoginWaitingMatchesDesign() async throws {
        let model = try previewModel()
        model.bank.selectedBank = Self.bank
        model.bank.setPreviewState(signInState: .waiting(sentAt: Date()))
        let value = try await render(
            BankLoginScreen(loginName: "lena.hoffmann", pin: "12345678"),
            slug: "states-bank-login-waiting-setup", model: model)
        print("ONBOARDING states-bank-login-waiting-setup mismatch \(value)")
    }

    // MARK: Behaviour

    @Test func searchFiltersTheDirectory() async throws {
        let model = try previewModel()
        let all = await model.bank.searchBanks("")
        #expect(all.count == 4)
        let koeln = await model.bank.searchBanks("Köln")
        #expect(koeln.map(\.name) == ["Sparkasse KölnBonn", "Kreissparkasse Köln"])
        #expect(await model.bank.searchBanks("koln").count == 2)
        #expect(await model.bank.searchBanks("leverkusen").map(\.name) == ["Sparkasse Leverkusen"])
        #expect(await model.bank.searchBanks("370 501").map(\.name) == ["Sparkasse KölnBonn"])
        #expect(await model.bank.searchBanks("zzz").isEmpty)
    }

    @Test func signInThenImportFinishesSetup() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.setPreviewState(phase: .needsBank)
        model.bank.selectedBank = Self.bank

        try await model.bank.signIn(
            bank: Self.bank,
            credentials: BankCredentials(loginName: "lena.hoffmann", pin: "12345678", tanMethod: "pushTAN"))
        guard case .confirmed(_, let accounts) = model.bank.signInState else {
            Issue.record("sign-in did not confirm: \(model.bank.signInState)")
            return
        }
        #expect(accounts.map(\.name) == ["Girokonto", "Tagesgeld"])

        try await model.bank.importAccounts(since: Date())
        guard case .ready = model.phase else {
            Issue.record("phase is \(model.phase)")
            return
        }
        #expect(model.bank.selectedBank == nil)

        // Back and a changed form reset the confirmed sign-in.
        model.bank.setPreviewState(signInState: .confirmed(at: Date(), accounts: accounts))
        model.bank.resetSignIn()
        #expect(model.bank.signInState == .idle)
    }

    private func storedPINCount(afterImportWithStorePIN storePIN: Bool) async throws -> Int {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.setPreviewState(phase: .needsBank)
        model.bank.selectedBank = Self.bank
        try await model.bank.signIn(
            bank: Self.bank,
            credentials: BankCredentials(loginName: "lena.hoffmann", pin: "12345678", tanMethod: "pushTAN"))
        #expect(model.storedPINCount == 0)
        try await model.bank.importAccounts(since: Date(), storePIN: storePIN)
        return model.storedPINCount
    }

    @Test func theKeychainChoiceIsAppliedAtImport() async throws {
        #expect(try await storedPINCount(afterImportWithStorePIN: true) == 1)
        #expect(try await storedPINCount(afterImportWithStorePIN: false) == 0)
    }

    @Test func importNeedsAConfirmedSignIn() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.setPreviewState(phase: .needsBank)
        await #expect(throws: BankControllerError.notSignedIn) {
            try await model.bank.importAccounts()
        }
        try await model.bank.signIn(
            bank: Self.bank,
            credentials: BankCredentials(loginName: "lena.hoffmann", pin: "12345678", tanMethod: "pushTAN"))
        model.bank.resetSignIn()
        #expect(model.bank.signInState == .idle)
        await #expect(throws: BankControllerError.notSignedIn) {
            try await model.bank.importAccounts(storePIN: true)
        }
        #expect(model.storedPINCount == 0)
    }
}
