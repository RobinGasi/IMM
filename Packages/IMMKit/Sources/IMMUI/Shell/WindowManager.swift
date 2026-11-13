import SwiftUI

/// Opens and closes the app's three windows (`main`, `setup`, `settings`). The window views register the
/// SwiftUI actions when they appear (`WindowBridge`); until one has appeared the latest request is
/// remembered and replayed on registration.
@MainActor
final class WindowManager {
    private var openHandler: ((String) -> Void)?
    private var dismissHandler: ((String) -> Void)?
    private var pendingPhase: AppModel.Phase?

    func register(open: @escaping (String) -> Void, dismiss: @escaping (String) -> Void) {
        openHandler = open
        dismissHandler = dismiss
        if let pending = pendingPhase {
            pendingPhase = nil
            showWindows(for: pending)
        }
    }

    func open(_ id: String) {
        openHandler?(id)
    }

    func dismiss(_ id: String) {
        dismissHandler?(id)
    }

    /// The main window for `.ready`; the setup window (create, unlock, add bank, missing database) for
    /// every other phase. Settings only exists while a database is open.
    func showWindows(for phase: AppModel.Phase) {
        guard openHandler != nil else {
            pendingPhase = phase
            return
        }
        switch phase {
        case .ready:
            open("main")
            dismiss("setup")
        case .needsBank:
            open("setup")
            dismiss("main")
        case .noVault, .missingVault, .locked:
            open("setup")
            dismiss("main")
            dismiss("settings")
        }
    }
}

/// Registers the window actions of the scene it sits in with the model.
struct WindowBridge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                model.windows.register(
                    open: { openWindow(id: $0) },
                    dismiss: { dismissWindow(id: $0) })
            }
    }
}
