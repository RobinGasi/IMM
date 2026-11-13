import Foundation
import Security

public protocol PINStore: Sendable {
    func store(pin: String, vaultID: UUID, loginID: UUID) throws
    func pin(vaultID: UUID, loginID: UUID) -> String?
    func count(vaultID: UUID) -> Int
    func removeAll(vaultID: UUID)
}

public enum PINStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}

/// Banking PINs as generic passwords: service `dev.gasi.imm.banking-pin`, account `<vaultID>:<loginID>`.
/// Uses the data-protection keychain only when the process has `keychain-access-groups`; otherwise the
/// file-based keychain (unsigned development builds).
public struct KeychainPINStore: PINStore {
    public static let defaultService = "dev.gasi.imm.banking-pin"

    private let service: String

    /// `service` is overridable so tests can use an isolated namespace.
    public init(service: String = KeychainPINStore.defaultService) {
        self.service = service
    }

    private func query(account: String? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account { query[kSecAttrAccount] = account }
        if Entitlements.hasKeychainAccessGroups { query[kSecUseDataProtectionKeychain] = true }
        return query
    }

    private func account(_ vaultID: UUID, _ loginID: UUID) -> String {
        "\(vaultID.uuidString):\(loginID.uuidString)"
    }

    public func store(pin: String, vaultID: UUID, loginID: UUID) throws {
        let itemAccount = account(vaultID, loginID)
        SecItemDelete(query(account: itemAccount) as CFDictionary)
        var attributes = query(account: itemAccount)
        attributes[kSecValueData] = Data(pin.utf8)
        if Entitlements.hasKeychainAccessGroups {
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw PINStoreError.keychain(status) }
    }

    public func pin(vaultID: UUID, loginID: UUID) -> String? {
        var request = query(account: account(vaultID, loginID))
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func count(vaultID: UUID) -> Int {
        accounts(for: vaultID).count
    }

    public func removeAll(vaultID: UUID) {
        for account in accounts(for: vaultID) {
            SecItemDelete(query(account: account) as CFDictionary)
        }
    }

    private func accounts(for vaultID: UUID) -> [String] {
        var request = query()
        request[kSecReturnAttributes] = true
        request[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        let prefix = "\(vaultID.uuidString):"
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { return nil }
            return account
        }
    }
}
