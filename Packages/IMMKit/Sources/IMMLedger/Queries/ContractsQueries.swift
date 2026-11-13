import Foundation
import GRDB

// Everything the Contracts screen shows, computed from the ledger in one read.

public struct ContractItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var provider: String
    public var accountID: String?
    /// `Girokonto`, `PayPal Wallet`.
    public var accountName: String
    public var rhythm: ContractRhythm
    public var nextDebit: LocalDate?
    /// Notice period as shown (`3 months`, `Statutory, no notice`); empty when unknown.
    public var noticeText: String
    public var noticeDeadline: LocalDate?
    /// Signed minor units per month (negative).
    public var monthlyAmount: Int
    /// New monthly amount (positive) and its start when the provider announced a price change.
    public var priceChange: ContractPriceChange?
}

public struct ContractPriceChange: Hashable, Sendable {
    /// New monthly cost, positive minor units.
    public var newAmount: Int
    public var start: LocalDate
}

public struct ContractGroup: Hashable, Sendable, Identifiable {
    public var name: String
    public var contracts: [ContractItem]
    public var id: String { name }
    /// Signed minor units.
    public var subtotal: Int { contracts.reduce(0) { $0 + $1.monthlyAmount } }
}

/// A price change banner row: the monthly difference is `newAmount - oldAmount` (positive minor units).
public struct ContractPriceNotice: Hashable, Sendable, Identifiable {
    public var provider: String
    public var accountID: String?
    /// Name of the paying account (`PayPal Wallet`, `Girokonto`).
    public var paidFrom: String
    public var oldAmount: Int
    public var newAmount: Int
    public var start: LocalDate
    public var id: String { provider }
}

/// A notice deadline banner row.
public struct ContractDeadlineNotice: Hashable, Sendable, Identifiable {
    public var provider: String
    public var groupName: String
    public var deadline: LocalDate
    public var daysLeft: Int
    public var renewalDate: LocalDate?
    /// Cost of the renewed term, positive minor units.
    public var renewalAmount: Int
    public var id: String { provider }
}

public struct ContractsSnapshot: Hashable, Sendable {
    public var today: LocalDate
    public var groups: [ContractGroup]
    public var count: Int
    /// Sum of all monthly amounts, signed minor units.
    public var monthlyTotal: Int
    /// Net salary per month (recurring income), positive minor units; 0 when there is none.
    public var salary: Int
    public var priceNotices: [ContractPriceNotice]
    public var deadlineNotices: [ContractDeadlineNotice]

    /// Positive minor units.
    public var yearlyTotal: Int { -monthlyTotal * 12 }
    /// Share of the net salary the fixed costs take, whole percent; nil without a salary.
    public var salaryShare: Int? {
        salary > 0 ? Int((Double(-monthlyTotal) * 100 / Double(salary)).rounded()) : nil
    }

    public static let empty = ContractsSnapshot(
        today: LocalDate(Date()), groups: [], count: 0, monthlyTotal: 0, salary: 0, priceNotices: [], deadlineNotices: [])
}

public enum ContractsQueries {
    /// How the screen names the paying account: wallets carry their provider (`PayPal Wallet`).
    static func displayName(_ account: AccountRecord) -> String {
        account.kind == .wallet ? "\(account.bankName) \(account.name)" : account.name
    }

    public static func snapshot(_ db: Database) throws -> ContractsSnapshot {
        let today = try LedgerClock.today(db)
        let accounts = try AccountRecord.live().fetchAll(db)
        let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let all = try ContractRecord.live().order(Column("sort_order")).fetchAll(db)
        let costs = all.filter { $0.kind == .contract }
        let salary = all.first { $0.kind == .income }?.monthlyAmount ?? 0

        var groups: [ContractGroup] = []
        for contract in costs {
            let item = ContractItem(
                id: contract.id, provider: contract.provider, accountID: contract.accountId,
                accountName: contract.accountId.flatMap { names[$0] }.map(displayName) ?? "", rhythm: contract.rhythm,
                nextDebit: contract.nextDebit, noticeText: contract.noticeText ?? "",
                noticeDeadline: contract.noticeDeadline, monthlyAmount: contract.monthlyAmount,
                priceChange: {
                    guard let amount = contract.priceChangeAmount, let start = contract.priceChangeStart else { return nil }
                    return ContractPriceChange(newAmount: abs(amount), start: start)
                }())
            if let index = groups.firstIndex(where: { $0.name == contract.groupName }) {
                groups[index].contracts.append(item)
            } else {
                groups.append(ContractGroup(name: contract.groupName, contracts: [item]))
            }
        }

        let priceNotices = costs.compactMap { contract -> ContractPriceNotice? in
            guard let changed = contract.priceChangeAmount, let start = contract.priceChangeStart else { return nil }
            let paidFrom = contract.accountId.flatMap { names[$0] }.map(displayName) ?? ""
            return ContractPriceNotice(
                provider: contract.provider, accountID: contract.accountId, paidFrom: paidFrom,
                oldAmount: abs(contract.monthlyAmount), newAmount: abs(changed), start: start)
        }
        // Without a stored renewal amount the renewed term is one year at the current monthly price.
        let deadlineNotices = costs.compactMap { contract -> ContractDeadlineNotice? in
            guard let deadline = contract.noticeDeadline, deadline >= today else { return nil }
            return ContractDeadlineNotice(
                provider: contract.provider, groupName: contract.groupName, deadline: deadline,
                daysLeft: deadline - today, renewalDate: contract.renewalDate,
                renewalAmount: contract.renewalAmount.map(abs) ?? abs(contract.monthlyAmount) * 12)
        }

        return ContractsSnapshot(
            today: today, groups: groups, count: costs.count, monthlyTotal: costs.reduce(0) { $0 + $1.monthlyAmount },
            salary: salary, priceNotices: priceNotices, deadlineNotices: deadlineNotices)
    }

    /// Re-emits whenever one of the tables behind the snapshot changes.
    public static func observe(in store: LedgerStore) -> AsyncValueObservation<ContractsSnapshot> {
        ValueObservation.tracking { try snapshot($0) }.values(in: store.database)
    }
}
