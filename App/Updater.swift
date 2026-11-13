import IMMUI
import Sparkle

/// Owns Sparkle's standard updater (automatic daily check, standard dialogs) and connects it to the
/// "Check for Updates…" menu item through `UpdaterHook`.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var observation: NSKeyValueObservation?

    private init() {
        let hook = UpdaterHook.shared
        hook.checkForUpdates = { [controller] in
            controller.checkForUpdates(nil)
        }
        hook.canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { _, change in
            let value = change.newValue ?? false
            Task { @MainActor in UpdaterHook.shared.canCheckForUpdates = value }
        }
    }

    /// Creates the controller and installs the hook; call once at launch.
    static func start() {
        _ = shared
    }
}
