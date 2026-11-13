import Foundation
import IMMLedger
@testable import IMMBanking

/// The data set every test below inspects; built once.
let demoBank: DemoBank = DemoDataset.build()

func day(_ year: Int, _ month: Int, _ day: Int) -> LocalDate { LocalDate(year: year, month: month, day: day) }

/// Ledger definitions on DTOs (the same ones the ledger queries implement in SQL).
struct DemoView {
    let bank: DemoBank
    var snapshot: BankSnapshot { bank.snapshot }
    var profile: DemoProfile { bank.profile }

    func account(_ id: String) -> BankAccount { snapshot.accounts.first { $0.id == id }! }

    func transactions(_ accountID: String) -> [BankTransaction] {
        snapshot.transactions.filter { $0.accountID == accountID }
            .sorted { ($0.bookingDate, $0.sequence) < ($1.bookingDate, $1.sequence) }
    }

    func category(_ t: BankTransaction) -> String? { profile.categoryByReference[t.reference] }

    func isOwnTransfer(_ t: BankTransaction) -> Bool { profile.ownTransferReferences.contains(t.reference) }

    /// Rows in booking order with the balance after each row.
    func running(_ accountID: String) -> [(row: BankTransaction, balance: Int)] {
        var after = account(accountID).balance
        var out: [(BankTransaction, Int)] = []
        for t in transactions(accountID).reversed() {
            out.append((t, after))
            after -= t.amount
        }
        return out.reversed().map { (row: $0.0, balance: $0.1) }
    }

    /// Spending = categorised expense transactions on all accounts, own transfers excluded.
    func isSpending(_ t: BankTransaction) -> Bool {
        guard !isOwnTransfer(t), let name = category(t),
              let c = profile.categories.first(where: { $0.name == name }) else { return false }
        return c.kind == .expense
    }

    func spending(from: LocalDate, to: LocalDate, category name: String? = nil) -> Int {
        snapshot.transactions.filter { isSpending($0) && $0.bookingDate >= from && $0.bookingDate <= to
            && (name == nil || category($0) == name) }
            .reduce(0) { $0 - $1.amount }
    }

    func monthSpending(_ year: Int, _ month: Int) -> Int {
        spending(from: day(year, month, 1), to: day(year, month, 31))
    }

    /// Sum of the account balances; the depot contributes its total value.
    var netWorth: Int { snapshot.accounts.reduce(0) { $0 + $1.balance } }

    func balance(_ accountID: String, on date: LocalDate) -> Int {
        let later = transactions(accountID).filter { $0.bookingDate > date }.reduce(0) { $0 + $1.amount }
        return account(accountID).balance - later
    }

    func netWorth(on date: LocalDate) -> Int {
        var total = 0
        for a in snapshot.accounts {
            if a.kind == .depot {
                total += snapshot.depotValueHistory.first { $0.date == date }?.value ?? 0
            } else {
                total += balance(a.id, on: date)
            }
        }
        return total
    }
}

let view = DemoView(bank: demoBank)
