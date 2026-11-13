import Foundation
import GRDB
import IMMBanking
import IMMLedger
import IMMVault
@testable import IMMUI
import Testing

/// What happens to work that is still running when the database locks: it must stop or finish before the vault closes, and
/// nothing may write into the closed database afterwards (a closed GRDB pool answers `SQLite error 21: out of memory`).
@MainActor
@Suite(.serialized) struct LockOrderingTests {
    /// A world whose model locks on sleep (the default) and has a confirmed sign-in, ready to import.
    private func worldAtImport() async throws -> ScenarioWorld {
        let world = ScenarioWorld()
        try await world.model.createVault(at: world.vaultURL, password: ScenarioWorld.password, enableTouchID: false)
        try await world.model.bank.signIn(
            bank: DemoConnector.directory[0],
            credentials: BankCredentials(loginName: "lena", pin: "12345678", tanMethod: "pushTAN"))
        return world
    }

    /// The Mac goes to sleep (or the screen locks) while the first import runs. `LockMonitor` locks the model on the main
    /// actor at any point of the import; the import must end as cancelled, not with a SQLite error from the closed pool.
    @Test func lockingWhileTheFirstImportRunsEndsItWithoutTouchingTheClosedDatabase() async throws {
        let world = try await worldAtImport()
        defer { world.finish() }
        let model = world.model

        let importing = Task { @MainActor in try await model.bank.importAccounts(since: Date(), storePIN: false) }
        try await Task.sleep(for: .milliseconds(15))
        model.lock(.sleep)

        do {
            try await importing.value
            Issue.record("the import finished although the database was locked meanwhile")
        } catch {
            let text = "\(error)"
            #expect(!text.contains("SQLite error"), "import ended with a database error: \(text)")
        }
        guard case .locked = model.phase else {
            Issue.record("phase is \(model.phase)")
            return
        }
        #expect(model.ledger == nil)
    }
}
