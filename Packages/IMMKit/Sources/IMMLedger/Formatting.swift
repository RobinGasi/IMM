import Foundation

/// German money formatting: "." grouping, "," decimals, U+2212 minus, NBSP before the currency symbol.
public enum MoneyFormatter {
    public enum Sign: Sendable {
        case negativeOnly
        case always
    }

    /// `string(-112000) == "−1.120,00 €"`, `string(384000, sign: .always) == "+3.840,00 €"`.
    /// Zero never carries a sign. Amounts are minor units with two decimals.
    public static func string(_ minorUnits: Int, currency: String = "EUR", sign: Sign = .negativeOnly, symbol: Bool = true) -> String {
        let magnitude = minorUnits.magnitude
        let whole = magnitude / 100
        let fraction = magnitude % 100

        var result = ""
        if minorUnits < 0 {
            result += "\u{2212}"
        } else if minorUnits > 0 && sign == .always {
            result += "+"
        }
        result += grouped(whole)
        result += ","
        if fraction < 10 { result += "0" }
        result += String(fraction)
        if symbol {
            result += "\u{00A0}" + currencySymbol(currency)
        }
        return result
    }

    static func grouped(_ value: UInt) -> String {
        let digits = Array(String(value))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(".") }
            out.append(digit)
        }
        return out
    }

    static func currencySymbol(_ code: String) -> String {
        switch code {
        case "EUR": return "€"
        case "USD": return "$"
        case "GBP": return "£"
        default: return code
        }
    }
}

/// Date strings used by the design (English month and weekday names, German numeric formats).
public enum DateFormats {
    static let monthNames = ["January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]
    static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// `12.11.`
    public static func dayMonth(_ d: LocalDate) -> String {
        LocalDate.pad(d.day, 2) + "." + LocalDate.pad(d.month, 2) + "."
    }

    /// `12.11.2026`
    public static func dayMonthYear(_ d: LocalDate) -> String {
        dayMonth(d) + LocalDate.pad(d.year, 4)
    }

    /// `November 2026`
    public static func monthYear(_ d: LocalDate) -> String {
        monthName(d) + " " + String(d.year)
    }

    /// `November`
    public static func monthName(_ d: LocalDate) -> String {
        monthNames[min(max(d.month, 1), 12) - 1]
    }

    /// `Thu`
    public static func weekdayShort(_ d: LocalDate) -> String {
        weekdayNames[d.weekday - 1]
    }
}
