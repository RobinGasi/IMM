import Foundation
import IMMLedger
import Observation

/// Holds the Budgets figures and follows the open ledger with a `ValueObservation`.
@MainActor @Observable
final class BudgetsModel {
    private(set) var snapshot: BudgetsSnapshot?

    /// Reads once, then re-reads whenever a table behind the snapshot changes. Returns when the
    /// surrounding task is cancelled or the database is closed (a lock).
    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(BudgetsQueries.snapshot) { snapshot = initial }
        do {
            for try await value in BudgetsQueries.observe(in: ledger) {
                snapshot = value
            }
        } catch {
            // Locked or closed: keep the last values; the shell leaves this screen.
        }
    }
}
