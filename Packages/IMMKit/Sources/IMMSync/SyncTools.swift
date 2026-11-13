import Foundation
import GRDB
import IMMLedger

/// Lookups by name for the peer tool and the Debug hooks of the app.
public enum SyncLookup {
    /// The newest transaction whose id equals `query` or whose counterparty contains it (case-insensitive).
    public static func transactionID(in ledger: LedgerStore, matching query: String) throws -> String? {
        try ledger.database.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM ledger_transaction
                    WHERE deleted_at IS NULL AND (id = ?1 OR counterparty_name LIKE '%' || ?1 || '%' COLLATE NOCASE)
                    ORDER BY (id = ?1) DESC, booking_date DESC, id LIMIT 1
                    """,
                arguments: [query])
        }
    }

    public static func categoryID(in ledger: LedgerStore, named name: String) throws -> String? {
        try ledger.database.read { db in
            try String.fetchOne(
                db, sql: "SELECT id FROM category WHERE deleted_at IS NULL AND (name = ?1 COLLATE NOCASE OR id = ?1) LIMIT 1", arguments: [name])
        }
    }

    public struct TransactionSummary: Codable, Sendable, Equatable {
        public var id: String
        public var payee: String
        public var bookingDate: String
        public var amountCents: Int
        public var category: String?
        public var note: String?
    }

    public static func summary(in ledger: LedgerStore, matching query: String) throws -> TransactionSummary? {
        guard let id = try transactionID(in: ledger, matching: query) else { return nil }
        return try ledger.database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT t.id, t.counterparty_name AS payee, t.booking_date, t.amount, c.name AS category, t.note
                    FROM ledger_transaction t LEFT JOIN category c ON c.id = t.category_id WHERE t.id = ?
                    """,
                arguments: [id]
            ).map {
                TransactionSummary(
                    id: $0["id"], payee: $0["payee"], bookingDate: $0["booking_date"], amountCents: $0["amount"], category: $0["category"],
                    note: $0["note"])
            }
        }
    }
}
