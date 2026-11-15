import Foundation
import GRDB
import IMMLedger

/// Manual accounts and bookings: the way into the app without a bank connection.
extension AppModel {
    /// Creates a manual account. During onboarding (`phase == .needsBank`) it finishes onboarding (→ `.ready`).
    public func createManualAccount(_ input: ManualAccountInput) async throws -> String {
        guard let ledger else { throw BankControllerError.notReady }
        let now = Date()
        let id = try await ledger.database.write { db in
            try ledger.writer.createManualAccount(input, now: now, in: db)
        }
        if phase == .needsBank { try finishOnboarding() }
        return id
    }

    /// Adds a booking to a manual account and moves its balance. Returns the booking id.
    public func addManualBooking(_ input: ManualBookingInput) async throws -> String {
        guard let ledger else { throw BankControllerError.notReady }
        let now = Date()
        return try await ledger.database.write { db in
            try ledger.writer.addManualBooking(input, now: now, in: db)
        }
    }

    /// Deletes a manual booking and reverses its balance.
    public func deleteManualBooking(id: String) async throws {
        guard let ledger else { throw BankControllerError.notReady }
        let now = Date()
        try await ledger.database.write { db in
            try ledger.writer.deleteManualBooking(id: id, now: now, in: db)
        }
    }

    /// Manual accounts of the open ledger, in sidebar order (for pickers).
    public func manualAccounts() async -> [AccountRecord] {
        guard let ledger else { return [] }
        let accounts = try? await ledger.database.read { db in
            try AccountRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        }
        return (accounts ?? []).filter(\.isManual)
    }
}
