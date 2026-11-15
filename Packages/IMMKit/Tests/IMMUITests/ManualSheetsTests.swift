import IMMLedger
@testable import IMMUI
import Testing

@Suite("Manual account and booking sheets")
struct ManualSheetsTests {
    // MARK: Money parsing

    @Test("German amounts parse to exact minor units", arguments: [
        ("1.234,56", 123_456),
        ("-50", -5_000),
        ("\u{2212}50", -5_000),
        ("12,5", 1_250),
        ("12,05", 1_205),
        ("0,01", 1),
        ("+7", 700),
        ("  1.000 ", 100_000),
        ("-1.234.567,89", -123_456_789),
        ("0", 0),
    ])
    func parsesGermanAmounts(text: String, expected: Int) {
        #expect(ManualMoney.parse(text) == expected)
    }

    @Test("Malformed amounts are rejected", arguments: ["", " ", "-", "abc", "1,234.56", "12,345", "--5", "1.2.3,4,5.6", "12a"])
    func rejectsMalformedAmounts(text: String) {
        #expect(ManualMoney.parse(text) == nil)
    }

    // MARK: Account form

    @Test("An empty name keeps the account form disabled")
    func emptyNameDisables() {
        var form = ManualAccountFormModel()
        #expect(!form.canSubmit)
        form.name = "   "
        #expect(!form.canSubmit)
        form.name = "Wallet"
        #expect(form.canSubmit)
    }

    @Test("An invalid opening balance keeps the account form disabled; empty means zero")
    func invalidBalanceDisables() {
        var form = ManualAccountFormModel()
        form.name = "Cash"
        #expect(form.canSubmit)
        #expect(form.openingBalance == 0)
        form.balanceText = "abc"
        #expect(form.balanceIsInvalid)
        #expect(!form.canSubmit)
        form.balanceText = "1.234,56"
        #expect(!form.balanceIsInvalid)
        #expect(form.typedBalance == 123_456)
    }

    @Test("The account form builds the ledger input")
    func accountInput() {
        var form = ManualAccountFormModel()
        form.name = "  Household cash "
        form.kind = .wallet
        form.balanceText = "-12,5"
        #expect(form.input == ManualAccountInput(name: "Household cash", kind: .wallet, openingBalance: -1_250))
    }

    @Test("Kinds are labelled as in the design")
    func kindLabels() {
        #expect(ManualAccountFormModel.kinds == [.giro, .savings, .creditCard, .wallet])
        #expect(ManualAccountFormModel.kinds.map(ManualAccountFormModel.title(of:)) == [
            "Current account", "Savings", "Credit card", "Cash / wallet",
        ])
    }

    // MARK: Booking form

    private func filledForm() -> ManualBookingFormModel {
        var form = ManualBookingFormModel(accountID: "manual-1", today: LocalDate(year: 2026, month: 11, day: 15))
        form.amountText = "12,50"
        form.counterparty = "Bakery"
        return form
    }

    @Test("The booking date starts on the ledger's today")
    func dateDefault() {
        let form = ManualBookingFormModel(accountID: nil, today: LocalDate(year: 2026, month: 11, day: 5))
        #expect(form.dateText == "05.11.2026")
        #expect(form.date == LocalDate(year: 2026, month: 11, day: 5))
    }

    @Test("An expense is booked negative")
    func expenseSign() {
        var form = filledForm()
        form.isExpense = true
        form.purpose = " Bread "
        let input = form.input
        #expect(input?.amount == -1_250)
        #expect(input?.accountID == "manual-1")
        #expect(input?.bookingDate == LocalDate(year: 2026, month: 11, day: 15))
        #expect(input?.counterparty == "Bakery")
        #expect(input?.purpose == "Bread")
        #expect(input?.categoryID == nil)
        #expect(input?.note == nil)
    }

    @Test("Income is booked positive, with category and note")
    func incomeSign() {
        var form = filledForm()
        form.isExpense = false
        form.categoryID = "salary"
        form.note = "Birthday"
        let input = form.input
        #expect(input?.amount == 1_250)
        #expect(input?.categoryID == "salary")
        #expect(input?.note == "Birthday")
    }

    @Test("A booking needs account, counterparty, a positive amount and a real date")
    func bookingValidation() {
        var form = filledForm()
        #expect(form.canSave)

        var noCounterparty = form
        noCounterparty.counterparty = "  "
        #expect(!noCounterparty.canSave)

        for text in ["", "0", "-5", "abc"] {
            form.amountText = text
            #expect(!form.canSave, "amount \(text)")
        }
        form.amountText = "5"
        form.dateText = "31.02.2026"
        #expect(form.dateIsInvalid)
        #expect(!form.canSave)
        form.dateText = "28.02.2026"
        #expect(form.canSave)
        form.accountID = nil
        #expect(!form.canSave)
    }
}
