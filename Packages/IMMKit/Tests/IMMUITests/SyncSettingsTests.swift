import AppKit
import IMMLedger
@testable import IMMSync
@testable import IMMSyncCore
@testable import IMMUI
import Observation
import SwiftUI
import Testing

/// An observable stand-in for `SyncService`: the tests set its state and read what the UI asked for.
@MainActor @Observable
final class FakeSync: SyncControlling {
    var status: SyncStatus = .off
    var devices: [SyncDeviceInfo] = []
    var pairing: SyncPairingPhase = .idle
    var isEnabled = false

    @ObservationIgnored var calls: [String] = []
    @ObservationIgnored var failure: (any Error)?

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    func setEnabled(_ on: Bool) async {
        calls.append("setEnabled(\(on))")
        isEnabled = on
    }

    func openLoginItemsSettings() { calls.append("openLoginItems") }

    func beginPairing() async throws -> PairingOffer {
        calls.append("beginPairing")
        if let failure { throw failure }
        let offer = SyncSettingsTests.offer
        pairing = .offering(offer)
        return offer
    }

    func confirmPairing(_ code: String?) async throws {
        calls.append("confirmPairing")
        if let failure { throw failure }
        pairing = .idle
    }

    func rejectPairing() async {
        calls.append("rejectPairing")
        pairing = .idle
    }

    func remove(device id: DeviceNodeID) async throws {
        calls.append("remove(\(id))")
        if let failure { throw failure }
        devices.removeAll { $0.id == id }
    }
}

@MainActor
@Suite(.serialized) struct SyncSettingsTests {
    private static let size = CGSize(width: 760, height: 560)
    private static let host = "robins-macbook.tail1234.ts.net"

    /// The clock of the artboards: "Synced 2 s ago", "Synced yesterday, 18:04", "Expires in 1:52".
    static let now: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 11
        parts.day = 13
        parts.hour = 10
        parts.minute = 0
        return Calendar.current.date(from: parts)!
    }()

    static var offer: PairingOffer {
        PairingOffer(
            // Fake pairing code from the design artboard, not a credential.
            qrPayload: #"{"v":1,"device":"1","agent":"AAAA","secret":"K7QM-4TZP-X2WD-6HNA","expiry":1,"host":"h","port":47380}"#, // gitleaks:allow
            code: "K7QM-4TZP-X2WD-6HNA", expiry: now.addingTimeInterval(112), host: host, port: 47380,
            agentKey: Data(repeating: 7, count: 32))
    }

    private static func iPhone(ago: TimeInterval = 2) -> SyncDeviceInfo {
        SyncDeviceInfo(
            id: 1, name: "Robin's iPhone", lastSeen: now, lastSync: now.addingTimeInterval(-ago), route: "Tailscale",
            isConnected: true)
    }

    private static var macMini: SyncDeviceInfo {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let evening = Calendar.current.date(bySettingHour: 18, minute: 4, second: 0, of: yesterday)!
        // The artboard shows "via iCloud" for this row; the app's only route is Tailscale, so the fake names the route.
        return SyncDeviceInfo(id: 2, name: "Mac mini", lastSeen: evening, lastSync: evening, route: "iCloud", isConnected: false)
    }

    private func makeModel() throws -> AppModel {
        let fixture = try DemoVaultFixture.shared()
        let model = AppModel.preview(store: fixture.store, vault: fixture.vault)
        model.setPreviewState(phase: .ready)
        return model
    }

    private func screen(_ sync: FakeSync) throws -> some View {
        let model = try makeModel()
        let actions = SyncSettingsActions(sync: sync, confirmRemoval: { _ in true }, report: { _, _ in })
        let now = Self.now
        return SettingsScreen(tab: .sync, sync: actions)
            .environment(model)
            .environment(\.settingsNow, { now })
    }

    private func render(_ sync: FakeSync, slug: String) async throws -> Double {
        let value = try await assertMatchesDesign(try screen(sync), slug: slug, size: Self.size)
        print("SYNCSETTINGS \(slug) mismatch \(value)")
        return value
    }

    // MARK: Comparison

    @Test func offMatchesDesign() async throws {
        _ = try await render(FakeSync(), slug: "states-settings-sync-off-mac")
    }

    @Test func tailscaleNotRunningMatchesDesign() async throws {
        let sync = FakeSync()
        sync.isEnabled = true
        sync.status = .noTailscale
        _ = try await render(sync, slug: "states-settings-sync-tailscale-not-running-mac")
    }

    @Test func onWithoutDevicesMatchesDesign() async throws {
        let sync = FakeSync()
        sync.isEnabled = true
        sync.status = .listening(host: Self.host)
        _ = try await render(sync, slug: "states-settings-sync-on-no-devices-mac")
    }

    @Test func onWithDevicesMatchesDesign() async throws {
        let sync = FakeSync()
        sync.isEnabled = true
        sync.status = .listening(host: Self.host)
        sync.devices = [Self.iPhone(), Self.macMini]
        _ = try await render(sync, slug: "states-settings-sync-on-devices-mac")
    }

    /// The designed QR code is a different pattern from the one a real pairing payload produces, so the square the
    /// code occupies (x 306…454, y 163…311) is painted white in both images before comparing.
    @Test func pairingMatchesDesign() async throws {
        let sync = FakeSync()
        sync.isEnabled = true
        sync.status = .listening(host: Self.host)
        sync.pairing = .offering(Self.offer)
        let slug = "states-settings-sync-pairing-mac"
        let value = try await maskedMismatch(sync, slug: slug, mask: CGRect(x: 306, y: 163, width: 148, height: 148))
        print("SYNCSETTINGS \(slug) mismatch (QR square masked) \(value)")
    }

    @Test func confirmCodeMatchesDesign() async throws {
        let sync = FakeSync()
        sync.isEnabled = true
        sync.status = .listening(host: Self.host)
        sync.pairing = .confirming(deviceName: "Robin's iPhone", code: ShortAuthCode(value: 482_913)!)
        _ = try await render(sync, slug: "states-settings-sync-confirm-code-mac")
    }

    /// The pairing panel draws a real QR code: the square is neither blank nor solid.
    @Test func pairingPanelDrawsTheQRCode() async throws {
        let sync = FakeSync()
        sync.isEnabled = true
        sync.status = .listening(host: Self.host)
        sync.pairing = .offering(Self.offer)
        let image = try await ScreenRenderer.render(try screen(sync), size: Self.size).requireCGImage()
        let share = try Self.darkShare(image, rect: CGRect(x: 306, y: 163, width: 148, height: 148))
        #expect(share > 0.2 && share < 0.8, "dark share \(share)")
    }

    private static func darkShare(_ image: CGImage, rect: CGRect) throws -> Double {
        guard let cropped = image.cropping(to: rect),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: cropped.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenRendererError.captureFailed }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let data = context.data else { throw ScreenRendererError.captureFailed }
        let bytes = data.bindMemory(to: UInt8.self, capacity: cropped.width * cropped.height * 4)
        var dark = 0
        for index in 0..<(cropped.width * cropped.height) where bytes[index * 4] < 100 { dark += 1 }
        return Double(dark) / Double(cropped.width * cropped.height)
    }

    private func maskedMismatch(_ sync: FakeSync, slug: String, mask: CGRect) async throws -> Double {
        let reference = try DesignReference.image(slug: slug)
        let rep = try await ScreenRenderer.render(try screen(sync), size: Self.size)
        let maskedReference = try Self.painted(reference, rect: mask)
        let maskedRendered = try Self.painted(try rep.requireCGImage(), rect: mask)
        let result = try DesignDiff.mismatch(maskedReference, maskedRendered)
        try DesignDiff.record(slug: slug, fraction: result.fraction, diff: result.diff, rendered: maskedRendered)
        #expect(result.fraction <= DesignThresholds.limit)
        return result.fraction
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

    // MARK: Behaviour

    private func actions(
        _ sync: FakeSync, confirm: Bool = true, reports: ReportLog = ReportLog(), confirmations: ReportLog = ReportLog()
    ) -> SyncSettingsActions {
        SyncSettingsActions(
            sync: sync,
            confirmRemoval: { name in
                confirmations.entries.append(name)
                return confirm
            },
            report: { title, detail in reports.entries.append("\(title) | \(detail)") })
    }

    @MainActor final class ReportLog {
        var entries: [String] = []
    }

    @Test func switchCallsSetEnabled() async {
        let sync = FakeSync()
        let actions = actions(sync)
        await actions.setEnabled(true)
        #expect(sync.isEnabled)
        await actions.setEnabled(false)
        #expect(!sync.isEnabled)
        #expect(sync.calls == ["setEnabled(true)", "setEnabled(false)"])
    }

    @Test func approvalRowOpensLoginItems() {
        let sync = FakeSync()
        actions(sync).openLoginItems()
        #expect(sync.calls == ["openLoginItems"])
    }

    @Test func removeAsksFirstAndRemovesOnConfirm() async {
        let sync = FakeSync()
        sync.devices = [Self.iPhone(), Self.macMini]
        let asked = ReportLog()
        await actions(sync, confirm: true, confirmations: asked).remove(Self.iPhone())
        #expect(asked.entries == ["Robin's iPhone"])
        #expect(sync.calls == ["remove(1)"])
        #expect(sync.devices.map(\.name) == ["Mac mini"])
    }

    @Test func removeDoesNothingWhenCancelled() async {
        let sync = FakeSync()
        sync.devices = [Self.iPhone()]
        await actions(sync, confirm: false).remove(Self.iPhone())
        #expect(sync.calls.isEmpty)
        #expect(sync.devices.count == 1)
    }

    @Test func removeFailureIsReported() async {
        let sync = FakeSync()
        sync.devices = [Self.iPhone()]
        sync.failure = FakeSync.Failure(description: "helper unreachable")
        let reports = ReportLog()
        await actions(sync, reports: reports).remove(Self.iPhone())
        #expect(reports.entries == ["Robin's iPhone couldn't be removed. | helper unreachable"])
        #expect(sync.devices.count == 1)
    }

    @Test func pairingOfferShowsTheCodeAndCancelRejects() async {
        let sync = FakeSync()
        let actions = actions(sync)
        await actions.beginPairing()
        guard case .offering(let offer) = sync.pairing else {
            Issue.record("expected an offer, got \(sync.pairing)")
            return
        }
        #expect(offer.code == "K7QM-4TZP-X2WD-6HNA")
        await actions.cancelPairing()
        #expect(sync.pairing == .idle)
        #expect(sync.calls == ["beginPairing", "rejectPairing"])
    }

    @Test func pairingStartFailureIsReported() async {
        let sync = FakeSync()
        sync.failure = FakeSync.Failure(description: "no tailscale")
        let reports = ReportLog()
        await actions(sync, reports: reports).beginPairing()
        #expect(reports.entries == ["Pairing couldn't start. | no tailscale"])
        #expect(sync.pairing == .idle)
    }

    @Test func codesMatchConfirmsAndCodesDontMatchRejects() async {
        let sync = FakeSync()
        sync.pairing = .confirming(deviceName: "Robin's iPhone", code: ShortAuthCode(value: 482_913)!)
        await actions(sync).confirmCodes()
        #expect(sync.calls == ["confirmPairing"])
        #expect(sync.pairing == .idle)

        sync.pairing = .confirming(deviceName: nil, code: ShortAuthCode(value: 12)!)
        await actions(sync).rejectCodes()
        #expect(sync.calls == ["confirmPairing", "rejectPairing"])
        #expect(sync.pairing == .idle)
    }

    @Test func confirmFailureIsReportedAndKeepsThePanel() async {
        let sync = FakeSync()
        let phase = SyncPairingPhase.confirming(deviceName: "Robin's iPhone", code: ShortAuthCode(value: 1)!)
        sync.pairing = phase
        sync.failure = FakeSync.Failure(description: "the new device disconnected")
        let reports = ReportLog()
        await actions(sync, reports: reports).confirmCodes()
        #expect(reports.entries == ["Pairing didn't finish. | the new device disconnected"])
        #expect(sync.pairing == phase)
    }

    @Test func escapeAbandonsAnOpenPairing() async {
        let sync = FakeSync()
        sync.pairing = .offering(Self.offer)
        await SyncPairingPanel(actions: actions(sync)).dismiss()
        #expect(sync.calls == ["rejectPairing"])
        #expect(sync.pairing == .idle)
    }

    @Test func onlySecurityAndSyncTabsAreEnabled() {
        #expect(SettingsTab.allCases.filter(\.isEnabled) == [.security, .sync])
        #expect(SettingsTab.allCases.map(\.rawValue) == ["general", "accounts", "security", "sync", "categories", "export"])
    }

    // MARK: Text

    @Test func relativeTimes() {
        let now = Self.now
        #expect(SyncSettingsText.ago(now.addingTimeInterval(-2), now: now) == "2 s ago")
        #expect(SyncSettingsText.ago(now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(SyncSettingsText.deviceLine(Self.iPhone(), now: now) == "Synced 2 s ago · via Tailscale")
        #expect(SyncSettingsText.deviceLine(Self.macMini, now: now) == "Synced yesterday, 18:04 · via iCloud")
        var never = Self.iPhone()
        never.lastSync = nil
        #expect(SyncSettingsText.deviceLine(never, now: now) == "Not synced yet · via Tailscale")
    }

    @Test func countdownAndSymbols() {
        let now = Self.now
        #expect(SyncSettingsText.countdown(until: now.addingTimeInterval(112), now: now) == "1:52")
        #expect(SyncSettingsText.countdown(until: now.addingTimeInterval(-5), now: now) == "0:00")
        #expect(SyncSettingsText.deviceSymbol(name: "Robin's iPhone") == "iphone")
        #expect(SyncSettingsText.deviceSymbol(name: "Robin's MacBook Pro") == "laptopcomputer")
        #expect(SyncSettingsText.deviceSymbol(name: "Mac mini") == "desktopcomputer")
    }

    @Test func sidebarLinesFollowTheArtboard() {
        let now = Self.now
        func line(_ enabled: Bool, _ status: SyncStatus, _ devices: [SyncDeviceInfo]) -> SyncFooterLine? {
            SyncFooterLine.make(isEnabled: enabled, status: status, devices: devices, now: now)
        }
        #expect(line(false, .listening(host: "h"), [Self.iPhone()]) == nil)
        #expect(line(true, .listening(host: "h"), []) == nil)
        #expect(
            line(true, .listening(host: "h"), [Self.iPhone()])
                == SyncFooterLine(icon: .synced, text: "Synced with Robin's iPhone 2 s ago", isWarning: false))
        var waiting = Self.iPhone()
        waiting.isConnected = false
        #expect(
            line(true, .listening(host: "h"), [waiting])
                == SyncFooterLine(icon: .waiting, text: "Waiting for Robin's iPhone", isWarning: false))
        #expect(
            line(true, .noTailscale, [Self.iPhone()])
                == SyncFooterLine(icon: .paused, text: "Sync paused — Tailscale isn't connected", isWarning: true))
        #expect(line(true, .needsApproval, [])?.isWarning == true)
        #expect(line(true, .error("x"), [])?.isWarning == true)
    }
}
