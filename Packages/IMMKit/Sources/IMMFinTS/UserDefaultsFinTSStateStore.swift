import Foundation

/// Keeps the FinTS customer system id and the chosen TAN method of each login in `UserDefaults`.
///
/// Keys are `fints.systemID.<bank code>.<login hash>` and `fints.tanMethod.<bank code>.<login hash>`, where the login hash
/// is the first ten hex characters of the SHA-256 of the login name. Neither the PIN nor the raw login name is stored.
public final class UserDefaultsFinTSStateStore: FinTSStateStore, @unchecked Sendable {
    // `UserDefaults` is documented thread-safe; the class holds no other state.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func systemID(bankCode: String, loginName: String) -> String? {
        defaults.string(forKey: Self.key("systemID", bankCode, loginName))
    }

    public func setSystemID(_ id: String, bankCode: String, loginName: String) {
        defaults.set(id, forKey: Self.key("systemID", bankCode, loginName))
    }

    public func tanMethod(bankCode: String, loginName: String) -> String? {
        defaults.string(forKey: Self.key("tanMethod", bankCode, loginName))
    }

    public func setTANMethod(_ code: String, bankCode: String, loginName: String) {
        defaults.set(code, forKey: Self.key("tanMethod", bankCode, loginName))
    }

    static func key(_ kind: String, _ bankCode: String, _ loginName: String) -> String {
        "fints.\(kind).\(bankCode.filter { !$0.isWhitespace }).\(FinTSDigest.loginHash(loginName))"
    }
}
