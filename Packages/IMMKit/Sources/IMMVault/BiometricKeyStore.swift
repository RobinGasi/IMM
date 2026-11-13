import Foundation
import LocalAuthentication
import Security

public enum BiometryAvailability: Equatable, Sendable {
    case available, noSensor, notEnrolled, missingEntitlement
}

public enum BiometryError: Error, Equatable, Sendable {
    case cancelled, failed, keyInvalidated
}

/// Stores the vault data key behind the current set of enrolled fingerprints.
public protocol BiometricKeyStore: Sendable {
    func availability() -> BiometryAvailability
    func store(vaultID: UUID, dataKey: borrowing SecureBytes) throws
    func load(vaultID: UUID, reason: String) async throws -> SecureBytes
    func remove(vaultID: UUID)
    func contains(vaultID: UUID) -> Bool
}

/// Keychain item protected by `.biometryCurrentSet` in the data-protection keychain.
/// Requires the `keychain-access-groups` entitlement; without it `availability()` is `.missingEntitlement`.
public struct KeychainBiometricKeyStore: BiometricKeyStore {
    public static let service = "dev.gasi.imm.vault-key"

    // UserDefaults is documented thread-safe but not marked Sendable in the SDK.
    nonisolated(unsafe) private let defaults: UserDefaults

    /// `defaults` holds a per-vault marker that an item was stored, so a vanished item (fingerprints changed)
    /// can be told apart from "never enabled".
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func markerKey(_ vaultID: UUID) -> String { "biometricKeyStored.\(vaultID.uuidString)" }

    private static func baseQuery(_ vaultID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: vaultID.uuidString,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    public func availability() -> BiometryAvailability {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let entitled = Entitlements.hasKeychainAccessGroups
        if canEvaluate {
            return entitled ? .available : .missingEntitlement
        }
        switch error.flatMap({ LAError.Code(rawValue: $0.code) }) {
        case .biometryNotEnrolled:
            return entitled ? .notEnrolled : .missingEntitlement
        case .biometryLockout:
            // Enrolled; the lockout clears after a passcode entry.
            return entitled ? .available : .missingEntitlement
        default:
            return .noSensor
        }
    }

    public func store(vaultID: UUID, dataKey: borrowing SecureBytes) throws {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &accessError
        ) else {
            accessError?.release()
            throw BiometryError.failed
        }
        var keyData = dataKey.withUnsafeBytes { Data($0) }
        defer { keyData.resetBytes(in: 0..<keyData.count) }

        SecItemDelete(Self.baseQuery(vaultID) as CFDictionary)
        var attributes = Self.baseQuery(vaultID)
        attributes[kSecValueData] = keyData
        attributes[kSecAttrAccessControl] = access
        attributes[kSecAttrSynchronizable] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw BiometryError.failed }
        defaults.set(true, forKey: markerKey(vaultID))
    }

    public func load(vaultID: UUID, reason: String) async throws -> SecureBytes {
        let existed = defaults.bool(forKey: markerKey(vaultID))
        let buffer: KeyBuffer = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.blockingLoad(vaultID: vaultID, reason: reason, existed: existed)
                })
            }
        }
        defer { buffer.wipe() }
        return buffer.copyOut()
    }

    private static func blockingLoad(vaultID: UUID, reason: String, existed: Bool) throws -> KeyBuffer {
        let context = LAContext()
        context.localizedReason = reason
        context.touchIDAuthenticationAllowableReuseDuration = 0

        var query = baseQuery(vaultID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw BiometryError.failed }
            return data.withUnsafeBytes { KeyBuffer(copying: $0) }
        case errSecUserCanceled:
            throw BiometryError.cancelled
        case errSecItemNotFound:
            throw existed ? BiometryError.keyInvalidated : BiometryError.failed
        default:
            throw BiometryError.failed
        }
    }

    public func remove(vaultID: UUID) {
        SecItemDelete(Self.baseQuery(vaultID) as CFDictionary)
        defaults.removeObject(forKey: markerKey(vaultID))
    }

    /// True while the keychain item exists (no prompt).
    public func contains(vaultID: UUID) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = Self.baseQuery(vaultID)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// True when an item was stored for this vault but the system has since invalidated it
    /// (enrolled fingerprints changed). The password is required once, then `store` again.
    public func isInvalidated(vaultID: UUID) -> Bool {
        defaults.bool(forKey: markerKey(vaultID)) && !contains(vaultID: vaultID)
    }
}
