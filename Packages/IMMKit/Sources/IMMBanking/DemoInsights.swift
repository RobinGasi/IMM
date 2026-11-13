import Foundation
import IMMLedger

/// Builds the stored insights from the finished ledger so that every number in a sentence is computed.
struct DemoInsightBuilder {
    let transactions: [BankTransaction]
    let categoryByReference: [String: String]
    let ownTransfers: Set<String>
    let contracts: [DemoContract]
    let standingOrders: [BankStandingOrder]
    let accounts: [BankAccount]

    private var today: LocalDate { DemoDataset.today }

    // MARK: Entry point

    func build() -> [DemoInsight] {
        var out: [DemoInsight] = []
        out.append(contentsOf: attention())
        out.append(ask())
        out.append(contentsOf: suggestions())
        out.append(review())
        out.append(tax())
        return out
    }

    // MARK: Helpers

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func category(of transaction: BankTransaction) -> String? { categoryByReference[transaction.reference] }

    /// Categorised expense (spending): non-income category, own transfers excluded, money out.
    private func isSpending(_ transaction: BankTransaction) -> Bool {
        guard transaction.amount < 0, !ownTransfers.contains(transaction.reference), let cat = category(of: transaction) else { return false }
        return cat != Cat.income
    }

    private func spending(category: String? = nil, from: LocalDate, to: LocalDate) -> [BankTransaction] {
        transactions.filter { transaction in
            guard isSpending(transaction), transaction.bookingDate >= from, transaction.bookingDate <= to else { return false }
            if let category { return self.category(of: transaction) == category }
            return true
        }
    }

    private func sum(_ rows: [BankTransaction]) -> Int { rows.reduce(0) { $0 - $1.amount } }

    private func monthRange(_ year: Int, _ month: Int) -> (LocalDate, LocalDate) {
        let first = LocalDate(year: year, month: month, day: 1)
        return (first, LocalDate(year: year, month: month, day: first.daysInMonth))
    }

    private func monthSpending(_ category: String?, _ year: Int, _ month: Int) -> Int {
        let (a, b) = monthRange(year, month)
        return sum(spending(category: category, from: a, to: b))
    }

    private func find(_ shortName: String, _ date: LocalDate, account: String? = nil) -> BankTransaction? {
        transactions.first { $0.shortName == shortName && $0.bookingDate == date && (account == nil || $0.accountID == account) }
    }

    /// `241 €` (whole euros, German grouping, non-breaking space).
    private func euros(_ minor: Int) -> String {
        let rounded = Int((Double(minor) / 100.0).rounded()) * 100
        return MoneyFormatter.string(rounded).replacingOccurrences(of: ",00", with: "")
    }

    private func wholeNumber(_ minor: Int) -> String {
        let rounded = Int((Double(minor) / 100.0).rounded()) * 100
        return MoneyFormatter.string(rounded, symbol: false).replacingOccurrences(of: ",00", with: "")
    }

    private func signedEuros(_ minor: Int) -> String {
        let rounded = Int((Double(minor) / 100.0).rounded()) * 100
        let text = MoneyFormatter.string(rounded, sign: .always).replacingOccurrences(of: ",00", with: "")
        return rounded == 0 ? "±" + euros(0) : text
    }

    private func numberWord(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return n >= 0 && n < words.count ? words[n] : String(n)
    }

    private func refs(_ rows: [BankTransaction]) -> [String] { rows.map(\.reference) }

    // MARK: Needs attention

    private func attention() -> [DemoInsight] {
        let uncategorised = transactions.filter { category(of: $0) == nil && !ownTransfers.contains($0.reference) }
        var groups: [String: (count: Int, latest: LocalDate)] = [:]
        for row in uncategorised {
            let key = row.accountID == DemoAccountID.paypal ? "PayPal" : String(row.shortName.split(separator: " ").first ?? "")
            let current = groups[key]
            groups[key] = ((current?.count ?? 0) + 1, max(current?.latest ?? row.bookingDate, row.bookingDate))
        }
        let top = groups.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            if lhs.value.latest != rhs.value.latest { return lhs.value.latest > rhs.value.latest }
            return lhs.key < rhs.key
        }.prefix(2).map { $0.key }.sorted()
        let earliest = uncategorised.map(\.bookingDate).min() ?? today
        var items = [
            DemoInsight(id: "attention-uncategorised", kind: .attention, transactionReference: nil, sortOrder: 0,
                        payload: encode(AttentionPayload(
                            title: "\(uncategorised.count) transactions without category",
                            detail: "Since \(DateFormats.dayMonth(earliest)), mostly " + top.joined(separator: " and "),
                            actionTitle: "Categorize", target: "suggestions"))),
        ]
        if let spotify = contracts.first(where: { $0.priceChangeAmount != nil }), let newAmount = spotify.priceChangeAmount,
           let start = spotify.priceChangeStart {
            let old = MoneyFormatter.string(-spotify.monthlyAmount)
            let new = MoneyFormatter.string(-newAmount)
            items.append(DemoInsight(id: "attention-price-increase", kind: .attention, transactionReference: nil, sortOrder: 1,
                                     payload: encode(AttentionPayload(
                                        title: "\(spotify.provider) raises its price",
                                        detail: "\(old) → \(new) from \(DateFormats.monthName(start))",
                                        actionTitle: nil, target: "contracts"))))
        }
        if let huk = contracts.first(where: { $0.noticeDeadline != nil }), let deadline = huk.noticeDeadline {
            items.append(DemoInsight(id: "attention-notice-deadline", kind: .attention, transactionReference: nil, sortOrder: 2,
                                     payload: encode(AttentionPayload(
                                        title: "\(huk.provider) notice deadline",
                                        detail: "Cancel or switch by \(DateFormats.dayMonth(deadline))",
                                        actionTitle: nil, target: "contracts"))))
        }
        return items
    }

    // MARK: Ask

    private func ask() -> DemoInsight {
        let start = LocalDate(year: 2026, month: 6, day: 1)
        let rows = spending(category: Cat.leisure, from: start, to: today)
        let total = sum(rows)
        var monthly: [AskMonth] = []
        for month in 6...11 {
            let label = String(DateFormats.monthName(LocalDate(year: 2026, month: month, day: 1)).prefix(3))
            monthly.append(AskMonth(label: label, amount: monthSpending(Cat.leisure, 2026, month), partial: month == 11))
        }
        let complete = monthly.filter { !$0.partial }.reduce(0) { $0 + $1.amount }
        var previous = 0
        for month in 6...10 { previous += monthSpending(Cat.leisure, 2025, month) }
        let average = complete / 5
        let percent = previous > 0 ? Int((Double(complete) / Double(previous) * 100.0 - 100.0).rounded()) : 0
        let direction = percent >= 0 ? "more" : "less"
        let summary = "About \(euros(average)) a month, \(abs(percent)) % \(direction) than the same months last year"

        let lieferando = rows.filter { $0.shortName == "Lieferando" }
        let cafe = rows.filter { $0.shortName == "Café Fassbender" }
        let rest = rows.filter { $0.shortName != "Lieferando" && $0.shortName != "Café Fassbender" }
        let groups = [
            AskGroup(name: "Lieferando", countText: "\(lieferando.count) orders", count: lieferando.count, amount: -sum(lieferando),
                     sourceNumber: 2, transactionReferences: refs(lieferando)),
            AskGroup(name: "Café Fassbender", countText: "\(cafe.count) visits", count: cafe.count, amount: -sum(cafe),
                     sourceNumber: 3, transactionReferences: refs(cafe)),
            AskGroup(name: "Restaurants, bars and other", countText: "\(rest.count) payments", count: rest.count, amount: -sum(rest),
                     sourceNumber: 4, transactionReferences: refs(rest)),
        ]
        let suggestedBudget = (average * 55 / 100 / 1_000) * 1_000
        let payload = AskPayload(
            question: "How much did we spend on eating out since June?",
            headline: "\(Cat.leisure), \(DateFormats.dayMonth(start))–\(DateFormats.dayMonthYear(today))",
            total: -total, confidenceLabel: "Sure", summary: summary, summarySourceNumber: 1, monthly: monthly,
            monthlyCaption: "€ per month · \(DateFormats.monthName(today).prefix(3)) so far", groups: groups,
            totalLabel: "Total since \(DateFormats.dayMonth(start))", totalPayments: rows.count, previousYearTotal: previous,
            percentChange: percent,
            actions: ["Set a \(euros(suggestedBudget)) monthly budget", "Compare with 2025", "Pay an invoice from a PDF"],
            transactionReferences: refs(rows))
        return DemoInsight(id: "ask-eating-out", kind: .ask, transactionReference: nil, sortOrder: 0, payload: encode(payload))
    }

    // MARK: Suggestions and notices

    private func suggestions() -> [DemoInsight] {
        let d = { (day: Int) in LocalDate(year: 2026, month: 11, day: day) }
        let amazonName = "Amazon EU S.a.r.l."
        let amazonEarlier = transactions.filter { $0.shortName == amazonName && $0.bookingDate < d(10) && category(of: $0) == Cat.other }
            .sorted { $0.bookingDate < $1.bookingDate }
        let etsyEarlier = transactions.filter { $0.shortName == "PayPal *Etsy" && $0.bookingDate < d(1) }
            .sorted { $0.bookingDate < $1.bookingDate }
        let lieferando90 = transactions.first { $0.shortName == "Lieferando" && $0.amount == -9_000 }

        var weeks = 4
        if let etsy = etsyEarlier.last {
            let birthday = LocalDate(year: etsy.bookingDate.year, month: 12, day: 7)
            weeks = (birthday - etsy.bookingDate) / 7
        }
        let splitDate = lieferando90.map { DateFormats.dayMonth($0.bookingDate) } ?? "31.10."

        let table: [(String, LocalDate, String?, String, String, String, String, Int?, Bool)] = [
            (amazonName, d(10), nil, Cat.other, "sure", "Sure",
             "Same payee as \(amazonEarlier.count) earlier payments you filed there", 1, true),
            ("PayPal *Etsy", d(8), nil, Cat.other, "likely", "Likely",
             "Bought \(weeks) weeks before Mia’s birthday last year too", 2, false),
            ("Apotheke am Neumarkt", d(7), nil, Cat.health, "sure", "Sure",
             "The card terminal is registered as a pharmacy", nil, true),
            ("SumUp *Kiosk Ehrenfeld", d(6), nil, Cat.leisure, "check", "Check this",
             "Unknown merchant, small card payment near home", nil, false),
            ("Bargeldauszahlung Sparkasse", d(4), nil, Cat.other, "sure", "Sure",
             "The booking text marks an ATM withdrawal", nil, true),
            ("Überweisung Jonas Weber", d(3), nil, Cat.income, "likely", "Likely",
             "Jonas paid you back after splitting Lieferando on \(splitDate)", 3, false),
        ]
        var out: [DemoInsight] = []
        for (index, row) in table.enumerated() {
            guard let transaction = find(row.0, row.1) else { continue }
            let payload = SuggestionPayload(suggestedCategory: row.3, confidence: row.4, confidenceLabel: row.5, reason: row.6,
                                            sourceNumber: row.7, preselected: row.8)
            out.append(DemoInsight(id: "suggestion-\(transaction.reference)", kind: .suggestion,
                                   transactionReference: transaction.reference, sortOrder: index, payload: encode(payload)))
        }

        // Also noticed: two identical Urban Sports Club charges on consecutive days.
        let urban = transactions.filter { $0.shortName == "Urban Sports Club" && $0.accountID == DemoAccountID.giro }
            .sorted { $0.bookingDate < $1.bookingDate }
        var duplicate: (BankTransaction, BankTransaction)?
        for index in 1..<max(urban.count, 1) where urban[index].amount == urban[index - 1].amount
            && urban[index].bookingDate - urban[index - 1].bookingDate == 1 {
            duplicate = (urban[index - 1], urban[index])
        }
        if let (first, second) = duplicate {
            let text = "Possible double charge: Urban Sports Club \(MoneyFormatter.string(first.amount)) on "
                + "\(DateFormats.dayMonth(first.bookingDate)) and \(DateFormats.dayMonth(second.bookingDate))"
            out.append(DemoInsight(
                id: "notice-double-charge", kind: .notice, transactionReference: first.reference, sortOrder: 0,
                payload: encode(NoticePayload(variant: "doubleCharge", text: text, sourceNumber: 4, actionTitle: "Compare payments",
                                              transactionReferences: [first.reference, second.reference], pattern: nil,
                                              category: nil, sources: []))))
        }
        out.append(DemoInsight(
            id: "notice-new-rule", kind: .notice, transactionReference: nil, sortOrder: 1,
            payload: encode(NoticePayload(variant: "newRule",
                                          text: "New rule: file every ‘SumUp *Kiosk’ payment under \(Cat.leisure)",
                                          sourceNumber: nil, actionTitle: "Create rule", transactionReferences: [],
                                          pattern: "SumUp *Kiosk", category: Cat.leisure, sources: []))))

        // Sources [1]–[4].
        var sources: [InsightSource] = []
        if let latest = amazonEarlier.last {
            sources.append(InsightSource(number: 1, dateText: DateFormats.dayMonthYear(latest.bookingDate),
                                         label: "\(amazonName), latest of \(amazonEarlier.count) filed under \(Cat.other)",
                                         amount: latest.amount, transactionReferences: [latest.reference]))
        }
        if let etsy = etsyEarlier.last {
            sources.append(InsightSource(number: 2, dateText: DateFormats.dayMonthYear(etsy.bookingDate),
                                         label: "PayPal *Etsy, filed under \(Cat.other)", amount: etsy.amount,
                                         transactionReferences: [etsy.reference]))
        }
        if let order = lieferando90 {
            sources.append(InsightSource(number: 3, dateText: DateFormats.dayMonthYear(order.bookingDate),
                                         label: "Lieferando, order for two", amount: order.amount,
                                         transactionReferences: [order.reference]))
        }
        if let (first, second) = duplicate {
            sources.append(InsightSource(number: 4, dateText: DateFormats.dayMonthYear(first.bookingDate),
                                         label: "Urban Sports Club, monthly membership", amount: first.amount,
                                         transactionReferences: [first.reference]))
            sources.append(InsightSource(number: 4, dateText: DateFormats.dayMonthYear(second.bookingDate),
                                         label: "Urban Sports Club, same amount one day later", amount: second.amount,
                                         transactionReferences: [second.reference]))
        }
        out.append(DemoInsight(
            id: "notice-sources", kind: .notice, transactionReference: nil, sortOrder: 2,
            payload: encode(NoticePayload(variant: "sources", text: "Sources", sourceNumber: nil, actionTitle: nil,
                                          transactionReferences: [], pattern: nil, category: nil, sources: sources))))
        return out
    }

    // MARK: October review

    private func review() -> DemoInsight {
        let year = 2026
        let month = 10
        func priorMonths() -> [(Int, Int)] { [(2026, 4), (2026, 5), (2026, 6), (2026, 7), (2026, 8), (2026, 9)] }
        func income(_ y: Int, _ m: Int) -> Int {
            let (a, b) = monthRange(y, m)
            return transactions.filter { category(of: $0) == Cat.income && $0.amount > 0 && $0.bookingDate >= a && $0.bookingDate <= b }
                .reduce(0) { $0 + $1.amount }
        }
        let incomeOct = income(year, month)
        let spendOct = monthSpending(nil, year, month)
        let savedOct = incomeOct - spendOct
        let prior = priorMonths()
        let incomeAvg = prior.reduce(0) { $0 + income($1.0, $1.1) } / prior.count
        let spendAvg = prior.reduce(0) { $0 + monthSpending(nil, $1.0, $1.1) } / prior.count
        let savedAvg = incomeAvg - spendAvg
        func avg(_ category: String) -> Int { prior.reduce(0) { $0 + monthSpending(category, $1.0, $1.1) } / prior.count }
        let leisureOct = monthSpending(Cat.leisure, year, month)
        let mobilityOct = monthSpending(Cat.mobility, year, month)
        let groceriesOct = monthSpending(Cat.groceries, year, month)
        let leisureAvg = avg(Cat.leisure)
        let mobilityAvg = avg(Cat.mobility)
        let groceriesAvg = avg(Cat.groceries)
        let added = (leisureOct - leisureAvg) + (mobilityOct - mobilityAvg)

        let lessThanUsual = savedOct < savedAvg
        let headline = "October closed with \(MoneyFormatter.string(savedOct)) saved — "
            + (lessThanUsual ? "less than usual" : "more than usual")
            + ", because eating out and the train to Frankfurt added \(euros(added))."

        // Rows cited as sources.
        let octFirst = LocalDate(year: 2026, month: 10, day: 1)
        let octLast = LocalDate(year: 2026, month: 10, day: 31)
        let lastWeek = spending(category: Cat.leisure, from: LocalDate(year: 2026, month: 10, day: 25), to: octLast)
            .filter { $0.shortName == "Lieferando" }
        let cafe = spending(category: Cat.leisure, from: octFirst, to: octLast).filter { $0.shortName == "Café Fassbender" }
        let trains = spending(category: Cat.mobility, from: octFirst, to: octLast)
            .filter { $0.shortName == "Deutsche Bahn" && $0.purpose.contains("Frankfurt") }
            .sorted { $0.bookingDate < $1.bookingDate }
        let groceryRows = spending(category: Cat.groceries, from: octFirst, to: octLast)

        let trainDates = trains.map { DateFormats.dayMonth($0.bookingDate) }
        let trainDetail = "ICE Köln–Frankfurt " + (trains.count == 2 ? "twice" : "\(trains.count) times") + ", on "
            + (trainDates.count >= 2 ? trainDates.dropLast().joined(separator: ", ") + " and " + (trainDates.last ?? "") : trainDates.joined())
        let groceriesDelta = groceriesOct - groceriesAvg
        let withinTen = abs(Double(groceriesDelta)) <= Double(groceriesAvg) * 0.10
        let groceriesTitle = withinTen
            ? "Groceries: \(euros(groceriesOct)), on average"
            : "Groceries: \(euros(groceriesOct)) vs \(euros(groceriesAvg)) average"

        let findings = [
            ReviewFinding(number: 1, title: "Eating out: \(euros(leisureOct)) vs \(euros(leisureAvg)) average",
                          detail: "Mostly Lieferando in the last week of October.", deltaText: signedEuros(leisureOct - leisureAvg),
                          deltaAmount: leisureOct - leisureAvg, sourceNumbers: [1, 2]),
            ReviewFinding(number: 2, title: "Mobility: \(euros(mobilityOct)) vs \(euros(mobilityAvg)) average",
                          detail: trainDetail, deltaText: signedEuros(mobilityOct - mobilityAvg),
                          deltaAmount: mobilityOct - mobilityAvg, sourceNumbers: [3]),
            ReviewFinding(number: 3, title: groceriesTitle, detail: "REWE and Edeka, in line with the last six months.",
                          deltaText: signedEuros(groceriesDelta), deltaAmount: groceriesDelta, sourceNumbers: [4]),
        ]
        let sources = [
            InsightSource(number: 1, dateText: "25.–31.10.2026", label: "Lieferando, \(lastWeek.count) orders", amount: -sum(lastWeek),
                          transactionReferences: refs(lastWeek)),
            InsightSource(number: 2, dateText: cafe.first.map { DateFormats.dayMonthYear($0.bookingDate) } ?? "",
                          label: "Café Fassbender", amount: -sum(cafe), transactionReferences: refs(cafe)),
            InsightSource(number: 3, dateText: trains.map { DemoText.two($0.bookingDate.day) + "." }.joined(separator: " + ") + "10.2026",
                          label: "Deutsche Bahn, ICE Köln–Frankfurt ×\(trains.count)", amount: -sum(trains),
                          transactionReferences: refs(trains)),
            InsightSource(number: 4, dateText: "01.–31.10.2026", label: "REWE and Edeka, \(groceryRows.count) purchases",
                          amount: -sum(groceryRows), transactionReferences: refs(groceryRows)),
        ]

        let outlook = forecast()
        let balance = outlook.todayBalance
        let move = max(50_000, ((balance - 140_000) / 50_000) * 50_000)
        let steps = [
            ReviewStep(title: "Move \(euros(move)) to Tagesgeld before rent is due? You'd still keep \(euros(balance - move)) buffer.",
                       detail: "Nothing moves until you confirm with pushTAN.", actionTitle: "Prepare transfer", sourceNumber: nil),
            ReviewStep(title: "Lieferando: \(lastWeek.count) orders in the last week of October. Set a weekly reminder?",
                       detail: "\(MoneyFormatter.string(sum(lastWeek))) in those \(numberWord(lastWeek.count)) orders.",
                       actionTitle: "Set reminder", sourceNumber: 1),
        ]
        let payload = ReviewPayload(
            month: LocalDate(year: year, month: month, day: 1), headline: headline,
            rows: [ReviewRow(label: "Income", month: incomeOct, average: incomeAvg),
                   ReviewRow(label: "Spending", month: -spendOct, average: -spendAvg),
                   ReviewRow(label: "Saved", month: savedOct, average: savedAvg)],
            findings: findings, sources: sources, outlook: outlook, steps: steps)
        return DemoInsight(id: "review-2026-10", kind: .review, transactionReference: nil, sortOrder: 0, payload: encode(payload))
    }

    /// Girokonto balance from today to 30.11. from the scheduled rows and the average everyday spending.
    private func forecast() -> ReviewOutlook {
        let giro = accounts.first { $0.id == DemoAccountID.giro }
        let start = giro?.balance ?? 0
        let fixedNames: Set<String> = ["HUK-COBURG", "KVB Deutschlandticket", "Miete Wohnbau Ehrenfeld eG", "Urban Sports Club",
                                       "Stadtwerke Köln", "Telekom Deutschland", "ARD ZDF Rundfunkbeitrag"]
        let from = LocalDate(year: 2026, month: 8, day: 1)
        let to = LocalDate(year: 2026, month: 10, day: 31)
        let everyday = transactions.filter { transaction in
            transaction.accountID == DemoAccountID.giro && isSpending(transaction) && !fixedNames.contains(transaction.shortName)
                && transaction.bookingDate >= from && transaction.bookingDate <= to
        }.reduce(0) { $0 - $1.amount }
        let perDay = everyday / (to - from + 1)

        // Scheduled rows on the Girokonto after today until 01.12.
        let horizon = LocalDate(year: 2026, month: 12, day: 1)
        var events: [(LocalDate, Int)] = []
        let providers = Set(contracts.map(\.provider))
        for contract in contracts where contract.accountID == DemoAccountID.giro && contract.nextDebit > today && contract.nextDebit <= horizon {
            events.append((contract.nextDebit, contract.monthlyAmount))
        }
        for order in standingOrders where order.accountID == DemoAccountID.giro && order.status != .paused && !providers.contains(order.recipient) {
            if let next = order.nextExecution, next > today, next <= horizon { events.append((next, order.amount)) }
        }
        let statement = transactions.filter { $0.accountID == DemoAccountID.visa }
            .filter { $0.bookingDate > LocalDate(year: 2026, month: 10, day: 20) }.reduce(0) { $0 + $1.amount }
        events.append((LocalDate(year: 2026, month: 11, day: 20), statement))

        var days: [ForecastDay] = []
        var lowest = Int.max
        var lowestDate = today
        let end = LocalDate(year: 2026, month: 11, day: 30)
        var balanceAtEnd = start
        var day = today
        while day <= end {
            let elapsed = day - today
            let scheduled = events.filter { $0.0 <= day }.reduce(0) { $0 + $1.1 }
            let expected = start - perDay * elapsed + scheduled
            let band = perDay * elapsed * 3 / 10
            days.append(ForecastDay(date: day, expected: expected, low: expected - band, high: expected + band))
            if expected < lowest { lowest = expected; lowestDate = day }
            if day == end { balanceAtEnd = expected }
            day = day.adding(days: 1)
        }
        let band = perDay * (end - today) * 3 / 10
        let rangeLow = ((balanceAtEnd - band) / 5_000) * 5_000
        let rangeHigh = ((balanceAtEnd + band + 4_999) / 5_000) * 5_000
        let salary = contracts.first { $0.kind == .income }
        let rent = contracts.first { $0.provider.hasPrefix("Miete") }
        let rentAmount = rent?.monthlyAmount ?? -112_000
        return ReviewOutlook(
            todayBalance: start, salaryDate: salary?.nextDebit ?? today, salaryAmount: salary?.monthlyAmount ?? 0,
            lowestAmount: lowest, lowestDate: lowestDate, endDate: end, expectedEnd: balanceAtEnd, rangeLow: rangeLow,
            rangeHigh: rangeHigh,
            lowestText: "Lowest \(euros(lowest)) on \(DateFormats.dayMonth(lowestDate))",
            rangeText: "Likely \(wholeNumber(rangeLow))–\(wholeNumber(rangeHigh)) € on \(DateFormats.dayMonth(end))",
            rentText: "Then Miete \(MoneyFormatter.string(rentAmount)) is booked on \(DateFormats.dayMonth(rent?.nextDebit ?? horizon))",
            days: days)
    }

    // MARK: Tax return

    private func tax() -> DemoInsight {
        let year2026 = LocalDate(year: 2026, month: 1, day: 1)
        func one(_ short: String, purposePrefix: String? = nil, from: LocalDate? = nil, to: LocalDate? = nil) -> [BankTransaction] {
            transactions.filter { transaction in
                guard transaction.shortName == short, transaction.bookingDate >= (from ?? year2026) else { return false }
                if let to, transaction.bookingDate > to { return false }
                if let purposePrefix { return transaction.purpose.hasPrefix(purposePrefix) }
                return true
            }.sorted { $0.bookingDate < $1.bookingDate }
        }
        let apple = one("Apple Store")
        let bahnCard = one("Deutsche Bahn", purposePrefix: "BahnCard")
        let course = one("Rheinwerk Weiterbildung")
        let carpenter = one("Schreinerei Kaiser GmbH")
        let donations = one("Ärzte ohne Grenzen e.V.")
        let hukCar = one("HUK-COBURG", purposePrefix: "Kfz-Versicherung", to: today)
        let hukPrivate = one("HUK-COBURG", purposePrefix: "Haftpflichtversicherung")

        func item(_ rows: [BankTransaction], payee: String, purpose: String, why: String, receipt: String, label: String,
                  eligible: Int? = nil, source: Int? = nil) -> TaxItem {
            TaxItem(transactionReferences: refs(rows), date: rows.first?.bookingDate ?? today, payee: payee, purpose: purpose,
                    why: why, receipt: receipt, receiptLabel: label, amount: rows.reduce(0) { $0 + $1.amount },
                    eligibleAmount: eligible, sourceNumber: source)
        }
        // DB tickets of 2026 (BahnCard excluded): how many were weekday trips Köln – Frankfurt.
        let tickets = transactions.filter { $0.shortName == "Deutsche Bahn" && $0.bookingDate >= year2026 && !$0.purpose.hasPrefix("BahnCard") }
        let frankfurt = tickets.filter { $0.purpose.contains("Frankfurt") && ($0.bookingDate.weekday >= 2 && $0.bookingDate.weekday <= 6) }

        let attached = "Receipt attached"
        let needed = "Needs receipt"
        var groups: [TaxGroup] = []
        func group(_ form: String, _ items: [TaxItem]) {
            let total = items.reduce(0) { $0 - $1.amount }
            groups.append(TaxGroup(form: form, itemCountText: items.count == 1 ? "1 item" : "\(items.count) items", total: total, items: items))
        }
        group("Anlage N — Werbungskosten", [
            item(apple, payee: "Apple Store", purpose: "MacBook Air 13″", why: "Work equipment, written off in 2026",
                 receipt: "attached", label: attached),
            item(bahnCard, payee: "Deutsche Bahn", purpose: "BahnCard 50, 2. Klasse", why: "Mostly business trips",
                 receipt: "needed", label: needed, source: 1),
            item(course, payee: "Rheinwerk Weiterbildung", purpose: "Typografie-Kurs, 3 Tage",
                 why: "Further training for your current job", receipt: "attached", label: attached),
        ])
        group("Haushaltsnahe Dienstleistungen (§ 35a)", [
            item(carpenter, payee: "Schreinerei Kaiser GmbH", purpose: "Einbauschrank Flur, Rechnung 2026-054",
                 why: "Labour on the invoice counts as a household service",
                 receipt: "attached", label: attached, source: 2),
        ])
        group("Sonderausgaben — Spenden", [
            item(Array(donations.prefix(1)), payee: "Ärzte ohne Grenzen e.V.", purpose: "Spende Nothilfe",
                 why: "Under 300 €: bank statement is enough", receipt: "statementEnough", label: "Statement is enough"),
            item(Array(donations.dropFirst().prefix(1)), payee: "Ärzte ohne Grenzen e.V.", purpose: "No purpose on the transfer",
                 why: "No purpose line, so ask for a donation receipt", receipt: "needed", label: needed),
        ])
        group("Vorsorgeaufwendungen", [
            item(hukCar, payee: "HUK-COBURG", purpose: "Kfz-Haftpflicht K-LH 2048 · \(hukCar.count) monthly payments",
                 why: "Car liability insurance counts as Vorsorge", receipt: "attached", label: attached),
            item(hukPrivate, payee: "HUK-COBURG", purpose: "Haftpflichtversicherung privat",
                 why: "Private liability insurance counts as Vorsorge", receipt: "needed", label: needed),
        ])
        let items = groups.flatMap(\.items)
        let total = groups.reduce(0) { $0 + $1.total }
        let withReceipts = items.filter { $0.receipt == "attached" }.count
        let needsReceipt = items.filter { $0.receipt == "needed" }.count
        let footnotes = [
            InsightSource(number: 1, dateText: "",
                          label: "\(frankfurt.count) of \(tickets.count) Deutsche Bahn tickets in 2026 were weekday trips Köln – Frankfurt.",
                          amount: nil, transactionReferences: refs(frankfurt)),
            InsightSource(number: 2, dateText: "", label: "Rechnung Schreinerei Kaiser 2026-054, line “Arbeitslohn”.",
                          amount: nil, transactionReferences: refs(carpenter)),
        ]
        let payload = TaxPayload(
            year: 2026, total: total, totalCaption: "possible deductions found so far, grouped by form",
            summary: "\(items.count) items from Girokonto and Visa Card, \(withReceipts) with receipts", itemCount: items.count,
            formCount: groups.count, needsReceiptCount: needsReceipt, groups: groups, footnotes: footnotes,
            disclaimer: "IMM collects and sorts; it doesn't give tax advice. Check the totals before you file.")
        return DemoInsight(id: "tax-2026", kind: .tax, transactionReference: nil, sortOrder: 0, payload: encode(payload))
    }
}
