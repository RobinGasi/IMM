import Foundation
import IMMBanking
import IMMLedger

/// Which accounts the Transactions screen shows.
public enum AccountScope: Hashable, Sendable {
    case all
    /// Ledger account id.
    case account(String)
}

/// What the main window's detail column shows. The sidebar sets it.
public enum MainRoute: Hashable, Sendable {
    case overview
    case transactions(AccountScope)
    case suggestions
    case monthReview
    case depot
    case budgets
    case standingOrders
    case contracts
    case categories
    case taxReturn
    case payInvoice

    /// Screens that lay out their own scrolling (Transactions: the table always scrolls; Pay invoice and Tax return: header fixed) are not put
    /// inside the shell's vertical `ScrollView`; they receive the full detail area instead.
    public var managesOwnScrolling: Bool {
        switch self {
        case .transactions, .payInvoice, .taxReturn: return true
        default: return false
        }
    }
}

/// The in-window panels.
public enum Panel: Equatable, Sendable {
    /// Ask / search (⌘K).
    case ask
    /// New transfer; the draft prefills the form (Pay invoice, "New standing order", "Prepare transfer").
    case newTransfer(TransferDraft?)
    /// TAN sheet under the toolbar; the phase follows `BankController.submit`.
    case tan(TANPhase)
    /// PIN sheet under the toolbar (after a rejected PIN).
    case pin

    /// Panels whose dim covers the whole window; the others dim only the content pane under the toolbar.
    public var dimsWholeWindow: Bool {
        switch self {
        case .ask, .newTransfer: return true
        case .tan, .pin: return false
        }
    }
}

/// State of a payment while the TAN sheet is open. Every case carries the order so the sheet can print
/// the amount and recipient and re-send it ("Send a new request").
public enum TANPhase: Equatable, Sendable {
    /// Step 2: "Waiting for approval". `sentAt` is when the bank sent the push request.
    case waiting(sentAt: Date, order: PaymentOrder)
    /// Step 3: "Booked HH:MM" (`at`), with the Done button. `sentAt` is when the request went to the bank (step 1).
    case booked(sentAt: Date, at: Date, order: PaymentOrder)
    /// The request timed out ("TAN expired"): `expiredAt` is the deadline the bank reported.
    case expired(sentAt: Date, expiredAt: Date, order: PaymentOrder)
    /// Any other bank error while paying (rejected, offline, maintenance). Show it like `expired` with `message`.
    case failed(message: String, order: PaymentOrder)

    public var order: PaymentOrder {
        switch self {
        case .waiting(_, let order), .booked(_, _, let order), .expired(_, _, let order), .failed(_, let order):
            return order
        }
    }
}

/// The values the New transfer form starts with (and edits). Amount is positive minor units.
public struct TransferDraft: Hashable, Sendable {
    /// Ledger account id of the source account; nil = the first Girokonto.
    public var fromAccount: String?
    public var recipient: String
    public var iban: String
    public var amountMinor: Int
    public var purpose: String
    public var execution: PaymentExecution
    public var instant: Bool

    public init(
        fromAccount: String? = nil, recipient: String = "", iban: String = "", amountMinor: Int = 0,
        purpose: String = "", execution: PaymentExecution = .now, instant: Bool = false
    ) {
        self.fromAccount = fromAccount
        self.recipient = recipient
        self.iban = iban
        self.amountMinor = amountMinor
        self.purpose = purpose
        self.execution = execution
        self.instant = instant
    }

    /// Send is enabled only for a valid IBAN, a recipient and an amount above zero.
    public var isSendable: Bool {
        IBAN.isValid(iban)
            && !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && amountMinor > 0
    }

    /// The order handed to the connector; `account` is the resolved source account id.
    public func order(fromAccount account: String) -> PaymentOrder {
        PaymentOrder(
            fromAccount: account, recipient: recipient.trimmingCharacters(in: .whitespacesAndNewlines),
            iban: IBAN.normalized(iban), amount: amountMinor, purpose: purpose, execution: execution, instant: instant)
    }
}
