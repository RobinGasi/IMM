import Foundation
import GRDB

/// A manual account the user types in (cash, an account the bank does not offer a connection for).
public struct ManualAccountInput: Sendable, Equatable {
    public var name: String
    public var kind: AccountKind
    /// Balance on creation, minor units (may be negative).
    public var openingBalance: Int
    public var currency: String

    public init(name: String, kind: AccountKind, openingBalance: Int, currency: String = "EUR") {
        self.name = name
        self.kind = kind
        self.openingBalance = openingBalance
        self.currency = currency
    }
}

/// A booking the user types into a manual account.
public struct ManualBookingInput: Sendable, Equatable {
    public var accountID: String
    public var bookingDate: LocalDate
    /// Signed minor units (negative = outflow).
    public var amount: Int
    public var counterparty: String
    public var purpose: String
    public var categoryID: String?
    public var note: String?

    public init(
        accountID: String, bookingDate: LocalDate, amount: Int, counterparty: String, purpose: String = "",
        categoryID: String? = nil, note: String? = nil
    ) {
        self.accountID = accountID
        self.bookingDate = bookingDate
        self.amount = amount
        self.counterparty = counterparty
        self.purpose = purpose
        self.categoryID = categoryID
        self.note = note
    }
}

public enum ManualLedgerError: Error, Equatable, Sendable {
    /// The account or booking belongs to a bank connection; its numbers come from the bank, not from the user.
    case notManual(id: String)
    case noSuchAccount(id: String)
    case noSuchBooking(id: String)
}

extension AccountRecord {
    /// Manual accounts are recognised by their id on every device, without a schema column that would change
    /// `SyncSchema.version`.
    public var isManual: Bool { id.hasPrefix(LedgerWriter.manualAccountPrefix) }
}

/// Manual accounts and bookings.
///
/// - Account: id `manual-<uuid>`, no bank login, `sync_status` never. Its `balance` starts at the opening balance.
/// - Booking: random UUID id, `bank_ref_kind = "manual"`, `bank_ref` = its own id.
///
/// Balance invariant: `account.balance` = opening balance + sum of the live manual bookings. Balances shown per
/// booking (`LedgerDefinitions.runningBalances`) and net worth on a past day are derived backwards from
/// `account.balance`, so the opening balance needs no booking of its own: it is whatever remains before the
/// oldest booking. Every write goes through the synced writer paths, so accounts and bookings reach other
/// devices like any other row.
extension LedgerWriter {
    static let manualAccountPrefix = "manual-"
    static let manualBookingRefKind = "manual"

    /// Creates the account and returns its id.
    public func createManualAccount(_ input: ManualAccountInput, now: Date, in db: Database) throws -> String {
        let id = Self.manualAccountPrefix + UUID().uuidString.lowercased()
        let highest = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM account WHERE deleted_at IS NULL")
        let record = AccountRecord(
            id: id, kind: input.kind, name: input.name, bankName: "", subtitle: nil, balance: input.openingBalance,
            currency: input.currency, overdraftLimit: 0, sortOrder: highest.map { $0 + 1 } ?? 0, syncStatus: .never,
            createdAt: now, updatedAt: now)
        try insert(record, in: db)
        return id
    }

    /// Adds a booking and moves the account balance by its amount. Returns the booking id.
    public func addManualBooking(_ input: ManualBookingInput, now: Date, in db: Database) throws -> String {
        let account = try manualAccount(input.accountID, in: db)
        let id = UUID().uuidString.lowercased()
        // The newest row of its day: one above the highest number already used (like the importer's booked rows).
        let highest = try Int.fetchOne(
            db, sql: "SELECT MAX(booking_seq) FROM ledger_transaction WHERE account_id = ? AND booking_date = ?",
            arguments: [account.id, input.bookingDate.iso]) ?? 0
        let record = TransactionRecord(
            id: id, accountId: account.id, bookingDate: input.bookingDate, valueDate: input.bookingDate,
            bookingSeq: highest + 1, amount: input.amount, currency: account.currency, counterpartyName: input.counterparty,
            shortName: input.counterparty, bookingText: "", purpose: input.purpose, kind: .transfer,
            categoryId: input.categoryID, isOwnTransfer: false, isNew: false, note: input.note,
            bankRefKind: Self.manualBookingRefKind, bankRef: id, createdAt: now, updatedAt: now)
        try insert(record, in: db)
        try set(table: "account", rowID: account.id, column: "balance", to: SyncValue(account.balance + input.amount), in: db)
        return id
    }

    /// Soft-deletes a manual booking and takes its amount back out of the account balance.
    /// Deleting a booking that is already deleted does nothing.
    public func deleteManualBooking(id: String, now: Date, in db: Database) throws {
        guard let booking = try TransactionRecord.fetchOne(db, key: id) else { throw ManualLedgerError.noSuchBooking(id: id) }
        guard booking.bankRefKind == Self.manualBookingRefKind else { throw ManualLedgerError.notManual(id: id) }
        if booking.deletedAt != nil { return }
        let account = try manualAccount(booking.accountId, in: db)
        try delete(table: "ledger_transaction", rowID: id, in: db)
        try set(table: "account", rowID: account.id, column: "balance", to: SyncValue(account.balance - booking.amount), in: db)
    }

    /// The live manual account with `id`.
    private func manualAccount(_ id: String, in db: Database) throws -> AccountRecord {
        guard let account = try AccountRecord.live().filter(key: id).fetchOne(db) else { throw ManualLedgerError.noSuchAccount(id: id) }
        guard account.isManual else { throw ManualLedgerError.notManual(id: id) }
        return account
    }
}
