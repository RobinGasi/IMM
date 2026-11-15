import IMMCompanion
import SwiftUI
import UIKit

@main
struct IMMPhoneApp: App {
    @State private var model = CompanionModel(environment: .live(deviceName: UIDevice.current.name))

    var body: some Scene {
        WindowGroup {
            PhoneRootView(model: model)
        }
    }
}

/// The companion root plus the app's lifecycle rules: start once, lock when the app goes to the
/// background (the locked screen asks for Face ID when the app is active again), and sync every
/// minute while unlocked and in the foreground.
private struct PhoneRootView: View {
    let model: CompanionModel
    @Environment(\.scenePhase) private var scenePhase

    private struct SyncLoopKey: Equatable {
        var isReady: Bool
        var isActive: Bool
    }

    var body: some View {
        CompanionRootView(model: model) {
            QRScannerView(model: model)
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, model.phase == .ready {
                model.lock()
            }
        }
        .task(id: SyncLoopKey(isReady: model.phase == .ready, isActive: scenePhase == .active)) {
            guard model.phase == .ready, scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                await model.syncNow()
            }
        }
    }
}
