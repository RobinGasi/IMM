import AppKit
import IMMVault
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct CreateVaultTests {
    // MARK: Rules

    @Test func passwordNeedsEightCharacters() {
        #expect(CreateVaultRules.isTooShort("kontor7"))
        #expect(!CreateVaultRules.isTooShort("kontor-7"))
        #expect(CreateVaultRules.isTooShort(""))
        // Characters, not bytes: eight umlauts are eight characters.
        #expect(!CreateVaultRules.isTooShort("äöüäöüäö"))
    }

    @Test func fieldsMustMatch() {
        #expect(CreateVaultRules.isMismatch(password: "kontor7", confirm: "kontor-7"))
        #expect(!CreateVaultRules.isMismatch(password: "kontor-7", confirm: "kontor-7"))
    }

    @Test func createStaysDisabledWhileAFieldIsEmpty() {
        #expect(!CreateVaultRules.canSubmit(password: "", confirm: ""))
        #expect(!CreateVaultRules.canSubmit(password: "kontor-ehrenfeld", confirm: ""))
        #expect(!CreateVaultRules.canSubmit(password: "", confirm: "kontor-ehrenfeld"))
        #expect(CreateVaultRules.canSubmit(password: "kontor7", confirm: "kontor-7"))
    }

    @Test func validNeedsLengthAndMatch() {
        #expect(CreateVaultRules.isValid(password: "kontor-ehrenfeld", confirm: "kontor-ehrenfeld"))
        #expect(!CreateVaultRules.isValid(password: "kontor7", confirm: "kontor7"))
        #expect(!CreateVaultRules.isValid(password: "kontor-ehrenfeld", confirm: "kontor-ehrenfeld "))
        #expect(!CreateVaultRules.isValid(password: "", confirm: ""))
    }

    @Test func touchIDCaptionsFollowAvailability() {
        #expect(CreateVaultTouchID.caption(for: .available) == nil)
        #expect(CreateVaultTouchID.caption(for: .missingEntitlement) == "Touch ID needs a signed build of IMM.")
        #expect(CreateVaultTouchID.caption(for: .noSensor) == "This Mac has no Touch ID.")
        #expect(CreateVaultTouchID.caption(for: .notEnrolled) != nil)
    }

    @Test func failureMessages() {
        #expect(CreateVaultScreen.message(for: VaultError.alreadyExists)
            == "A database with this name already exists. Choose another name.")
        #expect(CreateVaultScreen.message(for: VaultError.io("disk full")).contains("disk full"))
    }

    // MARK: Comparison with the design

    private func render<V: View>(
        slug: String, biometry: BiometryAvailability = .available, phase: AppModel.Phase? = nil,
        @ViewBuilder view: () -> V
    ) async throws -> Double {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.setPreviewState(phase: phase, biometry: biometry)
        let value = try await assertMatchesDesign(
            view().environment(model), slug: slug, size: CGSize(width: 960, height: 640), settle: 0.4)
        print("CREATEVAULT \(slug) mismatch \(value)")
        return value
    }

    private let sample = "orchard-lantern-42"

    @Test func createVaultMatchesDesign() async throws {
        _ = try await render(slug: "onboarding-1-create-vault-setup") { CreateVaultScreen() }
    }

    @Test func emptyMatchesDesign() async throws {
        _ = try await render(slug: "states-create-vault-empty-setup") { CreateVaultScreen() }
    }

    @Test func errorsMatchDesign() async throws {
        let draft = CreateVaultDraft(password: "kontor7", confirm: "kontor-7", attempted: true)
        _ = try await render(slug: "states-create-vault-errors-setup") { CreateVaultScreen(draft: draft) }
    }

    @Test func creatingMatchesDesign() async throws {
        let draft = CreateVaultDraft(password: sample, confirm: sample, creating: true)
        _ = try await render(slug: "states-create-vault-creating-setup") { CreateVaultScreen(draft: draft) }
    }

    @Test func touchIDUnavailableMatchesDesign() async throws {
        _ = try await render(slug: "states-create-vault-touch-id-unavailable-setup", biometry: .missingEntitlement) {
            CreateVaultScreen()
        }
    }

    @Test func noTouchIDMatchesDesign() async throws {
        _ = try await render(slug: "states-create-vault-no-touch-id-setup", biometry: .noSensor) { CreateVaultScreen() }
    }

    @Test func syncedFolderMatchesDesign() async throws {
        let draft = CreateVaultDraft(
            password: sample, confirm: sample,
            pendingSyncedLocation: URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/Moneten.imm"))
        _ = try await render(slug: "states-create-vault-synced-folder-setup") { CreateVaultScreen(draft: draft) }
    }

    @Test func databaseNotFoundMatchesDesign() async throws {
        let url = URL(fileURLWithPath: "/Users/me/Documents/Moneten.imm")
        _ = try await render(slug: "states-database-not-found-setup", phase: .missingVault(url)) { MissingVaultScreen() }
    }

    // MARK: Unlock behind the synced-folder warning

    private func unlockPixels(warning: Bool) async throws -> NSBitmapImageRep {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        let info = AppModel.LockedInfo(
            url: URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/Moneten.imm"), vaultID: UUID(),
            displayName: "Moneten.imm", lastOpened: nil, accountCount: 5, touchID: .unavailable,
            showsSyncedFolderWarning: warning)
        model.setPreviewState(phase: .locked(info))
        return try await ScreenRenderer.render(
            UnlockScreen(titlebarStep: "Locked", autoPrompt: false).environment(model),
            size: CGSize(width: 960, height: 640), settle: 0.5)
    }

    @Test func unlockShowsTheSyncedFolderPanelOnTop() async throws {
        let plain = try await unlockPixels(warning: false)
        let warned = try await unlockPixels(warning: true)

        // The render has no window background, so the dim shows as alpha: nothing in the corner of the
        // plain screen, 18 % of the foreground colour with the warning, and an opaque card in the middle.
        func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
            rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.alphaComponent ?? -1
        }
        #expect(alpha(plain, 40, 600) < 0.01)
        #expect(abs(alpha(warned, 40, 600) - 0.18) < 0.02)
        #expect(alpha(warned, 280, 380) > 0.99)
        #expect(plain.tiffRepresentation != warned.tiffRepresentation)
    }
}
