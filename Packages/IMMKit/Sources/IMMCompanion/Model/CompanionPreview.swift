import Foundation
import IMMLedger
import IMMSyncCore

/// A state of the companion for previews and screenshots (`CompanionModel.preview(_:)`).
public enum CompanionPreviewState: Sendable, CaseIterable {
    case welcome
    case scanning
    case connecting
    /// Code 482 913 for "Robin's MacBook".
    case confirm
    case waitingForMac
    case importing
    case failed
    case locked
    /// Paired and synced, with demo-like data.
    case ready
}

extension CompanionModel {
    /// A model in `state` with canned values; it performs no I/O. In `.ready`, `transactions`, `detail`, `setCategory` and
    /// `setNote` work on the canned rows; `unlock()` returns to the state's phase.
    public static func preview(_ state: CompanionPreviewState) -> CompanionModel {
        CompanionModel(previewing: CompanionPreviewContent(state))
    }
}

struct PreviewKeyStore: CompanionKeyStore {
    func hasKey() -> Bool { true }
    func createKey() throws -> String { "preview" }
    func readKey(reason: String) async throws -> String { "preview" }
    func deleteKey() {}
}

/// What a preview model shows and serves.
struct CompanionPreviewContent: Sendable {
    static let macName = "Robin's MacBook"

    var phase: CompanionModel.Phase
    var syncStatus: CompanionSyncStatus = .idle
    var macName: String?
    var overview: CompanionOverview?
    var accounts: [CompanionAccount] = []
    var categories: [CompanionCategory] = []
    private var order: [String] = []
    private var details: [String: CompanionTransactionDetail] = [:]

    init(_ state: CompanionPreviewState) {
        switch state {
        case .welcome:
            phase = .welcome
        case .scanning:
            phase = .pairing(.scanning)
        case .connecting:
            phase = .pairing(.connecting(macName: Self.macName))
        case .confirm:
            phase = .pairing(.confirm(code: ShortAuthCode(value: 482_913)!, macName: Self.macName))
        case .waitingForMac:
            phase = .pairing(.waitingForMac(macName: Self.macName))
        case .importing:
            phase = .pairing(.importing)
        case .failed:
            phase = .pairing(.failed(message: CompanionMessages.codesMismatch))
        case .locked:
            phase = .locked
        case .ready:
            phase = .ready
            syncStatus = .synced(at: Date())
            macName = Self.macName
            loadDemo()
        }
    }

    // MARK: Serving

    func transactions(accountID: String?, search: String) -> [CompanionTransaction] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return order.compactMap { details[$0] }
            .filter { accountID == nil || $0.transaction.accountID == accountID }
            .filter {
                terms.isEmpty
                    || CompanionQueries.matches(
                        [$0.transaction.counterparty, $0.transaction.purpose, $0.note, $0.transaction.categoryName], terms: terms)
            }
            .prefix(CompanionQueries.listLimit)
            .map(\.transaction)
    }

    func detail(transactionID: String) -> CompanionTransactionDetail? { details[transactionID] }

    mutating func setCategory(_ categoryID: String?, transactionID: String) {
        guard var current = details[transactionID] else { return }
        let category = categoryID.flatMap { id in categories.first { $0.id == id } }
        current.categoryID = category?.id
        current.transaction.categoryName = category?.name
        current.transaction.categoryColorToken = category?.colorToken
        details[transactionID] = current
        let count = uncategorisedCount
        overview?.uncategorisedCount = count
    }

    mutating func setNote(_ note: String, transactionID: String) {
        details[transactionID]?.note = note.isEmpty ? nil : note
    }

    var uncategorisedCount: Int { details.values.filter { $0.categoryID == nil }.count }

    // MARK: Demo data (shaped like the Mac's demo ledger, `ledger_today` 12.11.2026)

    private mutating func loadDemo() {
        categories = [
            CompanionCategory(id: "cat-housing", name: "Housing", colorToken: "chart-1", isIncome: false),
            CompanionCategory(id: "cat-groceries", name: "Groceries", colorToken: "chart-5", isIncome: false),
            CompanionCategory(id: "cat-mobility", name: "Mobility", colorToken: "chart-3", isIncome: false),
            CompanionCategory(id: "cat-leisure", name: "Leisure", colorToken: "chart-2", isIncome: false),
            CompanionCategory(id: "cat-insurance", name: "Insurance", colorToken: "chart-4", isIncome: false),
            CompanionCategory(id: "cat-health", name: "Health", colorToken: "muted-foreground", isIncome: false),
            CompanionCategory(id: "cat-other", name: "Other", colorToken: "input", isIncome: false),
            CompanionCategory(id: "cat-income", name: "Income", colorToken: "credit", isIncome: true),
        ]
        accounts = [
            CompanionAccount(
                id: "acc-giro", name: "Girokonto", bankName: "Sparkasse KölnBonn", subtitle: "Sparkasse KölnBonn · DE80 … 0827 51",
                balance: 342_815, currency: "EUR", kind: "giro"),
            CompanionAccount(
                id: "acc-savings", name: "Tagesgeld", bankName: "ING", subtitle: "ING · DE12 … 4410 02", balance: 1_850_000,
                currency: "EUR", kind: "savings"),
            CompanionAccount(
                id: "acc-card", name: "Visa Card", bankName: "DKB", subtitle: "DKB · Statement 20.11.", balance: -48_230,
                currency: "EUR", kind: "credit_card"),
            CompanionAccount(
                id: "acc-depot", name: "Depot", bankName: "Trade Republic", subtitle: "Trade Republic · 4 securities",
                balance: 2_473_190, currency: "EUR", kind: "depot"),
        ]

        let today = LocalDate(year: 2026, month: 11, day: 12)
        let rows: [(id: String, account: String, daysAgo: Int, payee: String, purpose: String, amount: Int, category: String?, iban: String?, text: String)] = [
            ("tx-1", "acc-giro", 0, "REWE Markt", "Kartenzahlung REWE SAGT DANKE", -4_732, "cat-groceries", nil, "Kartenzahlung"),
            ("tx-2", "acc-card", 0, "Deutsche Bahn", "Ticket Köln – Berlin", -5_990, "cat-mobility", nil, "Kartenzahlung"),
            ("tx-3", "acc-giro", 1, "Spotify", "Premium Individual", -1_199, "cat-leisure", "SE35 5000 0000 0549 1000 0003", "Lastschrift"),
            ("tx-4", "acc-giro", 2, "Café Reichard", "Frühstück", -1_480, nil, nil, "Kartenzahlung"),
            ("tx-5", "acc-giro", 3, "Stadtwerke Köln", "Abschlag Strom November", -8_900, "cat-housing", "DE44 3705 0198 0000 1234 56", "Lastschrift"),
            ("tx-6", "acc-giro", 4, "dm-drogerie markt", "Kartenzahlung dm", -2_345, "cat-health", nil, "Kartenzahlung"),
            ("tx-7", "acc-giro", 5, "Allianz Versicherung", "Haftpflicht 11/2026", -2_150, "cat-insurance", "DE02 1007 0000 0123 4567 89", "Lastschrift"),
            ("tx-8", "acc-card", 6, "Amazon", "Bestellung 302-1234567-8901234", -3_999, nil, nil, "Kartenzahlung"),
            ("tx-9", "acc-giro", 8, "Vermieter Müller", "Miete November", -92_000, "cat-housing", "DE89 3704 0044 0532 0130 00", "Dauerauftrag"),
            ("tx-10", "acc-giro", 9, "Acme GmbH", "Gehalt 10/2026", 385_000, "cat-income", "DE75 5121 0800 1245 1261 99", "Gutschrift"),
            ("tx-11", "acc-giro", 10, "ALDI SÜD", "Kartenzahlung ALDI", -3_118, "cat-groceries", nil, "Kartenzahlung"),
            ("tx-12", "acc-savings", 11, "Girokonto", "Sparrate", 50_000, nil, nil, "Umbuchung"),
        ]
        for row in rows {
            let category = row.category.flatMap { id in categories.first { $0.id == id } }
            let date = today.adding(days: -row.daysAgo)
            let transaction = CompanionTransaction(
                id: row.id, accountID: row.account, bookingDate: date, counterparty: row.payee, purpose: row.purpose, amount: row.amount,
                currency: "EUR", categoryName: category?.name, categoryColorToken: category?.colorToken, isPending: row.id == "tx-2")
            order.append(row.id)
            details[row.id] = CompanionTransactionDetail(
                transaction: transaction, accountName: accounts.first { $0.id == row.account }?.name ?? "", valueDate: date,
                counterpartyIBAN: row.iban, bookingText: row.text, note: row.id == "tx-9" ? "Rent, paid by standing order" : nil,
                categoryID: category?.id)
        }
        overview = CompanionOverview(
            netWorth: accounts.reduce(0) { $0 + $1.balance }, spentThisMonth: 187_642, averageMonthlySpending: 262_300,
            uncategorisedCount: 0, recent: Array(order.prefix(CompanionQueries.recentCount).compactMap { details[$0]?.transaction }))
        let count = uncategorisedCount
        overview?.uncategorisedCount = count
    }
}
