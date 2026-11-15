import Foundation
import GRDB
import IMMLedger

/// Everything the tabs show besides the transaction list, loaded in one read.
struct CompanionData: Sendable, Equatable {
    var overview: CompanionOverview
    var accounts: [CompanionAccount]
    var categories: [CompanionCategory]
}

/// Maps `IMMLedger` query results to the companion's value types. The figures come from the same queries as the Mac's
/// Overview and sidebar, so both devices show the same numbers; only the transaction list has its own (small) query
/// because `TransactionQueries.snapshot` also builds balance chart and running balances the phone does not show.
enum CompanionQueries {
    /// Bookings in the overview's "recent" list.
    static let recentCount = 8
    /// Rows `transactions` returns at most.
    static let listLimit = 500

    static func load(_ db: Database) throws -> CompanionData {
        let records = try categoryRecords(db)
        let lookup = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let sidebar = try SidebarQueries.snapshot(db)
        let overview = try OverviewQueries.snapshot(db)
        let recent = try transactionRecords(db, accountID: nil, limit: recentCount)
        return CompanionData(
            overview: CompanionOverview(
                netWorth: sidebar.netWorth, spentThisMonth: overview.spentTotal, averageMonthlySpending: overview.monthlyAverage,
                uncategorisedCount: sidebar.uncategorisedCount, recent: recent.map { transaction($0, categories: lookup) }),
            accounts: sidebar.accounts.map(account),
            categories: records.map(category))
    }

    // MARK: Lists

    /// Live bookings, newest first, optionally of one account and filtered by `search` (every word must occur in the payee,
    /// purpose, note or category name, ignoring case and diacritics); at most ``listLimit`` rows.
    static func transactions(_ db: Database, accountID: String?, search: String) throws -> [CompanionTransaction] {
        let lookup = Dictionary(uniqueKeysWithValues: try categoryRecords(db).map { ($0.id, $0) })
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else {
            return try transactionRecords(db, accountID: accountID, limit: listLimit).map { transaction($0, categories: lookup) }
        }
        var found: [CompanionTransaction] = []
        for record in try transactionRecords(db, accountID: accountID, limit: nil) {
            let mapped = transaction(record, categories: lookup)
            let fields = [mapped.counterparty, record.counterpartyName, mapped.purpose, record.note, mapped.categoryName]
            guard matches(fields, terms: terms) else { continue }
            found.append(mapped)
            if found.count == listLimit { break }
        }
        return found
    }

    static func detail(_ db: Database, transactionID: String) throws -> CompanionTransactionDetail? {
        guard let record = try TransactionRecord.live().filter(Column("id") == transactionID).fetchOne(db) else { return nil }
        let lookup = Dictionary(uniqueKeysWithValues: try categoryRecords(db).map { ($0.id, $0) })
        let accountName = try AccountRecord.live().filter(Column("id") == record.accountId).fetchOne(db)?.name ?? ""
        return CompanionTransactionDetail(
            transaction: transaction(record, categories: lookup), accountName: accountName,
            valueDate: record.valueDate ?? record.bookingDate, counterpartyIBAN: record.counterpartyIban,
            bookingText: record.bookingText ?? "", note: record.note, categoryID: record.categoryId)
    }

    /// True when every term occurs in one of `fields`.
    static func matches(_ fields: [String?], terms: [String]) -> Bool {
        let haystack = fields.compactMap { $0 }
        return terms.allSatisfy { term in
            haystack.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    // MARK: Mapping

    private static func categoryRecords(_ db: Database) throws -> [CategoryRecord] {
        try CategoryRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
    }

    private static func transactionRecords(_ db: Database, accountID: String?, limit: Int?) throws -> [TransactionRecord] {
        var sql = """
            SELECT t.* FROM ledger_transaction t JOIN account a ON a.id = t.account_id
            WHERE t.deleted_at IS NULL AND a.deleted_at IS NULL
            """
        var arguments: [any DatabaseValueConvertible] = []
        if let accountID {
            sql += " AND t.account_id = ?"
            arguments.append(accountID)
        }
        sql += " ORDER BY \(LedgerOrder.transactionsNewestFirst(alias: "t"))"
        if let limit { sql += " LIMIT \(limit)" }
        return try TransactionRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    static func transaction(_ record: TransactionRecord, categories: [String: CategoryRecord]) -> CompanionTransaction {
        let category = record.categoryId.flatMap { categories[$0] }
        let shortName = record.shortName.flatMap { $0.isEmpty ? nil : $0 }
        return CompanionTransaction(
            id: record.id, accountID: record.accountId, bookingDate: record.bookingDate,
            counterparty: shortName ?? record.counterpartyName, purpose: record.purpose ?? "", amount: record.amount,
            currency: record.currency, categoryName: category?.name, categoryColorToken: category?.colorToken,
            // The ledger only holds booked rows; pending bookings never reach it.
            isPending: false)
    }

    private static func account(_ account: SidebarAccount) -> CompanionAccount {
        CompanionAccount(
            id: account.id, name: account.name, bankName: account.bankName, subtitle: account.subtitle ?? account.bankName,
            balance: account.value, currency: account.currency, kind: account.kind.rawValue)
    }

    private static func category(_ record: CategoryRecord) -> CompanionCategory {
        CompanionCategory(id: record.id, name: record.name, colorToken: record.colorToken, isIncome: record.kind == .income)
    }
}
