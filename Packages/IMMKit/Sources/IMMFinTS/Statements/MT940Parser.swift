import Foundation
import IMMLedger

/// Input the MT940 parser cannot turn into a booking at all. Unknown tags and missing optional parts never raise one.
public enum MT940ParserError: Error, Sendable, Equatable {
    /// A `:61:` line that does not follow the layout (dates, debit/credit mark). Carries the offending line.
    case invalidTransactionLine(String)
    /// A `:61:` line whose amount is missing or not `digits,digits` with at most two decimals. Carries the line.
    case invalidAmount(String)
    /// A `:61:` value or booking date that is not a real calendar day. Carries the digits as delivered.
    case invalidDate(String)
    /// A `:61:` line before any `:60F:`/`:60M:`/`:34F:` named the statement's currency.
    case missingCurrency
}

/// Parses SWIFT MT940 (booked) and MT942 (pending) account statements as banks deliver them in `HKKAZ` answers:
/// the German structured `:86:` field, several statements per blob, `-`/`@@` separators and either line ending.
public enum MT940Parser {
    /// Parses `data` into entries in delivery order.
    ///
    /// - Parameter pending: marks every entry `isPending`; pass `true` for the MT942 blob of an `HKKAZ` answer.
    /// - Throws: `MT940ParserError` for a `:61:` line that has no usable amount, date or currency. Empty input and
    ///   tags the parser does not know yield no error.
    public static func parse(_ data: Data, pending: Bool = false) throws -> [StatementEntry] {
        var entries: [StatementEntry] = []
        var currency: String?
        var previousTag = ""
        for field in fields(in: decode(data)) {
            switch field.tag {
            case "20":
                currency = nil
            case "60F", "60M", "34F":
                if let code = currencyCode(of: field) { currency = code }
            case "61":
                guard let currency else { throw MT940ParserError.missingCurrency }
                var entry = try transaction(from: field.lines[0], currency: currency)
                entry.isPending = pending
                entries.append(entry)
            case "86":
                // A `:86:` after anything but `:61:` (for example after `:62F:`) describes the statement, not a booking.
                if previousTag == "61", !entries.isEmpty {
                    details(from: field.lines).apply(to: &entries[entries.count - 1])
                }
            default:
                break
            }
            previousTag = field.tag
        }
        return entries
    }

    // MARK: - Text and fields

    /// Width of the `?20`…`?29`, `?60`…`?63` and `?32`/`?33` subfields; banks fill them up to here before wrapping.
    private static let wrapWidth = 27

    private struct Field {
        var tag: String
        /// The text after `:tag:` followed by every continuation line, line endings removed.
        var lines: [String]
    }

    /// Valid UTF-8 (which includes plain ASCII) is taken as is, everything else is ISO-8859-1, the encoding the
    /// FinTS `HKKAZ` answer declares. Latin-1 text with umlauts is practically never valid UTF-8, so the two never clash.
    private static func decode(_ data: Data) -> String {
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    private static func fields(in text: String) -> [Field] {
        var fields: [Field] = []
        var open = false
        for line in lines(of: text.replacingOccurrences(of: "@@", with: "\n")) {
            if let (tag, rest) = tagLine(line) {
                fields.append(Field(tag: tag, lines: [rest]))
                open = true
            } else if isSeparator(line) {
                open = false
            } else if open {
                fields[fields.count - 1].lines.append(line)
            }
        }
        return fields
    }

    /// Splits at `\n` and `\r` alone (Swift treats `\r\n` as one `Character`), dropping empty lines.
    private static func lines(of text: String) -> [String] {
        text.unicodeScalars
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String(String.UnicodeScalarView($0)) }
    }

    private static func tagLine(_ line: String) -> (tag: String, rest: String)? {
        let s = Array(line.unicodeScalars)
        guard s.count >= 4, s[0] == ":", isDigit(s[1]), isDigit(s[2]) else { return nil }
        var i = 3
        if i < s.count, ("A"..."Z").contains(s[i]) { i += 1 }
        guard i < s.count, s[i] == ":" else { return nil }
        return (String(String.UnicodeScalarView(s[1..<i])), String(String.UnicodeScalarView(s[(i + 1)...])))
    }

    /// `-`, `-}` and SWIFT block headers (`{1:…`) end the current field; the next tag starts a new one anyway.
    private static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "-" || trimmed == "-}" || trimmed == "}" || trimmed.hasPrefix("{")
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
    private static func isDigit(_ character: Character) -> Bool { ("0"..."9").contains(character) }

    /// The ISO 4217 code of a `:60F:`/`:60M:` (`C260101EUR1234,56`) or `:34F:` (`EURD0,`) field.
    private static func currencyCode(of field: Field) -> String? {
        let chars = Array(field.lines[0])
        let range = field.tag == "34F" ? 0..<3 : 7..<10
        guard chars.count >= range.upperBound else { return nil }
        let code = String(chars[range])
        guard code.utf8.count == 3, code.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else { return nil }
        return code
    }

    // MARK: - :61:

    /// `YYMMDD[MMDD](C|D|RC|RD)[funds code]amount N<type>customer reference[//bank reference]`; a second line with
    /// supplementary details is ignored.
    private static func transaction(from line: String, currency: String) throws -> StatementEntry {
        let chars = Array(line)
        let n = chars.count
        guard n >= 7, chars[0..<6].allSatisfy(isDigit) else { throw MT940ParserError.invalidTransactionLine(line) }
        let valueDate = try parseValueDate(yymmdd: String(chars[0..<6]))
        var i = 6

        var bookingDate = valueDate
        if n >= i + 4, chars[i..<(i + 4)].allSatisfy(isDigit) {
            bookingDate = try parseBookingDate(mmdd: String(chars[i..<(i + 4)]), near: valueDate)
            i += 4
        }

        let isCredit: Bool
        var isReversal = false
        if i + 1 < n, chars[i] == "R", chars[i + 1] == "C" || chars[i + 1] == "D" {
            isReversal = true
            isCredit = chars[i + 1] == "C"
            i += 2
        } else if i + 1 < n, chars[i] == "E", chars[i + 1] == "C" || chars[i + 1] == "D" {
            isCredit = chars[i + 1] == "C"
            i += 2
        } else if i < n, chars[i] == "C" || chars[i] == "D" {
            isCredit = chars[i] == "C"
            i += 1
        } else {
            throw MT940ParserError.invalidTransactionLine(line)
        }
        // Optional third letter of the currency (the "funds code"); the amount itself starts with a digit or a comma.
        if i < n, chars[i].isASCII, chars[i].isUppercase { i += 1 }

        var j = i
        while j < n, isDigit(chars[j]) || chars[j] == "," { j += 1 }
        guard let magnitude = minorUnits(String(chars[i..<j])) else { throw MT940ParserError.invalidAmount(line) }
        i = j

        // `N` (also `S`, `F`) and a three-character transaction type such as `MSC`, `TRF`, `DDT`; we use the GVC from `:86:`.
        if i < n, chars[i] == "N" || chars[i] == "S" || chars[i] == "F" { i = min(i + 4, n) }
        let rest = String(chars[i...])
        var bankReference: String?
        if let slashes = rest.range(of: "//") {
            let reference = rest[slashes.upperBound...].trimmingCharacters(in: .whitespaces)
            if !reference.isEmpty, reference.uppercased() != "NONREF" { bankReference = reference }
        }

        // Credit and not reversed, or debit and reversed: money comes in.
        let signed = isCredit != isReversal ? magnitude : -magnitude
        return StatementEntry(
            bookingDate: bookingDate, valueDate: valueDate, amount: signed, currency: currency,
            isReversal: isReversal, purpose: "", bankReference: bankReference)
    }

    /// Two-digit years are 20YY; nobody delivers MT940 from before 2000.
    private static func parseValueDate(yymmdd: String) throws -> LocalDate {
        let chars = Array(yymmdd)
        guard let date = LocalDate(iso: "20\(String(chars[0..<2]))-\(String(chars[2..<4]))-\(String(chars[4..<6]))")
        else { throw MT940ParserError.invalidDate(yymmdd) }
        return date
    }

    /// The booking date has no year; take the one that puts it closest to the value date, so a value date of
    /// 2026-01-02 with `1231` books on 2025-12-31 and a value date of 2025-12-31 with `0102` on 2026-01-02.
    private static func parseBookingDate(mmdd: String, near value: LocalDate) throws -> LocalDate {
        let chars = Array(mmdd)
        let month = String(chars[0..<2]), day = String(chars[2..<4])
        var best: LocalDate?
        for year in [value.year, value.year - 1, value.year + 1] {
            guard let candidate = LocalDate(iso: "\(year)-\(month)-\(day)") else { continue }
            if let current = best, abs(candidate - value) >= abs(current - value) { continue }
            best = candidate
        }
        guard let best else { throw MT940ParserError.invalidDate(mmdd) }
        return best
    }

    /// `1234,56` → 123456, `0,5` → 50, `12,` → 1200. Exact integer arithmetic; more than two decimals, a second
    /// comma or an overflow is nil.
    static func minorUnits(_ text: String) -> Int? {
        let parts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = parts[0]
        let fraction = parts.count > 1 ? parts[1] : ""
        guard !(whole.isEmpty && fraction.isEmpty), fraction.count <= 2,
              whole.allSatisfy(isDigit), fraction.allSatisfy(isDigit) else { return nil }
        let units = whole.isEmpty ? 0 : Int(whole)
        let cents = fraction.isEmpty ? 0 : Int(fraction.count == 1 ? fraction + "0" : fraction)
        guard let units, let cents else { return nil }
        let (scaled, overflow) = units.multipliedReportingOverflow(by: 100)
        let (total, overflowSum) = scaled.addingReportingOverflow(cents)
        return overflow || overflowSum ? nil : total
    }

    // MARK: - :86:

    private struct Details {
        var bookingText: String?
        var transactionCode: String?
        var counterpartyName: String?
        var counterpartyIBAN: String?
        var counterpartyBIC: String?
        var purpose = ""
        var endToEndID: String?
        var mandateID: String?
        var creditorID: String?

        func apply(to entry: inout StatementEntry) {
            entry.bookingText = bookingText
            entry.transactionCode = transactionCode
            entry.counterpartyName = counterpartyName
            entry.counterpartyIBAN = counterpartyIBAN
            entry.counterpartyBIC = counterpartyBIC
            entry.purpose = purpose
            entry.endToEndID = endToEndID
            entry.mandateID = mandateID
            entry.creditorID = creditorID
        }
    }

    /// Reads the German structured `:86:` (`GVC?00text?10primanota?20…?32name`). Anything else is one free text.
    private static func details(from lines: [String]) -> Details {
        var details = Details()
        let scalars = Array(lines.joined(separator: "\n").unicodeScalars)
        let purposeText: String
        var name: String?
        var accountField: String?
        var bankField: String?

        if let separator = structuredSeparator(scalars) {
            details.transactionCode = String(String.UnicodeScalarView(scalars[0..<3]))
            var purposePieces: [String] = [], namePieces: [String] = []
            for (code, value) in subfields(String(String.UnicodeScalarView(scalars[4...])), separator: Character(separator)) {
                switch code {
                case "00": details.bookingText = nonEmpty(normalize(value))
                case "20"..."29", "60"..."63": purposePieces.append(value)
                case "30": bankField = value
                case "31": accountField = value
                case "32", "33": namePieces.append(value)
                default: break // 10 primanota, 34 text key extension, 35…
                }
            }
            purposeText = normalize(joinWrapped(purposePieces))
            name = nonEmpty(normalize(joinWrapped(namePieces)))
        } else {
            purposeText = normalize(lines.joined(separator: " "))
        }

        let keywords = scanKeywords(in: purposeText)
        if let remittance = keywords.values["SVWZ"], !remittance.isEmpty {
            details.purpose = remittance
        } else {
            details.purpose = keywords.lead
        }
        details.endToEndID = reference(keywords.values["EREF"])
        details.mandateID = reference(keywords.values["MREF"])
        details.creditorID = reference(keywords.values["CRED"])
        details.counterpartyName = name ?? nonEmpty(keywords.values["ABWA"] ?? keywords.values["ABWE"] ?? "")
        details.counterpartyIBAN = [accountField, keywords.values["IBAN"]].lazy
            .compactMap { $0.map(compact) }.first(where: looksLikeIBAN)
        details.counterpartyBIC = [bankField, keywords.values["BIC"]].lazy
            .compactMap { $0.map(compact) }.first(where: looksLikeBIC)
        return details
    }

    /// The separator character when the text starts like `166?00…`: three digits, a punctuation character, two digits.
    private static func structuredSeparator(_ s: [Unicode.Scalar]) -> Unicode.Scalar? {
        guard s.count >= 6, isDigit(s[0]), isDigit(s[1]), isDigit(s[2]), isDigit(s[4]), isDigit(s[5]) else { return nil }
        let separator = s[3]
        guard !CharacterSet.alphanumerics.contains(separator),
              !CharacterSet.whitespacesAndNewlines.contains(separator) else { return nil }
        return separator
    }

    /// Splits `00Lastschrift?10931?20…` (text after the first separator) into `(code, value)` pairs in document
    /// order. Line breaks inside a subfield are dropped; a part that does not start with two digits is a stray
    /// separator inside the text and stays with the previous subfield.
    private static func subfields(_ body: String, separator: Character) -> [(code: String, value: String)] {
        var result: [(code: String, value: String)] = []
        for part in body.split(separator: separator, omittingEmptySubsequences: false) {
            let text = String(part.filter { $0 != "\n" })
            let chars = Array(text)
            if chars.count >= 2, isDigit(chars[0]), isDigit(chars[1]) {
                result.append((String(chars[0..<2]), String(chars[2...])))
            } else if !result.isEmpty {
                result[result.count - 1].value += String(separator) + text
            }
        }
        return result
    }

    /// Joins subfield lines: a line filled to the full width continues in the next one (the break can fall inside a
    /// word or a keyword), a shorter one ended on purpose, so a space goes in between.
    private static func joinWrapped(_ pieces: [String]) -> String {
        var result = ""
        var previousLength: Int?
        for piece in pieces where !piece.isEmpty {
            if let previousLength, previousLength < wrapWidth { result += " " }
            result += piece
            previousLength = piece.count
        }
        return result
    }

    private struct Keywords {
        /// The text before the first keyword.
        var lead: String
        /// First value per keyword (`EREF`, `SVWZ`, …), whitespace-normalised.
        var values: [String: String]
    }

    /// SEPA remittance keywords (DFÜ-Abkommen Anlage 3) plus the ones that must not leak into the purpose.
    private static let keywordNames = [
        "EREF", "KREF", "MREF", "CRED", "DEBT", "SVWZ", "ABWA", "ABWE", "IBAN", "BIC",
        "COAM", "OAMT", "PURP", "ORCR", "ORMR", "ULTC", "ULTD", "BREF", "RREF",
    ]

    private static func scanKeywords(in text: String) -> Keywords {
        var hits: [(name: String, start: String.Index, end: String.Index)] = []
        for name in keywordNames {
            let token = name + "+"
            var from = text.startIndex
            while from < text.endIndex, let found = text.range(of: token, range: from..<text.endIndex) {
                hits.append((name, found.lowerBound, found.upperBound))
                from = found.upperBound
            }
        }
        hits.sort { $0.start < $1.start }
        var values: [String: String] = [:]
        for (index, hit) in hits.enumerated() where values[hit.name] == nil {
            let end = index + 1 < hits.count ? hits[index + 1].start : text.endIndex
            values[hit.name] = normalize(String(text[hit.end..<end]))
        }
        return Keywords(lead: normalize(String(text[..<(hits.first?.start ?? text.endIndex)])), values: values)
    }

    // MARK: - Small helpers

    /// Collapses runs of whitespace to one space and trims.
    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// A SEPA reference, or nil for empty values and the placeholders banks fill in.
    private static func reference(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !["NOTPROVIDED", "NONREF"].contains(value.uppercased()) else { return nil }
        return value
    }

    private static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.uppercased()
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }
    private static func isASCIIDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    /// Two letters, two check digits, then 11–30 letters or digits; the check digits themselves are not verified.
    private static func looksLikeIBAN(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (15...34).contains(bytes.count), isASCIILetter(bytes[0]), isASCIILetter(bytes[1]),
              isASCIIDigit(bytes[2]), isASCIIDigit(bytes[3]) else { return false }
        return bytes.allSatisfy { isASCIILetter($0) || isASCIIDigit($0) }
    }

    /// Four bank letters, two country letters, two location characters and optionally three branch characters.
    private static func looksLikeBIC(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 8 || bytes.count == 11, bytes[0..<6].allSatisfy(isASCIILetter) else { return false }
        return bytes[6...].allSatisfy { isASCIILetter($0) || isASCIIDigit($0) }
    }
}
