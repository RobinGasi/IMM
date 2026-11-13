import AppKit
import IMMDesign
import IMMVault
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite struct UnlockTests {
    // MARK: Fixtures

    private static let calendar = Calendar.current

    /// Today at 08:12 on the real clock: the artboards say "Last opened today, 08:12".
    private static var todayAtEight12: Date {
        calendar.date(bySettingHour: 8, minute: 12, second: 0, of: Date()) ?? Date()
    }

    private func info(_ touchID: AppModel.LockedInfo.TouchID) throws -> AppModel.LockedInfo {
        AppModel.LockedInfo(
            url: URL(fileURLWithPath: "/Users/me/Documents/Moneten.imm"), vaultID: UUID(),
            displayName: "Moneten.imm", lastOpened: Self.todayAtEight12, accountCount: 5,
            touchID: touchID, showsSyncedFolderWarning: false)
    }

    private func model(_ touchID: AppModel.LockedInfo.TouchID, reason: LockReason? = .inactivity(minutes: 5)) throws -> AppModel {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.lockReason = reason
        model.setPreviewState(phase: .locked(try info(touchID)))
        return model
    }

    private let size = CGSize(width: 960, height: 640)

    private func compare<V: View>(_ view: V, model: AppModel, slug: String) async throws -> Double {
        let value = try await assertMatchesDesign(view.environment(model), slug: slug, size: size)
        print("UNLOCK \(slug) mismatch \(value)")
        return value
    }

    // MARK: Comparison with the artboards

    @Test func unlockMatchesDesign() async throws {
        let model = try model(.ready)
        _ = try await compare(UnlockScreen(titlebarStep: "", autoPrompt: false), model: model, slug: "security-unlock-setup")
    }

    @Test func wrongPasswordMatchesDesign() async throws {
        let model = try model(.ready)
        _ = try await compare(
            UnlockScreen(titlebarStep: "Locked", password: "tulpe-2026", error: "Wrong password. Try again.", autoPrompt: false),
            model: model, slug: "states-unlock-wrong-password-setup")
    }

    @Test func noTouchIDMatchesDesign() async throws {
        let model = try model(.unavailable)
        _ = try await compare(
            UnlockScreen(titlebarStep: "Locked", autoPrompt: false), model: model, slug: "states-unlock-no-touch-id-setup")
    }

    @Test func fingerprintsChangedMatchesDesign() async throws {
        let model = try model(.invalidated)
        _ = try await compare(
            UnlockScreen(titlebarStep: "Locked"), model: model, slug: "states-unlock-fingerprints-changed-setup")
    }

    @Test func subtitlesMatchesDesign() async throws {
        let model = try model(.unavailable)
        _ = try await compare(SubtitlesSheet(), model: model, slug: "states-unlock-subtitles-setup")
    }

    // MARK: Strings

    @Test func subtitleFollowsTheLockReason() {
        #expect(UnlockText.subtitle(for: .inactivity(minutes: 5)) == "Locked automatically after 5 minutes of inactivity.")
        #expect(UnlockText.subtitle(for: .inactivity(minutes: 1)) == "Locked automatically after 1 minute of inactivity.")
        #expect(UnlockText.subtitle(for: .inactivity(minutes: 15)) == "Locked automatically after 15 minutes of inactivity.")
        #expect(UnlockText.subtitle(for: .inactivity(minutes: 60)) == "Locked automatically after 1 hour of inactivity.")
        #expect(UnlockText.subtitle(for: .inactivity(minutes: 120)) == "Locked automatically after 2 hours of inactivity.")
        #expect(UnlockText.subtitle(for: .sleep) == "Locked when your Mac went to sleep.")
        #expect(UnlockText.subtitle(for: .manual) == "Unlock to see your accounts.")
        #expect(UnlockText.subtitle(for: nil) == "Unlock to see your accounts.")
    }

    @Test func footerReadsLikeTheArtboard() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let now = date(12, 14, 30)

        #expect(UnlockText.footer(lastOpened: date(12, 8, 12), accountCount: 5, now: now, calendar: calendar)
            == "Last opened today, 08:12 · 5 accounts · Encrypted on this Mac")
        #expect(UnlockText.footer(lastOpened: date(11, 23, 5), accountCount: 1, now: now, calendar: calendar)
            == "Last opened yesterday, 23:05 · 1 account · Encrypted on this Mac")
        #expect(UnlockText.footer(lastOpened: date(3, 9, 0), accountCount: 5, now: now, calendar: calendar)
            == "Last opened 03.11.2026, 09:00 · 5 accounts · Encrypted on this Mac")
        #expect(UnlockText.footer(lastOpened: nil, accountCount: nil, now: now, calendar: calendar)
            == "Encrypted on this Mac")
    }

    // MARK: Unlock through the model

    @Test func lockThenUnlockWithThePassword() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)

        model.lock(.inactivity(minutes: 5))
        guard case .locked(let locked) = model.phase else {
            Issue.record("expected the locked phase, got \(model.phase)")
            return
        }
        #expect(locked.displayName == fixture.packageURL.lastPathComponent)
        #expect(UnlockText.subtitle(for: model.lockReason) == "Locked automatically after 5 minutes of inactivity.")

        await #expect(throws: VaultError.wrongPassword) {
            try await model.unlock(password: "not the password")
        }
        guard case .locked = model.phase else {
            Issue.record("a wrong password must keep the lock screen")
            return
        }

        try await model.unlock(password: DemoVaultFixture.password)
        #expect(model.phase == .ready)
        #expect(model.lockReason == nil)
    }
}

/// The "States / Unlock — Subtitles" artboard: the three subtitles side by side under one title bar.
private struct SubtitlesSheet: View {
    private let columns: [(label: String, reason: LockReason)] = [
        ("Locked after inactivity", .inactivity(minutes: 5)),
        ("Locked on sleep", .sleep),
        ("Locked manually", .manual),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SetupTitlebar(step: "Locked", title: "Ich mag Moneten")
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    VStack(spacing: 6) {
                        Text(verbatim: column.label)
                            .immFont(.smallMedium)
                            .foregroundStyle(IMMColor.mutedForeground)
                            .padding(.bottom, 14)
                        Text(verbatim: "Moneten.imm is locked")
                            .immFont(IMMFont(name: "sheetTitle", size: 22, lineHeight: 28, weight: .semibold))
                            .foregroundStyle(IMMColor.foreground)
                            .fixedSize()
                        Text(verbatim: UnlockText.subtitle(for: column.reason))
                            .immFont(.body)
                            .foregroundStyle(IMMColor.mutedForeground)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if index > 0 { Rectangle().fill(IMMColor.border).frame(width: 1) }
                    }
                }
            }
            .frame(maxWidth: 864)
            .padding(.vertical, 32)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            UnlockFooter(text: UnlockText.footer(lastOpened: Calendar.current.date(bySettingHour: 8, minute: 12, second: 0, of: Date()), accountCount: 5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IMMColor.background)
    }
}
