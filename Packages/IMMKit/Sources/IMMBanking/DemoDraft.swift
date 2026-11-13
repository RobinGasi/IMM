import Foundation
import IMMLedger

/// A transaction before references and sequence numbers are assigned.
struct Draft {
    var account: String
    var date: LocalDate
    var time: String?
    /// Position among rows of the same day without a time (smaller = earlier).
    var order: Int
    var amount: Int
    var name: String
    var short: String
    var iban: String?
    var bookingText: String
    var purpose: String
    var creditorID: String?
    var kind: BankTransactionKind
    var category: String?
    var ownTransfer: Bool

    static func make(_ merchant: Merchant, date: LocalDate, time: String?, amount: Int, purpose: String, order: Int = 50) -> Draft {
        Draft(account: merchant.account, date: date, time: time, order: order, amount: amount, name: merchant.name,
              short: merchant.short, iban: merchant.iban, bookingText: merchant.bookingText, purpose: purpose,
              creditorID: merchant.creditorID, kind: merchant.kind, category: merchant.category, ownTransfer: false)
    }

    /// Sort key inside an account: date, time of day, explicit order, then text for a total order.
    func sorts(before other: Draft) -> Bool {
        if date != other.date { return date < other.date }
        let a = time ?? "00:00"
        let b = other.time ?? "00:00"
        if a != b { return a < b }
        if order != other.order { return order < other.order }
        if amount != other.amount { return amount < other.amount }
        return purpose < other.purpose
    }
}

enum DemoText {
    static func two(_ n: Int) -> String { n < 10 ? "0" + String(n) : String(n) }

    static func hhmm(_ rng: inout SplitMix64) -> String {
        two(rng.int(8...21)) + ":" + two(rng.int(0...59))
    }

    /// `12.11.` style helper used in purposes: month and year of a date as `11/2026`.
    static func monthSlash(_ date: LocalDate) -> String { two(date.month) + "/" + String(date.year) }

    static func fill(_ template: String, rng: inout SplitMix64) -> String {
        template.replacingOccurrences(of: "{id}", with: rng.orderCode())
    }

    /// Splits `total` into `count` positive parts (each at least 1,50 €), summing exactly to `total`.
    static func split(total: Int, count: Int, rng: inout SplitMix64) -> [Int] {
        guard count > 0, total > 0 else { return [] }
        let n = max(1, min(count, total / 250))
        var weights: [Int] = []
        for _ in 0..<n { weights.append(rng.int(40...160)) }
        let sum = weights.reduce(0, +)
        var parts: [Int] = []
        var used = 0
        for index in 0..<(n - 1) {
            let part = max(150, total * weights[index] / sum)
            parts.append(part)
            used += part
        }
        var last = total - used
        if last < 150 {
            let deficit = 150 - last
            var biggest = 0
            for index in 0..<parts.count where parts[index] > parts[biggest] { biggest = index }
            if !parts.isEmpty {
                parts[biggest] -= deficit
                last = 150
            }
        }
        parts.append(last)
        return parts
    }

    static func pick(_ merchants: [Merchant], rng: inout SplitMix64) -> Merchant {
        let total = merchants.reduce(0) { $0 + $1.weight }
        var r = rng.int(0...(total - 1))
        for merchant in merchants {
            if r < merchant.weight { return merchant }
            r -= merchant.weight
        }
        return merchants[merchants.count - 1]
    }
}
