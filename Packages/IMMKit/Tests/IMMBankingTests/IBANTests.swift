import Testing
@testable import IMMBanking

@Suite("IBAN")
struct IBANTests {
    @Test func validIBANs() {
        #expect(IBAN.isValid("DE89 3704 0044 0532 0130 00"))
        #expect(IBAN.isValid("de89370400440532013000"))
        #expect(IBAN.isValid("GB82 WEST 1234 5698 7654 32"))
        #expect(IBAN.isValid("FR14 2004 1010 0505 0001 3M02 606"))
        #expect(IBAN.isValid("  DE89 3704 0044 0532 0130 00  "))
        #expect(IBAN.isValid("LU28 0019 4006 4475 0000"))
    }

    @Test func invalidIBANs() {
        #expect(!IBAN.isValid(""))
        #expect(!IBAN.isValid("DE89 3704 0044 0532 0130 01"))      // wrong check
        #expect(!IBAN.isValid("DE88 3704 0044 0532 0130 00"))      // wrong check digits
        #expect(!IBAN.isValid("DE89 3704 0044 0532 0130"))         // too short for DE
        #expect(!IBAN.isValid("DE89 3704 0044 0532 0130 000"))     // too long for DE
        #expect(!IBAN.isValid("1289 3704 0044 0532 0130 00"))      // no country
        #expect(!IBAN.isValid("DE89-3704-0044-0532-0130-00"))      // punctuation
        #expect(!IBAN.isValid("DE05 1203 0000 1056 7789 12"))      // the designed sample fails the checksum
    }

    @Test func checkDigitsAreRecomputed() {
        #expect(IBAN.withCheckDigits(country: "DE", bban: "370400440532013000") == "DE89370400440532013000")
        let fixed = IBAN.withCheckDigits(country: "DE", bban: "120300001056778912")
        #expect(IBAN.isValid(fixed))
        #expect(fixed.dropFirst(4) == "120300001056778912")
    }

    @Test func formatting() {
        #expect(IBAN.formatted("de89370400440532013000") == "DE89 3704 0044 0532 0130 00")
        #expect(IBAN.normalized(" de89 3704 ") == "DE893704")
    }
}
