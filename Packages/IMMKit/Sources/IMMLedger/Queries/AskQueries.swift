import Foundation
import GRDB

// Ask: the one stored question with its answer. Pay invoice: the accounts a payment can leave from.
// The answer's figures come from the stored `ask` insight; its total, counts and group amounts are
// recomputed from the transactions the insight cites whenever all of them exist in the ledger.

/// One bar of the monthly chart.
public struct AskMonthBar: Hashable, Sendable, Identifiable {
    /// Three-letter month name (`Jun`).
    public var label: String
    /// Positive minor units.
    public var amount: Int
    /// True for the running month (drawn faded).
    public var partial: Bool
    public var id: String { label }
}

/// One row of "Where it went".
public struct AskGroupRow: Hashable, Sendable, Identifiable {
    public var name: String
    /// `25 orders`, `11 visits`, `39 payments`.
    public var countText: String
    /// Footnote number (`[2]`).
    public var sourceNumber: Int
    /// Signed minor units (negative = spending).
    public var amount: Int
    public var id: String { name }
}

public struct AskAnswer: Hashable, Sendable {
    public var question: String
    /// `Leisure & eating out, 01.06.–12.11.2026`.
    public var headline: String
    /// Signed minor units.
    public var total: Int
    public var confidenceLabel: String
    public var summary: String
    public var summarySourceNumber: Int
    public var monthly: [AskMonthBar]
    public var monthlyCaption: String
    public var groups: [AskGroupRow]
    public var totalLabel: String
    /// Number of transactions the answer is built from.
    public var transactionCount: Int
    /// Texts of the three follow-up buttons, in stored order.
    public var actions: [String]
}

/// The invoice payment's candidate source accounts.
public struct PayInvoiceSource: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bankName: String
    /// Minor units.
    public var balance: Int
}

public struct PayInvoiceSnapshot: Hashable, Sendable {
    /// The ledger's today (`LedgerClock`).
    public var today: LocalDate
    /// Giro and savings accounts in ledger order.
    public var sources: [PayInvoiceSource]
}

public enum AskQueries {
    private struct Content: Decodable {
        struct Month: Decodable {
            var label: String
            var amount: Int
            var partial: Bool
        }
        struct Group: Decodable {
            var name: String
            var countText: String
            var count: Int
            var amount: Int
            var sourceNumber: Int
            var transactionReferences: [String]
        }
        var question: String
        var headline: String
        var total: Int
        var confidenceLabel: String
        var summary: String
        var summarySourceNumber: Int
        var monthly: [Month]
        var monthlyCaption: String
        var groups: [Group]
        var totalLabel: String
        var totalPayments: Int
        var actions: [String]
        var transactionReferences: [String]
    }

    /// The stored answer, or nil when the ledger holds none.
    public static func answer(_ db: Database) throws -> AskAnswer? {
        guard let insight = try InsightRecord.live()
            .filter(sql: "kind = ?", arguments: [InsightKind.ask.rawValue])
            .order(Column("sort_order"), Column("id"))
            .fetchOne(db),
            let content = try? JSONDecoder().decode(Content.self, from: Data(insight.payload.utf8))
        else { return nil }

        // Signed amount per cited bank reference.
        let references = Set(content.transactionReferences + content.groups.flatMap(\.transactionReferences))
        var amounts: [String: Int] = [:]
        for chunk in Array(references).askChunked(by: 400) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT bank_ref, amount FROM ledger_transaction WHERE deleted_at IS NULL AND bank_ref IN (\(marks))",
                arguments: StatementArguments(chunk))
            for row in rows { amounts[row["bank_ref"]] = row["amount"] }
        }

        func resolved(_ refs: [String]) -> (sum: Int, complete: Bool) {
            var sum = 0
            for reference in refs {
                guard let amount = amounts[reference] else { return (0, false) }
                sum += amount
            }
            return (sum, !refs.isEmpty)
        }

        let all = resolved(content.transactionReferences)
        let groups = content.groups.map { group -> AskGroupRow in
            let own = resolved(group.transactionReferences)
            return AskGroupRow(
                name: group.name, countText: group.countText, sourceNumber: group.sourceNumber,
                amount: own.complete ? own.sum : group.amount)
        }
        return AskAnswer(
            question: content.question, headline: content.headline, total: all.complete ? all.sum : content.total,
            confidenceLabel: content.confidenceLabel, summary: content.summary,
            summarySourceNumber: content.summarySourceNumber,
            monthly: content.monthly.map { AskMonthBar(label: $0.label, amount: $0.amount, partial: $0.partial) },
            monthlyCaption: content.monthlyCaption, groups: groups, totalLabel: content.totalLabel,
            transactionCount: all.complete ? content.transactionReferences.count : content.totalPayments,
            actions: content.actions)
    }

    /// Re-emits whenever the insight or a cited transaction changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<AskAnswer?> {
        ValueObservation.tracking { try answer($0) }.values(in: store.database)
    }
}

public enum PayInvoiceQueries {
    public static func snapshot(_ db: Database) throws -> PayInvoiceSnapshot {
        let today = try LedgerClock.today(db)
        let accounts = try AccountRecord.live()
            .filter(sql: "kind IN (?, ?)", arguments: [AccountKind.giro.rawValue, AccountKind.savings.rawValue])
            .order(Column("sort_order"), Column("id"))
            .fetchAll(db)
        let sources = accounts.map {
            PayInvoiceSource(id: $0.id, name: $0.name, bankName: $0.bankName, balance: $0.balance)
        }
        return PayInvoiceSnapshot(today: today, sources: sources)
    }

    public static func observe(in store: LedgerStore) -> AsyncValueObservation<PayInvoiceSnapshot> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }
}

private extension Array {
    func askChunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
