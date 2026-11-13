import Foundation
import GRDB

/// An account a transfer can leave from (Girokonto, Tagesgeld).
public struct TransferSource: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var bankName: String
    /// Balance in minor units.
    public var balance: Int
    public var currency: String

    public init(id: String, name: String, bankName: String, balance: Int, currency: String) {
        self.id = id
        self.name = name
        self.bankName = bankName
        self.balance = balance
        self.currency = currency
    }
}

/// A recipient the user paid before (standing orders and outgoing bookings).
public struct SavedRecipient: Sendable, Equatable {
    public var name: String
    /// Compact IBAN (no spaces).
    public var iban: String

    public init(name: String, iban: String) {
        self.name = name
        self.iban = iban
    }
}

/// Everything the New transfer form reads from the ledger.
public struct TransferFormSnapshot: Sendable, Equatable {
    public var sources: [TransferSource]
    public var recipients: [SavedRecipient]
    /// The ledger's "today" (first day offered for "On date").
    public var today: LocalDate

    public init(sources: [TransferSource], recipients: [SavedRecipient], today: LocalDate) {
        self.sources = sources
        self.recipients = recipients
        self.today = today
    }

    /// The first Girokonto (the form's default source); nil when no account can pay.
    public var defaultSourceID: String? { sources.first?.id }

    /// The saved recipient whose name equals `name` (case-insensitive, trimmed), if any.
    public func recipient(named name: String) -> SavedRecipient? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return recipients.first { $0.name.lowercased() == needle }
    }
}

public enum TransferQueries {
    /// Giro and savings accounts in sidebar order, the saved recipients and the ledger date.
    public static func snapshot(_ db: Database) throws -> TransferFormSnapshot {
        let accounts = try AccountRecord.live()
            .filter(sql: "kind IN (?, ?)", arguments: [AccountKind.giro.rawValue, AccountKind.savings.rawValue])
            .order(Column("sort_order"), Column("name"))
            .fetchAll(db)
        let sources = accounts.map {
            TransferSource(id: $0.id, name: $0.name, bankName: $0.bankName, balance: $0.balance, currency: $0.currency)
        }

        // Standing orders first (their IBAN was typed by the user), then outgoing bookings, newest first.
        let rows = try Row.fetchAll(db, sql: """
            SELECT recipient AS name, iban AS iban FROM standing_order
            WHERE deleted_at IS NULL AND iban != ''
            UNION ALL
            SELECT counterparty_name AS name, counterparty_iban AS iban FROM (
                SELECT counterparty_name, counterparty_iban FROM ledger_transaction
                WHERE deleted_at IS NULL AND amount < 0 AND counterparty_iban IS NOT NULL AND counterparty_iban != ''
                ORDER BY booking_date DESC, booking_seq DESC
            )
            """)
        var seen = Set<String>()
        var recipients: [SavedRecipient] = []
        for row in rows {
            let name: String = row["name"]
            let iban: String = row["iban"]
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            recipients.append(SavedRecipient(name: name, iban: iban.filter { !$0.isWhitespace }.uppercased()))
        }

        return TransferFormSnapshot(sources: sources, recipients: recipients, today: try LedgerClock.today(db))
    }

    /// Re-emits when accounts, standing orders or transactions change.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<TransferFormSnapshot> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }

    /// Name and bank of an account (the TAN sheet's "From Girokonto at Sparkasse KölnBonn").
    public static func source(_ db: Database, id: String) throws -> TransferSource? {
        guard let account = try AccountRecord.fetchOne(db, key: id) else { return nil }
        return TransferSource(
            id: account.id, name: account.name, bankName: account.bankName, balance: account.balance,
            currency: account.currency)
    }
}
