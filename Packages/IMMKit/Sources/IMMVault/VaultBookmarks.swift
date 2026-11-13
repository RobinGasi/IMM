import Foundation

/// Lock-screen metadata stored in IMM's preferences on this Mac (never inside the package).
public struct VaultInfo: Equatable, Sendable {
    public var displayName: String
    public var lastOpened: Date
    public var accountCount: Int

    public init(displayName: String, lastOpened: Date, accountCount: Int) {
        self.displayName = displayName
        self.lastOpened = lastOpened
        self.accountCount = accountCount
    }
}

/// UserDefaults-backed memory of the last database. Keys: `lastVaultBookmark` (security-scoped bookmark),
/// `lastVaultPath` (plain path for the "can't be found" screen), `vaultInfo.<vaultID>`,
/// `syncedFolderWarningShown.<vaultID>`.
public struct VaultBookmarks: Sendable {
    public static let bookmarkKey = "lastVaultBookmark"
    public static let pathKey = "lastVaultPath"

    // UserDefaults is documented thread-safe but not marked Sendable in the SDK.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let securityScoped: Bool

    /// `securityScoped` is `true` in the app; tests outside a sandbox may pass `false`.
    public init(defaults: UserDefaults = .standard, securityScoped: Bool = true) {
        self.defaults = defaults
        self.securityScoped = securityScoped
    }

    // MARK: Last vault

    public func saveLastVault(_ url: URL) throws {
        let options: URL.BookmarkCreationOptions = securityScoped ? [.withSecurityScope] : []
        let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.bookmarkKey)
        defaults.set(url.path, forKey: Self.pathKey)
    }

    /// Resolves the stored bookmark (it follows moves and renames). Returns nil when nothing is stored or the
    /// target no longer exists. The caller must call `startAccessingSecurityScopedResource()` on the result.
    public func resolveLastVault() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        let options: URL.BookmarkResolutionOptions = securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale { try? saveLastVault(url) }
        return url
    }

    /// The path last saved, for display when the bookmark no longer resolves.
    public var lastVaultPath: String? { defaults.string(forKey: Self.pathKey) }

    public func forgetLastVault() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.pathKey)
    }

    // MARK: Lock-screen info

    private func infoKey(_ vaultID: UUID) -> String { "vaultInfo.\(vaultID.uuidString)" }

    public func info(vaultID: UUID) -> VaultInfo? {
        guard let dictionary = defaults.dictionary(forKey: infoKey(vaultID)),
              let name = dictionary["displayName"] as? String,
              let opened = dictionary["lastOpened"] as? Date,
              let count = dictionary["accountCount"] as? Int else { return nil }
        return VaultInfo(displayName: name, lastOpened: opened, accountCount: count)
    }

    public func saveInfo(_ info: VaultInfo, vaultID: UUID) {
        defaults.set(
            ["displayName": info.displayName, "lastOpened": info.lastOpened, "accountCount": info.accountCount] as [String: Any],
            forKey: infoKey(vaultID)
        )
    }

    // MARK: Synced-folder warning

    private func warningKey(_ vaultID: UUID) -> String { "syncedFolderWarningShown.\(vaultID.uuidString)" }

    public func syncedFolderWarningShown(vaultID: UUID) -> Bool {
        defaults.bool(forKey: warningKey(vaultID))
    }

    public func setSyncedFolderWarningShown(_ shown: Bool, vaultID: UUID) {
        defaults.set(shown, forKey: warningKey(vaultID))
    }
}
