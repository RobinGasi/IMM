import Foundation
import GRDB

// Everything the Depot screen shows, computed from the ledger in one read.
// Definitions: `LedgerDefinitions.holdingsValue` (value), cost basis = sum of the holdings' cost bases,
// value history from `depot_value_history`; "today" is `LedgerClock`.

/// The ranges of the performance chart.
public enum DepotRange: String, CaseIterable, Hashable, Sendable {
    case oneMonth = "1M"
    case sixMonths = "6M"
    case oneYear = "1Y"
    case max = "Max"

    /// First day of the range for a ledger `today`; `nil` for `.max` (the whole history).
    public func start(today: LocalDate) -> LocalDate? {
        switch self {
        case .oneMonth: return today.adding(months: -1)
        case .sixMonths: return today.adding(months: -6)
        case .oneYear: return today.adding(months: -12)
        case .max: return nil
        }
    }
}

/// One day of the stored value history.
public struct DepotPoint: Hashable, Sendable {
    public var date: LocalDate
    /// Minor units.
    public var value: Int
}

/// A fund or the cash account.
public struct DepotHolding: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isin: String?
    /// Cash (Verrechnungskonto): no quantity, price or gain.
    public var isCash: Bool
    /// Millionths of a unit.
    public var quantityMicro: Int
    /// Unit price, minor units.
    public var price: Int
    /// `quantity × price`, minor units.
    public var value: Int
    public var costBasis: Int

    /// Gain or loss against the cost basis; nil for cash.
    public var gain: Int? { isCash ? nil : value - costBasis }
}

/// One slice of "Allocation by region".
public struct DepotRegion: Hashable, Sendable, Identifiable {
    public var name: String
    /// Design token name of the slice colour (`chart-1`).
    public var colorToken: String
    /// Minor units.
    public var value: Int
    public var id: String { name }
}

public struct DepotSavingsItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Minor units per run.
    public var amount: Int
}

public struct DepotSavingsPlan: Hashable, Sendable {
    /// Total per run, minor units.
    public var amount: Int
    public var dayOfMonth: Int
    public var nextExecution: LocalDate?
    /// `Girokonto, Sparkasse KölnBonn`, empty when the plan has no source account.
    public var sourceAccount: String
    public var items: [DepotSavingsItem]

    /// Debit days strictly after `start` and up to and including `today`.
    public func debitCount(after start: LocalDate, through today: LocalDate) -> Int {
        var count = 0
        var month = start.firstOfMonth
        while month <= today {
            let day = LocalDate(year: month.year, month: month.month, day: min(dayOfMonth, month.daysInMonth))
            if day > start && day <= today { count += 1 }
            month = month.adding(months: 1)
        }
        return count
    }
}

public struct DepotSnapshot: Hashable, Sendable {
    public var today: LocalDate
    /// Market value of all holdings including cash, minor units.
    public var value: Int
    /// Value on the day before `today` from the history; nil without one.
    public var valueYesterday: Int?
    public var costBasis: Int
    /// Funds in ledger order, then the cash account.
    public var holdings: [DepotHolding]
    /// Regions with a share, in design order; the cash slice is `cash`.
    public var regions: [DepotRegion]
    /// Cash held in the depot account, minor units.
    public var cash: Int
    /// The whole stored history, oldest first.
    public var history: [DepotPoint]
    public var savingsPlan: DepotSavingsPlan?

    public var gain: Int { value - costBasis }
    public var fundCount: Int { holdings.filter { !$0.isCash }.count }
    public var hasCash: Bool { holdings.contains { $0.isCash } }

    /// The history inside `range` (inclusive of its first day).
    public func points(in range: DepotRange) -> [DepotPoint] {
        guard let start = range.start(today: today) else { return history }
        return history.filter { $0.date >= start }
    }
}

/// Integer percentage maths shared by the screen and its tests.
public enum DepotMath {
    /// `num / den` in tenths of a percent, rounded half away from zero (`176` is 17,6 %); 0 without a denominator.
    public static func tenthsOfPercent(_ num: Int, _ den: Int) -> Int {
        guard den != 0 else { return 0 }
        let q = (abs(num) * 2000 + abs(den)) / (2 * abs(den))
        return (num < 0) != (den < 0) ? -q : q
    }

    /// `17,6 %`, `+0,1 %`, `−2,0 %`; a regular space before the percent sign as drawn.
    public static func percentText(tenths: Int, alwaysSign: Bool = false) -> String {
        let magnitude = abs(tenths)
        let sign = tenths < 0 ? "\u{2212}" : (alwaysSign && tenths > 0 ? "+" : "")
        return "\(sign)\(magnitude / 10),\(magnitude % 10) %"
    }
}

public enum DepotQueries {
    /// Region order of the allocation chart and the token of each slice; other regions follow in name order.
    static let regionOrder = ["North America", "Europe", "Emerging markets", "Japan & Pacific"]
    static let regionTokens = ["chart-1", "chart-2", "chart-3", "chart-4", "chart-5"]

    /// `nil` when the ledger has no depot account.
    public static func snapshot(_ db: Database) throws -> DepotSnapshot? {
        let today = try LedgerClock.today(db)
        let accounts = try AccountRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        guard let depot = accounts.first(where: { $0.kind == .depot }) else { return nil }

        let records = try HoldingRecord.live()
            .filter(sql: "account_id = ?", arguments: [depot.id])
            .order(Column("sort_order"), Column("id"))
            .fetchAll(db)

        func marketValue(_ record: HoldingRecord) -> Int {
            (record.quantityMicro * record.price + 500_000) / 1_000_000
        }
        let funds = records.filter { $0.securityId != nil }
        let cashRows = records.filter { $0.securityId == nil }
        let holdings = (funds + cashRows).map { record in
            DepotHolding(
                id: record.id, name: record.name, isin: record.isin, isCash: record.securityId == nil,
                quantityMicro: record.quantityMicro, price: record.price, value: marketValue(record),
                costBasis: record.costBasis)
        }

        let value = try LedgerDefinitions.holdingsValue(db, accountID: depot.id) ?? depot.balance
        let cash = cashRows.map(marketValue).reduce(0, +)

        // Allocation by region: fund value × the fund's regional weights (permille); cash on its own.
        var regionValue: [String: Double] = [:]
        for record in funds {
            guard let securityID = record.securityId,
                  let security = try SecurityRecord.fetchOne(db, key: securityID),
                  let json = security.region,
                  let weights = try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8)) else { continue }
            let fundValue = Double(marketValue(record))
            for (region, permille) in weights {
                regionValue[region, default: 0] += fundValue * Double(permille) / 1000
            }
        }
        let extra = regionValue.keys.filter { !regionOrder.contains($0) }.sorted()
        var regions: [DepotRegion] = []
        for name in regionOrder + extra {
            let cents = Int((regionValue[name] ?? 0).rounded())
            guard cents > 0 else { continue }
            let token = regionTokens[min(regions.count, regionTokens.count - 1)]
            regions.append(DepotRegion(name: name, colorToken: token, value: cents))
        }

        let history = try DepotValueRecord.live()
            .filter(sql: "account_id = ?", arguments: [depot.id])
            .order(Column("date"))
            .fetchAll(db)
            .map { DepotPoint(date: $0.date, value: $0.value) }

        return DepotSnapshot(
            today: today,
            value: value,
            valueYesterday: try LedgerDefinitions.depotValue(db, accountID: depot.id, on: today.adding(days: -1)),
            costBasis: records.map(\.costBasis).reduce(0, +),
            holdings: holdings,
            regions: regions,
            cash: cash,
            history: history,
            savingsPlan: try savingsPlan(db, depotID: depot.id, accounts: accounts))
    }

    private static func savingsPlan(_ db: Database, depotID: String, accounts: [AccountRecord]) throws -> DepotSavingsPlan? {
        guard let plan = try SavingsPlanRecord.live()
            .filter(sql: "account_id = ?", arguments: [depotID]).fetchOne(db) else { return nil }
        let rows = try SavingsPlanItemRecord.live()
            .filter(sql: "plan_id = ?", arguments: [plan.id])
            .order(Column("sort_order"), Column("id"))
            .fetchAll(db)
        var items: [DepotSavingsItem] = []
        for row in rows {
            let security = try SecurityRecord.fetchOne(db, key: row.securityId)
            items.append(DepotSavingsItem(id: row.id, name: security?.name ?? row.securityId, amount: row.amount))
        }
        let source = plan.sourceAccountId.flatMap { id in accounts.first { $0.id == id } }
        return DepotSavingsPlan(
            amount: plan.amount, dayOfMonth: plan.dayOfMonth, nextExecution: plan.nextExecution,
            sourceAccount: source.map { "\($0.name), \($0.bankName)" } ?? "", items: items)
    }

    /// Re-emits whenever one of the tables behind the snapshot changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<DepotSnapshot?> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }
}
