import Foundation
import GRDB
import IMMLedger

/// Why an import was rejected. The data set is validated before anything is half written: the whole
/// import runs in one write transaction, so an error leaves the ledger untouched.
public enum LedgerImportError: Error, Equatable, Sendable {
    case unknownAccount(String)
    case unknownCategory(String)
    case unknownSecurity(String)
    case unknownTransaction(String)
}

/// Writes bank data into the ledger.
///
/// Every write to a synced table goes through `LedgerWriter` (one op per changed field), so sync sees imports like
/// any other edit. Bank logins and insights are device-local and written directly.
///
/// Identity rules (what makes importing idempotent)
/// - Accounts get `StableID.accountID` from bank code and IBAN (or card/depot number); `account.connector_account_id`
///   remembers the connector's own id (`sparkasse-giro`) for later fetches. Bookings get `BookingIdentity` ids from their
///   content; securities, holdings, depot values, budgets and the savings plan get ids derived from what identifies them.
///   Standing orders, contracts and insights keep the data set's string id (`demo-so-…`). Bank logins keep theirs.
/// - Categories match on name, rules on (pattern, category).
/// - Bank-immutable rows (bookings, securities, depot values) are inserted once; an existing id, tombstone included,
///   is never touched again except for the bank-latest attributes of a booking. User-edit columns (category, note,
///   flags) are written only when a row is created, so what the user changed survives every sync.
/// - Bank-latest rows (account balances and status, standing orders, holdings, savings plan) are brought up to the
///   bank's values field by field; unchanged fields write nothing.
/// - Pending bookings (`isPending`) replace the account's device-local `pending_transaction` set and never become ledger rows.
///
/// `booking_seq` rule: within one account and booking day the rows are ordered by the data set's
/// `sequence` (ties broken by position in the snapshot) and numbered 1, 2, 3 … ; a higher number is
/// booked later. The ledger orders same-day rows by booked time first, then by this number.
public enum LedgerImporter {
    /// Imports `snapshot` in one write transaction.
    ///
    /// With a `profile` (the demo data set) the importer also creates the bank logins, categories,
    /// per-transaction categories, own-transfer and new flags, rules, budgets, contracts, the savings
    /// plan and the insights, and sets `demo_only = 1` and `ledger_today` to the profile's day.
    /// Without a profile only bank data is written (accounts, transactions, standing orders, holdings,
    /// depot history); transactions are uncategorised and not flagged new.
    ///
    /// Every account gets `last_synced_at` = now and sync status `ok`.
    public static func importSnapshot(_ snapshot: BankSnapshot, profile: DemoProfile?, into store: LedgerStore) throws {
        let now = Date()
        try store.database.write { db in
            try importAll(snapshot, profile: profile, writer: store.writer, db: db, now: now)
        }
    }

    /// Books the result of an approved payment: a transfer becomes a ledger transaction and moves the
    /// account balance by its amount; a scheduled payment becomes a standing order. Booking the same
    /// transaction (same account and reference) twice changes nothing the second time. `day` overrides the
    /// booking and value date (the app books "today" by the ledger's clock).
    public static func book(_ result: PaymentResult, into store: LedgerStore, on day: LocalDate? = nil) throws {
        let now = Date()
        try store.database.write { db in
            switch result {
            case .booked(let transaction):
                try bookTransaction(transaction, writer: store.writer, db: db, now: now, on: day)
            case .scheduled(let order):
                try bookStandingOrder(order, writer: store.writer, db: db, now: now)
            }
        }
    }

    // MARK: Import

    private static func importAll(_ snapshot: BankSnapshot, profile: DemoProfile?, writer: LedgerWriter, db: Database, now: Date) throws {
        try importLogins(profile, db: db, now: now)
        let categoryIDs = try importCategories(profile, writer: writer, db: db, now: now)
        let accountIDs = try importAccounts(snapshot, profile: profile, writer: writer, db: db, now: now)
        let securityIDs = try importSecurities(snapshot.holdings, profile: profile, writer: writer, db: db, now: now)
        let transactionIDs = try importTransactions(
            snapshot, profile: profile, accountIDs: accountIDs, categoryIDs: categoryIDs, writer: writer, db: db, now: now)
        try importStandingOrders(snapshot.standingOrders, accountIDs: accountIDs, writer: writer, db: db, now: now)
        try importHoldings(snapshot.holdings, accountIDs: accountIDs, securityIDs: securityIDs, writer: writer, db: db, now: now)
        try importDepotHistory(snapshot.depotValueHistory, accountIDs: accountIDs, writer: writer, db: db, now: now)
        guard let profile else { return }
        try importRules(profile.rules, categoryIDs: categoryIDs, writer: writer, db: db, now: now)
        try importBudgets(profile.budgets, categoryIDs: categoryIDs, writer: writer, db: db, now: now)
        try importContracts(profile.contracts, accountIDs: accountIDs, categoryIDs: categoryIDs, writer: writer, db: db, now: now)
        try importSavingsPlan(profile.savingsPlan, accountIDs: accountIDs, securityIDs: securityIDs, writer: writer, db: db, now: now)
        try importInsights(profile.insights, transactionIDs: transactionIDs, db: db, now: now)
        try LedgerStore.setSetting(.demoOnly, "1", in: db)
        try LedgerStore.setSetting(.ledgerToday, profile.ledgerToday.iso, in: db)
    }

    private static func importLogins(_ profile: DemoProfile?, db: Database, now: Date) throws {
        guard let profile else { return }
        for login in profile.logins {
            var record = try BankLoginRecord.fetchOne(db, key: login.id)
                ?? BankLoginRecord(id: login.id, connectorId: login.connectorID, bankName: login.bankName,
                                   bankCode: login.bankCode, loginName: login.loginName, tanMethod: login.tanMethod,
                                   createdAt: now, updatedAt: now)
            record.connectorId = login.connectorID
            record.bankName = login.bankName
            record.bankCode = login.bankCode
            record.loginName = login.loginName
            record.tanMethod = login.tanMethod
            record.updatedAt = now
            record.deletedAt = nil
            try record.save(db)
        }
    }

    /// Returns category id by category name. New categories get fractional order keys in the profile's order;
    /// existing ones are the user's and stay as they are.
    private static func importCategories(_ profile: DemoProfile?, writer: LedgerWriter, db: Database, now: Date) throws -> [String: String] {
        var ids: [String: String] = [:]
        guard let profile else { return ids }
        var existing: [String: CategoryRecord] = [:]
        for record in try CategoryRecord.fetchAll(db) where existing[record.name] == nil {
            existing[record.name] = record
        }
        let ordered = profile.categories.sorted { $0.sortOrder < $1.sortOrder }
        let keys = FractionalIndex.keys(count: ordered.count)
        for (category, key) in zip(ordered, keys) {
            if let record = existing[category.name] {
                ids[category.name] = record.id
                continue
            }
            let record = CategoryRecord(
                name: category.name, colorToken: category.colorToken, kind: CategoryKind(rawValue: category.kind.rawValue) ?? .expense,
                sortOrder: key, createdAt: now, updatedAt: now)
            try writer.insert(record, in: db)
            ids[category.name] = record.id
        }
        return ids
    }

    /// Prefix of the references the demo connector gives to payments booked through `book(_:into:)`.
    /// The static demo snapshot never contains them, so a later sync adds them back to the bank's balance.
    static let locallyBookedPrefix = "DEMO-PAY-"

    /// The ledger id of an account as the data transfer objects name it: the connector's id, or an id the ledger already uses.
    private static func resolve(_ id: String, in accountIDs: [String: String], db: Database) throws -> String {
        if let ledgerID = accountIDs[id] { return ledgerID }
        if let row = try String.fetchOne(
            db, sql: "SELECT id FROM account WHERE id = ? OR connector_account_id = ? ORDER BY (id = ?) DESC LIMIT 1", arguments: [id, id, id]) {
            return row
        }
        throw LedgerImportError.unknownAccount(id)
    }

    private static func bankCode(forLogin key: String, profile: DemoProfile?, db: Database) throws -> String {
        if let login = try String.fetchOne(db, sql: "SELECT bank_code FROM bank_login WHERE id = ?", arguments: [key]) { return login }
        return profile?.logins.first { $0.id == key }?.bankCode ?? ""
    }

    /// Imports accounts and returns the ledger id by connector account id.
    private static func importAccounts(
        _ snapshot: BankSnapshot, profile: DemoProfile?, writer: LedgerWriter, db: Database, now: Date
    ) throws -> [String: String] {
        let snapshotReferences = Set(snapshot.transactions.map(\.reference))
        var ids: [String: String] = [:]
        for account in snapshot.accounts {
            let kind = AccountKind(rawValue: account.kind.rawValue) ?? .giro
            let number = account.iban ?? account.number ?? account.id
            let derived = BookingIdentity.accountID(
                bankCode: try bankCode(forLogin: account.loginKey, profile: profile, db: db), accountNumber: number)
            let ledgerID = try String.fetchOne(
                db, sql: "SELECT id FROM account WHERE connector_account_id = ? OR id = ? ORDER BY (id = ?) DESC LIMIT 1",
                arguments: [account.id, derived, derived]) ?? derived
            ids[account.id] = ledgerID

            let locallyBooked = try locallyBookedTotal(ledgerID, excluding: snapshotReferences, db: db)
            let record = AccountRecord(
                id: ledgerID, kind: kind, name: account.name, bankName: account.bankName, iban: account.iban ?? account.number,
                subtitle: account.subtitle, balance: account.balance + locallyBooked, currency: account.currency,
                overdraftLimit: account.overdraftLimit ?? 0, statementNote: account.statementNote, sortOrder: account.sortOrder,
                lastSyncedAt: now, syncStatus: .ok, syncStatusText: nil, createdAt: now, updatedAt: now)
            // Name, subtitle and order are display fields the user owns; the bank refreshes the rest.
            try writer.upsert(record, refreshing: [
                "kind", "bank_name", "iban", "balance", "currency", "overdraft_limit", "statement_note", "last_synced_at",
                "sync_status", "sync_status_text",
            ], in: db)

            // Device-local links (not synced).
            let loginExists = try Int.fetchOne(db, sql: "SELECT 1 FROM bank_login WHERE id = ?", arguments: [account.loginKey]) != nil
            try db.execute(
                sql: "UPDATE account SET connector_account_id = ?, bank_login_id = COALESCE(?, bank_login_id) WHERE id = ?",
                arguments: [account.id, loginExists ? account.loginKey : nil, ledgerID])
        }
        return ids
    }

    private static func locallyBookedTotal(_ accountID: String, excluding snapshotReferences: Set<String>, db: Database) throws -> Int {
        let rows = try Row.fetchAll(
            db, sql: "SELECT bank_ref, amount FROM ledger_transaction WHERE account_id = ? AND deleted_at IS NULL AND bank_ref LIKE ?",
            arguments: [accountID, locallyBookedPrefix + "%"])
        var total = 0
        for row in rows {
            let reference: String = row["bank_ref"]
            if snapshotReferences.contains(reference) { continue }
            let amount: Int = row["amount"]
            total += amount
        }
        return total
    }

    /// Estimated regional weights in permille as JSON, e.g. `{"Europe":150,"North America":620,…}`.
    /// Stored in `security.region`; `nil` when the profile has no weights for the fund.
    static func regionJSON(isin: String, profile: DemoProfile?) -> String? {
        guard let weights = profile?.fundRegionWeights.first(where: { $0.isin == isin }) else { return nil }
        let map: [String: Int] = [
            "North America": weights.northAmerica,
            "Europe": weights.europe,
            "Emerging markets": weights.emergingMarkets,
            "Japan & Pacific": weights.japanPacific,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(map) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns security id by ISIN. Securities are bank-immutable: written once, then left alone.
    private static func importSecurities(
        _ holdings: [BankHolding], profile: DemoProfile?, writer: LedgerWriter, db: Database, now: Date
    ) throws -> [String: String] {
        var ids: [String: String] = [:]
        for holding in holdings {
            guard let security = holding.security, ids[security.isin] == nil else { continue }
            let id = StableID.securityID(isin: security.isin)
            let kind = IMMLedger.SecurityKind(rawValue: security.kind.rawValue) ?? .etf
            try writer.insert(
                SecurityRecord(id: id, name: security.name, isin: security.isin, wkn: security.wkn, kind: kind,
                               region: regionJSON(isin: security.isin, profile: profile), createdAt: now, updatedAt: now),
                in: db)
            ids[security.isin] = id
        }
        // Securities known from earlier imports stay addressable by ISIN (savings plan items).
        for row in try Row.fetchAll(db, sql: "SELECT isin, id FROM security") {
            let isin: String = row["isin"]
            if ids[isin] == nil { ids[isin] = row["id"] }
        }
        return ids
    }

    /// Writes the account's bookings and pending entries; returns the ledger id by bank reference.
    private static func importTransactions(
        _ snapshot: BankSnapshot, profile: DemoProfile?, accountIDs: [String: String], categoryIDs: [String: String],
        writer: LedgerWriter, db: Database, now: Date
    ) throws -> [String: String] {
        let booked = snapshot.transactions.filter { !$0.isPending }
        let pending = snapshot.transactions.filter(\.isPending)

        // Resolve every account first: an unknown one fails the whole import before anything is half written.
        var accountOf = [String](repeating: "", count: booked.count)
        var indicesByAccount: [String: [Int]] = [:]
        var accountOrder: [String] = []
        for (index, transaction) in booked.enumerated() {
            let account = try resolve(transaction.accountID, in: accountIDs, db: db)
            accountOf[index] = account
            if indicesByAccount[account] == nil { accountOrder.append(account) }
            indicesByAccount[account, default: []].append(index)
        }

        // booking_seq: rank within (account, booking day) by the data set's sequence, then snapshot position.
        struct DayKey: Hashable {
            let account: String
            let date: LocalDate
        }
        var groups: [DayKey: [(index: Int, sequence: Int)]] = [:]
        for (index, transaction) in booked.enumerated() {
            groups[DayKey(account: accountOf[index], date: transaction.bookingDate), default: []].append((index, transaction.sequence))
        }
        var seqByIndex = [Int](repeating: 0, count: booked.count)
        for (_, members) in groups {
            let ordered = members.sorted { ($0.sequence, $0.index) < ($1.sequence, $1.index) }
            for (rank, member) in ordered.enumerated() { seqByIndex[member.index] = rank + 1 }
        }

        let ownTransfers = Set(profile?.ownTransferReferences ?? [])
        let newRows = Set(profile?.newReferences ?? [])
        var idByReference: [String: String] = [:]

        for account in accountOrder {
            let indices = indicesByAccount[account] ?? []
            let ids = BookingIdentity.bookingIDs(for: indices.map { booked[$0] }, accountID: account)
            for (index, id) in zip(indices, ids) {
                let transaction = booked[index]
                idByReference[transaction.reference] = id
                var categoryID: String?
                if let name = profile?.categoryByReference[transaction.reference] {
                    guard let found = categoryIDs[name] else { throw LedgerImportError.unknownCategory(name) }
                    categoryID = found
                }
                let record = TransactionRecord(
                    id: id, accountId: account, bookingDate: transaction.bookingDate, valueDate: transaction.valueDate,
                    bookedTime: transaction.bookedTime, bookingSeq: seqByIndex[index], amount: transaction.amount,
                    currency: transaction.currency, counterpartyName: transaction.counterpartyName, shortName: transaction.shortName,
                    counterpartyIban: transaction.counterpartyIBAN, bookingText: transaction.bookingText, purpose: transaction.purpose,
                    creditorId: transaction.creditorID, kind: TransactionKind(rawValue: transaction.kind.rawValue) ?? .transfer,
                    categoryId: categoryID, isOwnTransfer: ownTransfers.contains(transaction.reference),
                    isNew: newRows.contains(transaction.reference), bankRefKind: "bank", bankRef: transaction.reference,
                    createdAt: now, updatedAt: now)
                // The identity columns never change; the bank's other attributes follow the latest fetch.
                try writer.upsert(record, refreshing: [
                    "value_date", "booked_time", "booking_seq", "counterparty_name", "short_name", "counterparty_iban",
                    "booking_text", "purpose", "creditor_id", "kind", "bank_ref",
                ], in: db)
            }
        }

        try replacePending(pending, snapshot: snapshot, accountIDs: accountIDs, db: db, now: now)
        return idByReference
    }

    /// Replaces the device-local pending set of every account in the snapshot: an empty answer empties the set.
    private static func replacePending(
        _ pending: [BankTransaction], snapshot: BankSnapshot, accountIDs: [String: String], db: Database, now: Date
    ) throws {
        for account in snapshot.accounts {
            guard let ledgerID = accountIDs[account.id] else { continue }
            try db.execute(sql: "DELETE FROM pending_transaction WHERE account_id = ?", arguments: [ledgerID])
        }
        var positions: [String: Int] = [:]
        for transaction in pending {
            let account = try resolve(transaction.accountID, in: accountIDs, db: db)
            let position = positions[account, default: 0]
            positions[account] = position + 1
            try PendingTransactionRecord(
                accountId: account, position: position, bookingDate: transaction.bookingDate, valueDate: transaction.valueDate,
                amount: transaction.amount, currency: transaction.currency, counterpartyName: transaction.counterpartyName,
                counterpartyIban: transaction.counterpartyIBAN, bookingText: transaction.bookingText, purpose: transaction.purpose,
                kind: TransactionKind(rawValue: transaction.kind.rawValue) ?? .transfer, fetchedAt: now
            ).insert(db)
        }
    }

    private static func importStandingOrders(
        _ orders: [BankStandingOrder], accountIDs: [String: String], writer: LedgerWriter, db: Database, now: Date
    ) throws {
        for order in orders {
            try upsertStandingOrder(order, account: try resolve(order.accountID, in: accountIDs, db: db), writer: writer, db: db, now: now)
        }
    }

    private static func upsertStandingOrder(
        _ order: BankStandingOrder, account: String, writer: LedgerWriter, db: Database, now: Date
    ) throws {
        let record = StandingOrderRecord(
            id: order.id, accountId: account, recipient: order.recipient, iban: order.iban, purpose: order.purpose,
            amount: order.amount, currency: order.currency,
            rhythm: IMMLedger.StandingOrderRhythm(rawValue: order.rhythm.rawValue) ?? .monthly,
            dayOfMonth: order.dayOfMonth, nextExecution: order.nextExecution,
            status: IMMLedger.StandingOrderStatus(rawValue: order.status.rawValue) ?? .active, createdAt: now, updatedAt: now)
        try writer.upsert(record, refreshing: [
            "recipient", "iban", "purpose", "amount", "currency", "rhythm", "day_of_month", "next_execution", "status",
        ], in: db)
    }

    private static func importHoldings(
        _ holdings: [BankHolding], accountIDs: [String: String], securityIDs: [String: String], writer: LedgerWriter,
        db: Database, now: Date
    ) throws {
        for (index, holding) in holdings.enumerated() {
            let account = try resolve(holding.accountID, in: accountIDs, db: db)
            let isin = holding.security?.isin
            var securityID: String?
            if let isin {
                guard let id = securityIDs[isin] else { throw LedgerImportError.unknownSecurity(isin) }
                securityID = id
            }
            let record = HoldingRecord(
                id: StableID.holdingID(accountID: account, isin: isin), accountId: account, securityId: securityID,
                name: holding.security?.name ?? "Verrechnungskonto, uninvested", isin: isin,
                quantityMicro: Int((holding.quantity * 1_000_000).rounded()), price: holding.price, priceAt: holding.priceTime,
                costBasis: holding.costBasis, sortOrder: index, createdAt: now, updatedAt: now)
            try writer.upsert(record, refreshing: ["name", "quantity_micro", "price", "price_at", "cost_basis", "currency", "sort_order"], in: db)
        }
    }

    private static func importDepotHistory(
        _ points: [BankDepotValuePoint], accountIDs: [String: String], writer: LedgerWriter, db: Database, now: Date
    ) throws {
        for point in points {
            let account = try resolve(point.accountID, in: accountIDs, db: db)
            try writer.insert(
                DepotValueRecord(
                    id: StableID.depotValueID(accountID: account, date: point.date), accountId: account, date: point.date,
                    value: point.value, createdAt: now, updatedAt: now),
                in: db)
        }
    }

    private static func importRules(
        _ rules: [DemoRule], categoryIDs: [String: String], writer: LedgerWriter, db: Database, now: Date
    ) throws {
        var existing = Set<String>()
        for record in try RuleRecord.fetchAll(db) { existing.insert(record.pattern + "\u{0}" + record.categoryId) }
        for rule in rules {
            guard let categoryID = categoryIDs[rule.category] else { throw LedgerImportError.unknownCategory(rule.category) }
            guard existing.insert(rule.pattern + "\u{0}" + categoryID).inserted else { continue }
            try writer.insert(
                RuleRecord(pattern: rule.pattern, categoryId: categoryID, origin: rule.origin == "manual" ? .manual : .suggested,
                           enabled: rule.enabled, createdAt: now, updatedAt: now),
                in: db)
        }
    }

    private static func importBudgets(
        _ budgets: [DemoBudget], categoryIDs: [String: String], writer: LedgerWriter, db: Database, now: Date
    ) throws {
        for budget in budgets {
            guard let categoryID = categoryIDs[budget.category] else { throw LedgerImportError.unknownCategory(budget.category) }
            try writer.insert(
                BudgetRecord(id: StableID.budgetID(categoryID: categoryID), categoryId: categoryID, monthlyLimit: budget.monthlyLimit,
                             createdAt: now, updatedAt: now),
                in: db)
        }
    }

    private static func importContracts(
        _ contracts: [DemoContract], accountIDs: [String: String], categoryIDs: [String: String], writer: LedgerWriter,
        db: Database, now: Date
    ) throws {
        for (index, contract) in contracts.enumerated() {
            let account = try resolve(contract.accountID, in: accountIDs, db: db)
            guard let categoryID = categoryIDs[contract.category] else { throw LedgerImportError.unknownCategory(contract.category) }
            try writer.insert(
                ContractRecord(
                    id: contract.id, provider: contract.provider, accountId: account, groupName: contract.groupName,
                    categoryId: categoryID, rhythm: ContractRhythm(rawValue: contract.rhythm) ?? .monthly,
                    monthlyAmount: contract.monthlyAmount, nextDebit: contract.nextDebit, noticeText: contract.noticeText,
                    noticeDeadline: contract.noticeDeadline, renewalDate: contract.renewalDate,
                    priceChangeAmount: contract.priceChangeAmount, priceChangeStart: contract.priceChangeStart,
                    kind: ContractKind(rawValue: contract.kind.rawValue) ?? .contract, sortOrder: index, createdAt: now, updatedAt: now),
                in: db)
        }
    }

    private static func importSavingsPlan(
        _ plan: DemoSavingsPlan, accountIDs: [String: String], securityIDs: [String: String], writer: LedgerWriter,
        db: Database, now: Date
    ) throws {
        let depot = try resolve(plan.depotAccountID, in: accountIDs, db: db)
        let source = try resolve(plan.sourceAccountID, in: accountIDs, db: db)
        let planID = StableID.savingsPlanID(accountID: depot)
        try writer.upsert(
            SavingsPlanRecord(
                id: planID, accountId: depot, sourceAccountId: source, amount: plan.monthlyAmount, dayOfMonth: plan.dayOfMonth,
                nextExecution: plan.nextExecution, createdAt: now, updatedAt: now),
            refreshing: ["source_account_id", "amount", "currency", "day_of_month", "next_execution"], in: db)

        for (index, item) in plan.items.enumerated() {
            guard let securityID = securityIDs[item.isin] else { throw LedgerImportError.unknownSecurity(item.isin) }
            try writer.upsert(
                SavingsPlanItemRecord(
                    id: StableID.savingsPlanItemID(planID: planID, securityID: securityID), planId: planID, securityId: securityID,
                    amount: item.amount, sortOrder: index, createdAt: now, updatedAt: now),
                refreshing: ["amount", "sort_order"], in: db)
        }
    }

    /// Insights are device-local: written directly, keyed by the data set's id.
    private static func importInsights(_ insights: [DemoInsight], transactionIDs: [String: String], db: Database, now: Date) throws {
        for insight in insights {
            var transactionID: String?
            if let reference = insight.transactionReference {
                guard let id = transactionIDs[reference] else { throw LedgerImportError.unknownTransaction(reference) }
                transactionID = id
            }
            let kind = InsightKind(rawValue: insight.kind.rawValue) ?? .notice
            var record = try InsightRecord.fetchOne(db, key: insight.id)
                ?? InsightRecord(id: insight.id, kind: kind, payload: insight.payload, createdAt: now, updatedAt: now)
            record.kind = kind
            record.transactionId = transactionID
            record.payload = insight.payload
            record.sortOrder = insight.sortOrder
            record.updatedAt = now
            record.deletedAt = nil
            try record.save(db)
        }
    }

    // MARK: Booking

    private static func bookTransaction(
        _ transaction: BankTransaction, writer: LedgerWriter, db: Database, now: Date, on day: LocalDate?
    ) throws {
        let accountID = try resolve(transaction.accountID, in: [:], db: db)
        guard let account = try AccountRecord.fetchOne(db, key: accountID) else { throw LedgerImportError.unknownAccount(transaction.accountID) }
        let duplicate = try Int.fetchOne(
            db, sql: "SELECT 1 FROM ledger_transaction WHERE account_id = ? AND bank_ref = ?",
            arguments: [accountID, transaction.reference]) != nil
        if duplicate { return }

        let bookingDay = day ?? transaction.bookingDate
        let counterparty = StableID.counterpartyKey(iban: transaction.counterpartyIBAN, name: transaction.counterpartyName)
        let purpose = StableID.purposeKey(transaction.purpose)
        // The same payment twice on one day is two bookings: take the first free occurrence index.
        var occurrence = 0
        var id: String
        repeat {
            id = StableID.bookingID(
                accountID: accountID, day: bookingDay, amount: transaction.amount, currency: transaction.currency,
                counterpartyKey: counterparty, purposeKey: purpose, occurrence: occurrence)
            occurrence += 1
        } while try Int.fetchOne(db, sql: "SELECT 1 FROM ledger_transaction WHERE id = ?", arguments: [id]) != nil

        // A booked payment is the newest row of its day: one above the highest number already used.
        let highest = try Int.fetchOne(
            db, sql: "SELECT MAX(booking_seq) FROM ledger_transaction WHERE account_id = ? AND booking_date = ?",
            arguments: [accountID, bookingDay.iso]) ?? 0
        try writer.insert(
            TransactionRecord(
                id: id, accountId: accountID, bookingDate: bookingDay, valueDate: day ?? transaction.valueDate,
                bookedTime: transaction.bookedTime, bookingSeq: highest + 1, amount: transaction.amount,
                currency: transaction.currency, counterpartyName: transaction.counterpartyName, shortName: transaction.shortName,
                counterpartyIban: transaction.counterpartyIBAN, bookingText: transaction.bookingText, purpose: transaction.purpose,
                creditorId: transaction.creditorID, kind: TransactionKind(rawValue: transaction.kind.rawValue) ?? .transfer,
                bankRefKind: "bank", bankRef: transaction.reference, createdAt: now, updatedAt: now),
            in: db)
        try writer.set(table: "account", rowID: accountID, column: "balance", to: SyncValue(account.balance + transaction.amount), in: db)
    }

    private static func bookStandingOrder(_ order: BankStandingOrder, writer: LedgerWriter, db: Database, now: Date) throws {
        let account = try resolve(order.accountID, in: [:], db: db)
        try upsertStandingOrder(order, account: account, writer: writer, db: db, now: now)
    }
}
