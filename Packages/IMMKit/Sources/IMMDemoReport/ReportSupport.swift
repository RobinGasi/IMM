import Foundation
import GRDB
import IMMLedger

/// JSON-compatible dictionary: strings, `Int`, `Bool`, arrays and nested dictionaries.
typealias JSON = [String: Any]

enum ReportError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let what): return "ledger has no \(what)"
        }
    }
}

/// Formatting shared by every screen. All money comes from `MoneyFormatter`.
enum Fmt {
    /// `−1.912,40 €`
    static func money(_ v: Int) -> String { MoneyFormatter.string(v) }
    /// `+1.204,18 €`
    static func signed(_ v: Int) -> String { MoneyFormatter.string(v, sign: .always) }
    /// `−1.526,43` (no currency sign, as drawn in the transaction list headers).
    static func plain(_ v: Int) -> String { MoneyFormatter.string(v, symbol: false) }

    /// Integer division rounding half away from zero.
    static func roundDiv(_ a: Int, _ b: Int) -> Int {
        guard b != 0 else { return 0 }
        let q = (abs(a) * 2 + abs(b)) / (2 * abs(b))
        return (a < 0) != (b < 0) ? -q : q
    }

    /// `77 %` (decimals 0) or `17,6 %` (decimals 1) for `num / den`.
    static func percent(_ num: Int, _ den: Int, decimals: Int = 0, alwaysSign: Bool = false) -> String {
        guard den != 0 else { return "0 %" }
        let value = roundDiv(num * (decimals == 0 ? 100 : 1000), den)
        let magnitude = abs(value)
        let body = decimals == 0 ? String(magnitude) : "\(magnitude / 10),\(magnitude % 10)"
        let sign = value < 0 ? "\u{2212}" : (alwaysSign && value > 0 ? "+" : "")
        return sign + body + " %"
    }

    /// `1st`, `2nd`, `3rd`, `15th`
    static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + String(text.dropFirst())
    }

    static func date(_ d: LocalDate?) -> String {
        guard let d else { return "\u{2014}" }
        return DateFormats.dayMonthYear(d)
    }
}

/// Everything a section needs: the open read transaction, the ledger's "today" and the master data.
struct ReportContext {
    let db: Database
    let today: LocalDate
    let categories: [CategoryRecord]
    let categoryName: [String: String]
    let accounts: [AccountRecord]

    init(db: Database) throws {
        self.db = db
        self.today = try LedgerClock.today(db)
        self.categories = try CategoryRecord.live().order(sql: "sort_order").fetchAll(db)
        var names: [String: String] = [:]
        for category in categories { names[category.id] = category.name }
        self.categoryName = names
        self.accounts = try AccountRecord.live().order(sql: "sort_order").fetchAll(db)
    }

    var expenseCategories: [CategoryRecord] { categories.filter { $0.kind == .expense } }

    func account(_ kind: AccountKind) throws -> AccountRecord {
        guard let account = accounts.first(where: { $0.kind == kind }) else { throw ReportError.missing("\(kind.rawValue) account") }
        return account
    }

    var giro: AccountRecord {
        get throws { try account(.giro) }
    }

    /// First of this month.
    var monthStart: LocalDate { today.firstOfMonth }

    func lastDay(ofMonthStarting start: LocalDate) -> LocalDate { start.adding(months: 1).adding(days: -1) }

    /// Value of an account as every screen shows it: depots from their holdings.
    func value(of account: AccountRecord) throws -> Int {
        if account.kind == .depot, let holdings = try LedgerDefinitions.holdingsValue(db, accountID: account.id) {
            return holdings
        }
        return account.balance
    }

    func scalar(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    /// Sum of transaction amounts in a date range, optionally for one account.
    func sum(account: String? = nil, from: LocalDate, through: LocalDate) throws -> Int {
        if let account {
            return try scalar(
                "SELECT COALESCE(SUM(amount), 0) FROM ledger_transaction WHERE deleted_at IS NULL AND account_id = ? AND booking_date BETWEEN ? AND ?",
                [account, from.iso, through.iso])
        }
        return try scalar(
            "SELECT COALESCE(SUM(amount), 0) FROM ledger_transaction WHERE deleted_at IS NULL AND booking_date BETWEEN ? AND ?",
            [from.iso, through.iso])
    }

    /// Number of transactions in a date range, optionally for one account.
    func count(account: String? = nil, from: LocalDate, through: LocalDate) throws -> Int {
        if let account {
            return try scalar(
                "SELECT COUNT(*) FROM ledger_transaction WHERE deleted_at IS NULL AND account_id = ? AND booking_date BETWEEN ? AND ?",
                [account, from.iso, through.iso])
        }
        return try scalar(
            "SELECT COUNT(*) FROM ledger_transaction WHERE deleted_at IS NULL AND booking_date BETWEEN ? AND ?",
            [from.iso, through.iso])
    }

    /// The transaction with the given bank reference (first match across accounts).
    func transaction(reference: String) throws -> TransactionRecord? {
        try TransactionRecord.fetchOne(
            db, sql: "SELECT * FROM ledger_transaction WHERE bank_ref = ? AND deleted_at IS NULL", arguments: [reference])
    }

    func accountName(_ id: String) -> String {
        accounts.first(where: { $0.id == id })?.name ?? id
    }

    func categoryLabel(_ id: String?) -> String {
        guard let id, let name = categoryName[id] else { return "Without category" }
        return name
    }

    func insights(_ kind: InsightKind) throws -> [InsightRecord] {
        try InsightRecord.live().filter(sql: "kind = ?", arguments: [kind.rawValue]).order(sql: "sort_order").fetchAll(db)
    }

    /// Three-letter month label (`Dec`).
    func shortMonth(_ d: LocalDate) -> String { String(DateFormats.monthName(d).prefix(3)) }

    /// Month-by-month spending per category for the 12 months ending with the current one.
    /// Index 0 = twelve months ago … index 11 = current (partial) month.
    func monthlySpending() throws -> [(start: LocalDate, end: LocalDate, byCategory: [String: Int])] {
        var result: [(start: LocalDate, end: LocalDate, byCategory: [String: Int])] = []
        for offset in -11...0 {
            let start = monthStart.adding(months: offset)
            let end = offset == 0 ? today : lastDay(ofMonthStarting: start)
            result.append((start, end, try LedgerDefinitions.spending(db, from: start, through: end)))
        }
        return result
    }
}

/// An item that will leave or arrive on the Girokonto.
struct Upcoming {
    var date: LocalDate
    var label: String
    var amount: Int

    var json: JSON {
        ["date": DateFormats.dayMonth(date), "isoDate": date.iso, "label": label, "amount": Fmt.money(amount), "cents": amount]
    }
}
