import Foundation
import LocalAuthentication
import Security

public enum CompanionKeyStoreError: Error, Equatable, Sendable {
    /// The user dismissed Face ID / passcode, or failed it.
    case cancelled
    /// The item is gone (device passcode removed, or never created).
    case notFound
    /// Any other Keychain failure, with its `OSStatus`.
    case unavailable(OSStatus)
}

/// The phone's vault password in the data-protection Keychain: a random 32-byte secret (base64) that only exists while a
/// device passcode is set, never leaves this device and is released after Face ID / passcode (`.userPresence`).
/// Needs the `keychain-access-groups` entitlement of the app.
public struct KeychainCompanionKeyStore: CompanionKeyStore {
    public static let defaultService = "dev.gasi.imm.companion-key"
    private static let account = "vault-password"

    private let service: String

    public init(service: String = KeychainCompanionKeyStore.defaultService) {
        self.service = service
    }

    private func baseQuery() -> [CFString: Any] { Self.baseQuery(service: service) }

    private static func baseQuery(service: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    /// True while the item exists; never prompts.
    public func hasKey() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery()
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func createKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let random = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard random == errSecSuccess else { throw CompanionKeyStoreError.unavailable(random) }
        let password = Data(bytes).base64EncodedString()

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &accessError
        ) else {
            accessError?.release()
            throw CompanionKeyStoreError.unavailable(errSecParam)
        }

        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData] = Data(password.utf8)
        attributes[kSecAttrAccessControl] = access
        attributes[kSecAttrSynchronizable] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionKeyStoreError.unavailable(status) }
        return password
    }

    public func readKey(reason: String) async throws -> String {
        let service = service
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.blockingRead(service: service, reason: reason) })
            }
        }
    }

    private static func blockingRead(service: String, reason: String) throws -> String {
        let context = LAContext()
        context.localizedReason = reason
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var query = baseQuery(service: service)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
                throw CompanionKeyStoreError.unavailable(errSecDecode)
            }
            return password
        case errSecUserCanceled, errSecAuthFailed:
            throw CompanionKeyStoreError.cancelled
        case errSecItemNotFound:
            throw CompanionKeyStoreError.notFound
        default:
            throw CompanionKeyStoreError.unavailable(status)
        }
    }

    public func deleteKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
