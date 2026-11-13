import Foundation
import IMMLedger
import Observation

/// Holds the October review's figures and follows the open ledger with a `ValueObservation`.
@MainActor @Observable
final class ReviewModel {
    private(set) var snapshot: ReviewSnapshot?

    /// Reads once, then re-reads whenever a table behind the review changes. Returns when the
    /// surrounding task is cancelled or the database is closed (a lock).
    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(ReviewQueries.snapshot) { snapshot = initial }
        do {
            for try await value in ReviewQueries.observe(in: ledger) {
                snapshot = value
            }
        } catch {
            // Locked or closed: keep the last values; the shell leaves this screen.
        }
    }
}

/// Holds the Tax return's rows and follows the open ledger with a `ValueObservation`.
@MainActor @Observable
final class TaxModel {
    private(set) var snapshot: TaxSnapshot?

    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(TaxQueries.snapshot) { snapshot = initial }
        do {
            for try await value in TaxQueries.observe(in: ledger) {
                snapshot = value
            }
        } catch {
            // Locked or closed: keep the last values; the shell leaves this screen.
        }
    }
}
