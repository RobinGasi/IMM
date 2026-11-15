import Foundation
import IMMBanking
import Testing
@testable import IMMFinTS

@Suite struct FinTSBankDirectoryTests {
    private static func bank(_ code: String, _ name: String, city: String, bic: String? = nil, version: String? = "3.0") -> FinTSBankInfo {
        FinTSBankInfo(bankCode: code, bic: bic, name: name, city: city,
                      pinTanURL: URL(string: "https://fints.example.invalid/\(code.filter { !$0.isWhitespace })")!,
                      fintsVersion: version)
    }

    private static let directory = FinTSBankDirectory(banks: [
        bank("37050198", "Sparkasse KölnBonn", city: "Köln", bic: "COLSDE33XXX"),
        bank("37050299", "Kreissparkasse Köln", city: "Köln", bic: "COKSDE33XXX"),
        bank("10010010", "Postbank", city: "Berlin", bic: "PBNKDEFFXXX"),
        bank("50010517", "ING-DiBa", city: "Frankfurt am Main", bic: "INGDDEFFXXX"),
        bank("10000001", "Bank für Gemeinwohl", city: "Berlin"),
        bank("20000002", "Gemeinschaftsbank Süd", city: "München"),
        bank("30000003", "Großstadt Volksbank", city: "Düsseldorf"),
        bank("40000004", "Münchner Sparkasse", city: "München", bic: "MUENDE01XXX"),
    ])

    private func codes(_ query: String, limit: Int = 50) -> [String] {
        Self.directory.search(query, limit: limit).map(\.bankCode)
    }

    // MARK: Search

    @Test func emptyQueryYieldsNothing() {
        #expect(codes("").isEmpty)
        #expect(codes("   ").isEmpty)
        #expect(codes("sparkasse", limit: 0).isEmpty)
    }

    @Test func foldsCaseAndDiacritics() {
        // Both mention Köln in name and city; Kreissparkasse sorts before Sparkasse.
        #expect(codes("koln") == ["37050299", "37050198"])
        #expect(codes("KÖLN") == ["37050299", "37050198"])
        #expect(codes("kreissparkasse KOLN") == ["37050299"])
        #expect(codes("munchen") == ["20000002", "40000004"])
        #expect(codes("MÜNCHEN") == ["20000002", "40000004"])
        #expect(codes("grossstadt") == ["30000003"])
        #expect(codes("GROßSTADT") == ["30000003"])
        #expect(codes("dusseldorf") == ["30000003"])
        #expect(codes("fur gemein") == ["10000001"])
    }

    @Test func matchesBankCodeWithAndWithoutSpaces() {
        #expect(codes("37050198") == ["37050198"])
        #expect(codes("370 501 98") == ["37050198"])
        #expect(codes(" 370501 98 ") == ["37050198"])
        // Prefix of a code, ordered by name.
        #expect(codes("3705") == ["37050299", "37050198"])
        // Digits contained in the middle of a code.
        #expect(codes("0010517") == ["50010517"])
        #expect(codes("0010") == ["50010517", "10010010"])
    }

    @Test func matchesBICPrefixAndExact() {
        #expect(codes("COLSDE33XXX") == ["37050198"])
        #expect(codes("colsde33") == ["37050198"])
        #expect(codes("PBNK") == ["10010010"])
        #expect(codes("DEFF").isEmpty)  // BIC matches by prefix only
    }

    @Test func ranksExactThenPrefixThenContains() {
        let directory = FinTSBankDirectory(banks: [
            Self.bank("11111111", "Alpha Bank", city: "Bonn"),
            Self.bank("22222222", "Beta Bank", city: "Bank"),
            Self.bank("33333333", "Zeta Bank Bonn", city: "Ulm"),
            Self.bank("44444444", "Bank Nord", city: "Kiel"),
            Self.bank("55555555", "Bank", city: "Kiel", bic: "BANKDEFFXXX"),
            Self.bank("66666666", "Gamma", city: "Hamm", bic: "BANKDE66XXX"),
        ])
        // Prefix of name or BIC first (alphabetical by name), then names containing the text.
        #expect(directory.search("bank").map(\.bankCode)
                == ["55555555", "44444444", "66666666", "11111111", "22222222", "33333333"])

        // An exact BIC beats a name prefix that sorts earlier.
        let exactBIC = FinTSBankDirectory(banks: [
            Self.bank("10000000", "AAAB Bank", city: "X", bic: "OTHERDEFXXX"),
            Self.bank("20000000", "ZZZ Bank", city: "Y", bic: "AAAB"),
        ])
        #expect(exactBIC.search("aaab").map(\.bankCode) == ["20000000", "10000000"])

        // An exact bank code beats a name that merely contains the digits.
        let exactCode = FinTSBankDirectory(banks: [
            Self.bank("99912345", "Alpha 12345678 Bank", city: "Y"),
            Self.bank("12345678", "Zeta", city: "X"),
            Self.bank("12345679", "Beta", city: "Z"),
        ])
        #expect(exactCode.search("12345678").map(\.bankCode) == ["12345678", "99912345"])
    }

    @Test func namePrefixBeatsContains() {
        // Only Sparkasse KölnBonn starts with the query; the other two contain it.
        #expect(codes("sparkasse") == ["37050198", "37050299", "40000004"])
    }

    @Test func tieBreakIsAlphabeticalByFoldedName() {
        let directory = FinTSBankDirectory(banks: [
            Self.bank("30000000", "Zebra Sparkasse", city: "Ulm"),
            Self.bank("10000000", "Ärzte Sparkasse", city: "Ulm"),
            Self.bank("20000000", "Mitte Sparkasse", city: "Ulm"),
        ])
        #expect(directory.search("sparkasse").map(\.name) == ["Ärzte Sparkasse", "Mitte Sparkasse", "Zebra Sparkasse"])
        // Same name: bank code decides.
        let same = FinTSBankDirectory(banks: [
            Self.bank("20000000", "Volksbank", city: "A"),
            Self.bank("10000000", "Volksbank", city: "B"),
        ])
        #expect(same.search("volks").map(\.bankCode) == ["10000000", "20000000"])
    }

    @Test func limitsResults() {
        #expect(codes("bank", limit: 2).count == 2)
        #expect(codes("e", limit: 3).count == 3)
        let many = FinTSBankDirectory(banks: (0..<120).map {
            Self.bank(String(10_000_000 + $0), "Volksbank \($0)", city: "Ort")
        })
        #expect(many.search("volksbank").count == 50)
        #expect(many.search("volksbank", limit: 7).count == 7)
        #expect(many.search("volksbank", limit: 500).count == 120)
    }

    @Test func noMatchYieldsNothing() {
        #expect(codes("zzzz").isEmpty)
    }

    // MARK: Lookup

    @Test func looksUpByCodeWithSpaces() {
        #expect(Self.directory.bank(code: "37050198")?.name == "Sparkasse KölnBonn")
        #expect(Self.directory.bank(code: "370 501 98")?.name == "Sparkasse KölnBonn")
        #expect(Self.directory.bank(code: " 370501 98 ")?.bankCode == "37050198")
        #expect(Self.directory.bank(code: "99999999") == nil)
        #expect(Self.directory.bank(code: "") == nil)
    }

    @Test func keepsOneEntryPerBankCode() {
        let directory = FinTSBankDirectory(banks: [
            Self.bank("37050198", "First", city: "A"),
            Self.bank("370 501 98", "Second", city: "B"),
        ])
        #expect(directory.search("37050198").map(\.name) == ["First"])
        #expect(directory.bank(code: "37050198")?.name == "First")
    }

    // MARK: Model

    @Test func codableRoundTrip() throws {
        let banks = [
            Self.bank("37050198", "Sparkasse KölnBonn", city: "Köln", bic: "COLSDE33XXX", version: "FinTS V3.0"),
            Self.bank("10000001", "Ohne BIC", city: "Berlin", version: nil),
        ]
        let data = try JSONEncoder().encode(banks)
        #expect(try JSONDecoder().decode([FinTSBankInfo].self, from: data) == banks)
    }

    @Test func decodesImporterOutputForm() throws {
        let json = """
        [{"bankCode":"10000001","bic":"TESTDE01XXX","city":"Berlin","fintsVersion":"FinTS V3.0",
          "name":"Beispielbank Ost","pinTanURL":"https://fints.example.invalid/ost/pintan"},
         {"bankCode":"10000006","city":"Düsseldorf","name":"Großstadt Genossenschaftsbank eG",
          "pinTanURL":"https://fints.example.invalid/gross"}]
        """
        let banks = try JSONDecoder().decode([FinTSBankInfo].self, from: Data(json.utf8))
        #expect(banks.count == 2)
        #expect(banks[0].pinTanURL.absoluteString == "https://fints.example.invalid/ost/pintan")
        #expect(banks[0].fintsVersion == "FinTS V3.0")
        #expect(banks[1].bic == nil)
        #expect(banks[1].fintsVersion == nil)
    }

    @Test func buildsPickerEntry() {
        let entry = Self.bank("37050198", "Sparkasse KölnBonn", city: "Köln").directoryEntry
        #expect(entry == BankDirectoryEntry(name: "Sparkasse KölnBonn", city: "Köln", bankCode: "37050198", protocolLabel: "FinTS"))
        #expect(entry.bankCodeFormatted == "370 501 98")
    }

    // MARK: Bundled list

    @Test func bundledListLoads() throws {
        let directory = try FinTSBankDirectory.bundled()
        // The list is empty until the product is registered; once filled, every entry needs an https endpoint.
        if directory.isEmpty {
            #expect(directory.search("sparkasse").isEmpty)
        } else {
            for bank in directory.search("bank", limit: 1000) {
                #expect(bank.pinTanURL.scheme == "https")
            }
        }
    }
}
