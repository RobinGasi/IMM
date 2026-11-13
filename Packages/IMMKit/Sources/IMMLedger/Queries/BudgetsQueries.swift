import Foundation
import GRDB

// Everything the Budgets screen shows, computed from the ledger in one read.
// Spending follows `LedgerDefinitions.spending`; "today" is `LedgerClock`.

/// One budget: a category's spending in the running month against its monthly limit.
public struct BudgetRow: Hashable, Sendable, Identifiable {
    public var id: String
    public var categoryName: String
    /// Design token name (`chart-5`).
    public var colorToken: String
    /// Positive minor units spent from the first of the month through today.
    public var spent: Int
    /// Positive minor units.
    public var limit: Int

    /// Limit minus spending; negative when the budget is over.
    public var remaining: Int { limit - spent }
    public var isOver: Bool { spent > limit }
    /// Spending as a share of the limit, not clamped (0 for a zero limit).
    public var fraction: Double { limit > 0 ? Double(spent) / Double(limit) : 0 }
}

/// One part of a grouped fixed cost.
public struct FixedCostMember: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// Positive minor units per month.
    public var amount: Int
}

/// A monthly cost that leaves by standing order or direct debit and stays outside the budgets.
public struct FixedCostRow: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var colorToken: String
    /// Positive minor units per month.
    public var amount: Int
    /// The parts of a group (contracts and insurance); empty for a single contract.
    public var members: [FixedCostMember]
}

public struct BudgetsSnapshot: Hashable, Sendable {
    public var today: LocalDate
    /// Budgets in category order.
    public var rows: [BudgetRow]
    public var totalSpent: Int
    public var totalLimit: Int
    public var overCount: Int
    public var fixedCosts: [FixedCostRow]
    public var fixedCostsTotal: Int
    /// The `rollover_enabled` setting; unset means on, as designed.
    public var rolloverEnabled: Bool

    /// Limits minus spending of all budgets.
    public var leftToSpend: Int { totalLimit - totalSpent }
    public var totalFraction: Double { totalLimit > 0 ? Double(totalSpent) / Double(totalLimit) : 0 }
    public var dayOfMonth: Int { today.day }
    public var daysInMonth: Int { today.daysInMonth }
    public var daysLeft: Int { today.daysInMonth - today.day }
    /// Share of the month that has passed: where the pace marker stands.
    public var paceFraction: Double { Double(today.day) / Double(today.daysInMonth) }
    /// Last day of the running month, when unused amounts roll over.
    public var monthEnd: LocalDate { today.firstOfMonth.adding(months: 1).adding(days: -1) }
    public var nextMonth: LocalDate { today.firstOfMonth.adding(months: 1) }
}

public enum BudgetsQueries {
    public static func snapshot(_ db: Database) throws -> BudgetsSnapshot {
        let today = try LedgerClock.today(db)
        let spending = try LedgerDefinitions.spending(db, from: today.firstOfMonth, through: today)
        let categories = try CategoryRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        let budgets = try BudgetRecord.live().fetchAll(db)

        var rows: [BudgetRow] = []
        for category in categories {
            guard let budget = budgets.first(where: { $0.categoryId == category.id }) else { continue }
            rows.append(BudgetRow(
                id: budget.id, categoryName: category.name, colorToken: category.colorToken,
                spent: spending[category.id] ?? 0, limit: budget.monthlyLimit))
        }

        let fixed = try fixedCosts(db, categories: categories, budgeted: Set(budgets.map(\.categoryId)))
        let rollover = try LedgerStore.setting(.rolloverEnabled, in: db)

        return BudgetsSnapshot(
            today: today,
            rows: rows,
            totalSpent: rows.reduce(0) { $0 + $1.spent },
            totalLimit: rows.reduce(0) { $0 + $1.limit },
            overCount: rows.filter(\.isOver).count,
            fixedCosts: fixed,
            fixedCostsTotal: fixed.reduce(0) { $0 + $1.amount },
            rolloverEnabled: rollover.map { $0 == "1" || $0.lowercased() == "true" } ?? true)
    }

    /// Re-emits whenever one of the tables behind the snapshot changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<BudgetsSnapshot> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }

    // MARK: Fixed costs

    /// Contracts whose category has no budget. Housing contracts (rent, electricity) are listed one
    /// by one; everything else is summed into one "Contracts & insurance" row that keeps its parts.
    private static func fixedCosts(
        _ db: Database, categories: [CategoryRecord], budgeted: Set<String>
    ) throws -> [FixedCostRow] {
        let contracts = try ContractRecord.live()
            .filter(sql: "kind = ?", arguments: [ContractKind.contract.rawValue])
            .order(Column("sort_order"), Column("provider"))
            .fetchAll(db)

        var rows: [FixedCostRow] = []
        var group: [ContractRecord] = []
        var groupColor = "chart-4"
        for contract in contracts {
            guard let categoryID = contract.categoryId, !budgeted.contains(categoryID),
                  let category = categories.first(where: { $0.id == categoryID }) else { continue }
            if category.name == "Housing" {
                rows.append(FixedCostRow(
                    id: contract.id, label: label(forProvider: contract.provider), colorToken: category.colorToken,
                    amount: -contract.monthlyAmount, members: []))
            } else {
                if group.isEmpty { groupColor = category.colorToken }
                group.append(contract)
            }
        }
        if !group.isEmpty {
            rows.append(FixedCostRow(
                id: "contracts-and-insurance", label: "Contracts & insurance", colorToken: groupColor,
                amount: group.reduce(0) { $0 - $1.monthlyAmount },
                members: group.map { FixedCostMember(id: $0.id, label: $0.provider, amount: -$0.monthlyAmount) }))
        }
        return rows
    }

    /// The short fixed-cost label of a housing contract: `Miete Wohnbau Ehrenfeld eG` reads
    /// `Rent, Wohnbau Ehrenfeld`, `Stadtwerke Köln Strom` reads `Electricity, Stadtwerke Köln`.
    public static func label(forProvider provider: String) -> String {
        if provider.hasPrefix("Miete ") {
            var landlord = String(provider.dropFirst("Miete ".count))
            if landlord.hasSuffix(" eG") { landlord = String(landlord.dropLast(" eG".count)) }
            return "Rent, " + landlord
        }
        if provider.hasSuffix(" Strom") {
            return "Electricity, " + provider.dropLast(" Strom".count)
        }
        return provider
    }
}
