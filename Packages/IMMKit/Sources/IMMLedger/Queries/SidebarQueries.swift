import Foundation
import GRDB

/// One account row of the sidebar (and the lookup the toolbar uses for account titles).
public struct SidebarAccount: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bankName: String
    public var subtitle: String?
    public var kind: AccountKind
    /// Value shown in the sidebar, minor units: the balance, or the holdings value for a depot.
    public var value: Int
    public var currency: String
    public var syncStatus: AccountSyncStatus
    public var lastSyncedAt: Date?
}

/// Everything the sidebar and toolbar show, computed in one read.
public struct SidebarSnapshot: Hashable, Sendable {
    /// The ledger's "today" (12.11.2026 while the database holds only demo data).
    public var today: LocalDate
    /// Non-tombstoned accounts in `sort_order`.
    public var accounts: [SidebarAccount]
    /// Rows with `is_new = 1`.
    public var newCount: Int
    /// Non-transfer rows without a category.
    public var uncategorisedCount: Int
    /// Sum of account values (depot value from holdings).
    public var netWorth: Int
    /// Most recent `last_synced_at` of any account.
    public var lastSyncedAt: Date?
    /// Accounts whose last sync failed.
    public var failedAccountCount: Int

    public static let empty = SidebarSnapshot(
        today: LocalDate(Date()), accounts: [], newCount: 0, uncategorisedCount: 0, netWorth: 0,
        lastSyncedAt: nil, failedAccountCount: 0)
}

public enum SidebarQueries {
    public static func snapshot(_ db: Database) throws -> SidebarSnapshot {
        let records = try AccountRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        var accounts: [SidebarAccount] = []
        accounts.reserveCapacity(records.count)
        for record in records {
            var value = record.balance
            if record.kind == .depot, let holdings = try LedgerDefinitions.holdingsValue(db, accountID: record.id) {
                value = holdings
            }
            accounts.append(SidebarAccount(
                id: record.id, name: record.name, bankName: record.bankName, subtitle: record.subtitle,
                kind: record.kind, value: value, currency: record.currency, syncStatus: record.syncStatus,
                lastSyncedAt: record.lastSyncedAt))
        }
        return SidebarSnapshot(
            today: try LedgerClock.today(db),
            accounts: accounts,
            newCount: try LedgerDefinitions.newCount(db),
            uncategorisedCount: try LedgerDefinitions.uncategorisedCount(db),
            netWorth: try LedgerDefinitions.netWorth(db),
            lastSyncedAt: records.compactMap(\.lastSyncedAt).max(),
            failedAccountCount: records.filter { $0.syncStatus == .failed }.count)
    }

    /// Re-emits whenever one of the tables behind the snapshot changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<SidebarSnapshot> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }
}
