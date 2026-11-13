import Foundation
import GRDB
import Testing
import IMMLedger
@testable import IMMBanking

/// An encrypted, migrated ledger in a temporary directory, filled with the demo data set.
private final class ImportFixture: Sendable {
    let directory: URL
    let store: LedgerStore
    let bank: DemoBank

    init(import shouldImport: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("imm-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase("x'" + String(repeating: "ef", count: 32) + "'")
        }
        let pool = try DatabasePool(path: directory.appendingPathComponent("data.sqlite").path, configuration: configuration)
        store = try LedgerStore(database: pool)
        bank = try DemoDataset.load()
        if shouldImport {
            try LedgerImporter.importSnapshot(bank.snapshot, profile: bank.profile, into: store)
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func counts() throws -> [String: Int] {
        try store.database.read { db in
            var result: [String: Int] = [:]
            for table in LedgerSchema.entityTables {
                result[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return result
        }
    }
}

private func day(_ iso: String) -> LocalDate {
    guard let date = LocalDate(iso: iso) else { fatalError("bad date \(iso)") }
    return date
}

private func money(_ cents: Int) -> String { MoneyFormatter.string(cents) }

@Suite struct ImportTests {
    // MARK: Idempotence

    @Test func importingTwiceCreatesNoDuplicates() throws {
        let fixture = try ImportFixture()
        let first = try fixture.counts()
        #expect(first["account"] == 5)
        #expect(first["bank_login"] == 4)
        #expect(first["category"] == 8)
        #expect((first["ledger_transaction"] ?? 0) > 148)
        try LedgerImporter.importSnapshot(fixture.bank.snapshot, profile: fixture.bank.profile, into: fixture.store)
        let second = try fixture.counts()
        #expect(first == second)
    }

    @Test func importKeepsUserCategoryChanges() throws {
        let fixture = try ImportFixture()
        let reference = try #require(fixture.bank.snapshot.transactions.first { fixture.bank.profile.categoryByReference[$0.reference] != nil })
        let id = try fixture.store.database.read {
            try #require(try String.fetchOne($0, sql: "SELECT id FROM ledger_transaction WHERE bank_ref = ?", arguments: [reference.reference]))
        }
        try fixture.store.writer.setCategory(transactionID: id, categoryID: nil)
        try LedgerImporter.importSnapshot(fixture.bank.snapshot, profile: fixture.bank.profile, into: fixture.store)
        let category = try fixture.store.database.read {
            try String?.fetchOne($0, sql: "SELECT category_id FROM ledger_transaction WHERE bank_ref = ?", arguments: [reference.reference]) ?? nil
        }
        #expect(category == nil)
    }

    @Test func importWithoutProfileWritesBankDataOnly() throws {
        let fixture = try ImportFixture(import: false)
        try LedgerImporter.importSnapshot(fixture.bank.snapshot, profile: nil, into: fixture.store)
        let counts = try fixture.counts()
        #expect(counts["account"] == 5)
        #expect(counts["category"] == 0)
        #expect(counts["rule"] == 0)
        #expect(counts["insight"] == 0)
        let flagged = try fixture.store.database.read { db in
            try LedgerDefinitions.newCount(db)
        }
        #expect(flagged == 0)
        #expect(try fixture.store.setting(.demoOnly) == nil)
    }

    @Test func importFailsAtomically() throws {
        let fixture = try ImportFixture(import: false)
        var snapshot = fixture.bank.snapshot
        let bad = BankTransaction(
            reference: "BAD", accountID: "no-such-account", bookingDate: day("2026-11-01"), valueDate: day("2026-11-01"),
            bookedTime: nil, sequence: 1, amount: -100, counterpartyName: "x", shortName: "x", counterpartyIBAN: nil,
            bookingText: "x", purpose: "x", creditorID: nil, kind: .transfer)
        snapshot.transactions.append(bad)
        #expect(throws: LedgerImportError.unknownAccount("no-such-account")) {
            try LedgerImporter.importSnapshot(snapshot, profile: fixture.bank.profile, into: fixture.store)
        }
        let counts = try fixture.counts()
        #expect(counts["account"] == 0)
        #expect(counts["ledger_transaction"] == 0)
    }

    @Test func settingsAreSet() throws {
        let fixture = try ImportFixture()
        #expect(try fixture.store.setting(.demoOnly) == "1")
        #expect(try fixture.store.setting(.ledgerToday) == "2026-11-12")
        #expect(try fixture.store.today() == day("2026-11-12"))
    }

    // MARK: Hard anchors

    @Test func accountBalancesAndNetWorth() throws {
        let fixture = try ImportFixture()
        try fixture.store.database.read { db in
            let balances = try Dictionary(uniqueKeysWithValues: AccountRecord.fetchAll(db).map { ($0.name, $0) })
            #expect(balances["Girokonto"]?.balance == 241_836)
            #expect(balances["Girokonto"]?.overdraftLimit == 200_000)
            #expect(balances["Tagesgeld"]?.balance == 1_205_000)
            #expect(balances["Visa Card"]?.balance == -38_412)
            #expect(balances["Wallet"]?.balance == 6_190)
            let depot = try #require(balances["Depot"])
            #expect(try LedgerDefinitions.holdingsValue(db, accountID: depot.id) == 4_891_240)
            #expect(money(try LedgerDefinitions.netWorth(db)) == "63.058,54\u{00A0}€")
            #expect(money(try LedgerDefinitions.netWorth(db, on: day("2026-10-31"))) == "61.854,36\u{00A0}€")
        }
    }

    @Test func girokontoRowsAndBalances() throws {
        let fixture = try ImportFixture()
        try fixture.store.database.read { db in
            let giro = try #require(try AccountRecord.fetchOne(db, sql: "SELECT * FROM account WHERE kind = 'giro'"))
            let balances = try LedgerDefinitions.runningBalances(db, accountID: giro.id)
            func balance(_ date: String, _ short: String) throws -> String {
                let rows = try TransactionRecord.fetchAll(
                    db, sql: "SELECT * FROM ledger_transaction WHERE account_id = ? AND booking_date = ? AND short_name = ?",
                    arguments: [giro.id, date, short])
                let row = try #require(rows.first, "missing \(short) \(date)")
                return MoneyFormatter.string(try #require(balances[row.id]), symbol: false)
            }
            #expect(try balance("2026-11-11", "REWE") == "2.418,36")
            #expect(try balance("2026-11-10", "Lieferando") == "2.481,84")
            #expect(try balance("2026-11-09", "dm-drogerie markt") == "2.509,74")
            #expect(try balance("2026-11-07", "Deutsche Bahn") == "2.528,19")
            #expect(try balance("2026-11-05", "Stadtwerke Köln") == "2.578,09")
            #expect(try balance("2026-11-03", "Urban Sports Club") == "2.664,09")
            // 01.11.: Miete is the latest row of the day, then KVB, then HUK.
            #expect(try balance("2026-11-01", "Miete Wohnbau Ehrenfeld eG") == "2.728,09")
            #expect(try balance("2026-11-01", "KVB Deutschlandticket") == "3.848,09")
            #expect(try balance("2026-11-01", "HUK-COBURG") == "3.906,09")
            #expect(try balance("2026-10-27", "Gehalt Rheinwerk Design GmbH") == "3.944,79")
            #expect(try balance("2026-10-24", "REWE") == "104,79")

            let afterOctober = try Int.fetchOne(
                db, sql: "SELECT SUM(amount) FROM ledger_transaction WHERE account_id = ? AND booking_date >= '2026-11-01'", arguments: [giro.id]) ?? 0
            #expect(giro.balance - afterOctober == 394_479)
            #expect(afterOctober == -152_643)
            let novemberCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM ledger_transaction WHERE account_id = ? AND booking_date >= '2026-11-01'", arguments: [giro.id]) ?? 0
            #expect(novemberCount == 9)
        }
    }

    @Test func overviewSpendingAndAverage() throws {
        let fixture = try ImportFixture()
        try fixture.store.database.read { db in
            let today = try LedgerClock.today(db)
            #expect(today == day("2026-11-12"))
            let spending = try LedgerDefinitions.spending(db, from: today.firstOfMonth, through: today)
            var byName: [String: Int] = [:]
            for category in try CategoryRecord.fetchAll(db) { byName[category.name] = spending[category.id] ?? 0 }
            #expect(byName["Housing"] == 120_600)
            #expect(byName["Groceries"] == 31_845)
            #expect(byName["Leisure & eating out"] == 17_665)
            #expect(byName["Mobility"] == 17_260)
            #expect(byName["Insurance & contracts"] == 3_870)
            #expect(byName["Health & drugstore"] == 0)
            #expect(byName["Other"] == 0)
            #expect(spending.values.reduce(0, +) == 191_240)
            #expect(try LedgerDefinitions.monthlyAverageSpending(db, today: today) == 248_000)
        }
    }

    @Test func countsMatchTheDesign() throws {
        let fixture = try ImportFixture()
        try fixture.store.database.read { db in
            #expect(try LedgerDefinitions.newCount(db) == 14)
            #expect(try LedgerDefinitions.uncategorisedCount(db) == 6)
            let giro = try #require(try AccountRecord.fetchOne(db, sql: "SELECT * FROM account WHERE kind = 'giro'"))
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM ledger_transaction WHERE account_id = ? AND booking_date BETWEEN '2026-08-14' AND '2026-11-12'",
                arguments: [giro.id]) ?? 0
            #expect(count == 148)
            #expect(try RuleRecord.fetchCount(db) == 34)
        }
    }

    @Test func derivedRecordsArePresent() throws {
        let fixture = try ImportFixture()
        try fixture.store.database.read { db in
            let orders = try StandingOrderRecord.fetchAll(db)
            let monthly = orders.filter { $0.status == .active && $0.rhythm == .monthly }.map(\.amount).reduce(0, +)
            #expect(monthly == -196_000)
            let contracts = try ContractRecord.fetchAll(db).filter { $0.kind == .contract }
            #expect(contracts.map(\.monthlyAmount).reduce(0, +) == -144_100)
            let holdings = try HoldingRecord.fetchAll(db)
            #expect(holdings.map(\.costBasis).reduce(0, +) == 4_159_418)
            let plan = try #require(try SavingsPlanRecord.fetchOne(db))
            #expect(plan.amount == 50_000)
            let items = try SavingsPlanItemRecord.fetchAll(db)
            #expect(items.map(\.amount).sorted() == [20_000, 30_000])
            #expect(try InsightRecord.fetchCount(db) > 0)
            // Every insight that cites a transaction points to a real row.
            let dangling = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM insight WHERE transaction_id IS NOT NULL AND transaction_id NOT IN (SELECT id FROM ledger_transaction)") ?? 0
            #expect(dangling == 0)
        }
    }

    @Test func accountsCarryLoginsAndSyncTime() throws {
        let fixture = try ImportFixture()
        try fixture.store.database.read { db in
            let accounts = try AccountRecord.fetchAll(db)
            #expect(accounts.allSatisfy { $0.bankLoginId != nil && $0.lastSyncedAt != nil && $0.syncStatus == .ok })
        }
    }

    @Test func sameDayRowsKeepDatasetOrder() throws {
        let fixture = try ImportFixture()
        try fixture.store.database.read { db in
            let rows = try TransactionRecord.fetchAll(
                db, sql: "SELECT * FROM ledger_transaction WHERE booking_date = '2026-11-01' AND short_name IN ('Miete Wohnbau Ehrenfeld eG', 'KVB Deutschlandticket', 'HUK-COBURG')")
            let seq = Dictionary(uniqueKeysWithValues: rows.map { ($0.shortName ?? "", $0.bookingSeq) })
            #expect(try #require(seq["Miete Wohnbau Ehrenfeld eG"]) > #require(seq["KVB Deutschlandticket"]))
            #expect(try #require(seq["KVB Deutschlandticket"]) > #require(seq["HUK-COBURG"]))
        }
    }

    // MARK: Booking

    @Test func bookingATransferMovesTheBalance() throws {
        let fixture = try ImportFixture()
        let giro = try fixture.store.database.read { try #require(try AccountRecord.fetchOne($0, sql: "SELECT * FROM account WHERE kind = 'giro'")) }
        let transaction = BankTransaction(
            reference: "DEMO-PAY-TEST", accountID: giro.id, bookingDate: day("2026-11-12"), valueDate: day("2026-11-12"),
            bookedTime: "10:15", sequence: 1, amount: -12_000, counterpartyName: "Jonas Weber", shortName: "Jonas Weber",
            counterpartyIBAN: "DE05120300001056778912", bookingText: "Überweisung", purpose: "Konzertkarten Dezember",
            creditorID: nil, kind: .transfer)
        try LedgerImporter.book(.booked(transaction), into: fixture.store)
        try LedgerImporter.book(.booked(transaction), into: fixture.store) // idempotent
        try fixture.store.database.read { db in
            let account = try #require(try AccountRecord.fetchOne(db, key: giro.id))
            #expect(account.balance == 229_836)
            #expect(money(account.balance) == "2.298,36\u{00A0}€")
            let balances = try LedgerDefinitions.runningBalances(db, accountID: giro.id)
            let row = try #require(try TransactionRecord.fetchOne(db, sql: "SELECT * FROM ledger_transaction WHERE bank_ref = 'DEMO-PAY-TEST'"))
            #expect(balances[row.id] == 229_836)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ledger_transaction WHERE bank_ref = 'DEMO-PAY-TEST'") ?? 0
            #expect(count == 1)
            #expect(try LedgerDefinitions.netWorth(db) == 6_305_854 - 12_000)
        }
    }

    @Test func syncKeepsLocallyBookedPaymentsInTheBalance() throws {
        let fixture = try ImportFixture()
        let giro = try fixture.store.database.read { try #require(try AccountRecord.fetchOne($0, sql: "SELECT * FROM account WHERE kind = 'giro'")) }
        let transaction = BankTransaction(
            reference: "DEMO-PAY-RESYNC", accountID: giro.id, bookingDate: day("2026-11-12"), valueDate: day("2026-11-12"),
            bookedTime: "10:15", sequence: 1, amount: -12_000, counterpartyName: "Jonas Weber", shortName: "Jonas Weber",
            counterpartyIBAN: nil, bookingText: "Überweisung", purpose: "x", creditorID: nil, kind: .transfer)
        try LedgerImporter.book(.booked(transaction), into: fixture.store)
        try LedgerImporter.importSnapshot(fixture.bank.snapshot, profile: fixture.bank.profile, into: fixture.store)
        let balance = try fixture.store.database.read { try AccountRecord.fetchOne($0, key: giro.id)?.balance }
        #expect(balance == 229_836)
    }

    @Test func bookingAScheduledPaymentCreatesAStandingOrder() throws {
        let fixture = try ImportFixture()
        let giro = try fixture.store.database.read { try #require(try AccountRecord.fetchOne($0, sql: "SELECT * FROM account WHERE kind = 'giro'")) }
        let before = try fixture.counts()
        let order = BankStandingOrder(
            id: "demo-so-test", accountID: giro.id, recipient: "Schreinerei Kaiser GmbH", iban: "DE89370400440532013000",
            purpose: "Rechnung 2026-118", amount: -64_000, rhythm: .once, dayOfMonth: nil, nextExecution: day("2026-11-30"),
            status: .scheduled)
        try LedgerImporter.book(.scheduled(order), into: fixture.store)
        try LedgerImporter.book(.scheduled(order), into: fixture.store)
        let after = try fixture.counts()
        #expect((after["standing_order"] ?? 0) == (before["standing_order"] ?? 0) + 1)
        #expect(after["ledger_transaction"] == before["ledger_transaction"])
        let balance = try fixture.store.database.read { try AccountRecord.fetchOne($0, key: giro.id)?.balance }
        #expect(balance == giro.balance)
    }
}
