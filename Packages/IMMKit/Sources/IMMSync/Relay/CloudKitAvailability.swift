import AppKit
import CloudKit
import Foundation
import Security

/// Whether this process may use CloudKit, answered without ever touching `CKContainer` unless the entitlements are there:
/// a process without `com.apple.developer.icloud-services` crashes inside `CKContainer(identifier:)`. Unsigned and ad-hoc
/// signed builds (`Debug-Unsigned`, the SwiftPM test runners) have none of the entitlements.
public enum CloudKitAvailability {
    public enum Result: Equatable, Sendable {
        /// Entitled and an iCloud account is signed in.
        case available(container: String)
        /// `message` is shown to the user (Settings › Sync).
        case unavailable(String)
    }

    /// The first container id of `com.apple.developer.icloud-container-identifiers`, when the process is entitled for CloudKit
    /// (`com.apple.developer.icloud-services` contains `CloudKit`). Nothing here touches CloudKit.
    public static var entitledContainer: String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
              services.contains("CloudKit") || services.contains("CloudKit-Anonymous"),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
                  as? [String],
              let container = containers.first
        else { return nil }
        return container
    }

    /// Whether the process may receive CloudKit's silent pushes (`aps-environment`).
    public static var canReceivePushes: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil) != nil
    }

    public static let unsignedMessage = "iCloud relay needs a signed build of IMM."

    /// Entitlement first, then the account status.
    public static func check() async -> Result {
        guard let container = entitledContainer else { return .unavailable(unsignedMessage) }
        return await accountStatus(of: container)
    }

    static func accountStatus(of container: String) async -> Result {
        do {
            switch try await CKContainer(identifier: container).accountStatus() {
            case .available: return .available(container: container)
            case .noAccount: return .unavailable("Sign in to iCloud in System Settings to use the iCloud relay.")
            case .restricted: return .unavailable("iCloud is restricted on this Mac.")
            case .temporarilyUnavailable: return .unavailable("iCloud is temporarily unavailable.")
            case .couldNotDetermine: return .unavailable("The iCloud account status could not be determined.")
            @unknown default: return .unavailable("iCloud is not available.")
            }
        } catch {
            return .unavailable("iCloud is not available: \(error.localizedDescription)")
        }
    }
}

/// CloudKit's silent pushes reach a Mac app only when it registered with APNs: `CKSyncEngine` creates the subscription and
/// handles the notification itself (no `application(_:didReceiveRemoteNotification:)` forwarding is needed), but without
/// `registerForRemoteNotifications()` pushes arrive late or not at all on macOS. Needs the `aps-environment` entitlement, so
/// unsigned builds skip it.
@MainActor
enum RemoteNotificationRegistration {
    private static var registered = false

    static func registerOnce() {
        guard !registered, CloudKitAvailability.canReceivePushes else { return }
        registered = true
        NSApplication.shared.registerForRemoteNotifications()
    }
}
