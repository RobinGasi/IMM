import Foundation
import IMMLedger
import Testing

@testable import IMMFinTS

@Suite struct CamtParserTests {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> LocalDate {
        LocalDate(year: year, month: month, day: day)
    }

    /// Wraps `ntry` markup into a minimal camt.053 document.
    private func document(_ ntry: String, namespace: String = "urn:iso:std:iso:20022:tech:xsd:camt.053.001.02") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Document xmlns="\(namespace)"><BkToCstmrStmt><Stmt>\(ntry)</Stmt></BkToCstmrStmt></Document>
        """.utf8)
    }

    // MARK: - Fixtures

    @Test func parsesCamt053V02() throws {
        let entries = try CamtParser.parse(fixture("camt053-v02.xml"))
        #expect(entries.count == 4)

        // Card payment: purpose from Ustrd, booking text from AddtlNtryInf, NOTPROVIDED end-to-end id dropped.
        #expect(entries[0] == StatementEntry(
            bookingDate: day(2026, 3, 2), valueDate: day(2026, 3, 2), amount: -2345, currency: "EUR",
            counterpartyName: "REWE Markt GmbH Musterstadt",
            purpose: "REWE SAGT DANKE. 01.03.2026 17:42 Debitk. 1 Folge 1 Verfalld. 12/28",
            bookingText: "Kartenzahlung", transactionCode: "106", bankReference: "2026030200001234"))

        // Direct debit: payee, its IBAN and BIC, mandate and creditor id; NONREF service reference dropped.
        #expect(entries[1] == StatementEntry(
            bookingDate: day(2026, 3, 3), valueDate: day(2026, 3, 3), amount: -999, currency: "EUR",
            counterpartyName: "Streamflix Europe S.a.r.l.", counterpartyIBAN: "LU280019400644750000",
            counterpartyBIC: "STRMLULLXXX", purpose: "Streamflix Abo Maerz 2026 Kundennr. 4400117",
            bookingText: "Basislastschrift", transactionCode: "105", endToEndID: "STRMFLX-2026-03-0001",
            mandateID: "STRMFLX-MANDATE-77310", creditorID: "LU98ZZZ0000000000000099999", bankReference: nil))

        // Salary: credit, payer side, two Ustrd lines joined, different value date.
        #expect(entries[2] == StatementEntry(
            bookingDate: day(2026, 3, 27), valueDate: day(2026, 3, 28), amount: 123_456, currency: "EUR",
            counterpartyName: "Muster Maschinenbau GmbH", counterpartyIBAN: "DE89370400440532013000",
            counterpartyBIC: "COBADEFFXXX", purpose: "Gehalt 03/2026 Pers.Nr. 4711", bookingText: "Gutschrift",
            transactionCode: "051", endToEndID: "GEHALT-2026-03", bankReference: "2026032700005555"))

        // Reversal of a credit: flagged, sign as delivered (DBIT), payee side.
        #expect(entries[3] == StatementEntry(
            bookingDate: day(2026, 3, 30), valueDate: day(2026, 3, 27), amount: -1, currency: "EUR", isReversal: true,
            counterpartyName: "Erika Probe", counterpartyIBAN: "DE75512108001245126199",
            purpose: "Storno Gutschrift Testueberweisung", bookingText: "Storno Gutschrift", transactionCode: "159",
            bankReference: "2026033000007777"))
    }

    @Test func parsesCamt053V08WithPrefixesStatusCodeAndDateTimes() throws {
        let entries = try CamtParser.parse(fixture("camt053-v08.xml"))
        #expect(entries.count == 2)

        // `12.5` is 12 euros 50 cents; DtTm dates keep the written calendar day; Pty/Nm and BICFI.
        #expect(entries[0] == StatementEntry(
            bookingDate: day(2026, 4, 3), valueDate: day(2026, 4, 4), amount: 1250, currency: "EUR",
            counterpartyName: "Erika Mustermann", counterpartyIBAN: "DE75512108001245126199",
            counterpartyBIC: "SOGEDEFFXXX", purpose: "Anteil Pizza vom Freitag",
            bookingText: "Echtzeitueberweisung Gutschrift", transactionCode: "166", bankReference: "2026040300000101"))

        // Creditor id lives under Cdtr/Pty/Id in v08; mixed DtTm booking date and Dt value date.
        #expect(entries[1] == StatementEntry(
            bookingDate: day(2026, 4, 15), valueDate: day(2026, 4, 15), amount: -4900, currency: "EUR",
            counterpartyName: "Fitness Beispielstadt e.V.", counterpartyIBAN: "DE44500105175407324931",
            counterpartyBIC: "INGDDEFFXXX", purpose: "Mitgliedsbeitrag April 2026", bookingText: "Basislastschrift",
            transactionCode: "105", endToEndID: "FITNESS-APR-2026", mandateID: "FIT-M-20240115-0815",
            creditorID: "DE12ZZZ00000123456", bankReference: "2026041500000202"))
    }

    @Test func parsesCamt052WithBatchEntryAndPendingEntries() throws {
        let entries = try CamtParser.parse(fixture("camt052-pending.xml"))
        #expect(entries.count == 3)

        // Batch credit: parties from the first TxDtls, Ustrd of both joined with a space.
        #expect(entries[0] == StatementEntry(
            bookingDate: day(2026, 5, 12), valueDate: day(2026, 5, 12), amount: 7530, currency: "EUR",
            counterpartyName: "Beispiel Versand GmbH", counterpartyIBAN: "DE27100777770209299700",
            counterpartyBIC: "NORSDE51XXX", purpose: "Erstattung Bestellung 10023 Erstattung Bestellung 10031",
            bookingText: "Sammelgutschrift", transactionCode: "052", endToEndID: "REFUND-0001",
            bankReference: "2026051200004711"))

        // Pending with booking date only: value date falls back to it.
        #expect(entries[1] == StatementEntry(
            bookingDate: day(2026, 5, 12), valueDate: day(2026, 5, 12), amount: -1990, currency: "EUR",
            isPending: true, counterpartyName: "Tankstelle Am Ring", purpose: "Tankstelle Am Ring Debitk. 1",
            bookingText: "Kartenzahlung (vorgemerkt)", transactionCode: "106"))

        // Pending with value date only and no Ustrd: purpose from AddtlTxInf, booking date falls back to value date.
        #expect(entries[2] == StatementEntry(
            bookingDate: day(2026, 5, 13), valueDate: day(2026, 5, 13), amount: -500, currency: "EUR",
            isPending: true, purpose: "Vormerkung Dauerauftrag Vereinsbeitrag"))
    }

    // MARK: - Inline documents

    @Test func statusCodeElementMarksPending() throws {
        let data = document("""
        <Ntry><Amt Ccy="EUR">3.20</Amt><CdtDbtInd>DBIT</CdtDbtInd><Sts><Cd>PDNG</Cd></Sts>
        <BookgDt><Dt>2026-06-01</Dt></BookgDt></Ntry>
        <Ntry><Amt Ccy="EUR">3.20</Amt><CdtDbtInd>DBIT</CdtDbtInd><Sts><Cd>BOOK</Cd></Sts>
        <BookgDt><Dt>2026-06-01</Dt></BookgDt></Ntry>
        """)
        let entries = try CamtParser.parse(data)
        #expect(entries.map(\.isPending) == [true, false])
        #expect(entries.map(\.purpose) == ["", ""])
    }

    @Test func amountsAreExactMinorUnits() throws {
        let amounts = ["12.5", "1234.56", "0.01", "100", "0.10", "19.990", "70368744177.07"]
        let ntries = amounts.map {
            "<Ntry><Amt Ccy=\"EUR\">\($0)</Amt><CdtDbtInd>CRDT</CdtDbtInd><BookgDt><Dt>2026-01-02</Dt></BookgDt></Ntry>"
        }
        let entries = try CamtParser.parse(document(ntries.joined()))
        #expect(entries.map(\.amount) == [1250, 123_456, 1, 10_000, 10, 1999, 7_036_874_417_707])
    }

    @Test func respectsCurrencyExponent() throws {
        #expect(CamtParser.minorUnits("1500", currency: "JPY") == 1500)
        #expect(CamtParser.minorUnits("1500.00", currency: "JPY") == 1500)
        #expect(CamtParser.minorUnits("1500.5", currency: "JPY") == nil)
        #expect(CamtParser.minorUnits("1.234", currency: "KWD") == 1234)
        #expect(CamtParser.minorUnits("1.2", currency: "KWD") == 1200)
        #expect(CamtParser.minorUnits("1.005", currency: "EUR") == nil)
        #expect(CamtParser.minorUnits(".5", currency: "EUR") == 50)
        #expect(CamtParser.minorUnits("-1.00", currency: "EUR") == nil)
        #expect(CamtParser.minorUnits("1,00", currency: "EUR") == nil)
        #expect(CamtParser.minorUnits("", currency: "EUR") == nil)
        #expect(CamtParser.minorUnits("99999999999999999999", currency: "EUR") == nil)
    }

    @Test func creditorSchemeIdentificationIsUsedWhenPartyHasNone() throws {
        let data = document("""
        <Ntry><Amt Ccy="EUR">8.00</Amt><CdtDbtInd>DBIT</CdtDbtInd><BookgDt><Dt>2026-02-01</Dt></BookgDt>
        <NtryDtls><TxDtls>
          <Refs><MndtId>M-1</MndtId></Refs>
          <RltdPties><Cdtr><Nm>Stadtwerke Beispiel</Nm></Cdtr></RltdPties>
          <CdtrSchmeId><Id><PrvtId><Othr><Id>DE31ZZZ00000031234</Id></Othr></PrvtId></Id></CdtrSchmeId>
        </TxDtls></NtryDtls></Ntry>
        """)
        let entry = try #require(CamtParser.parse(data).first)
        #expect(entry.creditorID == "DE31ZZZ00000031234")
        #expect(entry.mandateID == "M-1")
        #expect(entry.counterpartyName == "Stadtwerke Beispiel")
    }

    @Test func transactionCodeNeedsThreeDigitSecondPart() throws {
        func code(_ raw: String) throws -> String? {
            let data = document("""
            <Ntry><Amt Ccy="EUR">1.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><BookgDt><Dt>2026-02-01</Dt></BookgDt>
            <BkTxCd><Prtry><Cd>\(raw)</Cd></Prtry></BkTxCd></Ntry>
            """)
            return try CamtParser.parse(data).first?.transactionCode
        }
        #expect(try code("NMSC+201+9310") == "201")
        #expect(try code("NTRF+005+0") == "005")
        #expect(try code("NTRF") == nil)
        #expect(try code("NTRF+12+9310") == nil)
        #expect(try code("NTRF+ABC+9310") == nil)
        #expect(try code("PMNT") == nil)
    }

    @Test func ignoresNamespacesAndEntryDetailsLookalikes() throws {
        // No default namespace, an unrelated prefix, and balances/`NtryDtls` that must not count as entries.
        let data = Data("""
        <x:Document xmlns:x="urn:example:other"><x:BkToCstmrStmt><x:Stmt>
        <x:Bal><x:Amt Ccy="EUR">5.00</x:Amt><x:CdtDbtInd>CRDT</x:CdtDbtInd></x:Bal>
        <x:Ntry><x:Amt Ccy="EUR">5.00</x:Amt><x:CdtDbtInd>CRDT</x:CdtDbtInd>
        <x:BookgDt><x:Dt>2026-01-05</x:Dt></x:BookgDt>
        <x:NtryDtls><x:TxDtls><x:RmtInf><x:Ustrd>  Hallo
          Welt  </x:Ustrd></x:RmtInf></x:TxDtls></x:NtryDtls></x:Ntry>
        </x:Stmt></x:BkToCstmrStmt></x:Document>
        """.utf8)
        let entries = try CamtParser.parse(data)
        #expect(entries.count == 1)
        #expect(entries[0].purpose == "Hallo Welt")
        #expect(entries[0].amount == 500)
    }

    @Test func emptyStatementYieldsNoEntries() throws {
        #expect(try CamtParser.parse(document("")).isEmpty)
    }

    // MARK: - Errors

    @Test func rejectsNonXML() {
        #expect(throws: CamtParserError.notXML) { try CamtParser.parse(Data("this is not xml".utf8)) }
        #expect(throws: CamtParserError.notXML) { try CamtParser.parse(Data()) }
        #expect(throws: CamtParserError.notXML) { try CamtParser.parse(Data("<Document><BkToCstmrStmt>".utf8)) }
    }

    @Test func rejectsOtherXMLDocuments() {
        let data = Data(#"<?xml version="1.0"?><Document><CstmrCdtTrfInitn/></Document>"#.utf8)
        #expect(throws: CamtParserError.notCamt) { try CamtParser.parse(data) }
    }

    @Test func rejectsEntriesWithoutAmountCurrencyOrDate() {
        let noDate = document(#"<Ntry><Amt Ccy="EUR">1.00</Amt><CdtDbtInd>CRDT</CdtDbtInd></Ntry>"#)
        #expect(throws: CamtParserError.invalidEntry(index: 0, reason: "missing BookgDt and ValDt")) {
            try CamtParser.parse(noDate)
        }
        let noCurrency = document(#"<Ntry><Amt>1.00</Amt><BookgDt><Dt>2026-01-01</Dt></BookgDt></Ntry>"#)
        #expect(throws: CamtParserError.invalidEntry(index: 0, reason: "missing Amt/@Ccy")) {
            try CamtParser.parse(noCurrency)
        }
        let badAmount = document(
            #"<Ntry><Amt Ccy="EUR">abc</Amt><BookgDt><Dt>2026-01-01</Dt></BookgDt></Ntry>"#)
        #expect(throws: CamtParserError.invalidEntry(index: 0, reason: "bad amount 'abc'")) {
            try CamtParser.parse(badAmount)
        }
    }
}
