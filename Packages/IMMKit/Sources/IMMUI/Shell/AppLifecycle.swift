import AppKit
import SwiftUI

/// Hooks the app target fills from Sparkle. The "Check for Updates…" menu item is enabled only while
/// `canCheckForUpdates` is true.
@MainActor
@Observable
public final class UpdaterHook {
    public static let shared = UpdaterHook()
    public var checkForUpdates: (@MainActor () -> Void)?
    public var canCheckForUpdates = false
    private init() {}
}

/// App delegate: IMM keeps running when the last window closes, the Dock icon reopens the window for the
/// current phase, and quitting locks the database.
@MainActor
public final class IMMAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app before the first window appears.
    public static var model: AppModel?

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let model = Self.model {
            model.windows.showWindows(for: model.phase)
        }
        return false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.model?.lock(.manual)
        return .terminateNow
    }
}
