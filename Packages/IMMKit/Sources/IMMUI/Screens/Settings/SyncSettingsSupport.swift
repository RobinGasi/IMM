import AppKit
import Foundation
import IMMLedger
import IMMSync
import SwiftUI

/// What the Sync tab, the pairing panels and the sidebar line need from `SyncService`. `SyncService` conforms; tests
/// drive the screen with an observable fake.
@MainActor
protocol SyncControlling: AnyObject {
    var status: SyncStatus { get }
    var devices: [SyncDeviceInfo] { get }
    var pairing: SyncPairingPhase { get }
    var isEnabled: Bool { get }

    func setEnabled(_ on: Bool) async
    func openLoginItemsSettings()
    func beginPairing() async throws -> PairingOffer
    func confirmPairing(_ code: String?) async throws
    func rejectPairing() async
    func remove(device id: DeviceNodeID) async throws
}

extension SyncService: SyncControlling {}

/// The Sync tab's behaviour, separate from the views: every button maps to one method here.
@MainActor
struct SyncSettingsActions {
    let sync: any SyncControlling
    /// Asks "Remove <name>?"; true when the user chose Remove.
    var confirmRemoval: @MainActor (_ deviceName: String) async -> Bool
    /// Shows a problem (title, detail).
    var report: @MainActor (_ title: String, _ detail: String) -> Void

    init(
        sync: any SyncControlling,
        confirmRemoval: @escaping @MainActor (String) async -> Bool = SyncAlerts.confirmRemoval,
        report: @escaping @MainActor (String, String) -> Void = SettingsAlerts.show
    ) {
        self.sync = sync
        self.confirmRemoval = confirmRemoval
        self.report = report
    }

    /// The switch "Sync over Tailscale".
    func setEnabled(_ on: Bool) async {
        await sync.setEnabled(on)
    }

    /// "Open Login Items…"
    func openLoginItems() {
        sync.openLoginItemsSettings()
    }

    /// "Pair another device…": the pairing panel appears once the service publishes the offer.
    func beginPairing() async {
        do {
            _ = try await sync.beginPairing()
        } catch {
            report(String(localized: "Pairing couldn't start.", bundle: .module), String(describing: error))
        }
    }

    /// Cancel on the pairing panel.
    func cancelPairing() async {
        await sync.rejectPairing()
    }

    /// "Codes match".
    func confirmCodes() async {
        do {
            try await sync.confirmPairing(nil)
        } catch {
            report(String(localized: "Pairing didn't finish.", bundle: .module), String(describing: error))
        }
    }

    /// "Codes don't match".
    func rejectCodes() async {
        await sync.rejectPairing()
    }

    /// "Remove…" on a device row: asks first, then revokes the device.
    func remove(_ device: SyncDeviceInfo) async {
        guard await confirmRemoval(device.name) else { return }
        do {
            try await sync.remove(device: device.id)
        } catch {
            report(String(localized: "\(device.name) couldn't be removed.", bundle: .module), String(describing: error))
        }
    }
}

enum SyncAlerts {
    @MainActor
    static func confirmRemoval(deviceName name: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove \(name)?", bundle: .module)
        alert.informativeText = String(
            localized: "\(name) can no longer sync with this Mac. IMM changes the sync key on your other devices.",
            bundle: .module)
        let remove = alert.addButton(withTitle: String(localized: "Remove", bundle: .module))
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }
}

// MARK: - Text

enum SyncSettingsText {
    /// `2 s ago`, `5 min ago`, then `today, 08:42`, `yesterday, 18:04` or `12.11., 08:42`.
    static func ago(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(localized: "\(seconds) s ago", bundle: .module) }
        if seconds < 3600 { return String(localized: "\(seconds / 60) min ago", bundle: .module) }
        return ShellText.relative(date, now: now, calendar: calendar)
    }

    /// `Synced 2 s ago · via Tailscale`.
    static func deviceLine(_ device: SyncDeviceInfo, now: Date, calendar: Calendar = .current) -> String {
        let route = device.route
        guard let last = device.lastSync else {
            return String(localized: "Not synced yet · via \(route)", bundle: .module)
        }
        return String(localized: "Synced \(ago(last, now: now, calendar: calendar)) · via \(route)", bundle: .module)
    }

    /// SF Symbol of the device: phones and tablets by name, laptops by name, any other Mac as a desktop.
    static func deviceSymbol(name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("iphone") || lower.contains("phone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("macbook") || lower.contains("laptop") { return "laptopcomputer" }
        return "desktopcomputer"
    }

    /// `1:52`, never negative.
    static func countdown(until expiry: Date, now: Date) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The sidebar line under the net worth while sync over Tailscale is on (artboard "Sidebar footer — sync status").
struct SyncFooterLine: Equatable {
    enum Icon: Equatable { case synced, waiting, paused }
    var icon: Icon
    var text: String
    var isWarning: Bool

    /// nil while sync is off, nothing is paired yet and the Mac is listening (the bank line shows then).
    @MainActor
    static func make(sync: any SyncControlling, now: Date, calendar: Calendar = .current) -> SyncFooterLine? {
        make(isEnabled: sync.isEnabled, status: sync.status, devices: sync.devices, now: now, calendar: calendar)
    }

    static func make(
        isEnabled: Bool, status: SyncStatus, devices: [SyncDeviceInfo], now: Date, calendar: Calendar = .current
    ) -> SyncFooterLine? {
        guard isEnabled else { return nil }
        switch status {
        case .off:
            return nil
        case .noTailscale:
            return SyncFooterLine(
                icon: .paused, text: String(localized: "Sync paused — Tailscale isn't connected", bundle: .module), isWarning: true)
        case .needsApproval:
            return SyncFooterLine(
                icon: .paused, text: String(localized: "Sync paused — waiting for your approval in Login Items", bundle: .module),
                isWarning: true)
        case .error:
            return SyncFooterLine(
                icon: .paused, text: String(localized: "Sync paused — see Settings", bundle: .module), isWarning: true)
        case .listening:
            let connected = devices.filter(\.isConnected)
            if let device = connected.max(by: { ($0.lastSync ?? .distantPast) < ($1.lastSync ?? .distantPast) }) {
                let name = device.name
                if let last = device.lastSync {
                    let ago = SyncSettingsText.ago(last, now: now, calendar: calendar)
                    return SyncFooterLine(
                        icon: .synced, text: String(localized: "Synced with \(name) \(ago)", bundle: .module), isWarning: false)
                }
                return SyncFooterLine(
                    icon: .synced, text: String(localized: "Syncing with \(name)", bundle: .module), isWarning: false)
            }
            if let device = devices.first {
                let name = device.name
                return SyncFooterLine(
                    icon: .waiting, text: String(localized: "Waiting for \(name)", bundle: .module), isWarning: false)
            }
            return nil
        }
    }
}

// MARK: - Clock

private struct SettingsNowKey: EnvironmentKey {
    static let defaultValue: (@Sendable () -> Date)? = nil
}

extension EnvironmentValues {
    /// Replaces the real clock for relative times and the pairing countdown (screenshot tests pin it).
    var settingsNow: (@Sendable () -> Date)? {
        get { self[SettingsNowKey.self] }
        set { self[SettingsNowKey.self] = newValue }
    }
}
