import Foundation
import IMMLedger
import Observation

/// Holds the Depot's figures and follows the open ledger with a `ValueObservation`.
@MainActor @Observable
final class DepotModel {
    private(set) var snapshot: DepotSnapshot?

    /// Reads once, then re-reads whenever a table behind the snapshot changes. Returns when the
    /// surrounding task is cancelled or the database is closed (a lock).
    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(DepotQueries.snapshot) { snapshot = initial }
        do {
            for try await value in DepotQueries.observe(in: ledger) {
                snapshot = value
            }
        } catch {
            // Locked or closed: keep the last values; the shell leaves this screen.
        }
    }
}
