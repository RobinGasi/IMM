import Foundation
import IMMBanking
import IMMLedger

// Types shared by the parts of the FinTS client: the statement parsers (MT940, camt) produce `StatementEntry`,
// the dialog layer implements `FinTSBankClient`, and `FinTSConnector` maps both onto `IMMBanking`'s models.

// MARK: - Statements

/// One booking (or pending entry) as a bank statement format delivers it, before it becomes a `BankTransaction`.
/// MT940 (`HKKAZ`) and camt.052/053 (`HKCAZ`) parsers both produce this type.
public struct StatementEntry: Sendable, Hashable, Codable {
    public var bookingDate: LocalDate
    public var valueDate: LocalDate
    /// Signed minor units: negative leaves the account.
    public var amount: Int
    /// ISO 4217, for example `EUR`.
    public var currency: String
    /// A storno (MT940 `RC`/`RD`, camt `RvslInd`).
    public var isReversal: Bool
    /// A pending (*vorgemerkt*) entry: MT942 / camt.052 `PDNG`.
    public var isPending: Bool
    /// Payer for credits, payee for debits; nil when the bank sends none.
    public var counterpartyName: String?
    public var counterpartyIBAN: String?
    public var counterpartyBIC: String?
    /// Remittance information joined into one line (SEPA `SVWZ+` content when structured), never nil.
    public var purpose: String
    /// Booking text such as `Lastschrift`, `Gutschrift`, `Kartenzahlung`.
    public var bookingText: String?
    /// German business transaction code (*Geschäftsvorfallcode*, three digits such as `005`, `166`), MT940 `:86:`
    /// prefix or camt `Prtry` code; nil when absent.
    public var transactionCode: String?
    public var endToEndID: String?
    public var mandateID: String?
    public var creditorID: String?
    /// The bank's own reference when it is usable (not empty, not `NONREF`).
    public var bankReference: String?

    public init(bookingDate: LocalDate, valueDate: LocalDate, amount: Int, currency: String, isReversal: Bool = false,
                isPending: Bool = false, counterpartyName: String? = nil, counterpartyIBAN: String? = nil,
                counterpartyBIC: String? = nil, purpose: String, bookingText: String? = nil, transactionCode: String? = nil,
                endToEndID: String? = nil, mandateID: String? = nil, creditorID: String? = nil, bankReference: String? = nil) {
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.amount = amount
        self.currency = currency
        self.isReversal = isReversal
        self.isPending = isPending
        self.counterpartyName = counterpartyName
        self.counterpartyIBAN = counterpartyIBAN
        self.counterpartyBIC = counterpartyBIC
        self.purpose = purpose
        self.bookingText = bookingText
        self.transactionCode = transactionCode
        self.endToEndID = endToEndID
        self.mandateID = mandateID
        self.creditorID = creditorID
        self.bankReference = bankReference
    }
}

// MARK: - Bank access

/// Where a bank's FinTS PIN/TAN server lives.
public struct FinTSEndpoint: Sendable, Hashable, Codable {
    /// Eight digits (*Bankleitzahl*).
    public var bankCode: String
    /// HTTPS URL of the PIN/TAN access, for example `https://banking-dkb.s-fints-pt-dkb.de/fints30`.
    public var url: URL

    public init(bankCode: String, url: URL) {
        self.bankCode = bankCode
        self.url = url
    }
}

/// The user's login at the bank. FinTS calls the login name *Benutzerkennung*; IMM uses it as customer id too.
public struct FinTSUser: Sendable, Hashable {
    public var loginName: String
    public var pin: String

    public init(loginName: String, pin: String) {
        self.loginName = loginName
        self.pin = pin
    }
}

/// The registered product, sent in `HKVVB`. Without a registration number from the Deutsche Kreditwirtschaft banks
/// refuse the dialog.
public struct FinTSProduct: Sendable, Hashable {
    /// Registration number (*Produktbezeichnung*), up to 25 characters.
    public var id: String
    /// Product version, up to 5 characters, for example `0.2.0`.
    public var version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

/// An account the bank offers for SEPA business: `HISPA` joined with the user parameter data (`HIUPD`).
public struct FinTSSEPAAccount: Sendable, Hashable, Codable {
    public var iban: String?
    public var bic: String?
    /// National account number (*Kontonummer*).
    public var accountNumber: String
    /// *Unterkontomerkmal*; nil when the bank sends none.
    public var subaccount: String?
    /// Bank code of the account (may differ from the login's bank code).
    public var bankCode: String
    /// `HIUPD` product name, for example `Girokonto` or `Visa Card`.
    public var productName: String?
    public var ownerName: String?
    /// ISO 4217, default `EUR`.
    public var currency: String
    /// `HIUPD` *Kontoart*: 1–9 current account, 10–19 savings, 20–29 time deposit, 30–39 securities (depot),
    /// 40–49 loan, 50–59 credit card, 60–69 fund depot, 70–79 home savings, 80–89 insurance, 90–99 other.
    public var accountType: Int?

    public init(iban: String?, bic: String?, accountNumber: String, subaccount: String?, bankCode: String,
                productName: String?, ownerName: String?, currency: String = "EUR", accountType: Int?) {
        self.iban = iban
        self.bic = bic
        self.accountNumber = accountNumber
        self.subaccount = subaccount
        self.bankCode = bankCode
        self.productName = productName
        self.ownerName = ownerName
        self.currency = currency
        self.accountType = accountType
    }
}

/// `HISAL`: the booked balance and, when the bank sends them, pending entries and the credit line.
public struct FinTSBalance: Sendable, Hashable, Codable {
    /// Signed minor units.
    public var booked: Int
    public var currency: String
    public var date: LocalDate
    /// Signed minor units of the pending balance (*vorgemerkter Saldo*), nil when absent.
    public var pending: Int?
    /// Credit line (*Kreditlinie*) in minor units, positive; nil when absent.
    public var creditLine: Int?

    public init(booked: Int, currency: String, date: LocalDate, pending: Int? = nil, creditLine: Int? = nil) {
        self.booked = booked
        self.currency = currency
        self.date = date
        self.pending = pending
        self.creditLine = creditLine
    }
}

/// What can go wrong talking to a bank, in terms the connector can map onto `BankError` and user-facing text.
public enum FinTSError: Error, Sendable, Equatable {
    /// PIN wrong or login blocked: return codes 9340, 9931, 9942 and similar. `message` is the bank's text.
    case pinRejected(code: Int, message: String)
    /// Any other error return code (9xxx) the dialog cannot handle.
    case bankRejected(code: Int, message: String)
    /// The bank reports maintenance or is temporarily unavailable.
    case maintenance(message: String)
    /// The bank offers only TAN methods that need a TAN typed in (chipTAN, photoTAN, smsTAN). IMM handles decoupled
    /// methods (pushTAN, app approval) only. Lists the offered method names.
    case unsupportedTANMethods([String])
    /// The user did not approve within the bank's decoupled polling window.
    case approvalTimedOut(sentAt: Date)
    /// Network or HTTP failure; `offline` when the device has no connection.
    case transport(message: String, offline: Bool)
    /// The bank's answer could not be parsed or broke the protocol.
    case malformedResponse(String)
    /// No FinTS access is known for this bank code.
    case unknownBank(bankCode: String)
    /// No registered product id is configured; FinTS stays off.
    case productNotRegistered
}

/// One login at one bank. Implementations open a FinTS dialog on first use, run strong customer authentication when
/// the bank asks for it (reporting `.waiting` / `.confirmed` through `onApproval`), reuse the dialog for later calls
/// and end it in `close()`. All methods may be called from any task; implementations serialise them.
public protocol FinTSBankClient: Sendable {
    /// Display name of the TAN method in use, for example `pushTAN 2.0`; nil before the first dialog.
    func tanMethodName() async -> String?
    /// The SEPA accounts of this login.
    func accounts(onApproval: @Sendable (ApprovalState) -> Void) async throws -> [FinTSSEPAAccount]
    func balance(of account: FinTSSEPAAccount, onApproval: @Sendable (ApprovalState) -> Void) async throws -> FinTSBalance
    /// Booked and pending entries from `from` through today (all touchdown pages fetched). Uses camt (`HKCAZ`) when the
    /// bank supports it, else MT940 (`HKKAZ`).
    func statements(of account: FinTSSEPAAccount, from: LocalDate,
                    onApproval: @Sendable (ApprovalState) -> Void) async throws -> [StatementEntry]
    /// Ends the dialog (`HKEND`). Safe to call more than once and when no dialog is open.
    func close() async
}

/// Values a FinTS login keeps between dialogs. None of them is secret: the PIN never goes here.
public protocol FinTSStateStore: Sendable {
    /// The customer system id from `HKSYN`; reusing it keeps the bank from treating every sign-in as a new device.
    func systemID(bankCode: String, loginName: String) -> String?
    func setSystemID(_ id: String, bankCode: String, loginName: String)
    /// The chosen TAN method's security function code (`HITANS`, for example `921`).
    func tanMethod(bankCode: String, loginName: String) -> String?
    func setTANMethod(_ code: String, bankCode: String, loginName: String)
}

/// A `FinTSStateStore` that forgets everything when the process ends (tests, previews).
public final class InMemoryFinTSStateStore: FinTSStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func systemID(bankCode: String, loginName: String) -> String? { get("system", bankCode, loginName) }
    public func setSystemID(_ id: String, bankCode: String, loginName: String) { set(id, "system", bankCode, loginName) }
    public func tanMethod(bankCode: String, loginName: String) -> String? { get("tan", bankCode, loginName) }
    public func setTANMethod(_ code: String, bankCode: String, loginName: String) { set(code, "tan", bankCode, loginName) }

    private func get(_ kind: String, _ bankCode: String, _ loginName: String) -> String? {
        lock.withLock { values["\(kind)/\(bankCode)/\(loginName)"] }
    }

    private func set(_ value: String, _ kind: String, _ bankCode: String, _ loginName: String) {
        lock.withLock { values["\(kind)/\(bankCode)/\(loginName)"] = value }
    }
}
