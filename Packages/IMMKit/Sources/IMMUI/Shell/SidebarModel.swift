import Foundation
import IMMLedger
import Observation

/// Keeps the sidebar and toolbar numbers current with a `ValueObservation` on the open ledger.
@MainActor @Observable
public final class SidebarModel {
    public private(set) var snapshot = SidebarSnapshot.empty
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    func start(ledger: LedgerStore) {
        task?.cancel()
        if let initial = try? ledger.database.read(SidebarQueries.snapshot) { snapshot = initial }
        task = Task { @MainActor [weak self] in
            do {
                for try await value in SidebarQueries.observe(in: ledger) {
                    self?.snapshot = value
                }
            } catch {
                // The database was closed (lock) or the observation failed: keep the last values.
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        snapshot = .empty
    }
}
