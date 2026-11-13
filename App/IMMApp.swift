import IMMUI
import SwiftUI

@main
struct IMMApp: App {
    @NSApplicationDelegateAdaptor(IMMAppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        IMMAppDelegate.model = model
        Updater.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        // The setup window is declared first: it is the one SwiftUI opens at launch. The model opens or
        // dismisses the windows when the phase changes.
        Window("IMM", id: "setup") {
            SetupRootView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 640)
        .restorationBehavior(.disabled)

        Window("IMM", id: "main") {
            MainWindowView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Settings", id: "settings") {
            SettingsWindowView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 560)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        .commands {
            AppCommands(model: model)
        }
    }
}
