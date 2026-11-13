import Foundation
import Testing
@testable import IMMVault

@Suite struct VaultBookmarksTests {
    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "dev.gasi.imm.tests.bookmarks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func lastVaultBookmarkResolves() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let bookmarks = VaultBookmarks(defaults: defaults, securityScoped: false)
        #expect(bookmarks.resolveLastVault() == nil)

        try withTempDirectory { directory in
            let package = vaultURL(in: directory)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try bookmarks.saveLastVault(package)
            #expect(defaults.data(forKey: "lastVaultBookmark") != nil)
            #expect(bookmarks.lastVaultPath == package.path)
            let resolved = try #require(bookmarks.resolveLastVault())
            #expect(resolved.resolvingSymlinksInPath() == package.resolvingSymlinksInPath())
        }

        bookmarks.forgetLastVault()
        #expect(bookmarks.resolveLastVault() == nil)
        #expect(bookmarks.lastVaultPath == nil)
    }

    @Test func infoAndWarningFlagsArePerVault() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let bookmarks = VaultBookmarks(defaults: defaults)
        let vaultID = UUID()
        #expect(bookmarks.info(vaultID: vaultID) == nil)

        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        bookmarks.saveInfo(VaultInfo(displayName: "Moneten.imm", lastOpened: opened, accountCount: 5), vaultID: vaultID)
        let info = try #require(bookmarks.info(vaultID: vaultID))
        #expect(info == VaultInfo(displayName: "Moneten.imm", lastOpened: opened, accountCount: 5))
        #expect(bookmarks.info(vaultID: UUID()) == nil)
        #expect(defaults.dictionary(forKey: "vaultInfo.\(vaultID.uuidString)") != nil)

        #expect(!bookmarks.syncedFolderWarningShown(vaultID: vaultID))
        bookmarks.setSyncedFolderWarningShown(true, vaultID: vaultID)
        #expect(bookmarks.syncedFolderWarningShown(vaultID: vaultID))
        #expect(!bookmarks.syncedFolderWarningShown(vaultID: UUID()))
        #expect(defaults.bool(forKey: "syncedFolderWarningShown.\(vaultID.uuidString)"))
    }
}
