import Foundation

/// Category names (the one category list of the design).
enum Cat {
    static let housing = "Housing"
    static let groceries = "Groceries"
    static let mobility = "Mobility"
    static let leisure = "Leisure & eating out"
    static let insurance = "Insurance & contracts"
    static let health = "Health & drugstore"
    static let other = "Other"
    static let income = "Income"
}

/// Account ids of the demo ledger.
public enum DemoAccountID {
    public static let giro = "sparkasse-giro"
    public static let tagesgeld = "sparkasse-tagesgeld"
    public static let visa = "dkb-visa"
    public static let depot = "ing-depot"
    public static let paypal = "paypal-wallet"

    /// Display order in the sidebar and on the Overview.
    public static let all = [giro, tagesgeld, visa, depot, paypal]
}

/// IBANs of the demo data. Bank code and account number are the designed ones (or invented for
/// counterparties); the two check digits are always recomputed, so every IBAN is valid.
enum DemoIBANs {
    static let giro = IBAN.withCheckDigits(country: "DE", bban: "370501981934082751")
    static let tagesgeld = IBAN.withCheckDigits(country: "DE", bban: "370501981934082778")
    static let depot = IBAN.withCheckDigits(country: "DE", bban: "500105175419283746")
    static let miete = IBAN.withCheckDigits(country: "DE", bban: "370501980012345678")
    static let mia = IBAN.withCheckDigits(country: "DE", bban: "370501981022447130")
    static let fitness = IBAN.withCheckDigits(country: "DE", bban: "380400070123456700")
    static let schreinerei = IBAN.withCheckDigits(country: "DE", bban: "370501980012665543")
    /// The one IBAN of Jonas Weber (the New transfer artboard).
    static let jonas = IBAN.withCheckDigits(country: "DE", bban: "370400440532013000")
    static let huk = IBAN.withCheckDigits(country: "DE", bban: "783200760033224411")
    static let telekom = IBAN.withCheckDigits(country: "DE", bban: "370501980018811009")
    static let ard = IBAN.withCheckDigits(country: "DE", bban: "370700240044556677")
    static let stadtwerke = IBAN.withCheckDigits(country: "DE", bban: "370501980001122334")
    static let kvb = IBAN.withCheckDigits(country: "DE", bban: "370501980005566778")
    static let urban = IBAN.withCheckDigits(country: "DE", bban: "100110012626542133")
    static let employer = IBAN.withCheckDigits(country: "DE", bban: "370501980098765432")
    static let dkb = IBAN.withCheckDigits(country: "DE", bban: "120300001018437722")
    static let paypal = IBAN.withCheckDigits(country: "LU", bban: "0019400644750000")
    static let tradeRepublic = IBAN.withCheckDigits(country: "DE", bban: "502109007044511903")
    static let rheinwerkWeiterbildung = IBAN.withCheckDigits(country: "DE", bban: "370501980066100377")
    static let aerzte = IBAN.withCheckDigits(country: "DE", bban: "370205000000970970")
    static let finanzamt = IBAN.withCheckDigits(country: "DE", bban: "370000000037001500")
    static let sparkasseZinsen = IBAN.withCheckDigits(country: "DE", bban: "370501980000000001")
}

/// A counterparty that card payments and orders are drawn from. `purpose` may contain `{id}`
/// (a random order code) which is replaced when a transaction is made.
struct Merchant {
    var key: String
    var name: String
    var short: String
    var account: String
    var kind: BankTransactionKind
    var bookingText: String
    var purposes: [String]
    var iban: String?
    var creditorID: String?
    var category: String
    var weight: Int
    var hasTime: Bool
}

enum Merchants {
    static let rewe = Merchant(
        key: "rewe", name: "REWE Markt GmbH", short: "REWE", account: DemoAccountID.giro, kind: .cardPayment,
        bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · REWE Markt GmbH, Venloer Str."], iban: nil,
        creditorID: "DE79ZZZ00000110925", category: Cat.groceries, weight: 6, hasTime: true)
    static let edeka = Merchant(
        key: "edeka", name: "EDEKA Center Ehrenfeld", short: "Edeka", account: DemoAccountID.giro, kind: .cardPayment,
        bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · EDEKA Center Ehrenfeld, Subbelrather Str."], iban: nil,
        creditorID: nil, category: Cat.groceries, weight: 3, hasTime: true)
    static let aldi = Merchant(
        key: "aldi", name: "ALDI SÜD Dienstleistungs-GmbH", short: "Aldi Süd", account: DemoAccountID.giro, kind: .cardPayment,
        bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · ALDI SÜD, Vogelsanger Str."], iban: nil,
        creditorID: nil, category: Cat.groceries, weight: 1, hasTime: true)
    static let dm = Merchant(
        key: "dm", name: "dm-drogerie markt GmbH & Co. KG", short: "dm-drogerie markt", account: DemoAccountID.giro,
        kind: .cardPayment, bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · dm Köln Ehrenfeld, Venloer Str."],
        iban: nil, creditorID: nil, category: Cat.groceries, weight: 2, hasTime: true)
    static let kaufland = Merchant(
        key: "kaufland", name: "Kaufland Stiftung & Co. KG", short: "Kaufland", account: DemoAccountID.giro, kind: .cardPayment,
        bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · Kaufland Köln-Ossendorf"], iban: nil,
        creditorID: nil, category: Cat.groceries, weight: 1, hasTime: true)
    static let alnatura = Merchant(
        key: "alnatura", name: "Alnatura Super Natur Markt", short: "Alnatura", account: DemoAccountID.visa, kind: .cardPayment,
        bookingText: "Kartenzahlung Visa", purposes: ["Kartenzahlung Visa · Alnatura, Ehrenfeldgürtel"], iban: nil,
        creditorID: nil, category: Cat.groceries, weight: 1, hasTime: true)
    static let picnic = Merchant(
        key: "picnic", name: "Picnic Deutschland GmbH", short: "PayPal *Picnic", account: DemoAccountID.paypal,
        kind: .cardPayment, bookingText: "PayPal-Zahlung", purposes: ["PayPal Europe, Picnic Lieferung {id}"], iban: nil,
        creditorID: nil, category: Cat.groceries, weight: 1, hasTime: false)

    static let lieferando = Merchant(
        key: "lieferando", name: "Lieferando.de", short: "Lieferando", account: DemoAccountID.giro, kind: .cardPayment,
        bookingText: "Kartenzahlung",
        purposes: ["Lieferando.de Bestellung {id} · Pizzeria Ehrenfeld", "Lieferando.de Bestellung {id} · Sushi Palace",
                   "Lieferando.de Bestellung {id} · Burgerliebe"],
        iban: nil, creditorID: nil, category: Cat.leisure, weight: 4, hasTime: true)
    static let lieferandoPayPal = Merchant(
        key: "lieferando-paypal", name: "Lieferando.de", short: "Lieferando", account: DemoAccountID.paypal, kind: .cardPayment,
        bookingText: "PayPal-Zahlung", purposes: ["PayPal Europe, Lieferando.de Bestellung {id}"], iban: nil,
        creditorID: nil, category: Cat.leisure, weight: 1, hasTime: false)
    static let cafe = Merchant(
        key: "cafe", name: "Café Fassbender", short: "Café Fassbender", account: DemoAccountID.giro, kind: .cardPayment,
        bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · Café Fassbender, Körnerstr."], iban: nil,
        creditorID: nil, category: Cat.leisure, weight: 3, hasTime: true)
    static let paeffgen = Merchant(
        key: "paeffgen", name: "Brauhaus Päffgen", short: "Brauhaus Päffgen", account: DemoAccountID.visa, kind: .cardPayment,
        bookingText: "Kartenzahlung Visa", purposes: ["Kartenzahlung Visa · Brauhaus Päffgen, Friesenstr."], iban: nil,
        creditorID: nil, category: Cat.leisure, weight: 2, hasTime: true)
    static let trattoria = Merchant(
        key: "trattoria", name: "Trattoria Da Marco", short: "Trattoria Da Marco", account: DemoAccountID.giro,
        kind: .cardPayment, bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · Trattoria Da Marco, Venloer Str."],
        iban: nil, creditorID: nil, category: Cat.leisure, weight: 2, hasTime: true)
    static let kino = Merchant(
        key: "kino", name: "Cinedom Köln", short: "Kino Cinedom", account: DemoAccountID.visa, kind: .cardPayment,
        bookingText: "Kartenzahlung Visa", purposes: ["Kartenzahlung Visa · Cinedom, Im Mediapark"], iban: nil,
        creditorID: nil, category: Cat.leisure, weight: 1, hasTime: true)
    static let steam = Merchant(
        key: "steam", name: "Valve Corporation", short: "PayPal *Steam", account: DemoAccountID.paypal, kind: .cardPayment,
        bookingText: "PayPal-Zahlung", purposes: ["PayPal Europe, Steam Games {id}"], iban: nil,
        creditorID: nil, category: Cat.leisure, weight: 1, hasTime: false)

    static let bahn = Merchant(
        key: "bahn", name: "DB Vertrieb GmbH", short: "Deutsche Bahn", account: DemoAccountID.giro, kind: .cardPayment,
        bookingText: "Kartenzahlung",
        purposes: ["DB Fernverkehr · Köln Hbf – Frankfurt (Main) Hbf", "DB Fernverkehr · Köln Hbf – Frankfurt (Main) Hbf",
                   "DB Fernverkehr · Köln Hbf – Frankfurt (Main) Hbf", "DB Regio · Köln Hbf – Koblenz Hbf",
                   "DB Fernverkehr · Köln Hbf – Berlin Hbf"],
        iban: nil, creditorID: nil, category: Cat.mobility, weight: 3, hasTime: true)
    static let aral = Merchant(
        key: "aral", name: "Aral Tankstelle", short: "Aral", account: DemoAccountID.visa, kind: .cardPayment,
        bookingText: "Kartenzahlung Visa", purposes: ["Kartenzahlung Visa · Aral Tankstelle, Köln-Ehrenfeld"], iban: nil,
        creditorID: nil, category: Cat.mobility, weight: 2, hasTime: true)
    static let qpark = Merchant(
        key: "qpark", name: "Q-Park Deutschland", short: "Q-Park", account: DemoAccountID.visa, kind: .cardPayment,
        bookingText: "Kartenzahlung Visa", purposes: ["Kartenzahlung Visa · Q-Park Neumarkt Galerie"], iban: nil,
        creditorID: nil, category: Cat.mobility, weight: 2, hasTime: true)

    static let apotheke = Merchant(
        key: "apotheke", name: "Apotheke am Neumarkt", short: "Apotheke am Neumarkt", account: DemoAccountID.giro,
        kind: .cardPayment, bookingText: "Kartenzahlung", purposes: ["Kartenzahlung girocard · Neumarkt 18, Köln"], iban: nil,
        creditorID: nil, category: Cat.health, weight: 3, hasTime: true)
    static let rossmann = Merchant(
        key: "rossmann", name: "Dirk Rossmann GmbH", short: "Rossmann", account: DemoAccountID.giro, kind: .cardPayment,
        bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · Rossmann, Venloer Str."], iban: nil,
        creditorID: nil, category: Cat.health, weight: 2, hasTime: true)
    static let physio = Merchant(
        key: "physio", name: "Physiotherapie Hoffmann", short: "Physiotherapie Hoffmann", account: DemoAccountID.giro,
        kind: .cardPayment, bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · Physiotherapie Hoffmann, Körnerstr."],
        iban: nil, creditorID: nil, category: Cat.health, weight: 1, hasTime: true)

    static let hornbach = Merchant(
        key: "hornbach", name: "HORNBACH Baumarkt AG", short: "Hornbach", account: DemoAccountID.visa, kind: .cardPayment,
        bookingText: "Kartenzahlung Visa", purposes: ["Kartenzahlung Visa · Hornbach, Köln-Marsdorf"], iban: nil,
        creditorID: nil, category: Cat.other, weight: 2, hasTime: true)
    static let ikea = Merchant(
        key: "ikea", name: "IKEA Deutschland", short: "IKEA", account: DemoAccountID.visa, kind: .cardPayment,
        bookingText: "Kartenzahlung Visa", purposes: ["Kartenzahlung Visa · IKEA Köln-Godorf"], iban: nil,
        creditorID: nil, category: Cat.other, weight: 1, hasTime: true)
    static let thalia = Merchant(
        key: "thalia", name: "Thalia Bücher GmbH", short: "Thalia", account: DemoAccountID.giro, kind: .cardPayment,
        bookingText: "Kartenzahlung", purposes: ["Kartenzahlung · Thalia, Schildergasse"], iban: nil,
        creditorID: nil, category: Cat.other, weight: 2, hasTime: true)
    static let atmGiro = Merchant(
        key: "atm-giro", name: "Bargeldauszahlung Sparkasse", short: "Bargeldauszahlung Sparkasse", account: DemoAccountID.giro,
        kind: .atm, bookingText: "Bargeldauszahlung girocard", purposes: ["Geldautomat Venloer Str., Köln"], iban: nil,
        creditorID: nil, category: Cat.other, weight: 1, hasTime: true)

    static let groceries: [Merchant] = [rewe, edeka, aldi, dm, kaufland, alnatura, picnic]
    static let groceriesGiroOnly: [Merchant] = [rewe, edeka]
    static let leisure: [Merchant] = [lieferando, cafe, paeffgen, trattoria, kino, steam]
    static let mobility: [Merchant] = [bahn, aral, qpark]
    static let health: [Merchant] = [apotheke, rossmann, physio]
    static let otherMisc: [Merchant] = [hornbach, ikea, thalia]
}
