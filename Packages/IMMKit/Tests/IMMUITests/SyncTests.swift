import AppKit
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMUI
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct SyncTests {
    private static let size = CGSize(width: 1440, height: 900)

    private func render<V: View>(
        _ view: V, slug: String, startsClean: Bool = false, size: CGSize = SyncTests.size
    ) async throws -> Double {
        try await assertMatchesDesign(
            view, slug: slug, size: size,
            environment: {
                AnyView($0.environment(\.immWindowWidth, size.width).environment(\.syncPINSheetStartsClean, startsClean))
            })
    }

    /// An isolated ledger whose accounts carry the times the Sync failed artboards draw, and a model that
    /// has run a failing sync (Sparkasse rejects the PIN, DKB is under maintenance).
    private func failedModel() async throws -> (model: AppModel, fixture: DemoVaultFixture) {
        let fixture = try DemoVaultFixture.makeIsolated()
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let yesterdayMorning = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: yesterday) ?? yesterday
        let todayMorning = calendar.date(bySettingHour: 8, minute: 42, second: 0, of: now) ?? now
        try await fixture.store.database.write { db in
            try LedgerStore.unguarded(db) {
                try db.execute(sql: "UPDATE account SET last_synced_at = ?", arguments: [yesterdayMorning])
            }
        }
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.demoSyncFails = true
        defer { model.demoSyncFails = false }
        await model.bank.sync().value
        // The two banks that answered carry the drawn time of the morning sync.
        try await fixture.store.database.write { db in
            try LedgerStore.unguarded(db) {
                try db.execute(
                    sql: "UPDATE account SET last_synced_at = ? WHERE sync_status = 'ok'", arguments: [todayMorning])
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        model.navigate(to: .overview)
        return (model, fixture)
    }

    @Test func syncFailedMatchesDesign() async throws {
        let (model, _) = try await failedModel()
        model.panel = .pin
        let value = try await render(MainWindowView().environment(model), slug: "errors-1-sync-failed-desktop")
        print("SYNC errors-1-sync-failed-desktop mismatch \(value)")
    }

    @Test func bannerOnlyMatchesDesign() async throws {
        let (model, _) = try await failedModel()
        let value = try await render(MainWindowView().environment(model), slug: "states-sync-failed-banner-only-desktop")
        print("SYNC states-sync-failed-banner-only-desktop mismatch \(value)")
    }

    @Test func pinSheetEmptyMatchesDesign() async throws {
        let (model, _) = try await failedModel()
        model.panel = .pin
        let value = try await render(
            MainWindowView().environment(model), slug: "states-pin-sheet-empty-desktop", startsClean: true)
        print("SYNC states-pin-sheet-empty-desktop mismatch \(value)")
    }

    @Test func syncInProgressMatchesDesign() async throws {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.navigate(to: .overview)
        model.bank.setPreviewState(syncState: .syncing)
        let value = try await render(MainWindowView().environment(model), slug: "states-sync-in-progress-desktop")
        print("SYNC states-sync-in-progress-desktop mismatch \(value)")
    }

    // MARK: Behaviour

    @Test func failingSyncProducesFailuresThenANewPINClearsThem() async throws {
        let fixture = try DemoVaultFixture.makeIsolated()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        #expect(model.bank.syncState == .idle)

        model.demoSyncFails = true
        defer { model.demoSyncFails = false }
        await model.bank.sync().value

        let failures = model.bank.syncState.failures
        #expect(failures.map(\.accountName) == ["Girokonto", "Tagesgeld", "Visa Card"])
        #expect(failures.map(\.bankName) == ["Sparkasse KölnBonn", "Sparkasse KölnBonn", "DKB"])
        guard case .pinRejected(let code, let attemptsLeft) = failures[0].reason else {
            Issue.record("Sparkasse did not reject the PIN: \(failures[0].reason)")
            return
        }
        #expect(code == 9931 && attemptsLeft == 2)
        guard case .maintenance(let until) = failures[2].reason else {
            Issue.record("DKB is not under maintenance: \(failures[2].reason)")
            return
        }
        #expect(SyncText.clock(until) == "10:00")
        #expect(model.bank.syncState.byBank.map(\.bankName) == ["Sparkasse KölnBonn", "DKB"])
        #expect(model.bank.syncState.byBank.first?.accountNames == ["Girokonto", "Tagesgeld"])

        // The ledger remembers the status of the failed accounts.
        let failedInLedger = try await fixture.store.database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM account WHERE sync_status = 'failed' ORDER BY sort_order")
        }
        #expect(failedInLedger == ["Girokonto", "Tagesgeld", "Visa Card"])

        // "Enter new PIN" opens the sheet; the bank is back; a new PIN syncs everything again.
        model.panel = .pin
        model.demoSyncFails = false
        await model.bank.sync(newPIN: "654321", storePIN: true).value

        #expect(model.bank.syncState == .idle)
        #expect(model.panel == nil)
        let stillFailed = try await fixture.store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account WHERE sync_status = 'failed'")
        }
        #expect(stillFailed == 0)
        #expect(model.storedPINCount >= 1)
    }

    @Test func textsAreComputedFromTheFailures() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: calendar.date(byAdding: .day, value: -1, to: now) ?? now) ?? now
        #expect(SyncText.moment(yesterday, now: now) == "yesterday 07:30")
        #expect(SyncText.list(["Girokonto", "Tagesgeld"]) == "Girokonto and Tagesgeld")
        #expect(SyncText.list(["A", "B", "C"]) == "A, B and C")
        #expect(SyncText.balanceCaption(count: 3, oldest: yesterday, now: now) == "Includes balances from yesterday for 3 accounts")
        #expect(SyncText.updatedCount(updated: 2, total: 5) == "2 of 5 updated today")
        #expect(PINSheet.rejectionText((9931, 2))
            == "The bank rejected this PIN (error 9931). After 3 wrong attempts the bank locks online banking; you have 2 left.")
    }
}
