import Foundation
import GRDB

// Everything the Tax return screen shows. The stored `tax` insight supplies the grouping, the wording
// and the receipt status; dates, amounts, totals, counts and the accounts named in the summary come
// from the ledger rows the insight cites.

/// Receipt status of a deduction.
public enum TaxReceipt: String, Hashable, Sendable {
    case attached
    case needed
    case statementEnough
}

public struct TaxRow: Hashable, Sendable, Identifiable {
    public var id: String
    /// Booking date of the first cited payment.
    public var date: LocalDate
    public var payee: String
    public var purpose: String
    /// Stored reason, with its footnote marker (`Mostly business trips [1]`).
    public var why: String
    public var receipt: TaxReceipt
    public var receiptLabel: String
    /// Sum of the cited payments (signed minor units).
    public var amount: Int
    /// Part that counts towards the deduction (positive minor units).
    public var eligible: Int
    public var transactions: [CitedTransaction]

    /// The payment a click on the row opens: the first cited one.
    public var firstTransaction: CitedTransaction? { transactions.first }
}

public struct TaxGroupRows: Hashable, Sendable, Identifiable {
    /// `Anlage N — Werbungskosten`.
    public var form: String
    public var rows: [TaxRow]
    public var id: String { form }

    public init(form: String, rows: [TaxRow]) {
        self.form = form
        self.rows = rows
    }
    /// Sum of the rows' eligible amounts (positive minor units).
    public var total: Int { rows.reduce(0) { $0 + $1.eligible } }
}

public struct TaxSnapshot: Hashable, Sendable {
    public var year: Int
    public var totalCaption: String
    public var groups: [TaxGroupRows]
    /// `[1] 4 of 7 Deutsche Bahn tickets …` in the stored order.
    public var footnotes: [String]
    public var disclaimer: String
    /// Names of the accounts the cited payments come from, in ledger order.
    public var accountNames: [String]

    public var rows: [TaxRow] { groups.flatMap(\.rows) }
    /// Sum of all eligible amounts (positive minor units).
    public var total: Int { groups.reduce(0) { $0 + $1.total } }
    public var itemCount: Int { rows.count }
    public var formCount: Int { groups.count }
    public var needsReceiptCount: Int { rows.filter { $0.receipt == .needed }.count }
    public var withReceiptCount: Int { rows.filter { $0.receipt == .attached }.count }
}

public enum TaxQueries {
    // MARK: Stored content (mirrors of `TaxPayload` in IMMBanking, only the fields used here)

    private struct Payload: Decodable {
        var year: Int
        var totalCaption: String
        var groups: [Group]
        var footnotes: [Footnote]
        var disclaimer: String

        struct Item: Decodable {
            var transactionReferences: [String]
            var date: LocalDate
            var payee: String
            var purpose: String
            var why: String
            var receipt: String
            var receiptLabel: String
            var amount: Int
            var eligibleAmount: Int?
            var sourceNumber: Int?
        }

        struct Group: Decodable {
            var form: String
            var items: [Item]
        }

        struct Footnote: Decodable {
            var number: Int
            var label: String
        }
    }

    /// The tax return of the stored `tax` insight, or nil when there is none.
    public static func snapshot(_ db: Database) throws -> TaxSnapshot? {
        guard let insight = try InsightRecord.live()
            .filter(sql: "kind = ?", arguments: [InsightKind.tax.rawValue])
            .order(Column("sort_order"), Column("id"))
            .fetchOne(db),
            let payload = try? JSONDecoder().decode(Payload.self, from: Data(insight.payload.utf8))
        else { return nil }

        var usedAccounts: [String: Int] = [:]
        var groups: [TaxGroupRows] = []
        for (groupIndex, group) in payload.groups.enumerated() {
            var rows: [TaxRow] = []
            for (itemIndex, item) in group.items.enumerated() {
                let cited = try CitedTransactions.find(db, references: item.transactionReferences)
                for row in cited where usedAccounts[row.accountName] == nil {
                    usedAccounts[row.accountName] = 0
                }
                let amount = cited.isEmpty ? item.amount : cited.reduce(0) { $0 + $1.amount }
                let why = item.sourceNumber.map { "\(item.why) [\($0)]" } ?? item.why
                rows.append(TaxRow(
                    id: "tax-\(groupIndex)-\(itemIndex)", date: cited.map(\.bookingDate).min() ?? item.date,
                    payee: item.payee, purpose: item.purpose, why: why,
                    receipt: TaxReceipt(rawValue: item.receipt) ?? .needed, receiptLabel: item.receiptLabel,
                    amount: amount, eligible: item.eligibleAmount ?? abs(amount), transactions: cited))
            }
            groups.append(TaxGroupRows(form: group.form, rows: rows))
        }

        // Account names in ledger order.
        let accounts = try AccountRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        let names = accounts.map(\.name).filter { usedAccounts[$0] != nil }

        return TaxSnapshot(
            year: payload.year, totalCaption: payload.totalCaption, groups: groups,
            footnotes: payload.footnotes.map { "[\($0.number)] \($0.label)" }, disclaimer: payload.disclaimer,
            accountNames: names)
    }

    /// Re-emits whenever one of the tables behind the tax return changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<TaxSnapshot?> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }
}
