import Foundation
import IMMLedger

/// Deterministic ids for accounts and bookings: two devices that import the same bank data derive the same ids
/// without talking to each other, so sync never sees the same booking twice.
///
/// `BookingIdentity v1`. Bank references can't identify bookings (MT940 has no unique id and camt feeds send
/// `NONREF`), so the id is a hash over the booking's content:
///
///     id = UUIDv8(SHA-256("imm/booking/v1" ‖ acct ‖ day ‖ amt ‖ cur ‖ rev ‖ cp ‖ txt ‖ occ))
///
/// every field length-prefixed (4-byte big-endian length, UTF-8). `acct` is the derived account id, `day` the booking
/// date, `amt`/`cur` the signed minor units and currency, `rev` the reversal flag (0 until connectors report it),
/// `cp` the counterparty IBAN else the normalised name, `txt` the first 64 characters of the normalised purpose
/// (NFKC, lower case, `ä→ae ö→oe ü→ue ß→ss`, only `[a-z0-9]`), and `occ` the 0-based rank among identical entries of
/// the account in one merged fetch (ordered by usable bank reference, then delivery order).
///
/// Bank references, value dates, booking text, display forms of name and purpose and the booked time are attributes,
/// not identity. The algorithm is frozen: golden tests pin it. The hashing itself lives in `IMMLedger.StableID` because
/// the schema migration (`IMMLedger`) re-identifies existing rows with the very same function.
public enum BookingIdentity {
    /// `UUIDv8(SHA-256("imm/account/v1" ‖ key))` where `key` is the normalised IBAN, or `bankCode/number` for
    /// accounts without one (cards, depots, wallets). `accountNumber` is the IBAN when the account has one.
    public static func accountID(bankCode: String, accountNumber: String) -> String {
        StableID.accountID(bankCode: bankCode, accountNumber: accountNumber)
    }

    /// Ids for the bookings of one account, in input order. Pass the whole merged fetch of the account (all pages and
    /// parts, pending entries excluded): the occurrence index of identical entries is assigned over exactly this set.
    public static func bookingIDs(for transactions: [BankTransaction], accountID: String) -> [String] {
        StableID.bookingIDs(
            accountID: accountID,
            entries: transactions.map { transaction in
                (StableID.BookingContent(
                    day: transaction.bookingDate, amount: transaction.amount, currency: transaction.currency,
                    counterpartyKey: StableID.counterpartyKey(iban: transaction.counterpartyIBAN, name: transaction.counterpartyName),
                    purposeKey: StableID.purposeKey(transaction.purpose)),
                 transaction.reference)
            })
    }

    /// RFC 9562 §5.8 / Appendix B.2: the first 128 bits of `SHA-256(data)` with version 8 and variant `10`.
    public static func uuidV8(sha256Of data: Data) -> UUID {
        StableID.uuidV8(sha256Of: data)
    }
}
