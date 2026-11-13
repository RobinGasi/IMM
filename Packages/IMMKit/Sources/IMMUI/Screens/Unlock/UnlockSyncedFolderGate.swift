import IMMDesign
import SwiftUI

/// The one-time cloud-folder warning on Unlock: while `LockedInfo.showsSyncedFolderWarning` is set the
/// screen is dimmed and disabled and the Create vault panel "This folder is synced by a cloud service."
/// asks what to do.
///
/// - "Use this folder" keeps the database where it is (`AppModel.acknowledgeSyncedFolderWarning()`;
///   the warning does not come back for this database).
/// - "Choose another folder" opens the standard open panel for another database
///   (`AppModel.chooseDatabase()`); a cancelled panel leaves the warning up.
struct UnlockSyncedFolderGate: ViewModifier {
    @Environment(AppModel.self) private var model

    private var isShown: Bool {
        if case .locked(let info) = model.phase { return info.showsSyncedFolderWarning }
        return false
    }

    func body(content: Content) -> some View {
        content
            .environment(\.immInert, isShown)
            .disabled(isShown)
            .overlay {
                if isShown {
                    SyncedFolderWarning(
                        useFolder: { model.acknowledgeSyncedFolderWarning() },
                        chooseAnother: { model.chooseDatabase() },
                        dismiss: nil)
                }
            }
    }
}
