import IMMDesign
import SwiftUI

/// The fixed 960 × 640 setup window: create, unlock, "can't be found", Add bank and Bank login.
/// The phase decides which screen shows.
public struct SetupRootView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        Group {
            switch model.phase {
            case .noVault:
                CreateVaultScreen()
            case .missingVault:
                MissingVaultScreen()
            case .locked:
                UnlockScreen()
            case .needsBank:
                if model.bank.selectedBank == nil {
                    AddBankScreen()
                } else {
                    BankLoginScreen()
                }
            case .ready:
                Color.clear
            }
        }
        .frame(minWidth: 960, maxWidth: .infinity, minHeight: 640 - WindowChrome.titlebarInset, maxHeight: .infinity)
        .background(IMMColor.background)
        .ignoresSafeArea()
        .background(WindowChrome(.setup))
        .background(WindowBridge())
    }
}

/// The fixed 760 × 560 Settings window.
public struct SettingsWindowView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        Group {
            if model.ledger != nil {
                SettingsScreen()
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 560 - WindowChrome.titlebarInset, maxHeight: .infinity)
        .background(IMMColor.background)
        .ignoresSafeArea()
        .background(WindowChrome(.settings))
        .background(WindowBridge())
    }
}
