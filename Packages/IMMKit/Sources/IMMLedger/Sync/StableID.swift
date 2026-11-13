import CryptoKit
import Foundation

/// Deterministic ids: the same real-world thing gets the same id on every device without coordination
/// (account from bank code and number, booking from its content, depot value from account and day, …).
///
/// Every id is a name-based UUIDv8 over SHA-256 (RFC 9562 §5.8, Appendix B.2) of length-prefixed fields
/// behind a versioned domain string. The algorithm is frozen: any change to a domain, a field, the
/// normalisation or the occurrence rule changes every id. Ids are never logged or used outside the
/// encrypted database and sealed batches.
public enum StableID {
    // MARK: UUIDv8

    /// RFC 9562 Appendix B.2: the first 128 bits of `SHA-256(data)` with version 8 and variant `10`.
    public static func uuidV8(sha256Of data: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// `SHA-256(len32(f1) ‖ f1 ‖ len32(f2) ‖ f2 …)` as UUIDv8 text (upper case, the form every table stores).
    static func derive(_ fields: [String]) -> String {
        var data = Data()
        for field in fields {
            let bytes = Array(field.utf8)
            let count = UInt32(bytes.count)
            data.append(contentsOf: [UInt8(count >> 24), UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)])
            data.append(contentsOf: bytes)
        }
        return uuidV8(sha256Of: data).uuidString
    }

    // MARK: Normalisation

    /// IBAN upper case without blanks.
    public static func normalizedIBAN(_ iban: String) -> String {
        String(iban.unicodeScalars.filter { !$0.properties.isWhitespace }.map(Character.init)).uppercased()
    }

    /// NFKC, lower case, `ä→ae ö→oe ü→ue ß→ss`, then only `[a-z0-9]` survives. Kills line wraps, blanks and bank
    /// padding, so MT940, camt and file imports of one booking hash equal. (Subfield tags such as `SVWZ+` are the
    /// parser's business; they must be stripped before the text gets here.)
    public static func normalizedText(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9": out.append(scalar)
            case "ä": out.append(contentsOf: "ae".unicodeScalars)
            case "ö": out.append(contentsOf: "oe".unicodeScalars)
            case "ü": out.append(contentsOf: "ue".unicodeScalars)
            case "ß": out.append(contentsOf: "ss".unicodeScalars)
            default: break
            }
        }
        return String(out)
    }

    /// Number of normalised purpose characters that take part in a booking's identity.
    public static let purposeLength = 64

    /// Counterparty IBAN when present, else the normalised name.
    public static func counterpartyKey(iban: String?, name: String) -> String {
        if let iban, !normalizedIBAN(iban).isEmpty { return normalizedIBAN(iban) }
        return normalizedText(name)
    }

    public static func purposeKey(_ purpose: String?) -> String {
        String(normalizedText(purpose ?? "").prefix(purposeLength))
    }

    // MARK: Accounts

    private static let ibanShape = try? NSRegularExpression(pattern: "^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$")

    /// The account's normalised key: the IBAN when `accountNumber` is one, else `bankCode/number`
    /// (blanks trimmed). Never the row's own id.
    public static func accountKey(bankCode: String, accountNumber: String) -> String {
        let candidate = normalizedIBAN(accountNumber)
        let range = NSRange(candidate.startIndex..., in: candidate)
        if ibanShape?.firstMatch(in: candidate, range: range) != nil { return candidate }
        return bankCode.trimmingCharacters(in: .whitespaces) + "/" + accountNumber.trimmingCharacters(in: .whitespaces)
    }

    public static func accountID(bankCode: String, accountNumber: String) -> String {
        derive(["imm/account/v1", accountKey(bankCode: bankCode, accountNumber: accountNumber)])
    }

    // MARK: Bookings

    /// `acct` is the derived account id. `occurrence` is the 0-based rank among identical entries (same day,
    /// amount, currency, reversal flag, counterparty key and purpose key) of the account in one merged fetch.
    public static func bookingID(
        accountID: String, day: LocalDate, amount: Int, currency: String, reversal: Bool = false,
        counterpartyKey: String, purposeKey: String, occurrence: Int
    ) -> String {
        derive(["imm/booking/v1", accountID, day.iso, String(amount), currency, reversal ? "1" : "0",
                counterpartyKey, purposeKey, String(occurrence)])
    }

    /// Everything about a booking that its id depends on (one account, normalised).
    public struct BookingContent: Hashable, Sendable {
        public var day: LocalDate
        public var amount: Int
        public var currency: String
        public var reversal: Bool
        public var counterpartyKey: String
        public var purposeKey: String

        public init(day: LocalDate, amount: Int, currency: String, reversal: Bool = false, counterpartyKey: String, purposeKey: String) {
            self.day = day
            self.amount = amount
            self.currency = currency
            self.reversal = reversal
            self.counterpartyKey = counterpartyKey
            self.purposeKey = purposeKey
        }
    }

    /// References that identify nothing (camt feeds send `NONREF`).
    private static let unusableReferences: Set<String> = ["", "NONREF", "NOTPROVIDED"]

    /// Ids for the bookings of one account in one merged fetch, in input order. Identical entries (same
    /// `BookingContent`) get occurrence indices 0, 1, 2 … ordered by usable bank reference first, then by
    /// delivery position, so two devices that see the same multiset assign the same ids.
    public static func bookingIDs(accountID: String, entries: [(content: BookingContent, reference: String?)]) -> [String] {
        var groups: [BookingContent: [Int]] = [:]
        for (index, entry) in entries.enumerated() { groups[entry.content, default: []].append(index) }
        var ids = [String](repeating: "", count: entries.count)
        for (content, members) in groups {
            func reference(_ index: Int) -> String? {
                let value = entries[index].reference?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                return value.flatMap { unusableReferences.contains($0) ? nil : $0 }
            }
            let ordered = members.sorted { a, b in
                switch (reference(a), reference(b)) {
                case let (x?, y?): return x != y ? x < y : a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a < b
                }
            }
            for (occurrence, index) in ordered.enumerated() {
                ids[index] = bookingID(
                    accountID: accountID, day: content.day, amount: content.amount, currency: content.currency,
                    reversal: content.reversal, counterpartyKey: content.counterpartyKey, purposeKey: content.purposeKey,
                    occurrence: occurrence)
            }
        }
        return ids
    }

    // MARK: Other rows

    public static func securityID(isin: String) -> String { derive(["imm/security/v1", isin.uppercased()]) }
    public static func holdingID(accountID: String, isin: String?) -> String {
        derive(["imm/holding/v1", accountID, isin?.uppercased() ?? "cash"])
    }
    public static func depotValueID(accountID: String, date: LocalDate) -> String { derive(["imm/depot-value/v1", accountID, date.iso]) }
    public static func budgetID(categoryID: String) -> String { derive(["imm/budget/v1", categoryID]) }
    public static func savingsPlanID(accountID: String) -> String { derive(["imm/savings-plan/v1", accountID]) }
    public static func savingsPlanItemID(planID: String, securityID: String) -> String {
        derive(["imm/savings-plan-item/v1", planID, securityID])
    }
}
