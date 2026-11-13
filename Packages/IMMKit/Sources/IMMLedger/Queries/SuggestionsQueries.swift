import Foundation
import GRDB

// Everything the Suggestions screen shows: the stored `suggestion` insights joined with their
// uncategorised ledger rows, the `notice` insights ("Also noticed") and their numbered sources.

/// How sure IMM is about a suggested category.
public enum SuggestionConfidence: String, Sendable, Hashable {
    case sure, likely, check
}

/// One uncategorised transaction with the category IMM proposes for it.
public struct SuggestionRow: Hashable, Sendable, Identifiable {
    /// Transaction id.
    public var id: String
    public var accountID: String
    public var accountName: String
    public var date: LocalDate
    /// Short name, else counterparty name.
    public var payee: String
    public var purpose: String
    /// Signed minor units.
    public var amount: Int
    public var suggestedCategory: String
    /// Ledger id of the suggested category (nil when no category carries that name).
    public var suggestedCategoryID: String?
    /// Design token of the suggested category's dot (`chart-2`, `input`, `credit`).
    public var colorToken: String
    public var confidence: SuggestionConfidence
    /// Badge text as stored (`Sure`, `Likely`, `Check this`).
    public var confidenceLabel: String
    public var reason: String
    /// The `[n]` the reason cites.
    public var sourceNumber: Int?
    /// Checked when the screen opens.
    public var preselected: Bool
}

/// One line of "Also noticed".
public struct SuggestionNotice: Hashable, Sendable, Identifiable {
    public enum Variant: String, Sendable, Hashable {
        case doubleCharge, newRule
    }

    public var id: String
    public var variant: Variant
    public var text: String
    public var sourceNumber: Int?
    public var actionTitle: String?
    /// Account of the transaction the notice is about (the first of a double charge).
    public var accountID: String?
}

/// One numbered line under "Sources".
public struct SuggestionSource: Hashable, Sendable, Identifiable {
    public var id: Int
    public var number: Int
    /// `14.10.2026`
    public var dateText: String
    public var label: String
    /// Signed minor units.
    public var amount: Int?
}

public struct SuggestionsSnapshot: Hashable, Sendable {
    public var rows: [SuggestionRow]
    public var notices: [SuggestionNotice]
    public var sources: [SuggestionSource]
    /// All categories (the "Change" menu), in list order.
    public var categories: [TransactionCategory] = []

    /// Rows IMM is sure about ("Accept 3 sure suggestions").
    public var sureCount: Int { rows.filter { $0.confidence == .sure }.count }
}

public enum SuggestionsQueries {
    public static func snapshot(_ db: Database) throws -> SuggestionsSnapshot {
        let decoder = JSONDecoder()
        let categories = try CategoryRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        let accounts = Dictionary(uniqueKeysWithValues: try AccountRecord.live().fetchAll(db).map { ($0.id, $0.name) })

        var rows: [SuggestionRow] = []
        let suggestions = try InsightRecord.live()
            .filter(sql: "kind = ?", arguments: [InsightKind.suggestion.rawValue])
            .order(Column("sort_order"), Column("id"))
            .fetchAll(db)
        for insight in suggestions {
            guard let transactionID = insight.transactionId,
                  let transaction = try TransactionRecord.live().filter(Column("id") == transactionID).fetchOne(db),
                  transaction.categoryId == nil,
                  let content = try? decoder.decode(SuggestionContent.self, from: Data(insight.payload.utf8))
            else { continue }
            rows.append(SuggestionRow(
                id: transaction.id,
                accountID: transaction.accountId,
                accountName: accounts[transaction.accountId] ?? "",
                date: transaction.bookingDate,
                payee: transaction.shortName ?? transaction.counterpartyName,
                purpose: transaction.purpose ?? "",
                amount: transaction.amount,
                suggestedCategory: content.suggestedCategory,
                suggestedCategoryID: categories.first { $0.name == content.suggestedCategory }?.id,
                colorToken: categories.first { $0.name == content.suggestedCategory }?.colorToken ?? "input",
                confidence: SuggestionConfidence(rawValue: content.confidence) ?? .likely,
                confidenceLabel: content.confidenceLabel,
                reason: content.reason,
                sourceNumber: content.sourceNumber,
                preselected: content.preselected))
        }

        var notices: [SuggestionNotice] = []
        var sources: [SuggestionSource] = []
        let noticeInsights = try InsightRecord.live()
            .filter(sql: "kind = ?", arguments: [InsightKind.notice.rawValue])
            .order(Column("sort_order"), Column("id"))
            .fetchAll(db)
        for insight in noticeInsights {
            guard let content = try? decoder.decode(NoticeContent.self, from: Data(insight.payload.utf8)) else { continue }
            if content.variant == "sources" {
                for source in content.sources {
                    sources.append(SuggestionSource(
                        id: sources.count, number: source.number, dateText: source.dateText, label: source.label,
                        amount: source.amount))
                }
            } else if let variant = SuggestionNotice.Variant(rawValue: content.variant) {
                var accountID: String?
                if let transactionID = insight.transactionId {
                    accountID = try TransactionRecord.live().filter(Column("id") == transactionID).fetchOne(db)?.accountId
                }
                notices.append(SuggestionNotice(
                    id: insight.id, variant: variant, text: content.text, sourceNumber: content.sourceNumber,
                    actionTitle: content.actionTitle, accountID: accountID))
            }
        }
        return SuggestionsSnapshot(
            rows: rows, notices: notices, sources: sources,
            categories: categories.map {
                TransactionCategory(id: $0.id, name: $0.name, colorToken: $0.colorToken, kind: $0.kind)
            })
    }

    /// Re-emits whenever one of the tables behind the snapshot changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<SuggestionsSnapshot> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }

    // Contents of the stored insights (written by the demo data set as `SuggestionPayload` / `NoticePayload`).

    private struct SuggestionContent: Decodable {
        var suggestedCategory: String
        var confidence: String
        var confidenceLabel: String
        var reason: String
        var sourceNumber: Int?
        var preselected: Bool
    }

    private struct NoticeContent: Decodable {
        var variant: String
        var text: String
        var sourceNumber: Int?
        var actionTitle: String?
        var sources: [SourceContent]
    }

    private struct SourceContent: Decodable {
        var number: Int
        var dateText: String
        var label: String
        var amount: Int?
    }
}
