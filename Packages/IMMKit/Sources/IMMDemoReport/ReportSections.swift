import Foundation
import GRDB
import IMMBanking
import IMMLedger

/// Computes every figure the screens show from the ledger, never from the data-set DTOs. Money values
/// are strings from `MoneyFormatter` (`…Cents` siblings carry raw minor units where a chart needs them),
/// counts are numbers. Keys are `<screen>.<figure>`.
enum ReportBuilder {
    static func build(_ db: Database) throws -> JSON {
        let c = try ReportContext(db: db)
        var out: JSON = [:]
        out["ledger.today"] = c.today.iso
        try sidebar(c, &out)
        try overview(c, &out)
        try transactions(c, &out)
        try categories(c, &out)
        try budgets(c, &out)
        try standingOrders(c, &out)
        try contracts(c, &out)
        try depot(c, &out)
        try suggestions(c, &out)
        try review(c, &out)
        try tax(c, &out)
        try ask(c, &out)
        try syncFailed(c, &out)
        try onboarding(c, &out)
        return out
    }

    // MARK: Sidebar

    static func sidebar(_ c: ReportContext, _ out: inout JSON) throws {
        out["sidebar.newCount"] = try LedgerDefinitions.newCount(c.db)
        out["sidebar.uncategorisedCount"] = try LedgerDefinitions.uncategorisedCount(c.db)
        out["sidebar.suggestionsBadge"] = try c.insights(.suggestion).count
        out["sidebar.netWorth"] = Fmt.money(try LedgerDefinitions.netWorth(c.db))
        out["sidebar.accountCount"] = c.accounts.count
        out["sidebar.accountsSynced"] = try c.scalar("SELECT COUNT(*) FROM account WHERE deleted_at IS NULL AND last_synced_at IS NOT NULL")
        for account in c.accounts {
            out["sidebar.account.\(account.name)"] = Fmt.money(try c.value(of: account))
        }
    }

    // MARK: Overview

    static func overview(_ c: ReportContext, _ out: inout JSON) throws {
        let netWorth = try LedgerDefinitions.netWorth(c.db)
        let october31 = c.monthStart.adding(days: -1)
        let netWorthOctober = try LedgerDefinitions.netWorth(c.db, on: october31)
        out["overview.netWorth"] = Fmt.money(netWorth)
        out["overview.accountCount"] = c.accounts.count
        out["overview.netWorthOctober31"] = Fmt.money(netWorthOctober)
        out["overview.changeSinceOctober"] = Fmt.signed(netWorth - netWorthOctober)

        // Net-worth chart: month ends of the 12 months up to the current one (soft chart).
        var series: [JSON] = []
        for offset in -11...0 {
            let start = c.monthStart.adding(months: offset)
            let end = offset == 0 ? c.today : c.lastDay(ofMonthStarting: start)
            let cents = offset == 0 ? netWorth : try LedgerDefinitions.netWorth(c.db, on: end)
            series.append(["label": c.shortMonth(start), "date": end.iso, "value": Fmt.money(cents), "cents": cents])
        }
        out["overview.netWorthSeries"] = series

        // Accounts card.
        for account in c.accounts {
            out["overview.account.\(account.name)"] = Fmt.money(try c.value(of: account))
        }

        // Spent this month.
        let spending = try LedgerDefinitions.spending(c.db, from: c.monthStart, through: c.today)
        let total = spending.values.reduce(0, +)
        out["overview.spentRange"] = "1.\u{2013}" + DateFormats.dayMonth(c.today)
        for category in c.expenseCategories {
            out["overview.spentByCategory.\(category.name)"] = Fmt.money(-(spending[category.id] ?? 0))
        }
        out["overview.spentSoFar"] = Fmt.money(-total)
        let average = try LedgerDefinitions.monthlyAverageSpending(c.db, today: c.today)
        out["overview.monthlyAverage"] = Fmt.money(average)
        out["overview.averageShare"] = Fmt.percent(total, average)
        out["overview.daysToGo"] = c.today.daysInMonth - c.today.day

        // Coming up and projection.
        let giro = try c.giro
        let upcoming = try comingUp(c)
        out["overview.comingUp"] = upcoming.map(\.json)
        out["overview.comingUp.count"] = upcoming.count
        out["overview.comingUp.until"] = DateFormats.dayMonth(c.today.adding(months: 1).firstOfMonth)
        out["overview.projection"] = Fmt.money(giro.balance + upcoming.map(\.amount).reduce(0, +))
        out["overview.projectionDate"] = DateFormats.dayMonth(c.today.adding(months: 1).firstOfMonth)

        // Needs attention.
        var attention: [JSON] = []
        let uncategorised = try LedgerDefinitions.uncategorisedCount(c.db)
        if uncategorised > 0 {
            attention.append(["kind": "uncategorised", "title": "\(uncategorised) transactions without category", "target": "suggestions"])
        }
        let contracts = try ContractRecord.live().order(sql: "sort_order").fetchAll(c.db)
        for contract in contracts {
            if let changed = contract.priceChangeAmount, let start = contract.priceChangeStart, start > c.today {
                attention.append([
                    "kind": "priceChange",
                    "title": "\(contract.provider) raises its price",
                    "detail": "\(Fmt.money(abs(contract.monthlyAmount))) \u{2192} \(Fmt.money(abs(changed))) from \(DateFormats.monthName(start))",
                    "target": "contracts",
                ])
            }
        }
        for contract in contracts {
            if let deadline = contract.noticeDeadline, deadline >= c.today, deadline - c.today <= 30 {
                attention.append([
                    "kind": "noticeDeadline",
                    "title": "\(contract.provider) notice deadline",
                    "detail": DateFormats.dayMonth(deadline),
                    "daysLeft": deadline - c.today,
                    "target": "contracts",
                ])
            }
        }
        out["overview.attention"] = attention
        out["overview.attention.count"] = attention.count
        var stored: [JSON] = []
        for insight in try c.insights(.attention) {
            let payload = try JSONDecoder().decode(AttentionPayload.self, from: Data(insight.payload.utf8))
            stored.append(["title": payload.title, "detail": payload.detail, "actionTitle": payload.actionTitle ?? "", "target": payload.target])
        }
        out["overview.attention.stored"] = stored
    }

    /// Girokonto items "coming up" until the first of next month.
    ///
    /// Rule (fitted to the design's six rows; the standing-orders timeline uses the wider rule):
    /// - standing orders from the Girokonto that are active, monthly, at least 100,00 € and not a
    ///   transfer to one of the user's own non-depot accounts, due after today up to and including the horizon;
    /// - contract debits from the Girokonto due after today and strictly before the horizon day;
    /// - recurring income due after today up to and including the horizon;
    /// - the credit card statement (account with a statement note) when its date falls in the window.
    /// Sorted by date, larger amounts first.
    static func comingUp(_ c: ReportContext) throws -> [Upcoming] {
        let giro = try c.giro
        let horizon = c.today.adding(months: 1).firstOfMonth
        let others = c.accounts.filter { $0.id != giro.id && $0.kind != .depot }
        var items: [Upcoming] = []

        let orders = try StandingOrderRecord.live().filter(sql: "account_id = ?", arguments: [giro.id]).fetchAll(c.db)
        for order in orders {
            guard order.status == .active, order.rhythm == .monthly, order.amount <= -10_000,
                  let next = order.nextExecution, next > c.today, next <= horizon,
                  !isOwnTransfer(order, others: others) else { continue }
            items.append(Upcoming(date: next, label: order.recipient, amount: order.amount))
        }

        let contracts = try ContractRecord.live().filter(sql: "account_id = ?", arguments: [giro.id]).fetchAll(c.db)
        for contract in contracts {
            guard let next = contract.nextDebit, next > c.today else { continue }
            switch contract.kind {
            case .contract:
                if next < horizon { items.append(Upcoming(date: next, label: contract.provider, amount: contract.monthlyAmount)) }
            case .income:
                if next <= horizon { items.append(Upcoming(date: next, label: contract.provider, amount: contract.monthlyAmount)) }
            }
        }

        for account in c.accounts where account.kind == .creditCard && account.balance < 0 {
            guard let date = statementDate(account.statementNote, today: c.today), date > c.today, date <= horizon else { continue }
            let product = account.name.replacingOccurrences(of: " Card", with: "")
            items.append(Upcoming(date: date, label: "\(account.bankName) \(product) statement", amount: account.balance))
        }

        return items.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return abs(lhs.amount) > abs(rhs.amount)
        }
    }

    static func isOwnTransfer(_ order: StandingOrderRecord, others: [AccountRecord]) -> Bool {
        let iban = order.iban.filter { !$0.isWhitespace }.uppercased()
        for account in others {
            if !iban.isEmpty, let accountIBAN = account.iban, accountIBAN.filter({ !$0.isWhitespace }).uppercased() == iban { return true }
            if order.recipient.lowercased().hasPrefix(account.name.lowercased()) { return true }
        }
        return false
    }

    /// `Statement 20.11.` → 20.11. of the ledger's year.
    static func statementDate(_ note: String?, today: LocalDate) -> LocalDate? {
        guard let note else { return nil }
        let numbers = note.split(whereSeparator: { !$0.isNumber })
        guard numbers.count >= 2, let day = Int(numbers[0]), let month = Int(numbers[1]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return LocalDate(year: today.year, month: month, day: min(day, LocalDate(year: today.year, month: month, day: 1).daysInMonth))
    }

    // MARK: Transactions

    static func transactions(_ c: ReportContext, _ out: inout JSON) throws {
        let giro = try c.giro
        let from90 = c.today.adding(days: -90)
        let balance = giro.balance
        out["transactions.girokonto.balance"] = Fmt.money(balance)
        out["transactions.girokonto.available"] = Fmt.money(balance + giro.overdraftLimit)
        out["transactions.girokonto.overdraftLimit"] = Fmt.money(giro.overdraftLimit)
        out["transactions.girokonto.count90d"] = try c.count(account: giro.id, from: from90, through: c.today)
        out["transactions.girokonto.range90d"] = DateFormats.dayMonth(from90) + "\u{2013}" + DateFormats.dayMonth(c.today)
        out["transactions.girokonto.novemberTotal"] = Fmt.plain(try c.sum(account: giro.id, from: c.monthStart, through: c.today))
        out["transactions.girokonto.novemberCount"] = try c.count(account: giro.id, from: c.monthStart, through: c.today)
        let afterOctober = try c.sum(account: giro.id, from: c.monthStart, through: LocalDate(year: 9999, month: 12, day: 31))
        out["transactions.girokonto.closingBalance31Oct"] = Fmt.money(balance - afterOctober)

        let balances = try LedgerDefinitions.runningBalances(c.db, accountID: giro.id)
        let newest = try TransactionRecord.fetchAll(
            c.db,
            sql: "SELECT * FROM ledger_transaction WHERE account_id = ? AND deleted_at IS NULL ORDER BY \(LedgerOrder.transactionsNewestFirst()) LIMIT 12",
            arguments: [giro.id])
        out["transactions.girokonto.rows"] = newest.map { row -> JSON in
            [
                "date": DateFormats.dayMonth(row.bookingDate),
                "payee": row.shortName ?? row.counterpartyName,
                "purpose": row.purpose ?? "",
                "category": c.categoryLabel(row.categoryId),
                "amount": Fmt.money(row.amount),
                "balance": Fmt.money(balances[row.id] ?? 0),
                "isNew": row.isNew,
            ]
        }

        // Balance chart over the 90-day window (soft chart): end-of-day balance of the Girokonto.
        var changeByDay: [String: Int] = [:]
        let flows = try Row.fetchAll(
            c.db,
            sql: "SELECT booking_date, SUM(amount) AS total FROM ledger_transaction WHERE deleted_at IS NULL AND account_id = ? AND booking_date > ? GROUP BY booking_date",
            arguments: [giro.id, from90.iso])
        for row in flows {
            let day: String = row["booking_date"]
            let total: Int = row["total"]
            changeByDay[day] = total
        }
        // Balance at the end of `from90`, then walk forward.
        let after90 = try c.sum(account: giro.id, from: from90.adding(days: 1), through: LocalDate(year: 9999, month: 12, day: 31))
        var running = balance - after90
        var balanceSeries: [JSON] = [["date": from90.iso, "cents": running, "value": Fmt.money(running)]]
        for step in 1...90 {
            let day = from90.adding(days: step)
            running += changeByDay[day.iso] ?? 0
            balanceSeries.append(["date": day.iso, "cents": running, "value": Fmt.money(running)])
        }
        out["transactions.girokonto.balanceSeries"] = balanceSeries
        out["transactions.girokonto.balanceMin"] = Fmt.money(balanceSeries.compactMap { $0["cents"] as? Int }.min() ?? 0)
        out["transactions.girokonto.balanceMax"] = Fmt.money(balanceSeries.compactMap { $0["cents"] as? Int }.max() ?? 0)

        // Every account on its own.
        for account in c.accounts {
            let key = "transactions.account.\(account.name)"
            out["\(key).balance"] = Fmt.money(try c.value(of: account))
            out["\(key).count90d"] = try c.count(account: account.id, from: from90, through: c.today)
            out["\(key).novemberTotal"] = Fmt.plain(try c.sum(account: account.id, from: c.monthStart, through: c.today))
        }

        // All transactions.
        let nonDepot = c.accounts.filter { $0.kind != .depot }
        out["transactions.all.balance"] = Fmt.money(nonDepot.map(\.balance).reduce(0, +))
        out["transactions.all.balanceNote"] = "\(nonDepot.count) accounts, without Depot"
        out["transactions.all.subtitle"] = "\(c.accounts.count) accounts"
        out["transactions.all.count"] = try c.count(from: from90, through: c.today)
        out["transactions.all.novemberTotal"] = Fmt.plain(try c.sum(from: c.monthStart, through: c.today))
        let allNewest = try TransactionRecord.fetchAll(
            c.db,
            sql: "SELECT * FROM ledger_transaction WHERE deleted_at IS NULL ORDER BY \(LedgerOrder.transactionsNewestFirst()) LIMIT 14")
        out["transactions.all.rows"] = allNewest.map { row -> JSON in
            [
                "date": DateFormats.dayMonth(row.bookingDate),
                "payee": row.shortName ?? row.counterpartyName,
                "account": c.accountName(row.accountId),
                "category": c.categoryLabel(row.categoryId),
                "amount": Fmt.money(row.amount),
            ]
        }
    }

    // MARK: Categories

    static func categories(_ c: ReportContext, _ out: inout JSON) throws {
        let months = try c.monthlySpending()
        let complete = Array(months.dropLast())
        let current = months[months.count - 1]
        let totalAverage = try LedgerDefinitions.monthlyAverageSpending(c.db, today: c.today)
        out["categories.average"] = Fmt.money(totalAverage)
        out["categories.salary"] = Fmt.signed(try c.scalar(
            "SELECT COALESCE((SELECT amount FROM ledger_transaction WHERE kind = 'salary' AND deleted_at IS NULL ORDER BY booking_date DESC LIMIT 1), 0)"))
        out["categories.rulesCount"] = try c.scalar("SELECT COUNT(*) FROM rule WHERE deleted_at IS NULL AND enabled = 1")
        out["categories.period"] = "\(DateFormats.monthYear(months[0].start)) \u{2013} \(DateFormats.monthYear(current.start))"

        if let peak = complete.max(by: { $0.byCategory.values.reduce(0, +) < $1.byCategory.values.reduce(0, +) }) {
            out["categories.mostExpensiveMonth"] = DateFormats.monthName(peak.start)
            out["categories.mostExpensiveMonthAmount"] = Fmt.money(peak.byCategory.values.reduce(0, +))
        }

        // Year view: this month, monthly average of the 11 complete months, total of all 12 months.
        var yearRows: [JSON] = []
        var sumThisMonth = 0, sumAverage = 0, sumYear = 0
        for category in c.expenseCategories {
            let thisMonth = current.byCategory[category.id] ?? 0
            let completeSum = complete.map { $0.byCategory[category.id] ?? 0 }.reduce(0, +)
            let average = Fmt.roundDiv(completeSum, complete.count)
            let year = completeSum + thisMonth
            sumThisMonth += thisMonth
            sumAverage += average
            sumYear += year
            yearRows.append([
                "category": category.name, "colorToken": category.colorToken,
                "thisMonth": Fmt.money(-thisMonth), "average": Fmt.money(-average), "yearTotal": Fmt.money(-year),
                "shareOfAverage": Fmt.percent(average, totalAverage, decimals: 1),
            ])
        }
        out["categories.year.rows"] = yearRows
        out["categories.year.total"] = ["thisMonth": Fmt.money(-sumThisMonth), "average": Fmt.money(-sumAverage), "yearTotal": Fmt.money(-sumYear)] as JSON

        // Month view: the current month so far.
        let monthTotal = current.byCategory.values.reduce(0, +)
        out["categories.month.rows"] = c.expenseCategories.map { category -> JSON in
            let amount = current.byCategory[category.id] ?? 0
            return ["category": category.name, "amount": Fmt.money(-amount), "share": Fmt.percent(amount, monthTotal, decimals: 1)]
        }
        out["categories.month.total"] = Fmt.money(-monthTotal)

        // Quarter view: the calendar quarter to date.
        let quarterStart = LocalDate(year: c.today.year, month: (c.today.month - 1) / 3 * 3 + 1, day: 1)
        let quarter = try LedgerDefinitions.spending(c.db, from: quarterStart, through: c.today)
        let quarterTotal = quarter.values.reduce(0, +)
        out["categories.quarter.from"] = quarterStart.iso
        out["categories.quarter.rows"] = c.expenseCategories.map { category -> JSON in
            let amount = quarter[category.id] ?? 0
            return ["category": category.name, "amount": Fmt.money(-amount), "share": Fmt.percent(amount, quarterTotal, decimals: 1)]
        }
        out["categories.quarter.total"] = Fmt.money(-quarterTotal)

        // Stacked bar chart (soft chart): per month and category.
        out["categories.series"] = months.enumerated().map { index, month -> JSON in
            var byCategory: JSON = [:]
            for category in c.expenseCategories { byCategory[category.name] = month.byCategory[category.id] ?? 0 }
            return [
                "month": c.shortMonth(month.start), "start": month.start.iso, "partial": index == months.count - 1,
                "total": Fmt.money(-month.byCategory.values.reduce(0, +)), "cents": byCategory,
            ]
        }
    }

    // MARK: Budgets

    static func budgets(_ c: ReportContext, _ out: inout JSON) throws {
        let spending = try LedgerDefinitions.spending(c.db, from: c.monthStart, through: c.today)
        let budgets = try BudgetRecord.live().fetchAll(c.db)
        let ordered = c.categories.compactMap { category in budgets.first(where: { $0.categoryId == category.id }).map { (category, $0) } }
        var rows: [JSON] = []
        var totalSpent = 0, totalLimit = 0, over = 0
        for (category, budget) in ordered {
            let spent = spending[category.id] ?? 0
            let remaining = budget.monthlyLimit - spent
            if spent > budget.monthlyLimit { over += 1 }
            totalSpent += spent
            totalLimit += budget.monthlyLimit
            rows.append([
                "category": category.name, "spent": Fmt.money(spent), "limit": Fmt.money(budget.monthlyLimit),
                "remaining": Fmt.money(remaining), "percent": Fmt.percent(spent, budget.monthlyLimit, decimals: 1),
                "over": spent > budget.monthlyLimit,
                "overBy": spent > budget.monthlyLimit ? Fmt.money(spent - budget.monthlyLimit) : "",
            ])
        }
        out["budgets.rows"] = rows
        out["budgets.count"] = ordered.count
        out["budgets.overCount"] = over
        out["budgets.totalSpent"] = Fmt.money(totalSpent)
        out["budgets.totalLimit"] = Fmt.money(totalLimit)
        out["budgets.leftToSpend"] = Fmt.money(totalLimit - totalSpent)
        out["budgets.totalPercent"] = Fmt.percent(totalSpent, totalLimit, decimals: 1)
        out["budgets.paceDay"] = c.today.day
        out["budgets.daysInMonth"] = c.today.daysInMonth
        out["budgets.daysLeft"] = c.today.daysInMonth - c.today.day
        out["budgets.pacePercent"] = Fmt.percent(c.today.day, c.today.daysInMonth)
        out["budgets.subtitle"] = "\(DateFormats.monthYear(c.today)) \u{00B7} \(c.today.daysInMonth - c.today.day) days left"
        out["budgets.rolloverEnabled"] = try LedgerStore.setting(.rolloverEnabled, in: c.db) ?? "unset"

        // Fixed costs: contracts whose category has no budget (they leave by standing order or direct debit).
        let budgeted = Set(budgets.map(\.categoryId))
        let contracts = try ContractRecord.live().filter(sql: "kind = 'contract'").order(sql: "sort_order").fetchAll(c.db)
        var fixed: [JSON] = []
        var groupedTotals: [String: Int] = [:]
        var groupOrder: [String] = []
        for contract in contracts {
            guard let categoryID = contract.categoryId, !budgeted.contains(categoryID) else { continue }
            let categoryName = c.categoryLabel(categoryID)
            if categoryName == "Housing" {
                fixed.append(["label": contract.provider, "amount": Fmt.money(-contract.monthlyAmount), "cents": -contract.monthlyAmount])
            } else {
                if groupedTotals[categoryName] == nil { groupOrder.append(categoryName) }
                groupedTotals[categoryName, default: 0] += -contract.monthlyAmount
            }
        }
        for name in groupOrder {
            let amount = groupedTotals[name] ?? 0
            fixed.append(["label": name, "amount": Fmt.money(amount), "cents": amount])
        }
        out["budgets.fixedCosts"] = fixed
        out["budgets.fixedCosts.total"] = Fmt.money(fixed.compactMap { $0["cents"] as? Int }.reduce(0, +))
    }

    // MARK: Standing orders

    static func standingOrders(_ c: ReportContext, _ out: inout JSON) throws {
        let giro = try c.giro
        let orders = try StandingOrderRecord.live()
            .order(sql: "next_execution IS NULL, next_execution, recipient")
            .fetchAll(c.db)
        out["standingOrders.rows"] = orders.map { order -> JSON in
            let rhythm: String
            switch order.rhythm {
            case .once: rhythm = "Once"
            case .monthly: rhythm = "Monthly on the \(Fmt.ordinal(order.dayOfMonth ?? order.nextExecution?.day ?? 1))"
            }
            return [
                "recipient": order.recipient, "iban": order.iban, "purpose": order.purpose ?? "", "rhythm": rhythm,
                "next": Fmt.date(order.nextExecution), "amount": Fmt.money(order.amount),
                "status": Fmt.capitalized(order.status.rawValue),
                "account": c.accountName(order.accountId),
            ]
        }
        out["standingOrders.count"] = orders.count
        out["standingOrders.activeCount"] = orders.filter { $0.status == .active }.count
        let monthlyTotal = orders.filter { $0.status == .active && $0.rhythm == .monthly }.map(\.amount).reduce(0, +)
        out["standingOrders.total"] = Fmt.money(monthlyTotal)
        out["standingOrders.subtitle"] = "\(giro.bankName) \u{00B7} synced with your bank"

        // Leaving the Girokonto within the next 30 days: standing orders plus contract debits, without
        // counting a contract twice when a standing order pays it (same amount, same day).
        let horizon = c.today.adding(days: 30)
        var leaving: [Upcoming] = []
        for order in orders where order.accountId == giro.id && (order.status == .active || order.status == .scheduled) {
            guard let next = order.nextExecution, next > c.today, next <= horizon else { continue }
            leaving.append(Upcoming(date: next, label: order.recipient, amount: order.amount))
        }
        var salary: Upcoming?
        for contract in try ContractRecord.live().filter(sql: "account_id = ?", arguments: [giro.id]).fetchAll(c.db) {
            guard let next = contract.nextDebit, next > c.today, next <= horizon else { continue }
            switch contract.kind {
            case .income:
                salary = Upcoming(date: next, label: contract.provider, amount: contract.monthlyAmount)
            case .contract:
                if !leaving.contains(where: { $0.date == next && $0.amount == contract.monthlyAmount }) {
                    leaving.append(Upcoming(date: next, label: contract.provider, amount: contract.monthlyAmount))
                }
            }
        }
        out["standingOrders.leavingUntil"] = DateFormats.dayMonthYear(horizon)
        out["standingOrders.leaving"] = Fmt.money(leaving.map(\.amount).reduce(0, +))
        if let salary {
            out["standingOrders.salary"] = salary.json
        }
        var byDate: [LocalDate: [Upcoming]] = [:]
        for item in leaving { byDate[item.date, default: []].append(item) }
        out["standingOrders.timeline"] = byDate.keys.sorted().map { date -> JSON in
            let items = byDate[date] ?? []
            let total = items.map(\.amount).reduce(0, +)
            return ["date": DateFormats.dayMonth(date), "isoDate": date.iso, "amount": Fmt.plain(total), "cents": total, "items": items.map(\.label)]
        }
    }

    // MARK: Contracts

    static func contracts(_ c: ReportContext, _ out: inout JSON) throws {
        let all = try ContractRecord.live().order(sql: "sort_order").fetchAll(c.db)
        let costs = all.filter { $0.kind == .contract }
        let total = costs.map(\.monthlyAmount).reduce(0, +)
        let salary = all.first(where: { $0.kind == .income })?.monthlyAmount ?? 0
        out["contracts.count"] = costs.count
        out["contracts.total"] = Fmt.money(total)
        out["contracts.yearTotal"] = Fmt.money(-total * 12)
        out["contracts.salaryShare"] = Fmt.percent(-total, salary)
        out["contracts.salary"] = Fmt.signed(salary)

        var groupNames: [String] = []
        for contract in costs where !groupNames.contains(contract.groupName) { groupNames.append(contract.groupName) }
        out["contracts.groups"] = groupNames.map { name -> JSON in
            let members = costs.filter { $0.groupName == name }
            return [
                "name": name, "subtotal": Fmt.money(members.map(\.monthlyAmount).reduce(0, +)),
                "rows": members.map { contract -> JSON in
                    [
                        "provider": contract.provider,
                        "account": contract.accountId.map { c.accountName($0) } ?? "",
                        "rhythm": Fmt.capitalized(contract.rhythm.rawValue),
                        "nextDebit": Fmt.date(contract.nextDebit),
                        "notice": contract.noticeText ?? "",
                        "perMonth": Fmt.money(contract.monthlyAmount),
                    ]
                },
            ]
        }

        out["contracts.priceChanges"] = costs.compactMap { contract -> JSON? in
            guard let changed = contract.priceChangeAmount, let start = contract.priceChangeStart else { return nil }
            let more = abs(changed) - abs(contract.monthlyAmount)
            return [
                "provider": contract.provider, "from": Fmt.money(abs(contract.monthlyAmount)), "to": Fmt.money(abs(changed)),
                "start": DateFormats.monthName(start), "moreMonthly": Fmt.money(more), "moreYearly": Fmt.money(more * 12),
                "account": contract.accountId.map { c.accountName($0) } ?? "",
            ]
        }
        out["contracts.noticeDeadlines"] = costs.compactMap { contract -> JSON? in
            guard let deadline = contract.noticeDeadline, deadline >= c.today else { return nil }
            return [
                "provider": contract.provider, "deadline": DateFormats.dayMonthYear(deadline), "daysLeft": deadline - c.today,
                "renewal": Fmt.date(contract.renewalDate),
                "renewalAmount": contract.renewalAmount.map { Fmt.money($0) } ?? "",
            ]
        }
    }

    // MARK: Depot

    static func depot(_ c: ReportContext, _ out: inout JSON) throws {
        let depot = try c.account(.depot)
        let holdings = try HoldingRecord.live().filter(sql: "account_id = ?", arguments: [depot.id]).order(sql: "sort_order").fetchAll(c.db)
        let value = try LedgerDefinitions.holdingsValue(c.db, accountID: depot.id) ?? depot.balance
        let costBasis = holdings.map(\.costBasis).reduce(0, +)
        let cash = holdings.filter { $0.securityId == nil }.map { marketValue($0) }.reduce(0, +)
        out["depot.value"] = Fmt.money(value)
        out["depot.cash"] = Fmt.money(cash)
        out["depot.costBasis"] = Fmt.money(costBasis)
        out["depot.gain"] = Fmt.signed(value - costBasis)
        out["depot.gainPercent"] = Fmt.percent(value - costBasis, costBasis, decimals: 1, alwaysSign: true)
        out["depot.subtitle"] = "\(depot.bankName) \u{00B7} \(depot.iban ?? "")"
        out["depot.holdingsCount"] = holdings.filter { $0.securityId != nil }.count

        out["depot.holdings"] = holdings.map { holding -> JSON in
            let holdingValue = marketValue(holding)
            let isCash = holding.securityId == nil
            var row: JSON = [
                "name": holding.name, "isin": holding.isin ?? "", "isCash": isCash,
                "quantity": isCash ? "" : quantityText(holding.quantityMicro), "price": isCash ? "" : Fmt.money(holding.price),
                "value": Fmt.money(holdingValue), "costBasis": Fmt.money(holding.costBasis),
                "weight": Fmt.percent(holdingValue, value, decimals: 1),
            ]
            if !isCash {
                row["gain"] = Fmt.signed(holdingValue - holding.costBasis)
                row["gainPercent"] = Fmt.percent(holdingValue - holding.costBasis, holding.costBasis, decimals: 1, alwaysSign: true)
            }
            return row
        }

        // Performance over the last year and the day change (from the stored value history).
        let yearAgo = c.today.adding(months: -12)
        if let start = try LedgerDefinitions.depotValue(c.db, accountID: depot.id, on: yearAgo) {
            out["depot.valueOneYearAgo"] = Fmt.money(start)
            out["depot.performanceOneYear"] = Fmt.signed(value - start)
        }
        if let yesterday = try LedgerDefinitions.depotValue(c.db, accountID: depot.id, on: c.today.adding(days: -1)), yesterday > 0 {
            out["depot.changeToday"] = Fmt.percent(value - yesterday, yesterday, decimals: 1, alwaysSign: true)
        }

        // Savings plan.
        if let plan = try SavingsPlanRecord.live().filter(sql: "account_id = ?", arguments: [depot.id]).fetchOne(c.db) {
            let items = try SavingsPlanItemRecord.live().filter(sql: "plan_id = ?", arguments: [plan.id]).order(sql: "sort_order").fetchAll(c.db)
            out["depot.savingsPlan.amount"] = Fmt.money(plan.amount)
            out["depot.savingsPlan.day"] = Fmt.ordinal(plan.dayOfMonth)
            out["depot.savingsPlan.next"] = Fmt.date(plan.nextExecution)
            out["depot.savingsPlan.source"] = plan.sourceAccountId.map { id in
                c.accounts.first(where: { $0.id == id }).map { "\($0.name), \($0.bankName)" } ?? id
            } ?? ""
            out["depot.savingsPlan.items"] = try items.map { item -> JSON in
                let security = try SecurityRecord.fetchOne(c.db, key: item.securityId)
                return [
                    "name": security?.name ?? item.securityId, "share": Fmt.percent(item.amount, plan.amount),
                    "amount": Fmt.money(item.amount),
                ]
            }
            // Savings-plan debits between a year ago (exclusive) and today (inclusive).
            var debits = 0
            for offset in -12...0 {
                let month = c.monthStart.adding(months: offset)
                let day = min(plan.dayOfMonth, month.daysInMonth)
                let date = LocalDate(year: month.year, month: month.month, day: day)
                if date > yearAgo && date <= c.today { debits += 1 }
            }
            out["depot.savingsPlan.paidInLastYear"] = Fmt.money(debits * plan.amount)
            out["depot.savingsPlan.debitsLastYear"] = debits
        }

        // Allocation by region: fund value × the fund's regional weights; cash on its own.
        var regionValue: [String: Double] = [:]
        let regionOrder = ["North America", "Europe", "Emerging markets", "Japan & Pacific"]
        for holding in holdings {
            guard let securityID = holding.securityId, let security = try SecurityRecord.fetchOne(c.db, key: securityID),
                  let json = security.region, let weights = try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8)) else { continue }
            let fundValue = Double(marketValue(holding))
            for (region, permille) in weights {
                regionValue[region, default: 0] += fundValue * Double(permille) / 1000
            }
        }
        var allocation: [JSON] = []
        for region in regionOrder {
            let cents = Int((regionValue[region] ?? 0).rounded())
            allocation.append(["region": region, "percent": Fmt.percent(cents, value, decimals: 1), "value": Fmt.money(cents)])
        }
        allocation.append(["region": "Cash", "percent": Fmt.percent(cash, value, decimals: 1), "value": Fmt.money(cash)])
        out["depot.allocation"] = allocation

        // Value history for the chart (soft chart): the last year, plus point counts per range.
        let history = try DepotValueRecord.live().filter(sql: "account_id = ?", arguments: [depot.id]).order(sql: "date").fetchAll(c.db)
        let oneYear = history.filter { $0.date >= yearAgo }
        out["depot.history.1Y"] = oneYear.map { ["date": $0.date.iso, "cents": $0.value, "value": Fmt.money($0.value)] as JSON }
        out["depot.history.1Y.min"] = Fmt.money(oneYear.map(\.value).min() ?? 0)
        out["depot.history.1Y.max"] = Fmt.money(oneYear.map(\.value).max() ?? 0)
        out["depot.history.points.1M"] = history.filter { $0.date >= c.today.adding(months: -1) }.count
        out["depot.history.points.6M"] = history.filter { $0.date >= c.today.adding(months: -6) }.count
        out["depot.history.points.1Y"] = oneYear.count
        out["depot.history.points.Max"] = history.count
        out["depot.history.firstDate"] = history.first.map { DateFormats.dayMonthYear($0.date) } ?? ""
    }

    /// `quantity × price` in minor units, rounded half up.
    static func marketValue(_ holding: HoldingRecord) -> Int {
        (holding.quantityMicro * holding.price + 500_000) / 1_000_000
    }

    static func quantityText(_ micro: Int) -> String {
        if micro % 1_000_000 == 0 { return String(micro / 1_000_000) }
        var fraction = String(micro % 1_000_000)
        fraction = String(repeating: "0", count: 6 - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return "\(micro / 1_000_000),\(fraction)"
    }

    // MARK: Suggestions

    static func suggestions(_ c: ReportContext, _ out: inout JSON) throws {
        let insights = try c.insights(.suggestion)
        var rows: [JSON] = []
        var sure = 0
        var missing = 0
        for insight in insights {
            let payload = try JSONDecoder().decode(SuggestionPayload.self, from: Data(insight.payload.utf8))
            if payload.preselected { sure += 1 }
            guard let id = insight.transactionId, let transaction = try TransactionRecord.fetchOne(c.db, key: id) else {
                missing += 1
                continue
            }
            rows.append([
                "date": DateFormats.dayMonth(transaction.bookingDate),
                "payee": transaction.shortName ?? transaction.counterpartyName,
                "purpose": transaction.purpose ?? "",
                "account": c.accountName(transaction.accountId),
                "amount": Fmt.money(transaction.amount),
                "currentCategory": c.categoryLabel(transaction.categoryId),
                "suggestedCategory": payload.suggestedCategory,
                "suggestedCategoryExists": c.categories.contains(where: { $0.name == payload.suggestedCategory }),
                "confidence": payload.confidenceLabel,
                "reason": payload.reason,
                "preselected": payload.preselected,
            ])
        }
        out["suggestions.rows"] = rows
        out["suggestions.count"] = insights.count
        out["suggestions.sureCount"] = sure
        out["suggestions.withoutTransaction"] = missing
        out["suggestions.uncategorisedLedgerRows"] = try LedgerDefinitions.uncategorisedCount(c.db)
        var notices: [JSON] = []
        for insight in try c.insights(.notice) {
            let payload = try JSONDecoder().decode(NoticePayload.self, from: Data(insight.payload.utf8))
            notices.append(["variant": payload.variant, "text": payload.text, "actionTitle": payload.actionTitle ?? ""])
        }
        out["suggestions.notices"] = notices
    }

    // MARK: October review

    static func review(_ c: ReportContext, _ out: inout JSON) throws {
        let start = c.monthStart.adding(months: -1)
        let end = c.lastDay(ofMonthStarting: start)
        out["review.month"] = DateFormats.monthYear(start)

        /// Income = positive rows filed under an income category.
        func income(_ from: LocalDate, _ through: LocalDate) throws -> Int {
            try c.scalar(
                """
                SELECT COALESCE(SUM(t.amount), 0) FROM ledger_transaction t JOIN category k ON k.id = t.category_id
                WHERE t.deleted_at IS NULL AND k.kind = 'income' AND t.amount > 0 AND t.booking_date BETWEEN ? AND ?
                """,
                [from.iso, through.iso])
        }
        let monthIncome = try income(start, end)
        let monthSpending = try LedgerDefinitions.totalSpending(c.db, from: start, through: end)
        // "6-month average": the six complete months before the reviewed month (April to September), whole
        // minor units by truncating division.
        var sixIncome = 0, sixSpending = 0
        var sixByCategory: [String: Int] = [:]
        for offset in -6...(-1) {
            let from = start.adding(months: offset)
            let through = c.lastDay(ofMonthStarting: from)
            sixIncome += try income(from, through)
            let spending = try LedgerDefinitions.spending(c.db, from: from, through: through)
            sixSpending += spending.values.reduce(0, +)
            for (id, amount) in spending { sixByCategory[id, default: 0] += amount }
        }
        let incomeAverage = sixIncome / 6
        let spendingAverage = sixSpending / 6
        out["review.october.income"] = Fmt.signed(monthIncome)
        out["review.october.spending"] = Fmt.money(-monthSpending)
        out["review.october.saved"] = Fmt.money(monthIncome - monthSpending)
        out["review.sixMonthAverage.income"] = Fmt.signed(incomeAverage)
        out["review.sixMonthAverage.spending"] = Fmt.money(-spendingAverage)
        out["review.sixMonthAverage.saved"] = Fmt.money(incomeAverage - spendingAverage)

        let october = try LedgerDefinitions.spending(c.db, from: start, through: end)
        out["review.categories"] = c.expenseCategories.map { category -> JSON in
            let month = october[category.id] ?? 0
            let average = (sixByCategory[category.id] ?? 0) / 6
            return [
                "category": category.name, "october": Fmt.money(month), "sixMonthAverage": Fmt.money(average),
                "delta": Fmt.signed(month - average),
            ]
        }

        // Stored AI content and its consistency with the ledger.
        guard let insight = try c.insights(.review).first else { return }
        let payload = try JSONDecoder().decode(ReviewPayload.self, from: Data(insight.payload.utf8))
        out["review.stored.headline"] = payload.headline
        out["review.stored.rows"] = payload.rows.map { ["label": $0.label, "month": Fmt.money($0.month), "average": Fmt.money($0.average)] as JSON }
        out["review.stored.findings"] = payload.findings.map { ["number": $0.number, "title": $0.title, "delta": $0.deltaText] as JSON }
        out["review.stored.sources"] = payload.sources.map { ["number": $0.number, "label": $0.label, "dateText": $0.dateText] as JSON }
        let giro = try c.giro
        out["review.outlook.todayBalance"] = Fmt.money(payload.outlook.todayBalance)
        out["review.outlook.todayBalanceMatchesLedger"] = payload.outlook.todayBalance == giro.balance
        out["review.outlook.expectedEnd"] = Fmt.money(payload.outlook.expectedEnd)
        out["review.outlook.lowest"] = Fmt.money(payload.outlook.lowestAmount)
        out["review.outlook.lowestDate"] = DateFormats.dayMonth(payload.outlook.lowestDate)
        out["review.outlook.rangeLow"] = Fmt.money(payload.outlook.rangeLow)
        out["review.outlook.rangeHigh"] = Fmt.money(payload.outlook.rangeHigh)
        out["review.outlook.forecast"] = payload.outlook.days.map {
            ["date": $0.date.iso, "expected": $0.expected, "low": $0.low, "high": $0.high] as JSON
        }
        var missing = 0
        for source in payload.sources {
            for reference in source.transactionReferences {
                if try c.transaction(reference: reference) == nil { missing += 1 }
            }
        }
        out["review.stored.missingTransactions"] = missing
    }

    // MARK: Tax return

    static func tax(_ c: ReportContext, _ out: inout JSON) throws {
        guard let insight = try c.insights(.tax).first else { return }
        let payload = try JSONDecoder().decode(TaxPayload.self, from: Data(insight.payload.utf8))
        out["tax.year"] = payload.year
        out["tax.storedTotal"] = Fmt.money(payload.total)
        out["tax.itemCount"] = payload.itemCount
        out["tax.formCount"] = payload.formCount
        out["tax.needsReceiptCount"] = payload.needsReceiptCount

        var computedTotal = 0
        var itemTotal = 0
        var missing = 0
        var amountMismatches = 0
        var groups: [JSON] = []
        for group in payload.groups {
            var groupTotal = 0
            var rows: [JSON] = []
            for item in group.items {
                itemTotal += 1
                let eligible = item.eligibleAmount ?? abs(item.amount)
                groupTotal += eligible
                var ledgerAmount = 0
                for reference in item.transactionReferences {
                    if let transaction = try c.transaction(reference: reference) {
                        ledgerAmount += transaction.amount
                    } else {
                        missing += 1
                    }
                }
                if !item.transactionReferences.isEmpty && ledgerAmount != item.amount { amountMismatches += 1 }
                rows.append([
                    "date": DateFormats.dayMonth(item.date), "payee": item.payee, "purpose": item.purpose,
                    "receipt": item.receiptLabel, "amount": Fmt.money(item.amount), "eligible": Fmt.money(eligible),
                    "ledgerAmount": Fmt.money(ledgerAmount),
                ])
            }
            computedTotal += groupTotal
            groups.append([
                "form": group.form, "itemCountText": group.itemCountText, "storedTotal": Fmt.money(group.total),
                "computedTotal": Fmt.money(groupTotal), "items": rows,
            ])
        }
        out["tax.groups"] = groups
        out["tax.computedTotal"] = Fmt.money(computedTotal)
        out["tax.computedItemCount"] = itemTotal
        out["tax.missingTransactions"] = missing
        out["tax.amountMismatches"] = amountMismatches
        out["tax.totalMatches"] = computedTotal == payload.total
    }

    // MARK: Ask

    static func ask(_ c: ReportContext, _ out: inout JSON) throws {
        guard let insight = try c.insights(.ask).first else { return }
        let payload = try JSONDecoder().decode(AskPayload.self, from: Data(insight.payload.utf8))
        out["ask.question"] = payload.question
        out["ask.storedTotal"] = Fmt.money(payload.total)
        out["ask.headline"] = payload.headline

        var computed = 0
        var rows: [TransactionRecord] = []
        for reference in payload.transactionReferences {
            if let transaction = try c.transaction(reference: reference) {
                computed += transaction.amount
                rows.append(transaction)
            }
        }
        out["ask.computedTotal"] = Fmt.money(computed)
        out["ask.computedTransactionCount"] = rows.count
        out["ask.totalMatches"] = computed == payload.total

        var months: [String: Int] = [:]
        for row in rows { months[String(row.bookingDate.iso.prefix(7)), default: 0] += row.amount }
        out["ask.computedMonths"] = months.keys.sorted().map { ["month": $0, "amount": Fmt.money(months[$0] ?? 0)] as JSON }
        out["ask.storedMonths"] = payload.monthly.map { ["label": $0.label, "amount": Fmt.money($0.amount), "partial": $0.partial] as JSON }

        out["ask.groups"] = try payload.groups.map { group -> JSON in
            var amount = 0
            var count = 0
            for reference in group.transactionReferences {
                if let transaction = try c.transaction(reference: reference) {
                    amount += transaction.amount
                    count += 1
                }
            }
            return [
                "name": group.name, "countText": group.countText, "storedCount": group.count, "computedCount": count,
                "storedAmount": Fmt.money(group.amount), "computedAmount": Fmt.money(amount),
            ]
        }
        out["ask.previousYearTotal"] = Fmt.money(payload.previousYearTotal)
        out["ask.percentChange"] = payload.percentChange
    }

    // MARK: Sync failed

    /// Banks that fail when the demo bank is set to "fails" (Sparkasse KölnBonn: PIN rejected; DKB:
    /// maintenance), see `DemoConnector.fetch`.
    static let failingBanks = ["Sparkasse KölnBonn", "DKB"]

    static func syncFailed(_ c: ReportContext, _ out: inout JSON) throws {
        let rows = try Row.fetchAll(
            c.db,
            sql: """
                SELECT a.name AS name, a.balance AS balance, a.kind AS kind, b.bank_name AS login_bank
                FROM account a LEFT JOIN bank_login b ON b.id = a.bank_login_id
                WHERE a.deleted_at IS NULL ORDER BY a.sort_order
                """)
        var failed = 0
        var failedNames: [String] = []
        var failedBanks: [String] = []
        for row in rows {
            let bank: String? = row["login_bank"]
            guard let bank, failingBanks.contains(bank) else { continue }
            failed += 1
            let name: String = row["name"]
            failedNames.append(name)
            if !failedBanks.contains(bank) { failedBanks.append(bank) }
        }
        out["syncFailed.accountCount"] = rows.count
        out["syncFailed.notUpdatedCount"] = failed
        out["syncFailed.updatedCount"] = rows.count - failed
        out["syncFailed.notUpdatedAccounts"] = failedNames
        out["syncFailed.failedBanks"] = failedBanks
        out["syncFailed.updatedText"] = "\(rows.count - failed) of \(rows.count) updated today"
        out["syncFailed.notUpdatedText"] = "\(failed) accounts not updated"
        out["syncFailed.balancesText"] = "Includes balances from yesterday for \(failed) accounts"
        out["syncFailed.netWorth"] = Fmt.money(try LedgerDefinitions.netWorth(c.db))
    }

    // MARK: Onboarding

    static func onboarding(_ c: ReportContext, _ out: inout JSON) throws {
        let sparkasse = try c.scalar(
            "SELECT COUNT(*) FROM account a JOIN bank_login b ON b.id = a.bank_login_id WHERE a.deleted_at IS NULL AND b.bank_name = 'Sparkasse KölnBonn'")
        out["onboarding.sparkasseAccountCount"] = sparkasse
        out["onboarding.importLabel"] = "Import \(sparkasse) accounts"
        out["onboarding.loginCount"] = try c.scalar("SELECT COUNT(*) FROM bank_login WHERE deleted_at IS NULL")
        out["onboarding.totalAccountCount"] = c.accounts.count
        out["onboarding.rulesCount"] = try c.scalar("SELECT COUNT(*) FROM rule WHERE deleted_at IS NULL")
    }
}
