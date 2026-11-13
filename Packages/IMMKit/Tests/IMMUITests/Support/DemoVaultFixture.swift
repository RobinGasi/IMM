import Foundation
import IMMBanking
import IMMLedger
import IMMVault

/// A temporary encrypted vault holding the demo ledger, created once per test process.
/// Screen tests read from `store`; tests that mutate data use `makeIsolated()`.
final class DemoVaultFixture: @unchecked Sendable {
    static let password = "demo-demo"

    let vault: UnlockedVault
    let store: LedgerStore
    var packageURL: URL { vault.packageURL }

    private init(directory: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let vault = try Vault.create(at: directory, password: Self.password)
        let store = try LedgerStore(database: vault.database)
        let bank = try DemoDataset.load()
        try LedgerImporter.importSnapshot(bank.snapshot, profile: bank.profile, into: store)
        self.vault = vault
        self.store = store
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedFixture: DemoVaultFixture?

    private static var rootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("imm-ui-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// The per-process fixture at `<tmp>/imm-ui-tests-<pid>/Fixture.imm`; created on first use.
    static func shared() throws -> DemoVaultFixture {
        try sharedLock.withLock {
            if let sharedFixture { return sharedFixture }
            let fixture = try DemoVaultFixture(directory: rootDirectory.appendingPathComponent("Fixture.imm"))
            sharedFixture = fixture
            return fixture
        }
    }

    /// A fresh vault with its own demo ledger (`<tmp>/imm-ui-tests-<pid>/Isolated-<uuid>.imm`), for tests that write.
    static func makeIsolated() throws -> DemoVaultFixture {
        try DemoVaultFixture(directory: rootDirectory.appendingPathComponent("Isolated-\(UUID().uuidString).imm"))
    }

    /// Extension point for screen tests: the demo-filled ledger store (shared fixture).
    /// Screen tests build their `AppModel` around this store once `AppModel` exists.
    static func makeStore() async throws -> LedgerStore {
        try shared().store
    }
}
