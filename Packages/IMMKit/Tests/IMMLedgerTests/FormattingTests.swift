import Foundation
import Testing
@testable import IMMLedger

@Suite struct FormattingTests {
    @Test func money() {
        #expect(MoneyFormatter.string(-112000) == "\u{2212}1.120,00\u{00A0}€")
        #expect(MoneyFormatter.string(384000, sign: .always) == "+3.840,00\u{00A0}€")
        #expect(MoneyFormatter.string(6305854) == "63.058,54\u{00A0}€")
        #expect(MoneyFormatter.string(-152643, symbol: false) == "\u{2212}1.526,43")
        #expect(MoneyFormatter.string(0, sign: .always) == "0,00\u{00A0}€")
        #expect(MoneyFormatter.string(0) == "0,00\u{00A0}€")
        #expect(MoneyFormatter.string(5) == "0,05\u{00A0}€")
        #expect(MoneyFormatter.string(-5) == "\u{2212}0,05\u{00A0}€")
        #expect(MoneyFormatter.string(99) == "0,99\u{00A0}€")
        #expect(MoneyFormatter.string(100000) == "1.000,00\u{00A0}€")
        #expect(MoneyFormatter.string(99999) == "999,99\u{00A0}€")
        #expect(MoneyFormatter.string(123456789012) == "1.234.567.890,12\u{00A0}€")
        #expect(MoneyFormatter.string(Int.min, symbol: false).hasPrefix("\u{2212}92.233.720.368.547.758,08"))
        #expect(MoneyFormatter.string(1000, currency: "USD") == "10,00\u{00A0}$")
        #expect(MoneyFormatter.string(1000, currency: "CHF") == "10,00\u{00A0}CHF")
    }

    @Test func moneyUsesExactScalars() {
        let text = MoneyFormatter.string(-112000)
        let scalars = text.unicodeScalars.map(\.value)
        #expect(scalars.first == 0x2212)
        #expect(scalars.contains(0x00A0))
        #expect(!scalars.contains(0x20))
        #expect(!scalars.contains(0x2D))
        #expect(scalars.last == 0x20AC)
    }

    @Test func dates() {
        let date = d("2026-11-12")
        #expect(DateFormats.dayMonth(date) == "12.11.")
        #expect(DateFormats.dayMonthYear(date) == "12.11.2026")
        #expect(DateFormats.monthYear(date) == "November 2026")
        #expect(DateFormats.monthName(date) == "November")
        #expect(DateFormats.weekdayShort(date) == "Thu")
        #expect(DateFormats.dayMonth(d("2026-01-05")) == "05.01.")
        #expect(DateFormats.monthName(d("2026-03-01")) == "March")
        #expect(DateFormats.weekdayShort(d("2026-11-15")) == "Sun")
        #expect(DateFormats.weekdayShort(d("2026-11-14")) == "Sat")
    }
}
