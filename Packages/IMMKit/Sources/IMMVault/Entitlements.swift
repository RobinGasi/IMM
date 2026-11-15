import Foundation
import Security

enum Entitlements {
    /// True when the running process carries `keychain-access-groups` (a signed build with a provisioning profile).
    /// Always true on iOS, where every app has an access group and only the data-protection keychain exists.
    static let hasKeychainAccessGroups: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
        #else
        return true
        #endif
    }()
}
