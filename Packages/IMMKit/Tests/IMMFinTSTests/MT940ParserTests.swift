import Foundation
import IMMLedger
import Testing

@testable import IMMFinTS

@Suite struct MT940ParserTests {
    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
    }

    private func day(_ iso: String) -> LocalDate { LocalDate(iso: iso)! }

    /// Wraps `body` (`:61:`/`:86:` lines) into a statement with the given opening balance currency.
    private func statement(_ body: String, currency: String = "EUR") -> Data {
        let text = ":20:STARTUMS\n:25:10050000/54540402\n:28C:00000/001\n:60F:C260101\(currency)0,\n\(body):62F:C260131\(currency)0,\n-\n"
        return Data(text.utf8)
    }

    private func entries(_ body: String, currency: String = "EUR") throws -> [StatementEntry] {
        try MT940Parser.parse(statement(body, currency: currency))
    }

    // MARK: - Fixtures

    @Test func parsesSparkasseStatement() throws {
        let entries = try MT940Parser.parse(fixture("mt940-sparkasse.sta"))
        #expect(entries.count == 4)

        #expect(entries[0] == StatementEntry(
            bookingDate: day("2026-11-03"), valueDate: day("2026-11-02"), amount: -5430, currency: "EUR",
            counterpartyName: "REWE Markt GmbH", purpose: "REWE SAGT DANKE 4711 ADRESSE BERLIN DE",
            bookingText: "Kartenzahlung", transactionCode: "105"))

        // Direct debit: EREF split mid-value, MREF/CRED split inside the `CRED+` keyword, SVWZ over two full lines.
        #expect(entries[1] == StatementEntry(
            bookingDate: day("2026-11-04"), valueDate: day("2026-11-04"), amount: -2999, currency: "EUR",
            counterpartyName: "Stadtwerke Beispielstadt GmbH", counterpartyIBAN: "DE89370400440532013000",
            counterpartyBIC: "COBADEFFXXX", purpose: "Rechnung 2026-11-0042 Strom Abschlag November",
            bookingText: "SEPA-Basislastschrift", transactionCode: "105",
            endToEndID: "RE2026-11-0042-ABCDEFGHIJ", mandateID: "MANDAT-8812-A-0001",
            creditorID: "DE98ZZZ09999999999", bankReference: "000123456789"))

        // Salary credit; the statement is ISO-8859-1 and the names carry umlauts.
        #expect(entries[2] == StatementEntry(
            bookingDate: day("2026-11-06"), valueDate: day("2026-11-06"), amount: 285_000, currency: "EUR",
            counterpartyName: "Müller Maschinenbau GmbH", counterpartyIBAN: "DE12500105170648489890",
            counterpartyBIC: "GENODEF1S04", purpose: "Gehalt November 2026", bookingText: "Überweisungsgutschrift",
            transactionCode: "051", endToEndID: "LOHN112026", bankReference: "BNK778899"))

        #expect(entries[3] == StatementEntry(
            bookingDate: day("2026-11-09"), valueDate: day("2026-11-09"), amount: -95_000, currency: "EUR",
            counterpartyName: "Hausverwaltung Beispiel e.K.", purpose: "Miete Nov 2026 Whg 4",
            bookingText: "Dauerauftrag", transactionCode: "152"))

        #expect(entries.allSatisfy { !$0.isPending && !$0.isReversal })
    }

    @Test func parsesSeveralStatementsWithCRLF() throws {
        let data = try fixture("mt940-multi.sta")
        #expect(data.contains(0x0D))
        let entries = try MT940Parser.parse(data)
        #expect(entries.count == 6)

        // Statement 1 (EUR). Value date 2026-01-02, booking date 1231 → 2025-12-31.
        #expect(entries[0] == StatementEntry(
            bookingDate: day("2025-12-31"), valueDate: day("2026-01-02"), amount: 10_000, currency: "EUR",
            counterpartyName: "Erika Müller-Köhler", counterpartyIBAN: "DE02120300000000202051",
            counterpartyBIC: "BYLADEM1001", purpose: "Erstattung Januar 2026", bookingText: "Gutschrift",
            transactionCode: "166", bankReference: "REF0001"))
        // Unstructured `:86:` over two lines: the whole text is the purpose. The statement-level `:86:` after
        // `:62F:` does not touch it.
        #expect(entries[1] == StatementEntry(
            bookingDate: day("2026-01-05"), valueDate: day("2026-01-05"), amount: -150, currency: "EUR",
            purpose: "Entgelt Kontofuehrung 01/2026 Privatkonto"))

        // Statement 2 (USD): the second `:20:` resets the currency to the new `:60F:`.
        #expect(entries[2] == StatementEntry(
            bookingDate: day("2026-01-06"), valueDate: day("2026-01-06"), amount: 1250, currency: "USD",
            isReversal: true, counterpartyName: "Beispiel Trading Inc", purpose: "Storno Rechnung 77",
            bookingText: "Rueckbuchung", transactionCode: "166", bankReference: "STORNO1"))
        #expect(entries[3] == StatementEntry(
            bookingDate: day("2026-01-07"), valueDate: day("2026-01-07"), amount: -50, currency: "USD",
            isReversal: true, counterpartyName: "Beispiel Trading Inc", purpose: "Storno Gutschrift",
            bookingText: "Rueckbuchung", transactionCode: "166"))
        #expect(entries[4] == StatementEntry(
            bookingDate: day("2026-01-08"), valueDate: day("2026-01-08"), amount: 123_456, currency: "USD",
            counterpartyName: "Beispiel Trading Inc", purpose: "Rechnung 4711", bookingText: "Gutschrift",
            transactionCode: "166"))
        #expect(entries[5] == StatementEntry(
            bookingDate: day("2026-01-09"), valueDate: day("2026-01-09"), amount: -1200, currency: "USD",
            purpose: "Kaffee", bookingText: "Kartenzahlung", transactionCode: "105"))
    }

    @Test func parsesMT942AsPending() throws {
        let data = try fixture("mt942-pending.sta")
        let entries = try MT940Parser.parse(data, pending: true)
        #expect(entries.count == 2)
        #expect(entries[0] == StatementEntry(
            bookingDate: day("2026-11-14"), valueDate: day("2026-11-14"), amount: -1999, currency: "EUR",
            isPending: true, counterpartyName: "Netto Marken-Discount Filiale 1234",
            purpose: "Netto Marken-Discount 1234", bookingText: "Kartenzahlung", transactionCode: "105"))
        #expect(entries[1] == StatementEntry(
            bookingDate: day("2026-11-15"), valueDate: day("2026-11-15"), amount: 7500, currency: "EUR",
            isPending: true, counterpartyName: "Hans Beispiel", counterpartyIBAN: "DE12500105170648489890",
            counterpartyBIC: "INGDDEFFXXX", purpose: "Rueckzahlung Auslage", bookingText: "Gutschrift",
            transactionCode: "166", endToEndID: "RUECK2026", bankReference: "VORM0001"))

        // Without the flag the same bytes are booked entries.
        #expect(try MT940Parser.parse(data).allSatisfy { !$0.isPending })
    }

    // MARK: - :61:

    @Test func reversalsFlipTheSign() throws {
        let result = try entries("""
        :61:260105C10,00NTRFNONREF
        :61:260105D10,00NTRFNONREF
        :61:260105RC10,00NTRFNONREF
        :61:260105RD10,00NTRFNONREF
        """ + "\n")
        #expect(result.map(\.amount) == [1000, -1000, -1000, 1000])
        #expect(result.map(\.isReversal) == [false, false, true, true])
    }

    @Test func bookingDateYearFollowsTheValueDate() throws {
        let result = try entries("""
        :61:2601021231C1,00NTRFNONREF
        :61:2512310102C1,00NTRFNONREF
        :61:2603150316C1,00NTRFNONREF
        :61:2403010229D1,00NTRFNONREF
        :61:260105C1,00NTRFNONREF
        """ + "\n")
        #expect(result.map(\.valueDate) == [
            day("2026-01-02"), day("2025-12-31"), day("2026-03-15"), day("2024-03-01"), day("2026-01-05"),
        ])
        #expect(result.map(\.bookingDate) == [
            day("2025-12-31"), day("2026-01-02"), day("2026-03-16"), day("2024-02-29"), day("2026-01-05"),
        ])
    }

    @Test func parsesAmountsExactly() throws {
        let result = try entries("""
        :61:260105C0,5NTRFNONREF
        :61:260105C1234,56NTRFNONREF
        :61:260105D12,NTRFNONREF
        :61:260105C,07NTRFNONREF
        :61:260105C0,00NTRFNONREF
        :61:260105D90071992547409,91NTRFNONREF
        """ + "\n")
        #expect(result.map(\.amount) == [50, 123_456, -1200, 7, 0, -9_007_199_254_740_991])
        #expect(MT940Parser.minorUnits("19999999999999999999,99") == nil)
        #expect(MT940Parser.minorUnits("1,234") == nil)
        #expect(MT940Parser.minorUnits("1,2,3") == nil)
        #expect(MT940Parser.minorUnits("") == nil)
        #expect(MT940Parser.minorUnits(",") == nil)
    }

    @Test func skipsTheFundsCodeAndReadsReferences() throws {
        let result = try entries("""
        :61:2601060106DR12,34NMSCCUSTREF-1//BANKREF-1
        SUPPLEMENTARY DETAILS LINE
        :61:2601060106CR1,00NTRFNONREF//NONREF
        :61:2601060106C1,00NTRFONLYCUSTOMER
        :61:2601060106C1,00NTRFNONREF//
        """ + "\n")
        #expect(result.map(\.amount) == [-1234, 100, 100, 100])
        #expect(result.map(\.bankReference) == ["BANKREF-1", nil, nil, nil])
        #expect(result.allSatisfy { $0.currency == "EUR" && $0.purpose.isEmpty })
    }

    @Test func currencyComesFromTheOpeningBalance() throws {
        let result = try entries(":61:260105D5,00NTRFNONREF\n", currency: "CHF")
        #expect(result[0].currency == "CHF")
    }

    // MARK: - :86:

    @Test func splitsSEPAKeywordsAcrossSubfields() throws {
        let result = try entries("""
        :61:260105D5,00NDDTNONREF
        :86:105?00SEPA-Lastschrift?20EREF+ABCDEFGHIJKLMNOPQRSTUV?21WXYZ?22MREF+M-1CRED+DE12ZZZ0000012?2334?24SVWZ+Beitrag Januar?252026 Mitglied 12345?32Sportverein Muster e.V.?31DE02100500000054540402?30BELADEBEXXX
        """ + "\n")
        #expect(result[0].endToEndID == "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        #expect(result[0].mandateID == "M-1")
        #expect(result[0].creditorID == "DE12ZZZ000001234")
        #expect(result[0].purpose == "Beitrag Januar 2026 Mitglied 12345")
        #expect(result[0].counterpartyName == "Sportverein Muster e.V.")
        #expect(result[0].counterpartyIBAN == "DE02100500000054540402")
        #expect(result[0].counterpartyBIC == "BELADEBEXXX")
    }

    @Test func dropsPlaceholderReferencesAndKeepsTextWithoutSVWZ() throws {
        let result = try entries("""
        :61:260105D5,00NMSCNONREF
        :86:105?00Kartenzahlung?20EREF+NOTPROVIDED?21KREF+NONREF?22SVWZ+Tankstelle
        :61:260105D5,00NMSCNONREF
        :86:105?00Kartenzahlung?20Bezahlung Tankstelle?21Nr 5?22EREF+NOTPROVIDED
        """ + "\n")
        #expect(result[0].endToEndID == nil)
        #expect(result[0].purpose == "Tankstelle")
        // Without `SVWZ+` the purpose is the text before the first keyword.
        #expect(result[1].endToEndID == nil)
        #expect(result[1].purpose == "Bezahlung Tankstelle Nr 5")
    }

    @Test func fallsBackToKeywordIBANAndBICWhenSubfieldsHoldAccountNumbers() throws {
        let result = try entries("""
        :61:260105C5,00NTRFNONREF
        :86:166?00Gutschrift?20SVWZ+Danke?21IBAN+DE89370400440532013000?22BIC+COBADEFFXXX?3037040044?310532013000?32Anna Beispiel
        """ + "\n")
        #expect(result[0].counterpartyIBAN == "DE89370400440532013000")
        #expect(result[0].counterpartyBIC == "COBADEFFXXX")
        #expect(result[0].counterpartyName == "Anna Beispiel")
        #expect(result[0].purpose == "Danke")
    }

    @Test func ignoresAccountNumbersThatAreNoIBAN() throws {
        let result = try entries("""
        :61:260105C5,00NTRFNONREF
        :86:051?00Gutschrift?20Miete?3037040044?310532013000?32Anna Beispiel
        """ + "\n")
        #expect(result[0].counterpartyIBAN == nil)
        #expect(result[0].counterpartyBIC == nil)
        #expect(result[0].purpose == "Miete")
    }

    @Test func usesTheDeviatingPartyWhenNoNameSubfieldExists() throws {
        let result = try entries("""
        :61:260105D5,00NTRFNONREF
        :86:166?00Ueberweisung?20SVWZ+Rechnung 1?21ABWE+Treuhand AG
        """ + "\n")
        #expect(result[0].counterpartyName == "Treuhand AG")
        #expect(result[0].purpose == "Rechnung 1")
    }

    @Test func unstructuredDetailsBecomeThePurpose() throws {
        let result = try entries("""
        :61:260105D5,00NMSCNONREF
        :86:Kartenzahlung Edeka 4711
        Hamburg
        """ + "\n")
        #expect(result[0].purpose == "Kartenzahlung Edeka 4711 Hamburg")
        #expect(result[0].transactionCode == nil)
        #expect(result[0].bookingText == nil)
        #expect(result[0].counterpartyName == nil)
    }

    @Test func detailsWithoutKnownSeparatorAreNotMistakenForGVC() throws {
        let result = try entries("""
        :61:260105D5,00NMSCNONREF
        :86:123 45 Stueck Brot
        """ + "\n")
        #expect(result[0].purpose == "123 45 Stueck Brot")
        #expect(result[0].transactionCode == nil)
    }

    @Test func entryWithoutDetailsHasEmptyPurpose() throws {
        let result = try entries(":61:260105D5,00NMSCNONREF\n")
        #expect(result.count == 1)
        #expect(result[0].purpose == "")
        #expect(result[0].counterpartyName == nil)
    }

    // MARK: - Text handling

    @Test func lineEndingsAndEncodingsGiveTheSameEntries() throws {
        let text = """
        :20:STARTUMS
        :25:10050000/54540402
        :60F:C260101EUR0,
        :61:260105C5,00NTRFNONREF//B1
        :86:166?00Gutschrift?20SVWZ+Grüße aus Köln?32Jürgen Weiß
        :62F:C260105EUR5,00
        -

        """
        let lf = try MT940Parser.parse(Data(text.utf8))
        let crlf = try MT940Parser.parse(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        let latin1 = try MT940Parser.parse(#require(text.data(using: .isoLatin1)))
        #expect(lf.count == 1)
        #expect(lf[0].purpose == "Grüße aus Köln")
        #expect(lf[0].counterpartyName == "Jürgen Weiß")
        #expect(crlf == lf)
        #expect(latin1 == lf)
    }

    @Test func atSignSeparatorsActAsLineBreaks() throws {
        let text = ":20:STARTUMS@@:25:10050000/54540402@@:60F:C260101EUR0,@@:61:260105D5,00NMSCNONREF@@"
            + ":86:105?00Kartenzahlung?20SVWZ+Bäckerei@@:62F:C260105EUR0,@@-@@"
        let result = try MT940Parser.parse(Data(text.utf8))
        #expect(result.count == 1)
        #expect(result[0].amount == -500)
        #expect(result[0].purpose == "Bäckerei")
    }

    @Test func toleratesUnknownTagsAndSwiftBlocks() throws {
        let text = """
        {1:F01TESTDEFFAXXX0000000000}{2:O9401200260105TESTDEFFAXXX00000000002601051200N}{4:
        :20:STARTUMS
        :21:NONREF
        :25:10050000/54540402
        :28C:1/1
        :60F:C260101EUR0,
        :99:Something nobody knows
        :61:260105C5,00NTRFNONREF
        :86:166?00Gutschrift?20SVWZ+Test
        :62F:C260105EUR5,00
        :64:C260105EUR5,00
        :65:C260106EUR5,00
        -}
        """
        let result = try MT940Parser.parse(Data(text.utf8))
        #expect(result.count == 1)
        #expect(result[0].purpose == "Test")
    }

    @Test func emptyInputYieldsNoEntries() throws {
        #expect(try MT940Parser.parse(Data()).isEmpty)
        #expect(try MT940Parser.parse(Data("\n\n".utf8)).isEmpty)
        #expect(try MT940Parser.parse(statement("")).isEmpty)
    }

    // MARK: - Errors

    @Test func throwsForUnusableTransactionLines() {
        #expect(throws: MT940ParserError.invalidAmount("260105CNTRFNONREF")) {
            try MT940Parser.parse(statement(":61:260105CNTRFNONREF\n"))
        }
        #expect(throws: MT940ParserError.self) {
            try MT940Parser.parse(statement(":61:260105X5,00NTRFNONREF\n"))
        }
        #expect(throws: MT940ParserError.self) {
            try MT940Parser.parse(statement(":61:261340C5,00NTRFNONREF\n"))
        }
        #expect(throws: MT940ParserError.self) {
            try MT940Parser.parse(statement(":61:2601051340C5,00NTRFNONREF\n"))
        }
        #expect(throws: MT940ParserError.self) {
            try MT940Parser.parse(statement(":61:260105C5,123NTRFNONREF\n"))
        }
        #expect(throws: MT940ParserError.self) {
            try MT940Parser.parse(statement(":61:26\n"))
        }
    }

    @Test func throwsWhenNoCurrencyIsKnown() {
        let data = Data(":20:X\n:61:260105C5,00NTRFNONREF\n".utf8)
        #expect(throws: MT940ParserError.missingCurrency) {
            try MT940Parser.parse(data)
        }
    }
}
