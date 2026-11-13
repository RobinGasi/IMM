import Foundation
import GRDB
import Testing
import IMMLedger
@testable import IMMBanking

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func nov(_ day: Int) -> LocalDate { LocalDate(year: 2026, month: 11, day: day) }

private func booking(
    _ reference: String, _ date: LocalDate, _ amount: Int, name: String = "Kiosk", iban: String? = nil, purpose: String = "Kiosk Ehrenfeld",
    pending: Bool = false
) -> BankTransaction {
    BankTransaction(
        reference: reference, accountID: "acct", bookingDate: date, valueDate: date, bookedTime: nil, sequence: 1, amount: amount,
        counterpartyName: name, shortName: name, counterpartyIBAN: iban, bookingText: "Kartenzahlung", purpose: purpose,
        creditorID: nil, kind: .cardPayment, isPending: pending)
}

@Suite struct BookingIdentityTests {
    private let account = BookingIdentity.accountID(bankCode: "37050198", accountNumber: "DE02370501980000123456")

    @Test func uuidV8MatchesRFC9562AppendixB2() {
        let dns: [UInt8] = [0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        let id = BookingIdentity.uuidV8(sha256Of: Data(dns) + Data("www.example.com".utf8))
        #expect(id.uuidString.lowercased() == "5c146b14-3c52-8afd-938a-375d0df1fbf6")
    }

    @Test func accountIDIsStableAndKeyedByIBANOrBankCodeAndNumber() {
        #expect(account == "0F172802-68D7-8178-97C0-98D22EB58F92")
        #expect(account == BookingIdentity.accountID(bankCode: "", accountNumber: "de02 3705 0198 0000 1234 56"))
        let card = BookingIdentity.accountID(bankCode: "12030000", accountNumber: "•••• 4417")
        #expect(card != BookingIdentity.accountID(bankCode: "10010010", accountNumber: "•••• 4417"))
        #expect(UUID(uuidString: card) != nil)
    }

    @Test func pendingFlagDefaultsToFalseAndIsOmittedFromJSON() throws {
        let tx = booking("r", nov(5), -100)
        #expect(!tx.isPending)
        let json = String(decoding: try JSONEncoder().encode(tx), as: UTF8.self)
        #expect(!json.contains("isPending"))
        #expect(try JSONDecoder().decode(BankTransaction.self, from: Data(json.utf8)) == tx)
        let pending = booking("r", nov(5), -100, pending: true)
        let decoded = try JSONDecoder().decode(BankTransaction.self, from: JSONEncoder().encode(pending))
        #expect(decoded.isPending)
    }

    @Test func idsFollowContentNotReferencesOrValueDates() {
        let a = booking("REF-A", nov(5), -4999)
        var b = booking("OTHER-REF", nov(5), -4999)
        b.valueDate = nov(7)
        b.bookingText = "Lastschrift"
        b.bookedTime = "11:11"
        #expect(BookingIdentity.bookingIDs(for: [a], accountID: account) == BookingIdentity.bookingIDs(for: [b], accountID: account))
        var changed = a
        changed.amount = -5000
        #expect(BookingIdentity.bookingIDs(for: [a], accountID: account) != BookingIdentity.bookingIDs(for: [changed], accountID: account))
        #expect(BookingIdentity.bookingIDs(for: [a], accountID: account) != BookingIdentity.bookingIDs(for: [a], accountID: BookingIdentity.accountID(bankCode: "1", accountNumber: "2")))
    }

    @Test func identicalTwinsGetTwoStableIDsInAnyDeliveryOrder() {
        let twin1 = booking("T-1", nov(5), -4999)
        let twin2 = booking("T-2", nov(5), -4999)
        let other = booking("O", nov(5), -100)
        let forward = BookingIdentity.bookingIDs(for: [twin1, other, twin2], accountID: account)
        let reversed = BookingIdentity.bookingIDs(for: [twin2, other, twin1], accountID: account)
        #expect(forward[0] != forward[2])
        #expect(forward[0] == reversed[2] && forward[2] == reversed[0])       // by reference, not by position
        #expect(forward[1] == reversed[1])
        // Without usable references the multiset of ids is still the same.
        let noRef1 = BookingIdentity.bookingIDs(for: [booking("NONREF", nov(5), -4999), booking("NONREF", nov(5), -4999)], accountID: account)
        #expect(Set(noRef1).count == 2 && Set(noRef1) == Set([forward[0], forward[2]]))
    }

    @Test func aGrowingDayKeepsItsFirstIDs() {
        // A fetched at noon (one kiosk item), B in the evening (two).
        let noon = BookingIdentity.bookingIDs(for: [booking("1", nov(5), -640)], accountID: account)
        let evening = BookingIdentity.bookingIDs(for: [booking("1", nov(5), -640), booking("2", nov(5), -640)], accountID: account)
        #expect(Set(noon).isSubset(of: Set(evening)) && evening.count == 2)
    }

    /// The same bookings as MT940 and camt render them: wrapped, trimmed, differently cased, umlauts spelled out. (Tags such
    /// as `SVWZ+` are stripped by the connector's parser before the text reaches the identity.)
    @Test func formatDifferencesInTextDoNotChangeIDs() {
        let camt = booking("c", nov(9), -2999, name: "Müller & Söhne GmbH", iban: "DE02120300000000202051",
                           purpose: "Rechnungsnr1234567890A Kundennr 99 Tarif Magenta")
        let mt940 = booking("m", nov(9), -2999, name: "MUELLER SOEHNE GMBH", iban: "DE02 1203 0000 0000 2020 51",
                            purpose: "Rechnungsnr1234567890AKundennr 99 Tarif Magenta")
        #expect(BookingIdentity.bookingIDs(for: [camt], accountID: account) == BookingIdentity.bookingIDs(for: [mt940], accountID: account))
        // Without an IBAN the normalised name stands in.
        let camtName = booking("c", nov(9), -2999, name: "Müller & Söhne GmbH")
        let mt940Name = booking("m", nov(9), -2999, name: "MUELLER SOEHNE GMBH")
        #expect(BookingIdentity.bookingIDs(for: [camtName], accountID: account) == BookingIdentity.bookingIDs(for: [mt940Name], accountID: account))
    }

    /// Property: random ledgers, device A fetches everything, device B a random later window
    /// whose first day is complete, the order inside each day is shuffled. Ids are unique per device and B's are a subset of A's.
    @Test func windowsAndInDayOrderNeverChangeOverlappingIDs() {
        var rng = SeededRandom(seed: 10)
        var twinsExercised = 0
        for _ in 0..<600 {
            var ledger: [BankTransaction] = []
            for dayNumber in 1...20 {
                for _ in 0..<Int.random(in: 0...4, using: &rng) {
                    let kind = Int.random(in: 0..<3, using: &rng)       // few distinct contents so twins are common
                    let tx = booking(
                        Bool.random(using: &rng) ? "NONREF" : "REF-\(UUID().uuidString.prefix(6))", nov(dayNumber), -(kind + 1) * 100,
                        name: ["Kiosk", "Bäcker", "Bahn"][kind], purpose: ["a", "b", "c"][Int.random(in: 0..<2, using: &rng)])
                    ledger.append(tx)
                }
            }
            let start = Int.random(in: 1...20, using: &rng)
            let windowB = ledger.filter { $0.bookingDate.day >= start }
            let a = BookingIdentity.bookingIDs(for: ledger.shuffled(using: &rng), accountID: account)
            let shuffledB = windowB.shuffled(using: &rng)
            let b = BookingIdentity.bookingIDs(for: shuffledB, accountID: account)
            #expect(Set(a).count == a.count)
            #expect(Set(b).count == b.count)
            #expect(Set(b).isSubset(of: Set(a)))
            if Dictionary(grouping: ledger, by: { "\($0.bookingDate)\($0.amount)\($0.counterpartyName)\($0.purpose)" }).values.contains(where: { $0.count > 1 }) {
                twinsExercised += 1
            }
        }
        #expect(twinsExercised > 100)
    }
}

/// Importing through the ledger: identity, pending bookings and independent devices.
@Suite struct ImportIdentityTests {
    private final class Vault: Sendable {
        let directory: URL
        let store: LedgerStore
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("imm-ident-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.prepareDatabase { db in try db.usePassphrase("x'" + String(repeating: "ef", count: 32) + "'") }
            store = try LedgerStore(database: try DatabasePool(path: directory.appendingPathComponent("data.sqlite").path, configuration: configuration))
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func ids(_ table: String) throws -> Set<String> {
            try store.database.read { Set(try String.fetchAll($0, sql: "SELECT id FROM \(table)")) }
        }
    }

    private func importDemo(_ bank: DemoBank, into vault: Vault, transactions: [BankTransaction]? = nil) throws {
        var snapshot = bank.snapshot
        if let transactions { snapshot.transactions = transactions }
        try LedgerImporter.importSnapshot(snapshot, profile: bank.profile, into: vault.store)
    }

    @Test func twoIndependentImportsInDifferentOrdersAndWindowsAgreeOnEveryID() throws {
        let bank = try DemoDataset.load()
        let first = try Vault(), second = try Vault(), windowed = try Vault()
        try importDemo(bank, into: first)
        var rng = SeededRandom(seed: 5)
        try importDemo(bank, into: second, transactions: bank.snapshot.transactions.shuffled(using: &rng))
        let cutoff = LocalDate(year: 2026, month: 9, day: 1)
        try importDemo(bank, into: windowed, transactions: bank.snapshot.transactions.filter { $0.bookingDate >= cutoff }.shuffled(using: &rng))

        for table in ["account", "ledger_transaction", "security", "holding", "depot_value_history", "savings_plan", "savings_plan_item"] {
            #expect(try first.ids(table) == second.ids(table), "\(table)")
        }
        let all = try first.ids("ledger_transaction")
        let some = try windowed.ids("ledger_transaction")
        #expect(some.count < all.count && !some.isEmpty)
        #expect(some.isSubset(of: all))
        // Booking dates of the windowed import really start at the cutoff.
        let earliest = try windowed.store.database.read { try String.fetchOne($0, sql: "SELECT MIN(booking_date) FROM ledger_transaction") }
        #expect(earliest.map { $0 >= cutoff.iso } == true)
    }

    @Test func everyAccountIsKeyedByBankCodeAndNumber() throws {
        let bank = try DemoDataset.load()
        let vault = try Vault()
        try importDemo(bank, into: vault)
        let rows = try vault.store.database.read { try Row.fetchAll($0, sql: "SELECT id, iban, connector_account_id, bank_login_id FROM account") }
        #expect(rows.count == 5)
        for row in rows {
            let connector: String = row["connector_account_id"]
            let source = try #require(bank.snapshot.accounts.first { $0.id == connector })
            let login = try #require(bank.profile.logins.first { $0.id == source.loginKey })
            let expected = BookingIdentity.accountID(bankCode: login.bankCode, accountNumber: source.iban ?? source.number ?? source.id)
            #expect(row["id"] as String == expected)
            #expect(row["bank_login_id"] as String == source.loginKey)
        }
    }

    @Test func pendingBookingsStayOutOfTheLedger() throws {
        let bank = try DemoDataset.load()
        let vault = try Vault()
        try importDemo(bank, into: vault)
        let giro = try #require(bank.snapshot.accounts.first { $0.kind == .giro })
        let ledgerBookings = try vault.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ledger_transaction") }

        var snapshot = bank.snapshot
        snapshot.transactions.append(booking("PEND-1", nov(12), -3499, name: "Amazon EU SARL", purpose: "AMAZON.DE 028-123", pending: true))
        snapshot.transactions.append(booking("PEND-2", nov(12), -1250, name: "Bäckerei", pending: true))
        snapshot.transactions = snapshot.transactions.map { var t = $0; if t.reference.hasPrefix("PEND") { t.accountID = giro.id }; return t }
        try LedgerImporter.importSnapshot(snapshot, profile: bank.profile, into: vault.store)

        let pending = try vault.store.database.read { try PendingTransactionRecord.order(Column("position")).fetchAll($0) }
        #expect(pending.map(\.amount) == [-3499, -1250])
        #expect(pending.map(\.position) == [0, 1])
        #expect(try vault.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ledger_transaction") } == ledgerBookings)
        // Never part of sync.
        #expect(try vault.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_op WHERE tbl = 'pending_transaction'") } == 0)
        // Spending, balances and "new" ignore them.
        let newCount = try vault.store.database.read { try LedgerDefinitions.newCount($0) }
        #expect(newCount == 14)

        // The next fetch replaces the whole set; an empty answer empties it.
        try importDemo(bank, into: vault)
        #expect(try vault.store.database.read { try PendingTransactionRecord.fetchCount($0) } == 0)
    }

    @Test func aBookedPaymentGetsTheContentIDAHistoricalFetchWouldGive() throws {
        let bank = try DemoDataset.load()
        let vault = try Vault()
        try importDemo(bank, into: vault)
        let giro = try vault.store.database.read { try #require(try AccountRecord.fetchOne($0, sql: "SELECT * FROM account WHERE kind = 'giro'")) }
        var payment = booking("DEMO-PAY-X", nov(12), -12_000, name: "Jonas Weber", iban: "DE05120300001056778912", purpose: "Konzertkarten")
        payment.accountID = giro.id
        try LedgerImporter.book(.booked(payment), into: vault.store)
        let stored = try vault.store.database.read { try Row.fetchOne($0, sql: "SELECT id FROM ledger_transaction WHERE bank_ref = 'DEMO-PAY-X'") }
        #expect(stored?["id"] as String? == BookingIdentity.bookingIDs(for: [payment], accountID: giro.id)[0])
        // A second identical payment is a second booking, not a duplicate.
        var twin = payment
        twin.reference = "DEMO-PAY-Y"
        try LedgerImporter.book(.booked(twin), into: vault.store)
        #expect(try vault.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ledger_transaction WHERE counterparty_name = 'Jonas Weber' AND booking_date = '2026-11-12' AND amount = -12000") } == 2)
    }

    @Test func importsWriteThroughTheLedgerWriter() throws {
        let bank = try DemoDataset.load()
        let vault = try Vault()
        try importDemo(bank, into: vault)
        let ops = try vault.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_op") } ?? 0
        #expect(ops > 1_000)
        // A second, identical import writes ops only for what changed (account sync times), none for bookings.
        try importDemo(bank, into: vault)
        let bookingOps = try vault.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_op WHERE tbl = 'ledger_transaction' AND seq > ?", arguments: [ops]) }
        #expect(bookingOps == 0)
        let total = try vault.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_op") } ?? 0
        #expect(total - ops <= 5 * 3)
        // And a second device that applies the first one's ops holds the same synced data.
        let writer = vault.store.writer
        let replica = try Vault()
        let all = try writer.ops(from: writer.localNode, after: 0, limit: .max)
        try replica.store.writer.applyRemote(all)
        #expect(try replica.store.writer.snapshot().tables["ledger_transaction"] == writer.snapshot().tables["ledger_transaction"])
        #expect(try replica.store.writer.snapshot().converged.fieldClocks == writer.snapshot().converged.fieldClocks)
    }
}
