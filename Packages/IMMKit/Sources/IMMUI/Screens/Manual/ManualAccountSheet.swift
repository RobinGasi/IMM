import IMMDesign
import IMMLedger
import SwiftUI

extension AppModel {
    /// Opens the "New manual account" sheet (File menu). Only with an open ledger.
    public func openNewManualAccount() {
        guard phase == .ready else { return }
        panel = .newManualAccount
    }

    /// Opens the "New booking" sheet (File menu). Only with an open ledger.
    public func openNewManualBooking() {
        guard phase == .ready else { return }
        panel = .newManualBooking
    }
}

/// "New manual account" (480 wide; `PanelHost` adds dim, background, radius, shadow and motion). On
/// success the sheet closes and the Transactions screen shows the new account.
struct ManualAccountSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New manual account", bundle: .module)
                .immFont(.titleMD)
                .foregroundStyle(IMMColor.foreground)
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 4, trailing: 24))
            Text("For cash, a wallet or any account you keep by hand. You add the bookings yourself.", bundle: .module)
                .immFont(.small)
                .foregroundStyle(IMMColor.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
            ManualAccountForm(submitTitle: Text("Create account", bundle: .module)) { input in
                let id = try await model.createManualAccount(input)
                model.closePanel()
                model.navigate(to: .transactions(.account(id)))
            }
            .cancelAction { model.closePanel() }
            .padding(EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("New manual account", bundle: .module))
    }
}
