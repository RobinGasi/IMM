import Foundation
import Testing
import IMMLedger
@testable import IMMBanking

@Suite("Demo ledger: rules and profile")
struct DemoRulesTests {
    @Test func categories() {
        let categories = view.profile.categories.sorted { $0.sortOrder < $1.sortOrder }
        #expect(categories.map(\.name) == ["Housing", "Groceries", "Mobility", "Leisure & eating out", "Insurance & contracts",
                                           "Health & drugstore", "Other", "Income"])
        #expect(categories.map(\.colorToken) == ["chart-1", "chart-5", "chart-3", "chart-2", "chart-4", "muted-foreground",
                                                 "input", "credit"])
        #expect(categories.map(\.kind) == Array(repeating: .expense, count: 7) + [.income])
        // Every assigned category exists.
        let names = Set(categories.map(\.name))
        for name in view.profile.categoryByReference.values { #expect(names.contains(name)) }
    }

    @Test func dmIsGroceries() throws {
        let dm = try #require(view.transactions(DemoAccountID.giro).first { $0.shortName == "dm-drogerie markt" && $0.bookingDate == day(2026, 11, 9) })
        #expect(view.category(dm) == "Groceries")
    }

    @Test func sixUncategorisedTransactionsOnVisaAndPayPal() {
        let rows = view.snapshot.transactions.filter { view.category($0) == nil && !view.isOwnTransfer($0) }
        #expect(rows.count == 6)
        func has(_ account: String, _ date: LocalDate, _ amount: Int, _ name: String, _ text: String) -> Bool {
            rows.contains { $0.accountID == account && $0.bookingDate == date && $0.amount == amount
                && $0.shortName == name && $0.bookingText == text }
        }
        #expect(has(DemoAccountID.visa, day(2026, 11, 10), -3_499, "Amazon EU S.a.r.l.", "Kartenzahlung Visa"))
        #expect(has(DemoAccountID.visa, day(2026, 11, 7), -1_280, "Apotheke am Neumarkt", "Kartenzahlung Visa"))
        #expect(has(DemoAccountID.visa, day(2026, 11, 6), -640, "SumUp *Kiosk Ehrenfeld", "Kartenzahlung Visa"))
        #expect(has(DemoAccountID.visa, day(2026, 11, 4), -10_000, "Bargeldauszahlung Sparkasse", "Bargeldauszahlung Visa"))
        #expect(has(DemoAccountID.paypal, day(2026, 11, 8), -2_250, "PayPal *Etsy", "PayPal-Zahlung"))
        #expect(has(DemoAccountID.paypal, day(2026, 11, 3), 4_500, "Überweisung Jonas Weber", "PayPal-Zahlung"))
        #expect(rows.allSatisfy { $0.accountID != DemoAccountID.giro })
        #expect(rows.map(\.bookingDate).min() == day(2026, 11, 3))
    }

    @Test func visaCharges() {
        let visa = view.transactions(DemoAccountID.visa)
        let november = visa.filter { $0.bookingDate >= day(2026, 11, 1) && $0.bookingDate <= day(2026, 11, 12) }
        #expect(november.reduce(0) { $0 + $1.amount } == -38_412)
        #expect(november.count == 9)
        #expect(visa.filter { $0.bookingDate >= day(2026, 10, 21) && $0.bookingDate <= day(2026, 10, 31) }.isEmpty)
        #expect(view.balance(DemoAccountID.visa, on: day(2026, 10, 31)) == 0)
        #expect(visa.allSatisfy { $0.counterpartyIBAN == nil || $0.kind == .transfer })
    }

    @Test func fourteenNewRows() {
        let new = Set(view.profile.newReferences)
        #expect(new.count == 14)
        let rows = view.snapshot.transactions.filter { new.contains($0.reference) }
        #expect(rows.count == 14)
        let giro = rows.filter { $0.accountID == DemoAccountID.giro }
        #expect(giro.map(\.shortName).sorted() == ["Lieferando", "REWE", "dm-drogerie markt"])
        #expect(giro.map(\.bookingDate).sorted() == [day(2026, 11, 9), day(2026, 11, 10), day(2026, 11, 11)])
        let cards = rows.filter { $0.accountID != DemoAccountID.giro }
        #expect(cards.count == 11)
        // The 11 most recent Visa and PayPal rows: nothing outside the set is newer than its oldest member.
        let oldest = cards.map { ($0.bookingDate, $0.sequence) }.min { $0 < $1 }!
        let others = view.snapshot.transactions.filter {
            ($0.accountID == DemoAccountID.visa || $0.accountID == DemoAccountID.paypal) && !new.contains($0.reference)
        }
        #expect(others.allSatisfy { $0.bookingDate <= oldest.0 })
    }

    @Test func rulesBudgetsAndFixedCosts() {
        #expect(view.profile.rules.count == 34)
        let budgets = Dictionary(uniqueKeysWithValues: view.profile.budgets.map { ($0.category, $0.monthlyLimit) })
        #expect(budgets == ["Groceries": 42_000, "Leisure & eating out": 15_000, "Mobility": 22_000,
                            "Health & drugstore": 6_000, "Other": 15_000])
        let fixed = view.profile.fixedCosts
        #expect(fixed.map(\.amount) == [112_000, 8_600, 11_300])
        let contracts = fixed[2]
        #expect(contracts.items.map(\.amount) == [1_836, 3_870, 4_495, 1_099])
        #expect(contracts.items.reduce(0) { $0 + $1.amount } == contracts.amount)
    }

    @Test func ledgerTodayAndProfileLogins() {
        #expect(view.profile.ledgerToday == day(2026, 11, 12))
        #expect(DemoDataset.today == day(2026, 11, 12))
        #expect(view.profile.logins.map(\.bankName) == ["Sparkasse KölnBonn", "DKB", "ING", "PayPal"])
        let owned = view.profile.logins.flatMap(\.accountIDs).sorted()
        #expect(owned == DemoAccountID.all.sorted())
        for account in view.snapshot.accounts {
            #expect(view.profile.logins.first { $0.id == account.loginKey }?.accountIDs.contains(account.id) == true)
        }
    }

    @Test func referencesAreUniqueAndSequencesConsistent() {
        let refs = view.snapshot.transactions.map(\.reference)
        #expect(Set(refs).count == refs.count)
        for a in view.snapshot.accounts {
            var seen: [LocalDate: Int] = [:]
            for t in view.transactions(a.id) {
                seen[t.bookingDate, default: 0] += 1
                #expect(t.sequence == seen[t.bookingDate])
            }
        }
        #expect(Set(view.profile.ownTransferReferences).isSubset(of: Set(refs)))
        #expect(Set(view.profile.categoryByReference.keys).isSubset(of: Set(refs)))
    }

    @Test func ownTransferPairsCancelOut() {
        // Settlements and top-ups appear on both accounts with opposite signs.
        let visa = view.transactions(DemoAccountID.visa).filter { view.isOwnTransfer($0) }.reduce(0) { $0 + $1.amount }
        let giroStatement = view.transactions(DemoAccountID.giro).filter { $0.shortName == "DKB Visa statement" }.reduce(0) { $0 + $1.amount }
        #expect(visa + giroStatement == 0)
        let paypalTopUps = view.transactions(DemoAccountID.paypal).filter { $0.kind == .transfer && $0.amount > 0 && view.isOwnTransfer($0) }
            .reduce(0) { $0 + $1.amount }
        let giroTopUps = view.transactions(DemoAccountID.giro).filter { $0.shortName == "PayPal Aufladung" }.reduce(0) { $0 - $1.amount }
        #expect(paypalTopUps == giroTopUps)
    }

    @Test func jonasWeberHasOneIBAN() {
        var ibans = Set<String>()
        for t in view.snapshot.transactions where t.counterpartyName == "Jonas Weber" { if let i = t.counterpartyIBAN { ibans.insert(i) } }
        for o in view.snapshot.standingOrders where o.recipient == "Jonas Weber" { ibans.insert(o.iban) }
        #expect(ibans.count == 1)
        #expect(ibans.first == DemoIBANs.jonas)
        #expect(IBAN.formatted(DemoIBANs.jonas).hasPrefix("DE"))
    }

    @Test func ibansKeepBankCodeAndAccountNumber() {
        // Designed IBANs: bank code and account number survive, check digits are recomputed.
        #expect(DemoIBANs.giro.dropFirst(4) == "370501981934082751")
        #expect(DemoIBANs.tagesgeld.dropFirst(4) == "370501981934082778")
        #expect(DemoIBANs.depot.dropFirst(4) == "500105175419283746")
        #expect(DemoIBANs.miete.dropFirst(4) == "370501980012345678")
        #expect(DemoIBANs.mia.dropFirst(4) == "370501981022447130")
        #expect(DemoIBANs.fitness.dropFirst(4) == "380400070123456700")
        for iban in [DemoIBANs.giro, DemoIBANs.tagesgeld, DemoIBANs.depot, DemoIBANs.miete, DemoIBANs.mia, DemoIBANs.fitness,
                     DemoIBANs.jonas] {
            #expect(IBAN.isValid(iban))
        }
    }

    @Test func everyIBANInTheEncodedDataSetIsValid() throws {
        let text = String(decoding: DemoDataset.encode(demoBank), as: UTF8.self)
        let regex = try Regex("[A-Z]{2}[0-9]{2}(?: ?[0-9A-Z]{4}){3,7}(?: ?[0-9A-Z]{1,3})?")
        var found = 0
        for match in text.matches(of: regex) {
            let candidate = String(match.output[0].substring ?? "")
            // Only strings that look like IBANs of the countries used (DE, LU).
            guard candidate.hasPrefix("DE") || candidate.hasPrefix("LU") else { continue }
            guard candidate.filter({ $0 != " " }).count >= 15 else { continue }
            // Creditor ids (…ZZZ…) and booking references are not IBANs.
            if candidate.contains("ZZZ") { continue }
            found += 1
            #expect(IBAN.isValid(candidate), "\(candidate)")
        }
        #expect(found > 20)
        for a in demoBank.snapshot.accounts { if let iban = a.iban { #expect(IBAN.isValid(iban)) } }
        for t in demoBank.snapshot.transactions { if let iban = t.counterpartyIBAN { #expect(IBAN.isValid(iban), "\(t.reference)") } }
        for o in demoBank.snapshot.standingOrders { #expect(IBAN.isValid(o.iban), "\(o.id)") }
    }

    @Test func insightsExistAndCiteExistingTransactions() throws {
        let refs = Set(demoBank.snapshot.transactions.map(\.reference))
        let kinds = Dictionary(grouping: demoBank.profile.insights, by: \.kind)
        #expect(kinds[.attention]?.count == 3)
        #expect(kinds[.suggestion]?.count == 6)
        #expect(kinds[.ask]?.count == 1)
        #expect(kinds[.review]?.count == 1)
        #expect(kinds[.tax]?.count == 1)
        #expect((kinds[.notice]?.count ?? 0) >= 3)
        for insight in demoBank.profile.insights {
            if let ref = insight.transactionReference { #expect(refs.contains(ref), "\(insight.id)") }
            // Payload is valid JSON.
            _ = try JSONSerialization.jsonObject(with: Data(insight.payload.utf8))
            #expect(!insight.payload.contains(".."), "\(insight.id) has a doubled full stop")
        }
        // Cited references inside notices.
        for insight in kinds[.notice] ?? [] {
            let notice = try insight.payload(as: NoticePayload.self)
            for ref in notice.transactionReferences + notice.sources.flatMap(\.transactionReferences) { #expect(refs.contains(ref)) }
        }
        let ask = try #require(kinds[.ask]?.first).payload(as: AskPayload.self)
        for ref in ask.groups.flatMap(\.transactionReferences) + ask.transactionReferences { #expect(refs.contains(ref)) }
        let tax = try #require(kinds[.tax]?.first).payload(as: TaxPayload.self)
        let items = tax.groups.flatMap(\.items)
        #expect(items.allSatisfy { $0.eligibleAmount == nil })
        #expect(tax.groups.reduce(0) { $0 + $1.total } == tax.total)
        #expect(tax.groups.allSatisfy { group in group.total == group.items.reduce(0) { $0 - $1.amount } })
        #expect(items.first { $0.payee == "Schreinerei Kaiser GmbH" }?.why == "Labour on the invoice counts as a household service")
    }

    @Test func suggestedCategories() throws {
        let expected: [String: String] = [
            "Amazon EU S.a.r.l.": "Other", "PayPal *Etsy": "Other", "Apotheke am Neumarkt": "Health & drugstore",
            "SumUp *Kiosk Ehrenfeld": "Leisure & eating out", "Bargeldauszahlung Sparkasse": "Other",
            "Überweisung Jonas Weber": "Income",
        ]
        let byRef = Dictionary(uniqueKeysWithValues: demoBank.snapshot.transactions.map { ($0.reference, $0) })
        var seen: [String: String] = [:]
        for insight in demoBank.profile.insights where insight.kind == .suggestion {
            let payload = try insight.payload(as: SuggestionPayload.self)
            let reference = try #require(insight.transactionReference)
            let row = try #require(byRef[reference])
            seen[row.shortName] = payload.suggestedCategory
            #expect(view.category(row) == nil)
        }
        #expect(seen == expected)
    }

    @Test func netWorthAndStatementsInsideDepot() {
        // The depot account has no transactions, so its balance equals the holdings value.
        #expect(view.transactions(DemoAccountID.depot).isEmpty)
    }
}
