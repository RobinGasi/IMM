import IMMDesign
import SwiftUI

/// The paired Mac, the sync status, "Sync now" and "Unpair this iPhone".
struct CompanionSettingsView: View {
    @Environment(CompanionModel.self) private var model
    @State private var confirmingUnpair = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Mac", bundle: .module)
                        .foregroundStyle(IMMColor.mutedForeground)
                    Spacer(minLength: 12)
                    Text(verbatim: model.macName ?? "—")
                        .foregroundStyle(IMMColor.foreground)
                }
                .immFont(CompanionFont.callout)
                SyncStatusLine(status: model.syncStatus)
                Button {
                    Task { await model.syncNow() }
                } label: {
                    Text("Sync now", bundle: .module)
                        .immFont(CompanionFont.calloutMedium)
                }
                .disabled(model.syncStatus == .syncing)
            } header: {
                label("Paired Mac")
            } footer: {
                Text(
                    "Your ledger copy on this iPhone is encrypted and opens with Face ID or your passcode. Bank access stays on the Mac.",
                    bundle: .module
                )
                .immFont(CompanionFont.footnote)
                .foregroundStyle(IMMColor.mutedForeground)
            }
            .listRowBackground(IMMColor.muted)

            Section {
                Button(role: .destructive) {
                    confirmingUnpair = true
                } label: {
                    Text("Unpair this iPhone", bundle: .module)
                        .immFont(CompanionFont.calloutMedium)
                        .foregroundStyle(IMMColor.destructive)
                }
            }
            .listRowBackground(IMMColor.muted)
        }
        .companionGroupedList()
        .navigationTitle(Text("Settings", bundle: .module))
        .confirmationDialog(
            Text("Unpair this iPhone?", bundle: .module),
            isPresented: $confirmingUnpair,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.unpair() }
            } label: {
                Text("Unpair", bundle: .module)
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", bundle: .module)
            }
        } message: {
            Text(
                "This deletes the ledger copy and the keys from this iPhone. Your Mac and its data are not affected.",
                bundle: .module)
        }
    }

    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .immFont(CompanionFont.footnoteSemibold)
            .foregroundStyle(IMMColor.mutedForeground)
            .textCase(nil)
    }
}

#Preview("Settings") {
    NavigationStack { CompanionSettingsView() }
        .environment(CompanionModel.preview(.ready))
}
