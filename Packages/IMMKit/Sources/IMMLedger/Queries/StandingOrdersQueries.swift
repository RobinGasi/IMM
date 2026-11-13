import Foundation
import GRDB

// Everything the Standing orders screen shows, computed from the ledger in one read.
// "Today" is `LedgerClock`; the timeline covers the next 30 days of the first Girokonto.

/// One standing order or scheduled payment.
public struct StandingOrderItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var recipient: String
    public var iban: String
    public var purpose: String
    public var rhythm: StandingOrderRhythm
    public var dayOfMonth: Int?
    /// Next execution; nil while the order is paused.
    public var nextExecution: LocalDate?
    /// Signed minor units (negative).
    public var amount: Int
    public var status: StandingOrderStatus
}

/// The orders of one account with their monthly total.
public struct StandingOrderSection: Hashable, Sendable, Identifiable {
    public var accountID: String
    public var accountName: String
    public var orders: [StandingOrderItem]
    public var id: String { accountID }

    /// Active monthly orders only: one-off, scheduled and paused orders are not included.
    public var activeCount: Int { orders.lazy.filter { $0.status == .active }.count }
    public var monthlyTotal: Int {
        orders.lazy.filter { $0.status == .active && $0.rhythm == .monthly }.map(\.amount).reduce(0, +)
    }
}

/// All money leaving on one day of the timeline.
public struct StandingOrderTimelineDay: Hashable, Sendable, Identifiable {
    public var date: LocalDate
    /// Signed minor units (negative).
    public var amount: Int
    /// Recipients and providers, in the order they were found.
    public var items: [String]
    public var id: LocalDate { date }
}

/// The next salary within the timeline.
public struct StandingOrderSalary: Hashable, Sendable {
    public var date: LocalDate
    public var amount: Int
    public var label: String
}

public struct StandingOrdersSnapshot: Hashable, Sendable {
    public var today: LocalDate
    /// Bank of the first Girokonto (`Sparkasse KölnBonn`), used in the toolbar subtitle.
    public var bankName: String
    /// Name of the first Girokonto: the account the timeline and the New standing order button belong to.
    public var primaryAccountName: String
    /// One section per account that has orders; the primary account's section is always first and present.
    public var sections: [StandingOrderSection]
    /// Last day of the timeline: `today` + 30 days.
    public var horizon: LocalDate
    /// Everything leaving the primary account until `horizon`, signed minor units.
    public var leaving: Int
    public var timeline: [StandingOrderTimelineDay]
    public var salary: StandingOrderSalary?

    public var orderCount: Int { sections.reduce(0) { $0 + $1.orders.count } }

    public static let empty = StandingOrdersSnapshot(
        today: LocalDate(Date()), bankName: "", primaryAccountName: "", sections: [],
        horizon: LocalDate(Date()).adding(days: 30), leaving: 0, timeline: [], salary: nil)
}

public enum StandingOrdersQueries {
    /// Length of the timeline in days.
    public static let timelineDays = 30

    public static func snapshot(_ db: Database) throws -> StandingOrdersSnapshot {
        let today = try LedgerClock.today(db)
        let horizon = today.adding(days: timelineDays)
        let accounts = try AccountRecord.live().order(Column("sort_order"), Column("name")).fetchAll(db)
        let primary = accounts.first { $0.kind == .giro } ?? accounts.first
        let orders = try StandingOrderRecord.live()
            .order(sql: "next_execution IS NULL, next_execution, amount, recipient")
            .fetchAll(db)

        var sections: [StandingOrderSection] = []
        var accountsWithOrders = Set(orders.map(\.accountId))
        if let primary { accountsWithOrders.insert(primary.id) }
        for account in accounts where account.id == primary?.id || accountsWithOrders.contains(account.id) {
            let items = orders.filter { $0.accountId == account.id }.map { order in
                StandingOrderItem(
                    id: order.id, recipient: order.recipient, iban: order.iban, purpose: order.purpose ?? "",
                    rhythm: order.rhythm, dayOfMonth: order.dayOfMonth, nextExecution: order.nextExecution,
                    amount: order.amount, status: order.status)
            }
            sections.append(StandingOrderSection(accountID: account.id, accountName: account.name, orders: items))
        }
        // The primary account leads, the rest keeps ledger order.
        if let primary, let index = sections.firstIndex(where: { $0.accountID == primary.id }), index != 0 {
            sections.insert(sections.remove(at: index), at: 0)
        }

        var leaving: [(date: LocalDate, label: String, amount: Int)] = []
        var salary: StandingOrderSalary?
        if let primary {
            // Standing orders that run, plus contract debits; a contract a standing order already pays
            // (same day, same amount) is not counted twice.
            for order in orders where order.accountId == primary.id && order.status != .paused {
                guard let next = order.nextExecution, next > today, next <= horizon else { continue }
                leaving.append((next, order.recipient, order.amount))
            }
            let contracts = try ContractRecord.live()
                .filter(Column("account_id") == primary.id)
                .order(Column("sort_order"))
                .fetchAll(db)
            for contract in contracts {
                guard let next = contract.nextDebit, next > today, next <= horizon else { continue }
                switch contract.kind {
                case .income:
                    if salary == nil || next < salary!.date {
                        salary = StandingOrderSalary(date: next, amount: contract.monthlyAmount, label: contract.provider)
                    }
                case .contract:
                    if !leaving.contains(where: { $0.date == next && $0.amount == contract.monthlyAmount }) {
                        leaving.append((next, contract.provider, contract.monthlyAmount))
                    }
                }
            }
        }

        var days: [StandingOrderTimelineDay] = []
        for item in leaving.sorted(by: { $0.date < $1.date }) {
            if let index = days.firstIndex(where: { $0.date == item.date }) {
                days[index].amount += item.amount
                days[index].items.append(item.label)
            } else {
                days.append(StandingOrderTimelineDay(date: item.date, amount: item.amount, items: [item.label]))
            }
        }

        return StandingOrdersSnapshot(
            today: today, bankName: primary?.bankName ?? "", primaryAccountName: primary?.name ?? "",
            sections: sections, horizon: horizon, leaving: days.reduce(0) { $0 + $1.amount },
            timeline: days, salary: salary)
    }

    /// Re-emits whenever one of the tables behind the snapshot changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<StandingOrdersSnapshot> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }
}
