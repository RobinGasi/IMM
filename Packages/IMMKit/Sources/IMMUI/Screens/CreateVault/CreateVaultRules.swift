import IMMVault
import Foundation

/// The Create vault form rules: a password needs at least 8 characters and both fields must match.
/// Nothing else is checked.
enum CreateVaultRules {
    static let minimumLength = 8

    /// Create stays disabled while a field is empty.
    static func canSubmit(password: String, confirm: String) -> Bool {
        !password.isEmpty && !confirm.isEmpty
    }

    static func isTooShort(_ password: String) -> Bool {
        password.count < minimumLength
    }

    static func isMismatch(password: String, confirm: String) -> Bool {
        password != confirm
    }

    /// True when the form passes every rule.
    static func isValid(password: String, confirm: String) -> Bool {
        canSubmit(password: password, confirm: confirm) && !isTooShort(password)
            && !isMismatch(password: password, confirm: confirm)
    }
}

/// What the Touch ID row of the form shows for each availability.
enum CreateVaultTouchID {
    /// The caption under a disabled switch; nil when Touch ID can be turned on.
    static func caption(for availability: BiometryAvailability) -> String? {
        switch availability {
        case .available: return nil
        case .missingEntitlement: return String(localized: "Touch ID needs a signed build of IMM.", bundle: .module)
        case .noSensor: return String(localized: "This Mac has no Touch ID.", bundle: .module)
        case .notEnrolled: return String(localized: "No fingerprint is set up on this Mac.", bundle: .module)
        }
    }
}
