import AppKit
import GRDB
import IMMBanking
import IMMLedger
import IMMVault
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct SettingsTests {
    private static let size = CGSize(width: 760, height: 560)

    /// A model like the artboards: Touch ID on, 5 minutes, lock on sleep, 3 stored PINs, a package named Moneten.imm.
    private func makeModel(
        biometry: BiometryAvailability = .available, touchID: Bool = true, pins: Int = 3
    ) throws -> AppModel {
        let fixture = try DemoVaultFixture.shared()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imm-settings-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let url = directory.appendingPathComponent("Moneten.imm", isDirectory: true)
        let vault: UnlockedVault
        if let existing = try? Vault.open(at: url, password: "settings-test") {
            vault = existing
        } else {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            vault = try Vault.create(at: url, password: "settings-test")
        }
        let model = AppModel.preview(store: fixture.store, vault: vault)
        model.setPreviewState(phase: .ready, biometry: biometry, touchIDEnabled: touchID, storedPINCount: pins)
        model.autoLockMinutes = 5
        model.lockOnSleep = true
        return model
    }

    private func render(_ screen: SettingsScreen, slug: String, model: AppModel) async throws -> Double {
        let value = try await assertMatchesDesign(
            screen.environment(model), slug: slug, size: Self.size)
        print("SETTINGS \(slug) mismatch \(value)")
        return value
    }

    @Test func preferencesMatchesDesign() async throws {
        _ = try await render(SettingsScreen(), slug: "settings-preferences-mac", model: try makeModel())
    }

    @Test func noPINsMatchesDesign() async throws {
        _ = try await render(
            SettingsScreen(), slug: "states-settings-no-pins-mac", model: try makeModel(pins: 0))
    }

    @Test func touchIDUnavailableMatchesDesign() async throws {
        _ = try await render(
            SettingsScreen(), slug: "states-settings-touch-id-unavailable-mac",
            model: try makeModel(biometry: .missingEntitlement, touchID: false))
    }

    /// The opened list is a standard macOS menu and cannot be part of an offscreen render, so the region it
    /// covers in the artboard (x 264…512, y 364…517) is painted white in both images before comparing.
    @Test func autoLockOptionsMatchesDesign() async throws {
        let slug = "states-settings-auto-lock-options-mac"
        let model = try makeModel()
        let reference = try DesignReference.image(slug: slug)
        let rep = try await ScreenRenderer.render(SettingsScreen().environment(model), size: Self.size)
        let menu = CGRect(x: 264, y: 364, width: 248, height: 153)
        let maskedReference = try Self.painted(reference, rect: menu)
        let maskedRendered = try Self.painted(try rep.requireCGImage(), rect: menu)
        let result = try DesignDiff.mismatch(maskedReference, maskedRendered)
        try DesignDiff.record(slug: slug, fraction: result.fraction, diff: result.diff, rendered: maskedRendered)
        print("SETTINGS \(slug) mismatch (menu region masked) \(result.fraction)")
        #expect(result.fraction <= DesignThresholds.limit)
    }

    /// `rect` is in top-left pixel coordinates.
    private static func painted(_ image: CGImage, rect: CGRect) throws -> CGImage {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenRendererError.captureFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        guard let result = context.makeImage() else { throw ScreenRendererError.captureFailed }
        return result
    }

    @Test func changePasswordMatchesDesign() async throws {
        _ = try await render(
            SettingsScreen(sheet: .init()), slug: "states-settings-change-password-mac", model: try makeModel())
    }

    @Test func changePasswordErrorsMatchesDesign() async throws {
        let draft = ChangePasswordSheet.Draft(
            current: "tulpe-2026", new: "kontor7", confirm: "kontor-8",
            wrongCurrent: true, newTooShort: true, mismatch: true)
        _ = try await render(
            SettingsScreen(sheet: draft), slug: "states-settings-change-password-errors-mac", model: try makeModel())
    }

    // MARK: Behaviour

    @Test func databasePathUsesTilde() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(SettingsPaths.displayPath(home.appendingPathComponent("Documents/Finanzen/Moneten.imm"))
            == "~/Documents/Finanzen/Moneten.imm")
        #expect(SettingsPaths.displayPath(URL(fileURLWithPath: "/Volumes/Backup/Moneten.imm")) == "/Volumes/Backup/Moneten.imm")
    }

    @Test func validationRules() {
        #expect(ChangePasswordSheet.validate(new: "kontor7", confirm: "kontor7") == (true, false))
        #expect(ChangePasswordSheet.validate(new: "kontor-7", confirm: "kontor-8") == (false, true))
        #expect(ChangePasswordSheet.validate(new: "kontor-7", confirm: "kontor-7") == (false, false))
    }

    @Test func autoLockOptionsCoverTheModelValues() {
        #expect(SettingsScreen.autoLockOptions.map(\.value) == [1, 5, 15, 60, 0])
    }

    @Test func autoLockAndSleepBindToTheModel() throws {
        let model = try makeModel()
        model.autoLockMinutes = 15
        model.lockOnSleep = false
        #expect(model.autoLockMinutes == 15)
        #expect(model.lockOnSleep == false)
    }

    @Test func removingPINsClearsTheCount() throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.setPreviewState(phase: .ready, storedPINCount: 3)
        #expect(model.storedPINCount == 3)
        model.removeStoredPINs()
        #expect(model.storedPINCount == 0)
    }

    @Test func changingThePasswordKeepsTheModelUsable() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        await #expect(throws: VaultError.wrongPassword) {
            try await model.changePassword(current: "not-the-password", new: "kontor-7-new")
        }
        try await model.changePassword(current: DemoVaultFixture.password, new: "kontor-7-new")
        _ = try Vault.open(at: fixture.packageURL, password: "kontor-7-new")
    }
}
