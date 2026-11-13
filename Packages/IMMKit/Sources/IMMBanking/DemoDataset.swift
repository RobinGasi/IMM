import Foundation
import IMMLedger

/// The one place the demo ledger is defined: a deterministic builder (fixed seeds, no clock, no system
/// randomness) producing the bank snapshot and the profile, plus the JSON resource that ships with the app.
public enum DemoDataset {
    /// While a database holds only demo-bank data the ledger treats this day as today.
    public static let today = LocalDate(year: 2026, month: 11, day: 12)

    /// Net worth on 31.10.2026 (the Overview says "+1.204,18 € since October" against 63.058,54 €).
    static let netWorthOctober31 = 6_185_436

    public enum LoadError: Error, Equatable {
        case resourceMissing
    }

    // MARK: Public API

    /// Builds the data set. Two calls return equal values (and byte-identical `encode` output).
    public static func build() -> DemoBank {
        let history = DemoDepot.history()
        let depotOctober31 = history.first { $0.date == LocalDate(year: 2026, month: 10, day: 31) }?.value ?? 0

        // Balances on 31.10.2026 follow from today's balances and the literal November rows.
        let giroOctober31 = 241_836 + 152_643
        let paypalOctober31 = 6_190 + 13_354
        let visaOctober31 = 0
        // The Tagesgeld receives a tax refund on 06.11.2026 whose amount balances the 31.10. net worth.
        let tagesgeldToday = 1_205_000
        let tagesgeldOctober31 = netWorthOctober31 - giroOctober31 - paypalOctober31 - visaOctober31 - depotOctober31
        let taxRefund = tagesgeldToday - tagesgeldOctober31

        // The Girokonto has exactly 148 rows in the last 90 days. The random placement of the generated rows
        // makes the count jump, so two knobs (September groceries and leisure) are searched in a fixed order.
        var chosen: DemoLedgerBuilder?
        search: for groceries in 36...52 {
            for leisure in 8...16 {
                var builder = DemoLedgerBuilder(sepGroceryCount: groceries, sepLeisureCount: leisure, taxRefund: taxRefund)
                builder.build()
                chosen = builder
                if giroWindowCount(builder.drafts) == 148 { break search }
            }
        }
        let drafts = chosen?.drafts ?? []
        return assemble(drafts: drafts, history: history)
    }

    /// Canonical JSON of a data set: sorted keys, pretty printed, ISO 8601 dates.
    public static func encode(_ bank: DemoBank) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // Encoding plain value types cannot fail.
        return (try? encoder.encode(bank)) ?? Data()
    }

    /// Decodes a data set written by `encode`.
    public static func decode(_ data: Data) throws -> DemoBank {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DemoBank.self, from: data)
    }

    /// Loads `Resources/DemoBank.json` from the module bundle.
    public static func load() throws -> DemoBank {
        guard let url = Bundle.module.url(forResource: "DemoBank", withExtension: "json") else {
            throw LoadError.resourceMissing
        }
        return try decode(Data(contentsOf: url))
    }

    // MARK: Assembly

    private static func giroWindowCount(_ drafts: [Draft]) -> Int {
        let from = LocalDate(year: 2026, month: 8, day: 14)
        return drafts.filter { $0.account == DemoAccountID.giro && $0.date >= from && $0.date <= today }.count
    }

    private static func assemble(drafts: [Draft], history: [BankDepotValuePoint]) -> DemoBank {
        // References and sequence numbers.
        let prefixes: [String: String] = [
            DemoAccountID.giro: "GIRO", DemoAccountID.tagesgeld: "TAG", DemoAccountID.visa: "VISA",
            DemoAccountID.paypal: "PP", DemoAccountID.depot: "DEP",
        ]
        var transactions: [BankTransaction] = []
        var categoryByReference: [String: String] = [:]
        var ownTransfers: [String] = []
        var references: [Int: String] = [:]
        for accountID in DemoAccountID.all {
            let indices = drafts.indices.filter { drafts[$0].account == accountID }
            let sorted = indices.sorted { drafts[$0].sorts(before: drafts[$1]) }
            var sequence = 0
            var lastDate: LocalDate?
            for index in sorted {
                let draft = drafts[index]
                if draft.date == lastDate { sequence += 1 } else { sequence = 1; lastDate = draft.date }
                let reference = "DEMO-" + (prefixes[accountID] ?? "ACC") + "-" + dateKey(draft.date) + "-" + DemoText.two(sequence)
                references[index] = reference
                transactions.append(BankTransaction(
                    reference: reference, accountID: accountID, bookingDate: draft.date, valueDate: draft.date,
                    bookedTime: draft.time, sequence: sequence, amount: draft.amount, currency: "EUR",
                    counterpartyName: draft.name, shortName: draft.short, counterpartyIBAN: draft.iban,
                    bookingText: draft.bookingText, purpose: draft.purpose, creditorID: draft.creditorID, kind: draft.kind))
                if let category = draft.category { categoryByReference[reference] = category }
                if draft.ownTransfer { ownTransfers.append(reference) }
            }
        }

        // The 14 new rows: REWE 11.11., Lieferando 10.11., dm 09.11. and the 11 most recent Visa and PayPal rows.
        var newReferences: [String] = []
        for transaction in transactions where transaction.accountID == DemoAccountID.giro && transaction.bookingDate.year == 2026
            && transaction.bookingDate.month == 11 && ["REWE", "Lieferando", "dm-drogerie markt"].contains(transaction.shortName)
            && transaction.bookingDate.day >= 9 {
            newReferences.append(transaction.reference)
        }
        let cards = transactions.filter { $0.accountID == DemoAccountID.visa || $0.accountID == DemoAccountID.paypal }
            .sorted { lhs, rhs in
                if lhs.bookingDate != rhs.bookingDate { return lhs.bookingDate > rhs.bookingDate }
                if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
                return lhs.reference > rhs.reference
            }
        for transaction in cards.prefix(11) { newReferences.append(transaction.reference) }

        let accounts = makeAccounts()
        let snapshot = BankSnapshot(accounts: accounts, transactions: transactions, standingOrders: makeStandingOrders(),
                                    holdings: DemoDepot.holdings(), depotValueHistory: history)
        let contracts = makeContracts()
        let insights = DemoInsightBuilder(transactions: transactions, categoryByReference: categoryByReference,
                                          ownTransfers: Set(ownTransfers), contracts: contracts,
                                          standingOrders: snapshot.standingOrders, accounts: accounts).build()
        let profile = DemoProfile(
            ledgerToday: today, logins: makeLogins(), categories: makeCategories(),
            categoryByReference: categoryByReference, ownTransferReferences: ownTransfers.sorted(),
            newReferences: newReferences.sorted(), rules: makeRules(), budgets: makeBudgets(), fixedCosts: makeFixedCosts(),
            contracts: contracts, savingsPlan: makeSavingsPlan(), fundRegionWeights: DemoDepot.regionWeights, insights: insights)
        return DemoBank(snapshot: snapshot, profile: profile)
    }

    private static func dateKey(_ date: LocalDate) -> String {
        String(date.year) + DemoText.two(date.month) + DemoText.two(date.day)
    }

    private static func makeAccounts() -> [BankAccount] {
        [
            BankAccount(id: DemoAccountID.giro, kind: .giro, name: "Girokonto", bankName: "Sparkasse KölnBonn",
                        iban: DemoIBANs.giro, number: nil,
                        subtitle: "Sparkasse KölnBonn · " + IBAN.formatted(DemoIBANs.giro), balance: 241_836,
                        overdraftLimit: 200_000, statementNote: nil, loginKey: "sparkasse", sortOrder: 0),
            BankAccount(id: DemoAccountID.tagesgeld, kind: .savings, name: "Tagesgeld", bankName: "Sparkasse KölnBonn",
                        iban: DemoIBANs.tagesgeld, number: nil,
                        subtitle: "Sparkasse KölnBonn · " + IBAN.formatted(DemoIBANs.tagesgeld), balance: 1_205_000,
                        overdraftLimit: nil, statementNote: nil, loginKey: "sparkasse", sortOrder: 1),
            BankAccount(id: DemoAccountID.visa, kind: .creditCard, name: "Visa Card", bankName: "DKB", iban: nil,
                        number: "•••• 4417", subtitle: "DKB · Statement 20.11.", balance: -38_412, overdraftLimit: nil,
                        statementNote: "Statement 20.11.", loginKey: "dkb", sortOrder: 2),
            BankAccount(id: DemoAccountID.depot, kind: .depot, name: "Depot", bankName: "ING", iban: DemoIBANs.depot,
                        number: "5402 1187", subtitle: "ING · Depot 5402 1187", balance: 4_891_240, overdraftLimit: nil,
                        statementNote: nil, loginKey: "ing", sortOrder: 3),
            BankAccount(id: DemoAccountID.paypal, kind: .wallet, name: "Wallet", bankName: "PayPal", iban: nil, number: nil,
                        subtitle: "PayPal", balance: 6_190, overdraftLimit: nil, statementNote: nil, loginKey: "paypal",
                        sortOrder: 4),
        ]
    }

    private static func makeLogins() -> [DemoBankLogin] {
        [
            DemoBankLogin(id: "sparkasse", connectorID: DemoConnector.connectorID, bankName: "Sparkasse KölnBonn",
                          bankCode: "37050198", loginName: "41093872", tanMethod: "pushTAN — S-pushTAN app",
                          accountIDs: [DemoAccountID.giro, DemoAccountID.tagesgeld]),
            DemoBankLogin(id: "dkb", connectorID: DemoConnector.connectorID, bankName: "DKB", bankCode: "12030000",
                          loginName: "robin-dkb", tanMethod: "pushTAN — DKB app", accountIDs: [DemoAccountID.visa]),
            DemoBankLogin(id: "ing", connectorID: DemoConnector.connectorID, bankName: "ING", bankCode: "50010517",
                          loginName: "robin-ing", tanMethod: "pushTAN — ING app", accountIDs: [DemoAccountID.depot]),
            DemoBankLogin(id: "paypal", connectorID: DemoConnector.connectorID, bankName: "PayPal", bankCode: "",
                          loginName: "robin@example.com", tanMethod: "PayPal login", accountIDs: [DemoAccountID.paypal]),
        ]
    }

    private static func makeCategories() -> [DemoCategory] {
        [
            DemoCategory(name: Cat.housing, colorToken: "chart-1", kind: .expense, sortOrder: 0),
            DemoCategory(name: Cat.groceries, colorToken: "chart-5", kind: .expense, sortOrder: 1),
            DemoCategory(name: Cat.mobility, colorToken: "chart-3", kind: .expense, sortOrder: 2),
            DemoCategory(name: Cat.leisure, colorToken: "chart-2", kind: .expense, sortOrder: 3),
            DemoCategory(name: Cat.insurance, colorToken: "chart-4", kind: .expense, sortOrder: 4),
            DemoCategory(name: Cat.health, colorToken: "muted-foreground", kind: .expense, sortOrder: 5),
            DemoCategory(name: Cat.other, colorToken: "input", kind: .expense, sortOrder: 6),
            DemoCategory(name: Cat.income, colorToken: "credit", kind: .income, sortOrder: 7),
        ]
    }

    /// 34 rules.
    private static func makeRules() -> [DemoRule] {
        let table: [(String, String)] = [
            ("REWE", Cat.groceries), ("EDEKA", Cat.groceries), ("ALDI SÜD", Cat.groceries), ("Kaufland", Cat.groceries),
            ("dm-drogerie markt", Cat.groceries),
            ("Lieferando", Cat.leisure), ("Café Fassbender", Cat.leisure), ("Brauhaus Päffgen", Cat.leisure),
            ("Cinedom", Cat.leisure), ("Urban Sports Club", Cat.leisure), ("Steam", Cat.leisure),
            ("Deutsche Bahn", Cat.mobility), ("Aral", Cat.mobility), ("Q-Park", Cat.mobility), ("KVB", Cat.mobility),
            ("Wohnbau Ehrenfeld", Cat.housing), ("Stadtwerke Köln", Cat.housing),
            ("HUK-COBURG", Cat.insurance), ("Telekom", Cat.insurance), ("ARD ZDF", Cat.insurance), ("Spotify", Cat.insurance),
            ("Apotheke am Neumarkt", Cat.health), ("Rossmann", Cat.health), ("Physiotherapie Hoffmann", Cat.health),
            ("Amazon", Cat.other), ("Hornbach", Cat.other), ("IKEA", Cat.other), ("Thalia", Cat.other),
            ("Bargeldauszahlung", Cat.other), ("Rheinwerk Weiterbildung", Cat.other), ("Ärzte ohne Grenzen", Cat.other),
            ("Rheinwerk Design GmbH", Cat.income), ("Zinsen Tagesgeld", Cat.income), ("Finanzamt", Cat.income),
        ]
        return table.enumerated().map { index, row in
            DemoRule(pattern: row.0, category: row.1, origin: index % 3 == 0 ? "manual" : "learned", enabled: true)
        }
    }

    private static func makeBudgets() -> [DemoBudget] {
        [
            DemoBudget(category: Cat.groceries, monthlyLimit: 42_000),
            DemoBudget(category: Cat.leisure, monthlyLimit: 15_000),
            DemoBudget(category: Cat.mobility, monthlyLimit: 22_000),
            DemoBudget(category: Cat.health, monthlyLimit: 6_000),
            DemoBudget(category: Cat.other, monthlyLimit: 15_000),
        ]
    }

    private static func makeFixedCosts() -> [DemoFixedCost] {
        [
            DemoFixedCost(label: "Rent, Wohnbau Ehrenfeld", amount: 112_000, items: []),
            DemoFixedCost(label: "Electricity, Stadtwerke Köln", amount: 8_600, items: []),
            DemoFixedCost(label: "Contracts & insurance", amount: 11_300, items: [
                DemoFixedCostItem(label: "ARD ZDF Rundfunkbeitrag", amount: 1_836),
                DemoFixedCostItem(label: "HUK-COBURG", amount: 3_870),
                DemoFixedCostItem(label: "Telekom Deutschland", amount: 4_495),
                DemoFixedCostItem(label: "Spotify", amount: 1_099),
            ]),
        ]
    }

    private static func makeStandingOrders() -> [BankStandingOrder] {
        let giro = DemoAccountID.giro
        func day(_ y: Int, _ m: Int, _ d: Int) -> LocalDate { LocalDate(year: y, month: m, day: d) }
        return [
            BankStandingOrder(id: "so-etf-sparplan", accountID: giro, recipient: "ETF-Sparplan ING Depot", iban: DemoIBANs.depot,
                              purpose: "Sparplan Depot 5402 1187", amount: -50_000, rhythm: .monthly, dayOfMonth: 15,
                              nextExecution: day(2026, 11, 15), status: .active),
            BankStandingOrder(id: "so-jonas-weber", accountID: giro, recipient: "Jonas Weber", iban: DemoIBANs.jonas,
                              purpose: "Konzertkarten Dezember", amount: -12_000, rhythm: .once, dayOfMonth: nil,
                              nextExecution: day(2026, 11, 20), status: .scheduled),
            BankStandingOrder(id: "so-tagesgeld-sparen", accountID: giro, recipient: "Tagesgeld Sparen", iban: DemoIBANs.tagesgeld,
                              purpose: "Monatliche Sparrate", amount: -30_000, rhythm: .monthly, dayOfMonth: 28,
                              nextExecution: day(2026, 11, 28), status: .active),
            BankStandingOrder(id: "so-miete", accountID: giro, recipient: "Miete Wohnbau Ehrenfeld eG", iban: DemoIBANs.miete,
                              purpose: "Miete Venloer Str. 3. OG", amount: -112_000, rhythm: .monthly, dayOfMonth: 1,
                              nextExecution: day(2026, 12, 1), status: .active),
            BankStandingOrder(id: "so-mia-hoffmann", accountID: giro, recipient: "Mia Hoffmann", iban: DemoIBANs.mia,
                              purpose: "Taschengeld", amount: -4_000, rhythm: .monthly, dayOfMonth: 1,
                              nextExecution: day(2026, 12, 1), status: .active),
            BankStandingOrder(id: "so-fitnessstudio", accountID: giro, recipient: "Fitnessstudio Altvertrag", iban: DemoIBANs.fitness,
                              purpose: "Mitgliedsbeitrag", amount: -2_990, rhythm: .monthly, dayOfMonth: 1,
                              nextExecution: nil, status: .paused),
        ]
    }

    private static func makeContracts() -> [DemoContract] {
        func day(_ y: Int, _ m: Int, _ d: Int) -> LocalDate { LocalDate(year: y, month: m, day: d) }
        let giro = DemoAccountID.giro
        func contract(_ id: String, _ provider: String, _ account: String, _ group: String, _ category: String, _ amount: Int,
                      next: LocalDate, notice: String, deadline: LocalDate? = nil, renewal: LocalDate? = nil,
                      newAmount: Int? = nil, newStart: LocalDate? = nil, kind: DemoContractKind = .contract) -> DemoContract {
            DemoContract(id: id, provider: provider, accountID: account, groupName: group, category: category, rhythm: "monthly",
                         monthlyAmount: amount, nextDebit: next, noticeText: notice, noticeDeadline: deadline, renewalDate: renewal,
                         priceChangeAmount: newAmount, priceChangeStart: newStart, kind: kind)
        }
        return [
            contract("contract-miete", "Miete Wohnbau Ehrenfeld eG", giro, "Housing", Cat.housing, -112_000,
                     next: day(2026, 12, 1), notice: "3 months"),
            contract("contract-strom", "Stadtwerke Köln Strom", giro, "Housing", Cat.housing, -8_600,
                     next: day(2026, 12, 5), notice: "1 month"),
            contract("contract-ard", "ARD ZDF Rundfunkbeitrag", giro, "Housing", Cat.insurance, -1_836,
                     next: day(2026, 11, 15), notice: "Statutory, no notice"),
            contract("contract-huk", "HUK-COBURG Kfz", giro, "Insurance", Cat.insurance, -3_870,
                     next: day(2026, 12, 1), notice: "1 month, by 30.11.2026", deadline: day(2026, 11, 30),
                     renewal: day(2027, 1, 1)),
            contract("contract-telekom", "Telekom Deutschland", giro, "Communication & media", Cat.insurance, -4_495,
                     next: day(2026, 11, 15), notice: "1 month"),
            contract("contract-spotify", "Spotify", DemoAccountID.paypal, "Communication & media", Cat.insurance, -1_099,
                     next: day(2026, 11, 21), notice: "Any time", newAmount: -1_199, newStart: day(2026, 12, 1)),
            contract("contract-kvb", "KVB Deutschlandticket", giro, "Mobility & sport", Cat.mobility, -5_800,
                     next: day(2026, 12, 1), notice: "Monthly, by the 10th"),
            contract("contract-urban", "Urban Sports Club", giro, "Mobility & sport", Cat.leisure, -6_400,
                     next: day(2026, 12, 3), notice: "1 month"),
            contract("income-gehalt", "Gehalt Rheinwerk Design GmbH", giro, "Income", Cat.income, 384_000,
                     next: day(2026, 11, 27), notice: "", kind: .income),
        ]
    }

    private static func makeSavingsPlan() -> DemoSavingsPlan {
        DemoSavingsPlan(
            depotAccountID: DemoAccountID.depot, sourceAccountID: DemoAccountID.giro, monthlyAmount: 50_000, dayOfMonth: 15,
            nextExecution: LocalDate(year: 2026, month: 11, day: 15),
            items: [
                DemoSavingsPlanItem(isin: DemoDepot.world.isin, name: DemoDepot.world.name, sharePercent: 60, amount: 30_000),
                DemoSavingsPlanItem(isin: DemoDepot.allWorld.isin, name: DemoDepot.allWorld.name, sharePercent: 40, amount: 20_000),
            ])
    }
}
