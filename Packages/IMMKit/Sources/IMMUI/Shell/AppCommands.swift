import AppKit
import IMMBanking
import SwiftUI

/// The menu bar. IMM: Check for Updates…, Settings… (⌘,), Lock Database (⌘L). File: New Transfer (⌘N),
/// Open Database… (⌘O). View: Ask or Search (⌘K), Sync (⌘R). Debug builds add a Debug menu.
public struct AppCommands: Commands {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var isReady: Bool { model.phase == .ready }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(String(localized: "Check for Updates…", bundle: .module)) {
                UpdaterHook.shared.checkForUpdates?()
            }
            .disabled(!UpdaterHook.shared.canCheckForUpdates)
        }

        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "Settings…", bundle: .module)) { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(!(isReady || model.phase == .needsBank))
            Button(String(localized: "Lock Database", bundle: .module)) { model.lock(.manual) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.ledger == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New Transfer", bundle: .module)) { model.openNewTransfer() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!isReady)
            Button(String(localized: "Open Database…", bundle: .module)) { model.chooseDatabase() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(before: .toolbar) {
            Button(String(localized: "Ask or Search", bundle: .module)) { model.openAsk() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!isReady)
            Button(String(localized: "Sync", bundle: .module)) { model.bank.sync() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!isReady || model.bank.syncState.isSyncing)
            Divider()
        }

        #if DEBUG
        CommandMenu("Debug") {
            Menu("Demo bank sync") {
                Toggle("Succeeds", isOn: Binding(get: { !model.demoSyncFails }, set: { if $0 { model.demoSyncFails = false } }))
                Toggle("Fails", isOn: Binding(get: { model.demoSyncFails }, set: { if $0 { model.demoSyncFails = true } }))
            }
            Menu("Demo bank approval") {
                Toggle("Approves", isOn: Binding(get: { !model.demoApprovalExpires }, set: { if $0 { model.demoApprovalExpires = false } }))
                Toggle("Expires", isOn: Binding(get: { model.demoApprovalExpires }, set: { if $0 { model.demoApprovalExpires = true } }))
            }
        }
        #endif
    }
}
