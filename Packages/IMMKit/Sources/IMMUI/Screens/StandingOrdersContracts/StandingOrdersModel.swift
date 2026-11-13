import IMMLedger
import Observation

/// Follows the open ledger for the Standing orders screen.
@MainActor @Observable
final class StandingOrdersModel {
    private(set) var snapshot: StandingOrdersSnapshot?

    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(StandingOrdersQueries.snapshot) { snapshot = initial }
        do {
            for try await value in StandingOrdersQueries.observe(in: ledger) {
                snapshot = value
            }
        } catch {
            // Locked or closed: keep the last values; the shell leaves this screen.
        }
    }
}

/// Follows the open ledger for the Contracts screen.
@MainActor @Observable
final class ContractsModel {
    private(set) var snapshot: ContractsSnapshot?

    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(ContractsQueries.snapshot) { snapshot = initial }
        do {
            for try await value in ContractsQueries.observe(in: ledger) {
                snapshot = value
            }
        } catch {
            // Locked or closed: keep the last values; the shell leaves this screen.
        }
    }
}
