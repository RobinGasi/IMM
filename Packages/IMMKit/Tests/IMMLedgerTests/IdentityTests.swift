import CryptoKit
import Foundation
import Testing
@testable import IMMLedger

@Suite struct IdentityTests {
    // MARK: RFC 9562

    /// RFC 9562 Appendix B.2: UUIDv8 from SHA-256 over the DNS namespace and "www.example.com".
    @Test func uuidV8MatchesTheRFCVector() {
        let dnsNamespace: [UInt8] = [0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        let id = StableID.uuidV8(sha256Of: Data(dnsNamespace) + Data("www.example.com".utf8))
        #expect(id.uuidString.lowercased() == "5c146b14-3c52-8afd-938a-375d0df1fbf6")
    }

    @Test func derivedIDsCarryVersionEightAndVariantBits() {
        for sample in ["a", "b", "imm/account/v1", String(repeating: "x", count: 500)] {
            let id = StableID.uuidV8(sha256Of: Data(sample.utf8))
            let string = id.uuidString
            let parts = string.split(separator: "-")
            #expect(parts[2].first == "8")
            #expect("89AB".contains(parts[3].first!))
        }
    }

    // MARK: Normalisation

    @Test func normalisationTable() {
        let table: [(String, String)] = [
            ("REWE SAGT DANKE.", "rewesagtdanke"),
            ("Müller & Söhne GmbH", "muellersoehnegmbh"),
            ("Straße des 17. Juni", "strassedes17juni"),
            ("Rechnung 4711 / Kunde 7", "rechnung4711kunde7"),
            ("  padded\tand\nwrapped  ", "paddedandwrapped"),
            ("ÄÖÜ äöü ẞ", "aeoeueaeoeuess"),
            ("ＦＵＬＬ１２３", "full123"),   // NFKC folds full-width forms
            ("é-à", ""),   // other diacritics are dropped, not folded
            ("", ""),
        ]
        for (input, expected) in table { #expect(StableID.normalizedText(input) == expected, "\(input)") }
    }

    @Test func wrappedAndTrimmedPurposeHashEqual() {
        // A bank that trims the blank at a 27-character wrap boundary.
        let camt = "Rechnungsnr1234567890A Kundennr 99 Tarif Magenta"
        let mt940 = "Rechnungsnr1234567890AKundennr 99 Tarif Magenta"
        #expect(StableID.purposeKey(camt) == StableID.purposeKey(mt940))
    }

    @Test func purposeKeyKeepsOnlyTheFirstSixtyFourCharacters() {
        let long = String(repeating: "abcdefghij", count: 10)
        #expect(StableID.purposeKey(long).count == 64)
        #expect(StableID.purposeKey(long) == StableID.purposeKey(String(long.prefix(64)) + " tail that changes later"))
    }

    @Test func counterpartyIsIBANElseName() {
        #expect(StableID.counterpartyKey(iban: "de02 1203 0000 0000 2020 51", name: "Whatever") == "DE02120300000000202051")
        #expect(StableID.counterpartyKey(iban: nil, name: "Müller KG") == "muellerkg")
        #expect(StableID.counterpartyKey(iban: "  ", name: "Müller KG") == "muellerkg")
    }

    // MARK: Accounts

    @Test func accountKeys() {
        #expect(StableID.accountKey(bankCode: "37050198", accountNumber: "DE44 3705 0198 0012 3456 78") == "DE44370501980012345678")
        #expect(StableID.accountKey(bankCode: "12030000", accountNumber: "•••• 4417") == "12030000/•••• 4417")
        #expect(StableID.accountKey(bankCode: "", accountNumber: "paypal-wallet") == "/paypal-wallet")
    }

    @Test func accountIDDependsOnlyOnTheKey() {
        let a = StableID.accountID(bankCode: "37050198", accountNumber: "DE44370501980012345678")
        let b = StableID.accountID(bankCode: "something else", accountNumber: "de44 3705 0198 0012 3456 78")
        #expect(a == b)   // with an IBAN the bank code does not matter
        #expect(a != StableID.accountID(bankCode: "37050198", accountNumber: "DE44370501980012345679"))
    }

    // MARK: Bookings

    private let day = LocalDate(year: 2026, month: 11, day: 12)

    private func content(_ amount: Int = -4999, purpose: String = "Kiosk") -> StableID.BookingContent {
        .init(day: day, amount: amount, currency: "EUR", counterpartyKey: "kiosk", purposeKey: StableID.purposeKey(purpose))
    }

    @Test func occurrenceIndexSeparatesIdenticalEntries() {
        let ids = StableID.bookingIDs(accountID: "A", entries: [(content(), nil), (content(), nil), (content(-100), nil)])
        #expect(Set(ids).count == 3)
        // The first twin equals the id of a fetch that saw only one of them.
        #expect(StableID.bookingIDs(accountID: "A", entries: [(content(), nil)])[0] == ids[0])
    }

    @Test func identicalEntriesAreOrderedByReferenceThenDelivery() {
        let a = StableID.bookingIDs(accountID: "A", entries: [(content(), "REF-2"), (content(), "REF-1")])
        let b = StableID.bookingIDs(accountID: "A", entries: [(content(), "REF-1"), (content(), "REF-2")])
        // REF-1 gets occurrence 0 whichever way the bank delivers.
        #expect(a[1] == b[0])
        #expect(a[0] == b[1])
        // NONREF is no reference: delivery order decides.
        let c = StableID.bookingIDs(accountID: "A", entries: [(content(), "NONREF"), (content(), "NONREF")])
        #expect(c[0] != c[1])
        let noRef = StableID.bookingIDs(accountID: "A", entries: [(content(), nil)])
        #expect(c[0] == noRef[0])
    }

    @Test func bookingIDChangesWithEveryIdentityField() {
        let base = StableID.bookingID(
            accountID: "A", day: day, amount: -100, currency: "EUR", counterpartyKey: "x", purposeKey: "p", occurrence: 0)
        let variants = [
            StableID.bookingID(accountID: "B", day: day, amount: -100, currency: "EUR", counterpartyKey: "x", purposeKey: "p", occurrence: 0),
            StableID.bookingID(accountID: "A", day: day.adding(days: 1), amount: -100, currency: "EUR", counterpartyKey: "x", purposeKey: "p", occurrence: 0),
            StableID.bookingID(accountID: "A", day: day, amount: 100, currency: "EUR", counterpartyKey: "x", purposeKey: "p", occurrence: 0),
            StableID.bookingID(accountID: "A", day: day, amount: -100, currency: "USD", counterpartyKey: "x", purposeKey: "p", occurrence: 0),
            StableID.bookingID(accountID: "A", day: day, amount: -100, currency: "EUR", reversal: true, counterpartyKey: "x", purposeKey: "p", occurrence: 0),
            StableID.bookingID(accountID: "A", day: day, amount: -100, currency: "EUR", counterpartyKey: "y", purposeKey: "p", occurrence: 0),
            StableID.bookingID(accountID: "A", day: day, amount: -100, currency: "EUR", counterpartyKey: "x", purposeKey: "q", occurrence: 0),
            StableID.bookingID(accountID: "A", day: day, amount: -100, currency: "EUR", counterpartyKey: "x", purposeKey: "p", occurrence: 1),
        ]
        #expect(Set(variants + [base]).count == variants.count + 1)
    }

    /// Golden values: the algorithm is frozen, so these must never change (a change re-identifies every booking).
    @Test func goldenIDs() {
        let account = StableID.accountID(bankCode: "37050198", accountNumber: "DE02370501980000123456")
        let booking = StableID.bookingID(
            accountID: account, day: LocalDate(year: 2026, month: 11, day: 11), amount: -6348, currency: "EUR",
            counterpartyKey: StableID.counterpartyKey(iban: nil, name: "REWE Markt GmbH"),
            purposeKey: StableID.purposeKey("REWE SAGT DANKE."), occurrence: 0)
        // Recompute independently with CryptoKit over the documented byte layout.
        func lp(_ s: String) -> Data {
            var d = Data()
            let n = UInt32(s.utf8.count)
            d.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
            return d + Data(s.utf8)
        }
        var message = Data()
        for field in ["imm/booking/v1", account, "2026-11-11", "-6348", "EUR", "0", "rewemarktgmbh", "rewesagtdanke", "0"] {
            message += lp(field)
        }
        var bytes = Array(SHA256.hash(data: message).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let expected = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
                                   bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        #expect(booking == expected.uuidString)
        // Literal pins, computed once with the layout above.
        #expect(account == "0F172802-68D7-8178-97C0-98D22EB58F92")
        #expect(booking == "AEDEE166-27C7-877F-B64A-1351F376BC81")
        let accountMessage = lp("imm/account/v1") + lp("DE02370501980000123456")
        var accountBytes = Array(SHA256.hash(data: accountMessage).prefix(16))
        accountBytes[6] = (accountBytes[6] & 0x0F) | 0x80
        accountBytes[8] = (accountBytes[8] & 0x3F) | 0x80
        let expectedAccount = UUID(uuid: (accountBytes[0], accountBytes[1], accountBytes[2], accountBytes[3], accountBytes[4], accountBytes[5],
                                          accountBytes[6], accountBytes[7], accountBytes[8], accountBytes[9], accountBytes[10],
                                          accountBytes[11], accountBytes[12], accountBytes[13], accountBytes[14], accountBytes[15]))
        #expect(account == expectedAccount.uuidString)
    }
}

@Suite struct FractionalIndexTests {
    @Test func midpointOfAnEmptyList() {
        #expect(FractionalIndex.between(nil, nil) == FractionalIndex.midpoint)
    }

    @Test func betweenIsStrictlyBetween() {
        var keys = [FractionalIndex.midpoint]
        var state: UInt64 = 99
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33)
        }
        // Insert 400 keys at random positions (front, back, middle) and keep the list sorted.
        for _ in 0..<400 {
            let position = next() % (keys.count + 1)
            let lower = position == 0 ? nil : keys[position - 1]
            let upper = position == keys.count ? nil : keys[position]
            let key = FractionalIndex.between(lower, upper)
            if let lower { #expect(lower < key) }
            if let upper { #expect(key < upper) }
            #expect(!key.hasSuffix("0"))
            keys.insert(key, at: position)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
    }

    @Test func appendingAtTheEndAndFrontKeepsWorking() {
        var last: String?
        for _ in 0..<200 { last = FractionalIndex.between(last, nil) }
        var first: String?
        for _ in 0..<200 { first = FractionalIndex.between(nil, first ?? "V") }
        #expect(first! < "V" && "V" < last!)
    }

    @Test func evenlySpacedKeys() {
        for count in [0, 1, 2, 3, 8, 9, 50] {
            let keys = FractionalIndex.keys(count: count)
            #expect(keys.count == count)
            #expect(keys == keys.sorted())
            #expect(Set(keys).count == count)
        }
        #expect(FractionalIndex.keys(count: 1) == ["V"])
    }
}
