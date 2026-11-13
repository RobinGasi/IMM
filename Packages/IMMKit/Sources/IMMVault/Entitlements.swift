import Foundation
import Security

enum Entitlements {
    /// True when the running process carries `keychain-access-groups` (a signed build with a provisioning profile).
    static let hasKeychainAccessGroups: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
    }()
}
