import Foundation

/// ISO 13616 helpers (mod 97).
public enum IBAN {
    /// Removes spaces and uppercases.
    public static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map { Character($0) }).uppercased()
    }

    /// True when `text` (spaces ignored, case ignored) is a structurally valid IBAN with correct check digits.
    public static func isValid(_ text: String) -> Bool {
        let iban = normalized(text)
        let chars = Array(iban.unicodeScalars)
        guard chars.count >= 15, chars.count <= 34 else { return false }
        for (index, scalar) in chars.enumerated() {
            let isUpper = scalar.value >= 65 && scalar.value <= 90
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            if index < 2 {
                if !isUpper { return false }
            } else if index < 4 {
                if !isDigit { return false }
            } else if !(isUpper || isDigit) {
                return false
            }
        }
        if iban.hasPrefix("DE") && chars.count != 22 { return false }
        return remainder(of: String(iban.dropFirst(4)) + String(iban.prefix(4))) == 1
    }

    /// Builds the compact IBAN (no spaces) for `country` and `bban` by computing the two check digits.
    public static func withCheckDigits(country: String, bban: String) -> String {
        let country = country.uppercased()
        let bban = normalized(bban)
        let remainder = remainder(of: bban + country + "00")
        let check = 98 - remainder
        return country + (check < 10 ? "0" : "") + String(check) + bban
    }

    /// Groups of four characters separated by spaces: `DE44 3705 0198 1934 0827 51`.
    public static func formatted(_ text: String) -> String {
        let iban = normalized(text)
        var out = ""
        for (index, char) in iban.enumerated() {
            if index > 0 && index % 4 == 0 { out.append(" ") }
            out.append(char)
        }
        return out
    }

    private static func remainder(of text: String) -> Int {
        var remainder = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= 48 && value <= 57 {
                remainder = (remainder * 10 + Int(value - 48)) % 97
            } else if value >= 65 && value <= 90 {
                let number = Int(value - 55)
                remainder = (remainder * 100 + number) % 97
            } else {
                return -1
            }
        }
        return remainder
    }
}
