import Foundation
import IMMBanking
import IMMLedger
import Observation

/// "Now / On date / Standing order" of the Execute toggle.
enum TransferExecuteMode: Hashable {
    case now, onDate, standingOrder
}

/// Parsing and printing of the amounts and dates the form accepts (German notation).
enum TransferInput {
    /// Minor units for "120,00", "1.200,5", "120", "1200.50"; nil for empty or malformed text.
    static func amount(_ text: String) -> Int? {
        var cleaned = ""
        for char in text where !char.isWhitespace && char != "€" && char != "'" {
            cleaned.append(char)
        }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == ".") }) else { return nil }

        let decimalSeparator: Character?
        if cleaned.contains(",") {
            decimalSeparator = ","
        } else if cleaned.filter({ $0 == "." }).count == 1,
                  let dot = cleaned.firstIndex(of: "."),
                  cleaned.distance(from: dot, to: cleaned.endIndex) - 1 <= 2 {
            decimalSeparator = "."
        } else {
            decimalSeparator = nil
        }

        var whole = cleaned
        var fraction = ""
        if let separator = decimalSeparator, let index = cleaned.lastIndex(of: separator) {
            whole = String(cleaned[cleaned.startIndex..<index])
            fraction = String(cleaned[cleaned.index(after: index)...])
        }
        whole = whole.filter { $0 != "." && $0 != "," }
        guard fraction.count <= 2, !fraction.contains("."), !fraction.contains(","), whole.count <= 9 else { return nil }
        guard !(whole.isEmpty && fraction.isEmpty) else { return nil }
        while fraction.count < 2 { fraction.append("0") }
        guard let wholeValue = Int(whole.isEmpty ? "0" : whole), let fractionValue = Int(fraction) else { return nil }
        return wholeValue * 100 + fractionValue
    }

    /// `120,00`, `1.200,50` (no currency sign).
    static func amountText(_ minor: Int) -> String {
        MoneyFormatter.string(minor, symbol: false)
    }

    /// `dd.MM.yyyy` → date; nil when malformed or not a real day.
    static func date(_ text: String) -> LocalDate? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let day = Int(parts[0]), let month = Int(parts[1]), let year = Int(parts[2]),
              parts[2].count == 4, (1...12).contains(month), day >= 1, year >= 1900
        else { return nil }
        let date = LocalDate(year: year, month: month, day: 1)
        guard day <= date.daysInMonth else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }
}

/// Bank name and BIC for the bank codes of the demo data and the designed transfer.
enum TransferBankDirectory {
    private static let table: [String: String] = [
        "37040044": "Commerzbank Köln · COBADEFFXXX",
        "37050198": "Sparkasse KölnBonn · COLSDE33XXX",
        "37050299": "Kreissparkasse Köln · COKSDE33XXX",
        "37551440": "Sparkasse Leverkusen · WELADED1LEV",
        "38450000": "Sparkasse Gummersbach · WELADED1GMB",
        "50010517": "ING · INGDDEFFXXX",
        "12030000": "DKB · BYLADEM1001",
        "10010010": "Postbank Berlin · PBNKDEFFXXX",
        "10011001": "N26 · NTSBDEB1XXX",
    ]

    /// "Commerzbank Köln · COBADEFFXXX" for a German IBAN with a known bank code.
    static func description(forIBAN iban: String) -> String? {
        let compact = IBAN.normalized(iban)
        guard compact.hasPrefix("DE"), compact.count >= 12 else { return nil }
        let start = compact.index(compact.startIndex, offsetBy: 4)
        let end = compact.index(start, offsetBy: 8)
        return table[String(compact[start..<end])]
    }
}

/// State of the New transfer form: the editable fields, the ledger data they depend on, and the
/// rules that enable Send.
@MainActor @Observable
final class TransferFormModel {
    var fromAccount: String?
    var recipient: String
    var iban: String
    var amountText: String
    var purpose: String
    var mode: TransferExecuteMode
    var dateText: String
    var instant: Bool
    private(set) var snapshot: TransferFormSnapshot?

    /// `seed` prefills the form; nil starts empty with instant payment on, as designed.
    init(seed: TransferDraft?) {
        fromAccount = seed?.fromAccount
        recipient = seed?.recipient ?? ""
        iban = (seed?.iban).map { $0.isEmpty ? "" : IBAN.formatted($0) } ?? ""
        amountText = (seed?.amountMinor ?? 0) > 0 ? TransferInput.amountText(seed?.amountMinor ?? 0) : ""
        purpose = seed?.purpose ?? ""
        instant = seed?.instant ?? true
        switch seed?.execution ?? .now {
        case .now:
            mode = .now
            dateText = ""
        case .onDate(let date):
            mode = .onDate
            dateText = DateFormats.dayMonthYear(date)
        case .standingOrder(let first):
            mode = .standingOrder
            dateText = DateFormats.dayMonthYear(first)
            instant = false
        }
    }

    // MARK: Ledger data

    /// Reads once, then follows the ledger until the surrounding task is cancelled.
    func follow(ledger: LedgerStore) async {
        if let initial = try? await ledger.database.read(TransferQueries.snapshot) { apply(initial) }
        do {
            for try await value in TransferQueries.observe(in: ledger) { apply(value) }
        } catch {
            // Locked or closed: the panel closes with the lock.
        }
    }

    func apply(_ value: TransferFormSnapshot) {
        snapshot = value
        if fromAccount == nil || !value.sources.contains(where: { $0.id == fromAccount }) {
            fromAccount = value.defaultSourceID
        }
        if mode != .now, dateText.isEmpty { dateText = DateFormats.dayMonthYear(value.today.adding(days: 1)) }
    }

    // MARK: Derived values

    var amountMinor: Int? { TransferInput.amount(amountText) }
    var ibanIsValid: Bool { IBAN.isValid(iban) }
    var bankDescription: String? { ibanIsValid ? TransferBankDirectory.description(forIBAN: iban) : nil }

    /// Shown when the IBAN has the length of a complete one and still fails the checksum.
    var showsIBANError: Bool { !ibanIsValid && IBAN.normalized(iban).count >= 15 }

    /// The saved recipient named in the To field.
    var savedRecipient: SavedRecipient? { snapshot?.recipient(named: recipient) }

    /// "Saved recipient, IBAN filled in …" while To and IBAN agree with a saved recipient.
    var showsSavedRecipientHint: Bool {
        guard let saved = savedRecipient else { return false }
        return IBAN.normalized(saved.iban) == IBAN.normalized(iban)
    }

    var executionDate: LocalDate? { TransferInput.date(dateText) }

    /// A date for "On date" and "Standing order" must be today or later.
    var dateIsValid: Bool {
        guard mode != .now else { return true }
        guard let date = executionDate, let today = snapshot?.today else { return executionDate != nil }
        return date >= today
    }

    var execution: PaymentExecution {
        switch mode {
        case .now: return .now
        case .onDate: return executionDate.map { .onDate($0) } ?? .now
        case .standingOrder: return executionDate.map { .standingOrder(firstExecution: $0) } ?? .now
        }
    }

    var draft: TransferDraft {
        TransferDraft(
            fromAccount: fromAccount, recipient: recipient, iban: IBAN.normalized(iban), amountMinor: amountMinor ?? 0,
            purpose: purpose, execution: execution, instant: mode == .now && instant)
    }

    /// Send is enabled only for a valid IBAN, a recipient and an amount above zero (plus a valid date
    /// for the dated modes and a source account).
    var canSend: Bool { draft.isSendable && fromAccount != nil && dateIsValid }

    /// "Send 120,00 €"; plain "Send" while the amount is empty or zero.
    var sendTitle: String {
        guard let minor = amountMinor, minor > 0 else { return String(localized: "Send", bundle: .module) }
        let amount = TransferInput.amountText(minor)
        return String(localized: "Send \(amount) €", bundle: .module)
    }

    // MARK: Editing

    /// Fills the IBAN from the saved recipient when the user typed a known name and left the IBAN empty.
    func recipientEdited() {
        guard IBAN.normalized(iban).isEmpty, let saved = savedRecipient else { return }
        iban = IBAN.formatted(saved.iban)
    }

    /// Groups a complete IBAN in fours (`DE89 3704 …`).
    func ibanEdited() {
        guard ibanIsValid else { return }
        let formatted = IBAN.formatted(iban)
        if formatted != iban { iban = formatted }
    }

    /// Prints the amount as `120,00` once the user is done typing.
    func normalizeAmount() {
        if let minor = amountMinor, minor > 0 { amountText = TransferInput.amountText(minor) }
    }

    /// Switches the mode; the dated modes start on tomorrow.
    func select(_ newMode: TransferExecuteMode) {
        mode = newMode
        if newMode != .now, executionDate == nil, let today = snapshot?.today {
            dateText = DateFormats.dayMonthYear(today.adding(days: 1))
        }
    }
}
