import Foundation
import IMMLedger

/// Monthly spending targets in minor units per category. Housing (1.206,00) and contracts (113,00) are
/// fixed rows; `m` includes the KVB ticket (58,00) and `l` the Urban Sports Club fee (64,00).
struct MonthSpec {
    var g: Int
    var l: Int
    var m: Int
    var h: Int
    /// Nil = filled by the builder (pinned items plus a random remainder, or the balancer month).
    var o: Int?
    var extraContracts: Int = 0
}

enum DemoTables {
    static let monthCount = 22          // 2025-01 … 2026-10
    static let decIndex = 11
    static let febIndex = 13
    static let sepIndex = 20
    static let octIndex = 21
    static let housing = 120_600
    static let contracts = 11_300
    static let kvb = 5_800
    static let urban = 6_400
    /// 11 complete months before November 2026 average exactly 2.480,00.
    static let meanTotal = 2_728_000

    static func year(_ index: Int) -> Int { 2025 + index / 12 }
    static func month(_ index: Int) -> Int { index % 12 + 1 }
    static func index(of date: LocalDate) -> Int { (date.year - 2025) * 12 + date.month - 1 }

    static func spec(_ index: Int) -> MonthSpec {
        switch index {
        case 11: return MonthSpec(g: 44_000, l: 30_000, m: 16_000, h: 5_000, o: 41_600)
        case 12: return MonthSpec(g: 38_000, l: 23_000, m: 30_200, h: 3_000, o: 6_000, extraContracts: 3_760)
        case 13: return MonthSpec(g: 33_000, l: 23_000, m: 11_000, h: 2_500, o: nil)
        case 14: return MonthSpec(g: 29_500, l: 22_000, m: 9_000, h: 2_400, o: 89_900)
        case 15: return MonthSpec(g: 38_000, l: 30_000, m: 13_000, h: 4_000, o: 16_000)
        case 16: return MonthSpec(g: 38_500, l: 29_000, m: 13_000, h: 3_000, o: 11_000)
        case 17: return MonthSpec(g: 33_000, l: 24_000, m: 12_000, h: 2_000, o: 67_745)
        case 18: return MonthSpec(g: 38_500, l: 30_000, m: 14_000, h: 4_000, o: 11_000)
        case 19: return MonthSpec(g: 38_000, l: 28_000, m: 13_000, h: 3_000, o: 11_000)
        case 20: return MonthSpec(g: 39_000, l: 30_000, m: 13_000, h: 4_000, o: 37_100)
        case 21: return MonthSpec(g: 40_100, l: 48_600, m: 26_800, h: 6_600, o: 24_000)
        default:
            // 2025: invented months, leisure of June to October fixed so the year-on-year comparison on the Ask
            // screen lands near +18 %.
            var rng = SplitMix64(seed: 0xA5A5_0000 &+ UInt64(index) &* 7919)
            let leisure2025 = [25_000, 25_500, 24_500, 27_000, 38_300]
            let l = (5...9).contains(index) ? leisure2025[index - 5] : urban + rng.int(15_000...32_000)
            return MonthSpec(g: rng.int(32_000...43_000), l: l, m: kvb + rng.int(4_000...13_000),
                             h: rng.int(2_000...7_000), o: nil)
        }
    }
}

/// Builds every transaction draft of the demo ledger.
struct DemoLedgerBuilder {
    let sepGroceryCount: Int
    /// Second knob of the 148-row search: number of leisure payments in September 2026.
    let sepLeisureCount: Int
    /// Amount (minor units) of the tax refund that lands on the Tagesgeld on 06.11.2026.
    let taxRefund: Int
    private(set) var drafts: [Draft] = []

    static let today = LocalDate(year: 2026, month: 11, day: 12)

    init(sepGroceryCount: Int, sepLeisureCount: Int = 12, taxRefund: Int) {
        self.sepGroceryCount = sepGroceryCount
        self.sepLeisureCount = sepLeisureCount
        self.taxRefund = taxRefund
    }

    // MARK: Entry point

    mutating func build() {
        for index in 0..<DemoTables.monthCount {
            addFixedRows(index)
        }
        let pins = Self.pinned()
        drafts.append(contentsOf: pins)
        generateSpending(pins: pins)
        addNovember()
        addVisaSettlements()
        addPayPalTopUps()
        addTagesgeldAndTransfers()
    }

    // MARK: Fixed monthly rows

    private mutating func addFixedRows(_ index: Int) {
        let y = DemoTables.year(index)
        let mo = DemoTables.month(index)
        let slash = DemoText.two(mo) + "/" + String(y)
        func date(_ day: Int) -> LocalDate { LocalDate(year: y, month: mo, day: day) }
        let giro = DemoAccountID.giro

        drafts.append(Draft(account: giro, date: date(1), time: nil, order: 1, amount: -3_870, name: "HUK-COBURG Versicherungsgruppe",
                            short: "HUK-COBURG", iban: DemoIBANs.huk, bookingText: "Lastschrift",
                            purpose: "Kfz-Versicherung · Beitrag \(slash) · Lastschrift", creditorID: "DE46ZZZ00000014237",
                            kind: .directDebit, category: Cat.insurance, ownTransfer: false))
        drafts.append(Draft(account: giro, date: date(1), time: nil, order: 2, amount: -DemoTables.kvb, name: "Kölner Verkehrs-Betriebe AG",
                            short: "KVB Deutschlandticket", iban: DemoIBANs.kvb, bookingText: "Lastschrift",
                            purpose: "Deutschlandticket \(slash) · Lastschrift", creditorID: "DE68ZZZ00000013145",
                            kind: .directDebit, category: Cat.mobility, ownTransfer: false))
        drafts.append(Draft(account: giro, date: date(1), time: nil, order: 3, amount: -112_000, name: "Wohnbau Ehrenfeld eG",
                            short: "Miete Wohnbau Ehrenfeld eG", iban: DemoIBANs.miete, bookingText: "Dauerauftrag",
                            purpose: "Miete \(slash) · Dauerauftrag", creditorID: nil,
                            kind: .standingOrder, category: Cat.housing, ownTransfer: false))
        drafts.append(Draft(account: giro, date: date(3), time: nil, order: 1, amount: -DemoTables.urban, name: "Urban Sports Club GmbH",
                            short: "Urban Sports Club", iban: DemoIBANs.urban, bookingText: "Lastschrift",
                            purpose: "Mitgliedschaft M · \(slash) · Lastschrift", creditorID: "DE09ZZZ00001724422",
                            kind: .directDebit, category: Cat.leisure, ownTransfer: false))
        drafts.append(Draft(account: giro, date: date(5), time: nil, order: 1, amount: -8_600, name: "Stadtwerke Köln GmbH",
                            short: "Stadtwerke Köln", iban: DemoIBANs.stadtwerke, bookingText: "Lastschrift",
                            purpose: "Abschlag Strom \(slash) · Lastschrift", creditorID: "DE75ZZZ00000007941",
                            kind: .directDebit, category: Cat.housing, ownTransfer: false))
        drafts.append(Draft(account: giro, date: date(15), time: nil, order: 1, amount: -50_000, name: "ETF-Sparplan ING Depot",
                            short: "ETF-Sparplan ING Depot", iban: DemoIBANs.depot, bookingText: "Dauerauftrag",
                            purpose: "Sparplan Depot 5402 1187 · Dauerauftrag", creditorID: nil,
                            kind: .standingOrder, category: nil, ownTransfer: true))
        drafts.append(Draft(account: giro, date: date(15), time: nil, order: 2, amount: -4_495, name: "Telekom Deutschland GmbH",
                            short: "Telekom Deutschland", iban: DemoIBANs.telekom, bookingText: "Lastschrift",
                            purpose: "Mobilfunk und DSL · Rechnung \(slash) · Lastschrift", creditorID: "DE73ZZZ00000027318",
                            kind: .directDebit, category: Cat.insurance, ownTransfer: false))
        drafts.append(Draft(account: giro, date: date(15), time: nil, order: 3, amount: -1_836, name: "ARD ZDF Deutschlandradio Beitragsservice",
                            short: "ARD ZDF Rundfunkbeitrag", iban: DemoIBANs.ard, bookingText: "Lastschrift",
                            purpose: "Rundfunkbeitrag \(slash) · Lastschrift", creditorID: "DE83ZZZ00000013222",
                            kind: .directDebit, category: Cat.insurance, ownTransfer: false))
        drafts.append(Draft(account: giro, date: date(27), time: nil, order: 5, amount: 384_000, name: "Rheinwerk Design GmbH",
                            short: "Gehalt Rheinwerk Design GmbH", iban: DemoIBANs.employer, bookingText: "Gehalt/Rente",
                            purpose: "Lohn/Gehalt \(slash) · Personalnr. 0417", creditorID: nil,
                            kind: .salary, category: Cat.income, ownTransfer: false))
        drafts.append(Draft(account: DemoAccountID.paypal, date: date(21), time: nil, order: 1, amount: -1_099, name: "Spotify AB",
                            short: "Spotify", iban: nil, bookingText: "PayPal-Zahlung",
                            purpose: "PayPal Europe, Spotify Premium", creditorID: nil,
                            kind: .directDebit, category: Cat.insurance, ownTransfer: false))
    }

    // MARK: Pinned rows (literal data and the rows insights cite)

    private static func card(_ merchant: Merchant, _ y: Int, _ mo: Int, _ d: Int, time: String?, amount: Int,
                             purpose: String? = nil, order: Int = 50) -> Draft {
        Draft.make(merchant, date: LocalDate(year: y, month: mo, day: d), time: time, amount: amount,
                   purpose: purpose ?? merchant.purposes[0], order: order)
    }

    static let amazon = Merchant(
        key: "amazon", name: "Amazon EU S.a.r.l.", short: "Amazon EU S.a.r.l.", account: DemoAccountID.visa, kind: .cardPayment,
        bookingText: "Kartenzahlung Visa", purposes: ["Amazon.de"], iban: nil, creditorID: nil, category: Cat.other,
        weight: 1, hasTime: false)
    static let etsy = Merchant(
        key: "etsy", name: "Etsy Ireland UC", short: "PayPal *Etsy", account: DemoAccountID.paypal, kind: .cardPayment,
        bookingText: "PayPal-Zahlung", purposes: ["PayPal Europe, Etsy order"], iban: nil, creditorID: nil, category: Cat.other,
        weight: 1, hasTime: false)
    static let apple = Merchant(
        key: "apple", name: "Apple Store", short: "Apple Store", account: DemoAccountID.visa, kind: .cardPayment,
        bookingText: "Kartenzahlung Visa", purposes: ["Kartenzahlung Visa · Apple Store Köln · MacBook Air 13″"], iban: nil,
        creditorID: nil, category: Cat.other, weight: 1, hasTime: true)

    static func pinned() -> [Draft] {
        var out: [Draft] = []
        var rng = SplitMix64(seed: 0xB1B1_B1B1)

        // Twelve earlier Amazon payments, the latest on 14.10.2026 (cited by Suggestions).
        let amazonRows: [(Int, Int, Int, Int)] = [
            (2025, 2, 8, 1_999), (2025, 4, 12, 4_230), (2025, 6, 21, 2_349), (2025, 8, 30, 5_900),
            (2025, 10, 4, 1_499), (2025, 12, 13, 8_890), (2026, 2, 7, 3_199), (2026, 4, 18, 2_490),
            (2026, 6, 6, 3_745), (2026, 8, 22, 1_699), (2026, 9, 12, 5_220), (2026, 10, 14, 2_749),
        ]
        for (y, mo, d, cents) in amazonRows {
            let purpose = "302-" + rng.digits(7) + "-" + rng.digits(7) + " Amazon.de"
            out.append(card(amazon, y, mo, d, time: nil, amount: -cents, purpose: purpose, order: 50))
        }
        // PayPal *Etsy a year ago (cited by Suggestions).
        out.append(card(etsy, 2025, 11, 9, time: nil, amount: -3_100, purpose: "PayPal Europe, Etsy order " + rng.digits(10)))

        // Tax return items.
        out.append(Draft(account: DemoAccountID.giro, date: LocalDate(year: 2026, month: 1, day: 2), time: "10:14", order: 50,
                         amount: -24_400, name: Merchants.bahn.name, short: "Deutsche Bahn", iban: nil, bookingText: "Kartenzahlung",
                         purpose: "BahnCard 50, 2. Klasse", creditorID: nil, kind: .cardPayment, category: Cat.mobility, ownTransfer: false))
        out.append(Draft(account: DemoAccountID.giro, date: LocalDate(year: 2026, month: 1, day: 2), time: nil, order: 2,
                         amount: -3_760, name: "HUK-COBURG Versicherungsgruppe", short: "HUK-COBURG", iban: DemoIBANs.huk,
                         bookingText: "Lastschrift", purpose: "Haftpflichtversicherung privat · Beitrag 2026 · Lastschrift",
                         creditorID: "DE46ZZZ00000014237", kind: .directDebit, category: Cat.insurance, ownTransfer: false))
        out.append(card(apple, 2026, 3, 14, time: "11:32", amount: -89_900))
        out.append(Draft(account: DemoAccountID.giro, date: LocalDate(year: 2026, month: 4, day: 20), time: nil, order: 4,
                         amount: -6_000, name: "Ärzte ohne Grenzen e.V.", short: "Ärzte ohne Grenzen e.V.", iban: DemoIBANs.aerzte,
                         bookingText: "Überweisung", purpose: "Spende Nothilfe", creditorID: nil, kind: .transfer,
                         category: Cat.other, ownTransfer: false))
        out.append(Draft(account: DemoAccountID.giro, date: LocalDate(year: 2026, month: 6, day: 18), time: nil, order: 4,
                         amount: -64_000, name: "Schreinerei Kaiser GmbH", short: "Schreinerei Kaiser GmbH", iban: DemoIBANs.schreinerei,
                         bookingText: "Überweisung", purpose: "Einbauschrank Flur, Rechnung 2026-054", creditorID: nil,
                         kind: .transfer, category: Cat.other, ownTransfer: false))
        out.append(Draft(account: DemoAccountID.giro, date: LocalDate(year: 2026, month: 9, day: 21), time: nil, order: 4,
                         amount: -24_132, name: "Rheinwerk Weiterbildung GmbH", short: "Rheinwerk Weiterbildung",
                         iban: DemoIBANs.rheinwerkWeiterbildung, bookingText: "Überweisung", purpose: "Typografie-Kurs, 3 Tage",
                         creditorID: nil, kind: .transfer, category: Cat.other, ownTransfer: false))
        out.append(Draft(account: DemoAccountID.giro, date: LocalDate(year: 2026, month: 10, day: 10), time: nil, order: 4,
                         amount: -6_000, name: "Ärzte ohne Grenzen e.V.", short: "Ärzte ohne Grenzen e.V.", iban: DemoIBANs.aerzte,
                         bookingText: "Überweisung", purpose: "", creditorID: nil, kind: .transfer,
                         category: Cat.other, ownTransfer: false))

        // October 2026: the rows the October review cites.
        for (day, time) in [(8, "07:12"), (22, "06:48")] {
            out.append(card(Merchants.bahn, 2026, 10, day, time: time, amount: -9_990,
                            purpose: "DB Fernverkehr · Köln Hbf – Frankfurt (Main) Hbf"))
        }
        out.append(card(Merchants.cafe, 2026, 10, 17, time: "10:41", amount: -4_680))
        out.append(card(Merchants.rewe, 2026, 10, 24, time: "17:55", amount: -5_216))
        out.append(Draft(account: DemoAccountID.giro, date: LocalDate(year: 2026, month: 10, day: 4), time: nil, order: 1,
                         amount: -DemoTables.urban, name: "Urban Sports Club GmbH", short: "Urban Sports Club", iban: DemoIBANs.urban,
                         bookingText: "Lastschrift", purpose: "Mitgliedschaft M · 10/2026 · Lastschrift",
                         creditorID: "DE09ZZZ00001724422", kind: .directDebit, category: Cat.leisure, ownTransfer: false))
        let lieferando: [(Int, Int)] = [(25, 1_640), (26, 1_520), (28, 1_780), (29, 1_490), (30, 1_730), (31, 9_000)]
        for (day, cents) in lieferando {
            let purpose = day == 31
                ? "PayPal Europe, Lieferando.de Bestellung " + rng.orderCode() + " · für zwei Personen"
                : "PayPal Europe, Lieferando.de Bestellung " + rng.orderCode()
            out.append(card(Merchants.lieferandoPayPal, 2026, 10, day, time: nil, amount: -cents, purpose: purpose))
        }
        return out
    }

    // MARK: Generated spending

    private func pinnedSum(_ category: String, month index: Int, in pinned: [Draft]) -> Int {
        var sum = 0
        for draft in pinned where draft.category == category && draft.amount < 0 && DemoTables.index(of: draft.date) == index {
            sum += -draft.amount
        }
        return sum
    }

    private static func day(year: Int, month: Int, account: String, rng: inout SplitMix64) -> Int {
        var maxDay = 28
        if year == 2026 && month == 10 {
            if account == DemoAccountID.giro { maxDay = 23 } else if account == DemoAccountID.visa { maxDay = 20 } else { maxDay = 24 }
        }
        while true {
            let d = rng.int(1...maxDay)
            if account == DemoAccountID.giro && year == 2026 && month == 8 && (d == 12 || d == 13) { continue }
            return d
        }
    }

    private mutating func spend(_ category: String, total: Int, count: Int, merchants: [Merchant], index: Int, seedSalt: UInt64) {
        guard total > 0, count > 0 else { return }
        var rng = SplitMix64(seed: 0xC0DE_0000 &+ UInt64(index) &* 1_000 &+ seedSalt)
        let y = DemoTables.year(index)
        let mo = DemoTables.month(index)
        let amounts = DemoText.split(total: total, count: count, rng: &rng)
        for amount in amounts {
            let merchant = DemoText.pick(merchants, rng: &rng)
            let d = Self.day(year: y, month: mo, account: merchant.account, rng: &rng)
            let time = merchant.hasTime ? DemoText.hhmm(&rng) : nil
            let template = merchant.purposes[rng.int(0...(merchant.purposes.count - 1))]
            let purpose = DemoText.fill(template, rng: &rng)
            drafts.append(Draft.make(merchant, date: LocalDate(year: y, month: mo, day: d), time: time, amount: -amount, purpose: purpose))
        }
    }

    private mutating func generateSpending(pins pinned: [Draft]) {
        // Resolve open "other" targets: pinned items plus a random remainder, and the balancer month.
        var specs: [MonthSpec] = []
        for index in 0..<DemoTables.monthCount {
            var spec = DemoTables.spec(index)
            if spec.o == nil && index != DemoTables.febIndex {
                var rng = SplitMix64(seed: 0xE0E0_0000 &+ UInt64(index))
                spec.o = pinnedSum(Cat.other, month: index, in: pinned) + rng.int(6_000...18_000)
            }
            specs.append(spec)
        }
        var others = 0
        for index in DemoTables.decIndex..<DemoTables.monthCount where index != DemoTables.febIndex {
            let s = specs[index]
            others += DemoTables.housing + DemoTables.contracts + s.extraContracts + s.g + s.l + s.m + s.h + (s.o ?? 0)
        }
        let feb = specs[DemoTables.febIndex]
        let febFixed = DemoTables.housing + DemoTables.contracts + feb.extraContracts + feb.g + feb.l + feb.m + feb.h
        specs[DemoTables.febIndex].o = DemoTables.meanTotal - others - febFixed

        for index in 0..<DemoTables.monthCount {
            let spec = specs[index]
            let isOct = index == DemoTables.octIndex
            let pg = pinnedSum(Cat.groceries, month: index, in: pinned)
            let pl = pinnedSum(Cat.leisure, month: index, in: pinned)
            let pm = pinnedSum(Cat.mobility, month: index, in: pinned)
            let ph = pinnedSum(Cat.health, month: index, in: pinned)
            let po = pinnedSum(Cat.other, month: index, in: pinned)
            // Pinned items that are also fixed rows (the second Urban charge in October) are part of `pl`.

            let groceryCount: Int
            if index == DemoTables.sepIndex { groceryCount = sepGroceryCount } else if isOct { groceryCount = 22 } else { groceryCount = 28 }
            spend(Cat.groceries, total: spec.g - pg, count: groceryCount,
                  merchants: isOct ? Merchants.groceriesGiroOnly : Merchants.groceries, index: index, seedSalt: 1)

            spend(Cat.leisure, total: spec.l - DemoTables.urban - pl, count: isOct ? 5 : (index == DemoTables.sepIndex ? sepLeisureCount : 12),
                  merchants: Merchants.leisure, index: index, seedSalt: 2)

            let mobilityTarget = spec.m - DemoTables.kvb - pm
            let mobilityCount = mobilityTarget >= 6_000 ? 2 : (mobilityTarget > 0 ? 1 : 0)
            spend(Cat.mobility, total: mobilityTarget, count: mobilityCount,
                  merchants: isOct ? [Merchants.qpark] : Merchants.mobility, index: index, seedSalt: 3)

            let healthTarget = spec.h - ph
            spend(Cat.health, total: healthTarget, count: healthTarget >= 3_500 ? 2 : (healthTarget > 0 ? 1 : 0),
                  merchants: Merchants.health, index: index, seedSalt: 4)

            var otherTarget = (spec.o ?? 0) - po
            if otherTarget >= 15_000 {
                var rng = SplitMix64(seed: 0xA7A7_0000 &+ UInt64(index))
                let atm = 5_000 * rng.int(1...2)
                let y = DemoTables.year(index)
                let mo = DemoTables.month(index)
                let d = Self.day(year: y, month: mo, account: DemoAccountID.giro, rng: &rng)
                drafts.append(Draft.make(Merchants.atmGiro, date: LocalDate(year: y, month: mo, day: d), time: DemoText.hhmm(&rng),
                                         amount: -atm, purpose: Merchants.atmGiro.purposes[0]))
                otherTarget -= atm
            }
            spend(Cat.other, total: otherTarget, count: otherTarget >= 8_000 ? 2 : 1, merchants: Merchants.otherMisc,
                  index: index, seedSalt: 5)
        }
    }

    // MARK: November 2026 (all literal)

    private mutating func addNovember() {
        func d(_ day: Int) -> LocalDate { LocalDate(year: 2026, month: 11, day: day) }
        let giro = DemoAccountID.giro
        // Girokonto: the nine rows of the Transactions artboard.
        drafts.append(Draft(account: giro, date: d(11), time: "18:42", order: 50, amount: -6_348, name: "REWE Markt GmbH", short: "REWE",
                            iban: nil, bookingText: "Kartenzahlung", purpose: "Kartenzahlung · REWE Markt GmbH, Venloer Str.",
                            creditorID: "DE79ZZZ00000110925", kind: .cardPayment, category: Cat.groceries, ownTransfer: false))
        drafts.append(Draft(account: giro, date: d(10), time: "19:26", order: 50, amount: -2_790, name: "Lieferando.de", short: "Lieferando",
                            iban: nil, bookingText: "Kartenzahlung",
                            purpose: "Lieferando.de Bestellung 4KX9-22T · Pizzeria Ehrenfeld", creditorID: nil,
                            kind: .cardPayment, category: Cat.leisure, ownTransfer: false))
        drafts.append(Draft(account: giro, date: d(9), time: "16:10", order: 50, amount: -1_845, name: "dm-drogerie markt GmbH & Co. KG",
                            short: "dm-drogerie markt", iban: nil, bookingText: "Kartenzahlung",
                            purpose: "Kartenzahlung · dm Köln Ehrenfeld, Venloer Str.", creditorID: nil,
                            kind: .cardPayment, category: Cat.groceries, ownTransfer: false))
        drafts.append(Draft(account: giro, date: d(7), time: "09:35", order: 50, amount: -4_990, name: "DB Vertrieb GmbH", short: "Deutsche Bahn",
                            iban: nil, bookingText: "Kartenzahlung", purpose: "DB Fernverkehr · Köln Hbf – Frankfurt (Main) Hbf",
                            creditorID: nil, kind: .cardPayment, category: Cat.mobility, ownTransfer: false))
        drafts.append(Draft(account: giro, date: d(5), time: nil, order: 1, amount: -8_600, name: "Stadtwerke Köln GmbH", short: "Stadtwerke Köln",
                            iban: DemoIBANs.stadtwerke, bookingText: "Lastschrift", purpose: "Abschlag Strom 11/2026 · Lastschrift",
                            creditorID: "DE75ZZZ00000007941", kind: .directDebit, category: Cat.housing, ownTransfer: false))
        drafts.append(Draft(account: giro, date: d(3), time: nil, order: 1, amount: -DemoTables.urban, name: "Urban Sports Club GmbH",
                            short: "Urban Sports Club", iban: DemoIBANs.urban, bookingText: "Lastschrift",
                            purpose: "Mitgliedschaft M · 11/2026 · Lastschrift", creditorID: "DE09ZZZ00001724422",
                            kind: .directDebit, category: Cat.leisure, ownTransfer: false))
        drafts.append(Draft(account: giro, date: d(1), time: nil, order: 1, amount: -3_870, name: "HUK-COBURG Versicherungsgruppe",
                            short: "HUK-COBURG", iban: DemoIBANs.huk, bookingText: "Lastschrift",
                            purpose: "Kfz-Versicherung · Beitrag 11/2026 · Lastschrift", creditorID: "DE46ZZZ00000014237",
                            kind: .directDebit, category: Cat.insurance, ownTransfer: false))
        drafts.append(Draft(account: giro, date: d(1), time: nil, order: 2, amount: -DemoTables.kvb, name: "Kölner Verkehrs-Betriebe AG",
                            short: "KVB Deutschlandticket", iban: DemoIBANs.kvb, bookingText: "Lastschrift",
                            purpose: "Deutschlandticket 11/2026 · Lastschrift", creditorID: "DE68ZZZ00000013145",
                            kind: .directDebit, category: Cat.mobility, ownTransfer: false))
        drafts.append(Draft(account: giro, date: d(1), time: nil, order: 3, amount: -112_000, name: "Wohnbau Ehrenfeld eG",
                            short: "Miete Wohnbau Ehrenfeld eG", iban: DemoIBANs.miete, bookingText: "Dauerauftrag",
                            purpose: "Miete 11/2026 · Dauerauftrag", creditorID: nil, kind: .standingOrder,
                            category: Cat.housing, ownTransfer: false))

        // Visa Card: nine rows summing to 384,12; four of them uncategorised.
        let visa = DemoAccountID.visa
        func visaRow(_ day: Int, _ time: String, _ amount: Int, name: String, short: String, text: String = "Kartenzahlung Visa",
                     purpose: String, kind: BankTransactionKind = .cardPayment, category: String?) {
            drafts.append(Draft(account: visa, date: d(day), time: time, order: 50, amount: -amount, name: name, short: short, iban: nil,
                                bookingText: text, purpose: purpose, creditorID: nil, kind: kind, category: category, ownTransfer: false))
        }
        visaRow(11, "19:08", 4_733, name: "Alnatura Super Natur Markt", short: "Alnatura",
                purpose: "Kartenzahlung Visa · Alnatura, Ehrenfeldgürtel", category: Cat.groceries)
        visaRow(10, "07:52", 3_499, name: "Amazon EU S.a.r.l.", short: "Amazon EU S.a.r.l.",
                purpose: "302-4817265-1193406 Amazon.de", category: nil)
        visaRow(9, "20:05", 2_150, name: "Cinedom Köln", short: "Kino Cinedom",
                purpose: "Kartenzahlung Visa · Cinedom, Im Mediapark", category: Cat.leisure)
        visaRow(8, "11:25", 7_319, name: "EDEKA Center Ehrenfeld", short: "Edeka",
                purpose: "Kartenzahlung Visa · EDEKA Center Ehrenfeld, Subbelrather Str.", category: Cat.groceries)
        visaRow(7, "16:42", 1_280, name: "Apotheke am Neumarkt", short: "Apotheke am Neumarkt",
                purpose: "Kartenzahlung Visa · Neumarkt 18, Köln", category: nil)
        visaRow(6, "21:47", 640, name: "SumUp *Kiosk Ehrenfeld", short: "SumUp *Kiosk Ehrenfeld",
                purpose: "Kartenzahlung Visa, 21:47", category: nil)
        visaRow(5, "20:30", 2_321, name: "Brauhaus Päffgen", short: "Brauhaus Päffgen",
                purpose: "Kartenzahlung Visa · Brauhaus Päffgen, Friesenstr.", category: Cat.leisure)
        visaRow(4, "12:15", 10_000, name: "Bargeldauszahlung Sparkasse", short: "Bargeldauszahlung Sparkasse",
                text: "Bargeldauszahlung Visa", purpose: "Geldautomat Ehrenstraße, Köln", kind: .atm, category: nil)
        visaRow(2, "08:20", 6_470, name: "Aral Tankstelle", short: "Aral",
                purpose: "Kartenzahlung Visa · Aral Tankstelle, Köln-Ehrenfeld", category: Cat.mobility)

        // PayPal Wallet: five rows, net −133,54; Etsy and Jonas Weber uncategorised.
        let paypal = DemoAccountID.paypal
        func paypalRow(_ day: Int, _ amount: Int, name: String, short: String, purpose: String, kind: BankTransactionKind,
                       category: String?) {
            drafts.append(Draft(account: paypal, date: d(day), time: nil, order: 50, amount: amount, name: name, short: short, iban: nil,
                                bookingText: "PayPal-Zahlung", purpose: purpose, creditorID: nil, kind: kind,
                                category: category, ownTransfer: false))
        }
        paypalRow(10, -5_450, name: "Picnic Deutschland GmbH", short: "PayPal *Picnic",
                  purpose: "PayPal Europe, Picnic Lieferung 7Q4-2981", kind: .cardPayment, category: Cat.groceries)
        paypalRow(8, -2_250, name: "Etsy Ireland UC", short: "PayPal *Etsy",
                  purpose: "PayPal Europe, Etsy order 3184479201", kind: .cardPayment, category: nil)
        paypalRow(7, -4_004, name: "Valve Corporation", short: "PayPal *Steam",
                  purpose: "PayPal Europe, Steam Games 55-2210", kind: .cardPayment, category: Cat.leisure)
        paypalRow(3, 4_500, name: "Jonas Weber", short: "Überweisung Jonas Weber",
                  purpose: "Lieferando Freitag, danke!", kind: .transfer, category: nil)
        paypalRow(2, -6_150, name: "Flaschenpost SE", short: "PayPal *Flaschenpost",
                  purpose: "PayPal Europe, Flaschenpost Bestellung 4411-90", kind: .cardPayment, category: Cat.groceries)

        // Tagesgeld: the tax refund (amount balances net worth on 31.10.2026).
        drafts.append(Draft(account: DemoAccountID.tagesgeld, date: d(6), time: nil, order: 1, amount: taxRefund,
                            name: "Finanzamt Köln-Altstadt", short: "Finanzamt Köln-Altstadt", iban: DemoIBANs.finanzamt,
                            bookingText: "Gutschrift", purpose: "Einkommensteuer 2025 · Erstattung", creditorID: nil,
                            kind: .transfer, category: Cat.income, ownTransfer: false))
    }

    // MARK: Visa statements and PayPal top-ups

    private mutating func addVisaSettlements() {
        let visaCharges = drafts.filter { $0.account == DemoAccountID.visa && $0.amount < 0 }
        var previous = LocalDate(year: 2024, month: 12, day: 31)
        for index in 0..<DemoTables.monthCount {
            let settle = LocalDate(year: DemoTables.year(index), month: DemoTables.month(index), day: 20)
            var sum = 0
            for charge in visaCharges where charge.date > previous && charge.date <= settle { sum += charge.amount }
            previous = settle
            if sum == 0 { continue }
            let label = DemoText.two(settle.month) + "/" + String(settle.year)
            drafts.append(Draft(account: DemoAccountID.visa, date: settle, time: nil, order: 90, amount: -sum, name: "Sparkasse KölnBonn",
                                short: "Ausgleich Kartenabrechnung", iban: DemoIBANs.giro, bookingText: "Überweisung",
                                purpose: "Ausgleich Kartenabrechnung \(label)", creditorID: nil, kind: .transfer,
                                category: nil, ownTransfer: true))
            drafts.append(Draft(account: DemoAccountID.giro, date: settle, time: nil, order: 1, amount: sum, name: "DKB AG",
                                short: "DKB Visa statement", iban: DemoIBANs.dkb, bookingText: "Lastschrift",
                                purpose: "Kartenabrechnung \(label) · Visa Card · Lastschrift", creditorID: "DE62ZZZ00000026231",
                                kind: .directDebit, category: nil, ownTransfer: true))
        }
    }

    private mutating func addPayPalTopUps() {
        var net = [Int](repeating: 0, count: DemoTables.monthCount)
        var novemberNet = 0
        for draft in drafts where draft.account == DemoAccountID.paypal {
            let index = DemoTables.index(of: draft.date)
            if index >= 0 && index < DemoTables.monthCount {
                net[index] -= draft.amount
            } else if draft.date.year == 2026 && draft.date.month == 11 {
                novemberNet -= draft.amount
            }
        }
        // End of October balance = today's balance + what November spent.
        var end = 6_190 + novemberNet
        var rng = SplitMix64(seed: 0xFACE_0001)
        var topUps = [Int](repeating: 0, count: DemoTables.monthCount)
        for index in stride(from: DemoTables.monthCount - 1, through: 0, by: -1) {
            let low = rng.int(20_000...30_000)
            let needed = end + net[index] - low
            let top = needed > 0 ? ((needed + 999) / 1_000) * 1_000 : 0
            topUps[index] = top
            end = end - top + net[index]
        }
        for index in 0..<DemoTables.monthCount where topUps[index] > 0 {
            let first = LocalDate(year: DemoTables.year(index), month: DemoTables.month(index), day: 1)
            drafts.append(Draft(account: DemoAccountID.paypal, date: first, time: nil, order: 0, amount: topUps[index],
                                name: "Sparkasse KölnBonn", short: "Aufladung vom Girokonto", iban: DemoIBANs.giro,
                                bookingText: "Aufladung", purpose: "Aufladung vom Girokonto", creditorID: nil,
                                kind: .transfer, category: nil, ownTransfer: true))
            drafts.append(Draft(account: DemoAccountID.giro, date: first, time: nil, order: 4, amount: -topUps[index],
                                name: "PayPal (Europe) S.à r.l. et Cie, S.C.A.", short: "PayPal Aufladung", iban: DemoIBANs.paypal,
                                bookingText: "Lastschrift", purpose: "PayPal Aufladung · Lastschrift", creditorID: "LU96ZZZ0000000000000000058",
                                kind: .directDebit, category: nil, ownTransfer: true))
        }
    }

    // MARK: Girokonto → Tagesgeld and out-of-sight savings

    private mutating func addTagesgeldAndTransfers() {
        // Interest on the Tagesgeld, quarterly.
        var rng = SplitMix64(seed: 0x1717_0001)
        var interestTotal = 0
        let quarters: [(Int, Int, Int)] = [(2025, 3, 31), (2025, 6, 30), (2025, 9, 30), (2025, 12, 31),
                                           (2026, 3, 31), (2026, 6, 30), (2026, 9, 30)]
        for (y, mo, d) in quarters {
            let amount = rng.int(800...3_200)
            interestTotal += amount
            let quarter = (mo - 1) / 3 + 1
            drafts.append(Draft(account: DemoAccountID.tagesgeld, date: LocalDate(year: y, month: mo, day: d), time: nil, order: 9,
                                amount: amount, name: "Sparkasse KölnBonn", short: "Zinsen Tagesgeld", iban: nil,
                                bookingText: "Abschluss", purpose: "Zinsen Tagesgeld Q\(quarter)/\(y)", creditorID: nil,
                                kind: .interest, category: Cat.income, ownTransfer: false))
        }

        // Cumulative Girokonto flow up to the 26th of each month (before the salary).
        let giroDrafts = drafts.filter { $0.account == DemoAccountID.giro }
        var flow = [Int](repeating: 0, count: DemoTables.monthCount)
        for index in 0..<DemoTables.monthCount {
            let cutoff = LocalDate(year: DemoTables.year(index), month: DemoTables.month(index), day: 26)
            var sum = 0
            for draft in giroDrafts where draft.date <= cutoff { sum += draft.amount }
            flow[index] = sum
        }
        // Walk backwards from the anchor (balance 104,79 before the October salary) and decide how much
        // is moved out of the Girokonto each month so that it stays close to a few hundred euros.
        var target = 10_479
        var moved = [Int](repeating: 0, count: DemoTables.monthCount)
        for index in stride(from: DemoTables.monthCount - 1, to: 0, by: -1) {
            let surplus = flow[index] - flow[index - 1]
            let desired = rng.int(30_000...60_000)
            var amount = surplus + target - desired
            if amount < 0 { amount = 0 }
            amount = (amount / 1_000) * 1_000
            moved[index] = amount
            target = target + surplus - amount
        }
        moved[0] = 50_000

        // Share that goes to the Tagesgeld; the rest leaves to an external own account.
        var percent = 40
        var toTagesgeld = [Int](repeating: 0, count: DemoTables.monthCount)
        while true {
            var sum = 0
            for index in 0..<DemoTables.monthCount {
                toTagesgeld[index] = (moved[index] * percent / 100 / 1_000) * 1_000
                sum += toTagesgeld[index]
            }
            let opening = 1_205_000 - sum - interestTotal - taxRefund
            if opening >= 100_000 || percent == 0 { break }
            percent -= 5
        }

        for index in 0..<DemoTables.monthCount {
            let y = DemoTables.year(index)
            let mo = DemoTables.month(index)
            let slash = DemoText.two(mo) + "/" + String(y)
            let e = toTagesgeld[index]
            let r = moved[index] - e
            if e > 0 {
                let day = LocalDate(year: y, month: mo, day: 22)
                drafts.append(Draft(account: DemoAccountID.giro, date: day, time: nil, order: 6, amount: -e, name: "Sparkasse KölnBonn",
                                    short: "Umbuchung Tagesgeld", iban: DemoIBANs.tagesgeld, bookingText: "Umbuchung",
                                    purpose: "Sparen \(slash)", creditorID: nil, kind: .transfer, category: nil, ownTransfer: true))
                drafts.append(Draft(account: DemoAccountID.tagesgeld, date: day, time: nil, order: 6, amount: e, name: "Sparkasse KölnBonn",
                                    short: "Umbuchung vom Girokonto", iban: DemoIBANs.giro, bookingText: "Umbuchung",
                                    purpose: "Sparen \(slash)", creditorID: nil, kind: .transfer, category: nil, ownTransfer: true))
            }
            if r > 0 {
                drafts.append(Draft(account: DemoAccountID.giro, date: LocalDate(year: y, month: mo, day: 23), time: nil, order: 6,
                                    amount: -r, name: "Trade Republic Bank GmbH", short: "Trade Republic Sparplan",
                                    iban: DemoIBANs.tradeRepublic, bookingText: "Überweisung", purpose: "Eigene Überweisung \(slash)",
                                    creditorID: nil, kind: .transfer, category: nil, ownTransfer: true))
            }
        }
    }
}
