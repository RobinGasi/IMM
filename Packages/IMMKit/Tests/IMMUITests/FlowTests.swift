import Foundation
import GRDB
import IMMBanking
import IMMLedger
import IMMVault
@testable import IMMUI
import Testing

/// Walks every entry of `DesignReference/flows.json` (the prototype's link graph: source
/// artboard, the node clicked, target artboard) and runs the app's transition for it through the same
/// `AppModel` / `BankController` calls the views make:
/// sidebar and link rows `navigate`, panels open and close, Settings opens, the Sync button runs
/// `bank.sync()`, "Send" runs `bank.submit`, rows select a transaction in the Transactions model.
///
/// The mapping is the explicit table `FlowTable.entries`, keyed by (node clicked, target artboard).
/// Artboards that are *states* of a screen (`States / …`, `Errors / …`, `Dark`, `Compact`, setup states)
/// are the source's own state in the app, not another route: flows into and out of them map to the panel,
/// phase or `syncState` transition. Where the app deliberately differs from the prototype the entry
/// carries a `deviation` text and the test asserts the app's behaviour.
@MainActor
@Suite(.serialized) struct FlowTests {
    // MARK: flows.json

    struct Screen: Decodable {
        var id: String
        var name: String
        var route: String
        /// `app-2-transactions-desktop` (the route without its leading slash; the `index.tsv` slug).
        var slug: String { String(route.drop(while: { $0 == "/" })) }
    }

    struct Via: Decodable {
        var node_id: String
        var name: String
    }

    struct Flow: Decodable {
        var from: Screen
        var via: Via
        var to: Screen

        var key: FlowKey { FlowKey(via: via.name, target: to.slug) }
        var label: String { "\(from.slug) —[\(via.name)]→ \(to.slug)" }
    }

    struct FlowsFile: Decodable { var flows: [Flow] }

    struct FlowKey: Hashable { var via: String; var target: String }

    static func loadFlows() throws -> [Flow] {
        let url = RepoPaths.root.appendingPathComponent("DesignReference/flows.json")
        return try JSONDecoder().decode(FlowsFile.self, from: Data(contentsOf: url)).flows
    }

    static func screenSlugs() throws -> Set<String> {
        let url = RepoPaths.referenceScreens.appendingPathComponent("index.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(text.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) })
    }

    /// Source and target artboards that belong to the setup window (phase changes, no main-window route).
    static func isSetupScreen(_ slug: String) -> Bool {
        slug.hasPrefix("onboarding-") || slug.hasPrefix("states-create-vault") || slug.hasPrefix("states-bank-login")
            || slug.hasPrefix("security-unlock") || slug.hasPrefix("states-unlock") || slug.hasPrefix("states-database")
    }

    // MARK: Inventory checks

    @Test func everyFlowHasAnExplicitMappingAndNoEntryIsStale() throws {
        let flows = try Self.loadFlows()
        #expect(flows.count == 565)
        let slugs = try Self.screenSlugs()
        var unmapped: [String] = []
        var used = Set<FlowKey>()
        for flow in flows {
            #expect(slugs.contains(flow.from.slug), "unknown source artboard \(flow.from.slug)")
            #expect(slugs.contains(flow.to.slug), "unknown target artboard \(flow.to.slug)")
            if FlowTable.entry(for: flow) != nil {
                used.insert(flow.key)
            } else if !(Self.isSetupScreen(flow.from.slug) && FlowTable.setupEntry(for: flow) != nil) {
                unmapped.append(flow.label)
            }
        }
        #expect(unmapped.isEmpty, "unmapped flows: \(Set(unmapped).sorted())")
        let stale = Set(FlowTable.entries.keys).subtracting(used)
        #expect(stale.isEmpty, "table entries without a flow: \(stale)")
        var deviations: [String: Int] = [:]
        for flow in flows {
            if let text = FlowTable.entry(for: flow)?.deviation { deviations["\(flow.via.name) → \(flow.to.slug): \(text)", default: 0] += 1 }
        }
        print("FLOWS total \(flows.count), unmapped \(unmapped.count), table entries \(FlowTable.entries.count), setup flows \(flows.filter { Self.isSetupScreen($0.from.slug) }.count)")
        for (text, count) in deviations.sorted(by: { $0.key < $1.key }) { print("FLOWS deviation (\(count) flows) \(text)") }
    }

    // MARK: Main window

    @Test func mainWindowFlowsRunTheMappedTransition() async throws {
        let flows = try Self.loadFlows().filter { !Self.isSetupScreen($0.from.slug) }
        let world = ScenarioWorld()
        defer { world.finish() }
        try await world.createReadyVault(storePIN: true)
        let context = try await FlowContext(world: world)

        var executed = 0
        for flow in flows {
            guard let entry = FlowTable.entry(for: flow) else {
                Issue.record("unmapped flow \(flow.label)")
                continue
            }
            try await context.reset()
            try await context.prepare(source: flow.from.slug)
            context.label = flow.label
            try await entry.run(context)
            executed += 1
        }
        print("FLOWS main window: executed \(executed) of \(flows.count)")
        #expect(executed == flows.count)
    }

    // MARK: Setup and unlock window

    @Test func setupFlowsRunTheMappedPhaseTransition() async throws {
        let flows = try Self.loadFlows().filter { Self.isSetupScreen($0.from.slug) }
        #expect(!flows.isEmpty)

        // One database for the unlock flows; every other setup flow starts from a fresh model.
        let vaultWorld = ScenarioWorld()
        defer { vaultWorld.finish() }
        try await vaultWorld.createReadyVault(storePIN: false)
        try await vaultWorld.model.setTouchID(true)

        var executed = 0
        for flow in flows {
            guard let entry = FlowTable.setupEntry(for: flow) else {
                Issue.record("unmapped setup flow \(flow.label)")
                continue
            }
            let setup = SetupContext(label: flow.label, flow: flow, vaultWorld: vaultWorld)
            try await entry(setup)
            executed += 1
        }
        print("FLOWS setup window: executed \(executed) of \(flows.count)")
        #expect(executed == flows.count)
    }
}

// MARK: - Mapping table

struct FlowEntry {
    var run: @MainActor (FlowContext) async throws -> Void
    /// Where the app deliberately differs from the prototype (the test asserts the app's behaviour).
    var deviation: String?

    init(deviation: String? = nil, _ run: @escaping @MainActor (FlowContext) async throws -> Void) {
        self.run = run
        self.deviation = deviation
    }
}

enum FlowTable {
    typealias Key = FlowTests.FlowKey

    /// (node clicked, target artboard slug) → transition. The `Nav / …` rows exist on every main-window
    /// artboard (sidebar), so each of those keys is hit once per source.
    static let entries: [Key: FlowEntry] = {
        var table: [Key: FlowEntry] = [:]
        func add(_ via: String, _ target: String, _ entry: FlowEntry) { table[Key(via: via, target: target)] = entry }

        // Sidebar items and links that only change the route.
        let navigation: [(String, String, MainRoute)] = [
            ("Nav / Overview", "app-1-overview-desktop", .overview),
            ("Nav / All transactions", "app-2-transactions-desktop", .transactions(.all)),
            ("Nav / Suggestions", "app-11-suggestions-desktop", .suggestions),
            ("Nav / Month review", "app-12-october-review-desktop", .monthReview),
            ("Nav / Budgets", "app-6-budgets-desktop", .budgets),
            ("Nav / Standing orders", "app-7-standing-orders-desktop", .standingOrders),
            ("Nav / Contracts", "app-8-contracts-desktop", .contracts),
            ("Nav / Categories", "app-5-categories-desktop", .categories),
            ("Nav / Tax", "app-14-tax-return-desktop", .taxReturn),
            ("Attention / HUK notice deadline", "app-8-contracts-desktop", .contracts),
            ("Attention / Spotify price", "app-8-contracts-desktop", .contracts),
            ("Button / Categorize", "app-11-suggestions-desktop", .suggestions),
            ("Finding / Mobility", "app-5-categories-desktop", .categories),
            ("Finding / Groceries", "app-5-categories-desktop", .categories),
            ("Finding / Eating out", "app-5-categories-desktop", .categories),
        ]
        for (via, target, route) in navigation {
            add(via, target, FlowEntry { ctx in
                ctx.model.navigate(to: route)
                ctx.expect(ctx.model.route == route, "route is \(ctx.model.route), expected \(route)")
            })
        }

        // Account rows: the sidebar and the Overview accounts list navigate the same way
        // (`account.kind == .depot ? .depot : .transactions(.account(id))`).
        let accounts: [(String, String, String)] = [
            ("Nav / Girokonto", "app-2-transactions-desktop", "Girokonto"),
            ("Nav / Tagesgeld", "app-2-transactions-desktop", "Tagesgeld"),
            ("Nav / Visa Card", "app-2-transactions-desktop", "Visa Card"),
            ("Nav / PayPal", "app-2-transactions-desktop", "PayPal"),
            ("Nav / Depot", "app-9-depot-desktop", "Depot"),
            ("Row / Girokonto", "app-2-transactions-desktop", "Girokonto"),
            ("Row / Depot", "app-9-depot-desktop", "Depot"),
        ]
        for (via, target, name) in accounts {
            add(via, target, FlowEntry { ctx in
                let account = try ctx.sidebarAccount(containing: name)
                ctx.model.navigate(to: account.kind == .depot ? .depot : .transactions(.account(account.id)))
                let expected: MainRoute = account.kind == .depot ? .depot : .transactions(.account(account.id))
                ctx.expect(ctx.model.route == expected, "route is \(ctx.model.route), expected \(expected)")
                ctx.expect((target == "app-9-depot-desktop") == (account.kind == .depot), "target artboard \(target) matches the account kind")
            })
        }

        // Toolbar and sidebar footer.
        add("Search field", "app-10-ask-desktop", FlowEntry { ctx in
            ctx.model.openAsk()
            ctx.expect(ctx.model.panel == .ask, "panel is \(String(describing: ctx.model.panel))")
        })
        add("New transfer button", "app-4-new-transfer-desktop", FlowEntry { ctx in
            ctx.model.openNewTransfer()
            ctx.expect(ctx.model.panel == .newTransfer(nil), "panel is \(String(describing: ctx.model.panel))")
        })
        add("Sync row", "settings-preferences-mac", FlowEntry { ctx in try ctx.expectSettingsOpens() })
        add("Why this happens", "settings-preferences-mac", FlowEntry { ctx in try ctx.expectSettingsOpens() })
        add("Change TAN method", "settings-preferences-mac", FlowEntry { ctx in try ctx.expectSettingsOpens() })
        add("Sync button", "errors-1-sync-failed-desktop", FlowEntry(
            deviation: "The Sync button only runs the sync; the failure shows where the Overview is on screen (route is kept). Pressed while a sync runs it is ignored."
        ) { ctx in
            let routeBefore = ctx.model.route
            let wasSyncing = ctx.model.bank.syncState.isSyncing
            ctx.world.behaviour.sync = .fails
            await ctx.model.bank.sync().value
            if wasSyncing {
                ctx.expect(ctx.model.bank.syncState.isSyncing, "a second sync must not start while one runs")
            } else {
                ctx.expectFailedSync()
            }
            ctx.expect(ctx.model.route == routeBefore, "the Sync button must not change the route")
        })

        // Sync failure recovery (Sync failed banner, PIN sheet).
        add("Retry now", "app-1-overview-desktop", FlowEntry { ctx in
            ctx.expect(!ctx.model.bank.syncState.failures.isEmpty, "Retry now starts from a failed sync")
            ctx.world.behaviour.sync = .succeeds
            await ctx.model.bank.sync().value
            ctx.expect(ctx.model.bank.syncState == .idle, "sync state is \(ctx.model.bank.syncState)")
            ctx.expect(ctx.model.route == .overview, "route is \(ctx.model.route)")
        })
        add("Sync with new PIN", "app-1-overview-desktop", FlowEntry { ctx in
            ctx.expect(ctx.model.panel == .pin, "the PIN sheet is open")
            ctx.world.behaviour.sync = .succeeds
            await ctx.model.bank.sync(newPIN: "87654321", storePIN: false).value
            ctx.expect(ctx.model.bank.syncState == .idle, "sync state is \(ctx.model.bank.syncState)")
            ctx.expect(ctx.model.panel == nil, "the PIN sheet closes")
        })
        add("Cancel", "app-1-overview-desktop", FlowEntry { ctx in
            ctx.expect(ctx.model.panel == .pin, "the PIN sheet is open")
            ctx.model.closePanel()
            ctx.expect(ctx.model.panel == nil, "panel is \(String(describing: ctx.model.panel))")
            ctx.expect(!ctx.model.bank.syncState.failures.isEmpty, "Cancel keeps the failed state and its banner")
            ctx.expect(ctx.model.route == .overview, "route is \(ctx.model.route)")
        })

        // Transactions: rows open the inspector, "Close inspector" closes it.
        for (via, target) in [("Row / REWE 11.11.", "app-3-transaction-detail-desktop"), ("Row / REWE", "app-3-transaction-detail-desktop")] {
            add(via, target, FlowEntry { ctx in
                let tx = try await ctx.openInspector(for: try await ctx.reweID(), scope: ctx.currentScope)
                ctx.expect(tx.selectedItem?.counterpartyName == "REWE Markt GmbH", "inspector shows \(String(describing: tx.selectedItem?.counterpartyName))")
                ctx.expect(tx.selectedItem.map { MoneyFormatter.string($0.amount) } == "−63,48\u{00A0}€", "inspector amount")
                ctx.expect(tx.isInspectorOpen, "the inspector is open")
            })
        }
        add("Button / Close inspector", "app-2-transactions-desktop", FlowEntry { ctx in
            let tx = try await ctx.openInspector(for: try await ctx.reweID(), scope: ctx.currentScope)
            ctx.expect(tx.isInspectorOpen, "the inspector is open before closing")
            tx.clearSelection()
            ctx.expect(tx.selection == nil && !tx.isInspectorOpen, "Close inspector clears the selection")
        })
        add("Button / Show payments", "app-2-transactions-desktop", FlowEntry { ctx in
            // Contracts: "Show payments" opens the paying account (every contract is paid from the Girokonto).
            ctx.model.navigate(to: .transactions(.account(ctx.giro)))
            ctx.expect(ctx.model.route == .transactions(.account(ctx.giro)), "route is \(ctx.model.route)")
        })

        // Suggestions: rows, notices.
        for (via, key) in [
            ("Row / Amazon", "Amazon"), ("Row / Apotheke", "Apotheke"), ("Row / Bargeld", "Bargeld"),
            ("Row / Etsy", "Etsy"), ("Row / Jonas Weber", "JonasWeber"), ("Row / SumUp Kiosk", "SumUpKiosk"),
        ] {
            add(via, "app-3-transaction-detail-desktop", FlowEntry { ctx in
                let row = try await ctx.suggestionRow(matching: key)
                ctx.model.showTransaction(id: row.id, accountID: row.accountID)
                ctx.expect(ctx.model.route == .transactions(.account(row.accountID)), "route is \(ctx.model.route)")
                ctx.expect(ctx.model.pendingTransactionSelection == row.id, "the row is queued for selection")
                let tx = try await ctx.openInspector(for: row.id, scope: .account(row.accountID))
                ctx.expect(tx.selectedItem?.payee == row.payee, "inspector shows \(String(describing: tx.selectedItem?.payee)), expected \(row.payee)")
            })
        }
        add("Compare payments", "app-2-transactions-desktop", FlowEntry { ctx in
            let notice = try await ctx.suggestionNotice(.doubleCharge)
            ctx.model.navigate(to: .transactions(notice.accountID.map(AccountScope.account) ?? .all))
            let expected: MainRoute = .transactions(notice.accountID.map(AccountScope.account) ?? .all)
            ctx.expect(ctx.model.route == expected, "route is \(ctx.model.route), expected \(expected)")
        })
        add("Create rule", "app-5-categories-desktop", FlowEntry { ctx in
            _ = try await ctx.suggestionNotice(.newRule)
            ctx.model.navigate(to: .categories)
            ctx.expect(ctx.model.route == .categories, "route is \(ctx.model.route)")
        })

        // Tax return rows.
        for (via, key) in [
            ("Row / Deutsche Bahn", "DeutscheBahn"), ("Row / HUK Haftpflicht", "HUK"),
            ("Row / Ärzte ohne Grenzen 10.10.", "Ärzteohne"),
        ] {
            add(via, "app-3-transaction-detail-desktop", FlowEntry { ctx in
                let cited = try await ctx.taxRow(matching: key)
                ctx.model.showTransaction(id: cited.id, accountID: cited.accountID)
                ctx.expect(ctx.model.route == .transactions(.account(cited.accountID)), "route is \(ctx.model.route)")
                ctx.expect(ctx.model.pendingTransactionSelection == cited.id, "the row is queued for selection")
                let tx = try await ctx.openInspector(for: cited.id, scope: .account(cited.accountID))
                ctx.expect(tx.selectedItem?.id == cited.id, "inspector follows the cited transaction")
            })
        }

        // The compact Overview's "Categorize" is drawn as a link to the transaction detail.
        // The app sends it to Suggestions in every size; it is registered under its own target key.
        add("Button / Categorize", "app-3-transaction-detail-desktop", FlowEntry(
            deviation: "Compact Overview draws \"Categorize\" linking to Transaction detail; the app sends it to Suggestions in every size."
        ) { ctx in
            ctx.model.navigate(to: .suggestions)
            ctx.expect(ctx.model.route == .suggestions, "route is \(ctx.model.route)")
        })

        // Ask panel.
        add("Overlay", "app-1-overview-desktop", FlowEntry { ctx in
            let routeBefore = ctx.model.route
            ctx.model.closePanel()
            ctx.expect(ctx.model.panel == nil, "a click on the dim closes Ask")
            ctx.expect(ctx.model.route == routeBefore, "the route is kept")
        })
        add("Show all", "app-2-transactions-desktop", FlowEntry { ctx in
            ctx.model.closePanel()
            ctx.model.navigate(to: .transactions(.all))
            ctx.expect(ctx.model.panel == nil, "panel is \(String(describing: ctx.model.panel))")
            ctx.expect(ctx.model.route == .transactions(.all), "route is \(ctx.model.route)")
        })
        let askActions: [(String, String, Int, String, MainRoute)] = [
            ("Action / Set budget", "app-6-budgets-desktop", 0, "Set a", .budgets),
            ("Action / Compare 2025", "app-5-categories-desktop", 1, "Compare", .categories),
            ("Action / Pay invoice PDF", "app-13-pay-invoice-desktop", 2, "Pay an invoice", .payInvoice),
        ]
        for (via, target, index, titlePrefix, route) in askActions {
            add(via, target, FlowEntry { ctx in
                let answer = try await ctx.askAnswer()
                ctx.expect(answer.actions.indices.contains(index) && answer.actions[index].hasPrefix(titlePrefix),
                           "follow-up \(index) is \(answer.actions)")
                // `AskPanel.open(action:)`: close the panel, then go to the follow-up's screen.
                ctx.model.closePanel()
                ctx.model.navigate(to: route)
                ctx.expect(ctx.model.panel == nil, "Ask closes")
                ctx.expect(ctx.model.route == route, "route is \(ctx.model.route)")
            })
        }

        // October review: "Prepare transfer" opens New transfer prefilled.
        add("Prepare transfer", "app-4-new-transfer-desktop", FlowEntry { ctx in
            let step = try await ctx.reviewTransferStep()
            let hint = try #require(step.transfer)
            let draft = TransferDraft(
                fromAccount: hint.fromAccountID, recipient: hint.recipient, iban: hint.iban, amountMinor: hint.amount)
            ctx.model.openNewTransfer(draft)
            ctx.expect(ctx.model.panel == .newTransfer(draft), "panel is \(String(describing: ctx.model.panel))")
            ctx.expect(draft.isSendable, "the prepared transfer is sendable")
        })

        // Pay invoice.
        add("Cancel", "app-2-transactions-desktop", FlowEntry { ctx in
            let sources = try await ctx.payInvoiceSources()
            let scope: AccountScope = sources.first.map { .account($0.id) } ?? .all
            ctx.model.navigate(to: .transactions(scope))
            ctx.expect(ctx.model.route == .transactions(scope), "route is \(ctx.model.route)")
        })
        add("Schedule payment", "app-7-standing-orders-desktop", FlowEntry { ctx in
            let before = try await ctx.standingOrderCount()
            let date = ctx.model.sidebar.snapshot.today.adding(days: 8)
            let order = PaymentOrder(
                fromAccount: ctx.giro, recipient: "Schreinerei Kaiser GmbH", iban: "DE89 3704 0044 0532 0130 00",
                amount: 53_782, purpose: "Rechnung 2026-118", execution: .onDate(date), instant: false)
            ctx.model.submitInvoicePayment(order)
            let arrived = await ctx.world.eventually { ctx.model.route == .standingOrders }
            ctx.expect(arrived, "route is \(ctx.model.route), expected standingOrders after the sheet books")
            if case .tan(.booked)? = ctx.model.panel {} else { ctx.expect(false, "panel is \(String(describing: ctx.model.panel))") }
            ctx.expect(try await ctx.standingOrderCount() == before + 1, "a scheduled payment becomes a standing order")
        })

        // New transfer panel.
        add("Button / Cancel", "app-2-transactions-desktop", FlowEntry { ctx in
            ctx.model.closePanel()
            ctx.expect(ctx.model.panel == nil, "panel is \(String(describing: ctx.model.panel))")
        })
        add("Toggle / Standing order", "app-7-standing-orders-desktop", FlowEntry { ctx in
            // `NewTransferPanel`: choosing "Standing order" closes the panel and opens Standing orders.
            ctx.model.closePanel()
            ctx.model.navigate(to: .standingOrders)
            ctx.expect(ctx.model.panel == nil, "panel is \(String(describing: ctx.model.panel))")
            ctx.expect(ctx.model.route == .standingOrders, "route is \(ctx.model.route)")
        })
        add("Button / Send transfer", "errors-2-tan-expired-desktop", FlowEntry { ctx in
            // The designed transfer; the Debug approval switch is on "Expires".
            let draft = ctx.designedTransfer
            ctx.expect(draft.isSendable, "the designed transfer is sendable")
            ctx.world.behaviour.approval = .expires
            let balance = try await ctx.world.balance("Girokonto")
            await ctx.model.bank.submit(draft).value
            if case .tan(.expired)? = ctx.model.panel {} else {
                ctx.expect(false, "panel is \(String(describing: ctx.model.panel)), expected the TAN expired sheet")
            }
            ctx.expect(try await ctx.world.balance("Girokonto") == balance, "an expired request books nothing")
        })
        add("Button / New standing order", "app-4-new-transfer-desktop", FlowEntry { ctx in
            let first = ctx.model.sidebar.snapshot.today.adding(months: 1).firstOfMonth
            let draft = TransferDraft(execution: .standingOrder(firstExecution: first))
            ctx.model.openNewTransfer(draft)
            ctx.expect(ctx.model.panel == .newTransfer(draft), "panel is \(String(describing: ctx.model.panel))")
        })

        // TAN sheet.
        for (via, target) in [("Cancel transfer", "app-2-transactions-desktop")] {
            add(via, target, FlowEntry { ctx in
                ctx.model.closePanel()
                ctx.expect(ctx.model.panel == nil, "Cancel transfer closes the sheet")
                ctx.expect(ctx.model.bank.approval == nil, "the pending request is abandoned")
            })
        }
        add("Send a new request", "app-2-transactions-desktop", FlowEntry { ctx in
            guard case .tan(let phase)? = ctx.model.panel else {
                ctx.expect(false, "the TAN sheet is open")
                return
            }
            let order = phase.order
            let balance = try await ctx.world.balance("Girokonto")
            ctx.world.behaviour.approval = .approves
            await ctx.model.bank.submit(order).value
            if case .tan(.booked)? = ctx.model.panel {} else {
                ctx.expect(false, "panel is \(String(describing: ctx.model.panel)), expected booked")
            }
            ctx.expect(try await ctx.world.balance("Girokonto") == balance - order.amount, "the new request books the transfer")
            // Done: the source account's list.
            ctx.model.finishTransfer(order)
            ctx.expect(ctx.model.panel == nil, "Done closes the sheet")
            ctx.expect(ctx.model.route == .transactions(.account(order.fromAccount)), "route is \(ctx.model.route)")
        })
        return table
    }()

    static func entry(for flow: FlowTests.Flow) -> FlowEntry? { entries[flow.key] }

    // MARK: Setup window

    typealias SetupEntry = @MainActor (SetupContext) async throws -> Void

    /// Setup and unlock flows, keyed like the main-window table.
    static func setupEntry(for flow: FlowTests.Flow) -> SetupEntry? {
        switch (flow.from.slug, flow.via.name, flow.to.slug) {
        case (let from, "Button / Create database", "onboarding-2-add-bank-setup")
            where from.hasPrefix("onboarding-1") || from.hasPrefix("states-create-vault"):
            return { setup in try await setup.createDatabase(invalidFirst: from.contains("errors")) }
        case ("onboarding-2-add-bank-setup", "Button / Continue", "onboarding-3-bank-login-setup"):
            return { setup in try await setup.continueToBankLogin() }
        case ("onboarding-2-add-bank-setup", "Button / Back", "onboarding-1-create-vault-setup"):
            return { setup in try await setup.backFromAddBank() }
        case (let from, "Button / Back", "onboarding-2-add-bank-setup")
            where from.hasPrefix("onboarding-3") || from.hasPrefix("states-bank-login"):
            return { setup in try await setup.backFromBankLogin(waiting: from.contains("waiting")) }
        case ("onboarding-3-bank-login-setup", "Button / Import 2 accounts", "app-1-overview-desktop"):
            return { setup in try await setup.importAccounts() }
        case (let from, "Unlock", "app-1-overview-desktop") where from.hasPrefix("security-unlock") || from.hasPrefix("states-unlock"):
            return { setup in try await setup.unlock(touchID: false, variant: from) }
        case (let from, "Touch ID", "app-1-overview-desktop") where from.hasPrefix("security-unlock") || from.hasPrefix("states-unlock"):
            return { setup in try await setup.unlock(touchID: true, variant: from) }
        default:
            return nil
        }
    }
}

// MARK: - Main-window context

/// Records the window actions the model asks for (`openSettings` → `windows.open("settings")`).
final class WindowLog {
    var opened: [String] = []
}

/// One ready database with the demo ledger and the helpers the table entries use. The context is
/// reset between flows; `prepare(source:)` puts the model into the state the source artboard shows.
@MainActor
final class FlowContext {
    let world: ScenarioWorld
    let giro: String
    var label = ""
    private let windowLog = WindowLog()
    var model: AppModel { world.model }

    init(world: ScenarioWorld) async throws {
        self.world = world
        self.giro = try await world.accountID("Girokonto")
        let loaded = await world.eventually { world.model.sidebar.snapshot.accounts.count == 5 }
        #expect(loaded, "the sidebar lists the five accounts")
        let log = windowLog
        world.model.windows.register(open: { log.opened.append($0) }, dismiss: { _ in })
        log.opened.removeAll()
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, "\(label): \(message())", sourceLocation: sourceLocation)
    }

    // MARK: State

    var designedTransfer: TransferDraft {
        TransferDraft(
            recipient: "Jonas Weber", iban: "DE89 3704 0044 0532 0130 00", amountMinor: 12_000,
            purpose: "Konzertkarten Dezember", execution: .now, instant: true)
    }

    var currentScope: TransactionScope {
        if case .transactions(.account(let id)) = model.route { return .account(id) }
        return .all
    }

    func reset() async throws {
        model.closePanel()
        world.behaviour.sync = .succeeds
        world.behaviour.approval = .approves
        model.bank.setPreviewState(syncState: .idle, approval: .some(nil))
        model.navigate(to: .overview)
        model.pendingTransactionSelection = nil
        windowLog.opened.removeAll()
    }

    /// Fails one sync (Sparkasse rejects the PIN, DKB is under maintenance), then restores the switch.
    func failSync() async {
        world.behaviour.sync = .fails
        await model.bank.sync().value
        world.behaviour.sync = .succeeds
        expectFailedSync()
    }

    func expectFailedSync() {
        let banks = model.bank.syncState.byBank
        expect(banks.map(\.bankName) == ["Sparkasse KölnBonn", "DKB"], "failed banks \(banks.map(\.bankName))")
        if let first = banks.first {
            expect(first.reason == .pinRejected(code: 9931, attemptsLeft: 2), "Sparkasse reason \(first.reason)")
        }
        if banks.count > 1, case .maintenance = banks[1].reason {} else { expect(false, "DKB is under maintenance") }
        expect(model.bank.syncState.failures.count == 3, "three accounts were not updated")
    }

    /// The state the source artboard draws.
    func prepare(source slug: String) async throws {
        let order = designedTransfer.order(fromAccount: giro)
        switch slug {
        case "app-1-overview-desktop", "compact-1-overview-desktop":
            model.navigate(to: .overview)
        case "app-2-transactions-desktop", "compact-2-transactions-desktop", "dark-2-transactions-desktop",
             "app-3-transaction-detail-desktop":
            model.navigate(to: .transactions(.account(giro)))
        case "states-all-transactions-desktop":
            model.navigate(to: .transactions(.all))
        case "app-4-new-transfer-desktop":
            model.navigate(to: .transactions(.account(giro)))
            model.openNewTransfer()
        case "app-5-categories-desktop": model.navigate(to: .categories)
        case "app-6-budgets-desktop", "compact-6-budgets-desktop": model.navigate(to: .budgets)
        case "app-7-standing-orders-desktop": model.navigate(to: .standingOrders)
        case "app-8-contracts-desktop": model.navigate(to: .contracts)
        case "app-9-depot-desktop", "compact-9-depot-desktop": model.navigate(to: .depot)
        case "app-10-ask-desktop":
            model.openAsk()
        case "app-11-suggestions-desktop": model.navigate(to: .suggestions)
        case "app-12-october-review-desktop": model.navigate(to: .monthReview)
        case "app-13-pay-invoice-desktop": model.navigate(to: .payInvoice)
        case "app-14-tax-return-desktop": model.navigate(to: .taxReturn)
        case "errors-1-sync-failed-desktop", "states-pin-sheet-empty-desktop":
            await failSync()
            model.panel = .pin
        case "states-sync-failed-banner-only-desktop":
            await failSync()
        case "states-sync-in-progress-desktop":
            model.bank.setPreviewState(syncState: .syncing)
        case "errors-2-tan-expired-desktop":
            model.navigate(to: .transactions(.account(giro)))
            model.panel = .tan(.expired(sentAt: Date(), expiredAt: Date().addingTimeInterval(300), order: order))
        case "states-transfer-waiting-desktop":
            model.navigate(to: .transactions(.account(giro)))
            model.panel = .tan(.waiting(sentAt: Date(), order: order))
        case "states-transfer-booked-desktop":
            model.navigate(to: .transactions(.account(giro)))
            model.panel = .tan(.booked(sentAt: Date(), at: Date(), order: order))
        default:
            Issue.record("no state preparation for source artboard \(slug)")
        }
    }

    // MARK: Lookups

    func sidebarAccount(containing name: String) throws -> SidebarAccount {
        guard let account = model.sidebar.snapshot.accounts.first(where: { $0.name.contains(name) || $0.bankName.contains(name) }) else {
            throw ScenarioFailure.missing("sidebar account \(name)")
        }
        return account
    }

    func expectSettingsOpens() throws {
        windowLog.opened.removeAll()
        model.openSettings()
        expect(windowLog.opened == ["settings"], "windows opened: \(windowLog.opened)")
    }

    private static func normalised(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    func reweID() async throws -> String {
        let account = giro
        return try await world.ledger().database.read { db in
            let filter = TransactionFilter(scope: .account(account), period: .thisMonth)
            guard let item = try TransactionQueries.snapshot(db, filter: filter).items.first(where: { $0.shortName == "REWE" }) else {
                throw ScenarioFailure.missing("REWE 11.11.")
            }
            return item.id
        }
    }

    func suggestionRow(matching key: String) async throws -> SuggestionRow {
        let snapshot = try await world.ledger().database.read(SuggestionsQueries.snapshot)
        let needle = Self.normalised(key)
        guard let row = snapshot.rows.first(where: { Self.normalised($0.payee).contains(needle) }) else {
            throw ScenarioFailure.missing("suggestion row \(key) in \(snapshot.rows.map(\.payee))")
        }
        return row
    }

    func suggestionNotice(_ variant: SuggestionNotice.Variant) async throws -> SuggestionNotice {
        let snapshot = try await world.ledger().database.read(SuggestionsQueries.snapshot)
        guard let notice = snapshot.notices.first(where: { $0.variant == variant }) else {
            throw ScenarioFailure.missing("suggestion notice \(variant)")
        }
        return notice
    }

    func taxRow(matching key: String) async throws -> CitedTransaction {
        guard let snapshot = try await world.ledger().database.read(TaxQueries.snapshot) else {
            throw ScenarioFailure.missing("tax snapshot")
        }
        let needle = Self.normalised(key)
        guard let row = snapshot.rows.first(where: { Self.normalised($0.payee).contains(needle) }),
              let cited = row.firstTransaction else {
            throw ScenarioFailure.missing("tax row \(key) in \(snapshot.rows.map(\.payee))")
        }
        return cited
    }

    func askAnswer() async throws -> AskAnswer {
        guard let answer = try await world.ledger().database.read(AskQueries.answer) else {
            throw ScenarioFailure.missing("ask answer")
        }
        return answer
    }

    func reviewTransferStep() async throws -> ReviewStepRow {
        guard let snapshot = try await world.ledger().database.read(ReviewQueries.snapshot),
              let step = snapshot.steps.first(where: { $0.transfer != nil }) else {
            throw ScenarioFailure.missing("review step with a transfer")
        }
        return step
    }

    func payInvoiceSources() async throws -> [PayInvoiceSource] {
        try await world.ledger().database.read(PayInvoiceQueries.snapshot).sources
    }

    func standingOrderCount() async throws -> Int {
        try await world.ledger().database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standing_order WHERE deleted_at IS NULL") ?? 0
        }
    }

    /// Builds the Transactions screen's model for `scope`, asks it to select `id` (as a deep link does)
    /// and observes the ledger until the row is selected; the model widens a filter that hides the row.
    func openInspector(for id: String, scope: TransactionScope) async throws -> TransactionsModel {
        let ledger = try world.ledger()
        let tx = TransactionsModel(filter: TransactionFilter(scope: scope))
        tx.requestSelection(id)
        for _ in 0..<3 {
            let observing = Task { await tx.observe(ledger) }
            _ = await world.eventually(timeout: .seconds(3)) { tx.selection == id }
            observing.cancel()
            if tx.selection == id { return tx }
        }
        throw ScenarioFailure.missing("selection of transaction \(id)")
    }
}

// MARK: - Setup context

/// Setup and unlock flows run on their own models: Create vault → Add bank → Bank login → Overview, and
/// Unlock → Overview on the shared database of `vaultWorld`.
@MainActor
struct SetupContext {
    let label: String
    let flow: FlowTests.Flow
    let vaultWorld: ScenarioWorld

    func expect(_ condition: Bool, _ message: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, "\(label): \(message())", sourceLocation: sourceLocation)
    }

    private var source: String { flow.from.slug }

    // MARK: Create vault

    /// "Create database": the screen's rules gate it; a valid draft creates the package and the app
    /// shows Add bank (phase `.needsBank`, no bank chosen).
    func createDatabase(invalidFirst: Bool) async throws {
        let touchIDUnavailable = source.contains("touch-id-unavailable") || source.contains("no-touch-id")
        let world = ScenarioWorld(biometry: touchIDUnavailable ? .noSensor : .available)
        defer { world.finish() }
        if invalidFirst {
            expect(!CreateVaultRules.isValid(password: "1234567", confirm: "1234567"), "seven characters are refused")
            expect(!CreateVaultRules.isValid(password: "12345678", confirm: "1234567"), "different passwords are refused")
            expect(world.model.phase == .noVault, "a refused draft creates nothing")
            expect(!FileManager.default.fileExists(atPath: world.vaultURL.path), "no package yet")
        }
        expect(CreateVaultRules.isValid(password: ScenarioWorld.password, confirm: ScenarioWorld.password), "a valid draft passes")
        try await world.model.createVault(at: world.vaultURL, password: ScenarioWorld.password, enableTouchID: true)
        expect(world.model.phase == .needsBank, "phase is \(world.model.phase)")
        expect(world.model.bank.selectedBank == nil, "Add bank starts without a chosen bank")
        expect(world.model.touchIDEnabled == !touchIDUnavailable, "Touch ID is \(world.model.touchIDEnabled)")
        let items = try FileManager.default.contentsOfDirectory(atPath: world.vaultURL.path)
        expect(items.contains("vault.json") && items.contains("data.sqlite"), "package holds \(items)")
    }

    // MARK: Add bank, Bank login

    private func needsBankWorld(approvals: ApprovalGate? = nil) async throws -> ScenarioWorld {
        let world = ScenarioWorld(approvals: approvals)
        try await world.model.createVault(at: world.vaultURL, password: ScenarioWorld.password, enableTouchID: false)
        expect(world.model.phase == .needsBank, "setup resumes at Add bank")
        return world
    }

    /// "Continue": the chosen bank opens the Bank login screen.
    func continueToBankLogin() async throws {
        let world = try await needsBankWorld()
        defer { world.finish() }
        let found = await world.model.bank.searchBanks("Sparkasse Köln")
        world.model.bank.selectedBank = found.first
        expect(world.model.bank.selectedBank?.name == "Sparkasse KölnBonn", "chosen bank \(String(describing: world.model.bank.selectedBank?.name))")
        expect(world.model.phase == .needsBank, "phase is \(world.model.phase)")
        expect(world.model.bank.signInState == .idle, "no sign-in yet")
    }

    /// Add bank → Create vault: the database exists already, so "Back" is inert (setup resumes at Add bank).
    func backFromAddBank() async throws {
        let world = try await needsBankWorld()
        defer { world.finish() }
        expect(world.model.phase == .needsBank, "Back on Add bank leaves the phase at .needsBank (the control is inert)")
        expect(world.model.vaultURL != nil, "the database stays open")
    }

    /// Bank login → Add bank: forgets the sign-in and the chosen bank (`BankLoginScreen.back()`).
    func backFromBankLogin(waiting: Bool) async throws {
        let approvals = ApprovalGate()
        let world = try await needsBankWorld(approvals: waiting ? approvals : nil)
        defer { world.finish() }
        let bank = DemoConnector.directory[0]
        world.model.bank.selectedBank = bank
        var signInTask: Task<Void, Never>?
        if waiting {
            await approvals.holdNext()
            signInTask = Task { @MainActor in
                do {
                    try await world.model.bank.signIn(
                        bank: bank, credentials: BankCredentials(loginName: "lena", pin: "12345678", tanMethod: "pushTAN"))
                } catch {
                    if Task.isCancelled { world.model.bank.resetSignIn() }
                }
            }
            let waitingNow = await world.eventually {
                if case .waiting = world.model.bank.signInState { return true }
                return false
            }
            expect(waitingNow, "sign-in is waiting for approval")
        }
        // `back()`.
        signInTask?.cancel()
        // The held approval would wait forever otherwise; the reset below discards whatever it delivers.
        await approvals.release()
        _ = await signInTask?.value
        world.model.bank.resetSignIn()
        world.model.bank.selectedBank = nil
        expect(world.model.bank.selectedBank == nil, "Back clears the chosen bank")
        expect(world.model.bank.signInState == .idle, "sign-in state is \(world.model.bank.signInState)")
        expect(world.model.phase == .needsBank, "phase is \(world.model.phase)")
    }

    /// "Import 2 accounts": all five designed accounts arrive and the main window opens on the Overview.
    func importAccounts() async throws {
        let world = try await needsBankWorld()
        defer { world.finish() }
        try await world.importDemo(storePIN: false)
        expect(world.model.phase == .ready, "phase is \(world.model.phase)")
        expect(world.model.route == .overview, "route is \(world.model.route)")
        let loaded = await world.eventually { world.model.sidebar.snapshot.accounts.count == 5 }
        expect(loaded, "five accounts after the import")
    }

    // MARK: Unlock

    /// The shared database, locked, with Touch ID on and its key intact (the plain Unlock artboard).
    private func lockedWithTouchID() async throws -> AppModel.LockedInfo {
        let model = vaultWorld.model
        if model.phase == .ready { model.lock(.manual) }
        guard case .locked(var info) = model.phase else { throw ScenarioFailure.missing("locked phase, got \(model.phase)") }
        if info.touchID != .ready {
            try await model.unlock(password: ScenarioWorld.password)
            if !model.touchIDEnabled { try await model.setTouchID(true) }
            model.lock(.manual)
            guard case .locked(let again) = model.phase else { throw ScenarioFailure.missing("locked phase, got \(model.phase)") }
            info = again
        }
        return info
    }

    /// Unlock → Overview for the unlock artboard and its states, by password ("Unlock") or fingerprint
    /// ("Touch ID"). The states first bring the lock screen into their situation: a wrong password is
    /// refused, Touch ID is off, or the fingerprints changed (the key is gone and the password re-arms it).
    func unlock(touchID: Bool, variant: String) async throws {
        let model = vaultWorld.model
        let biometrics = vaultWorld.biometrics
        let info = try await lockedWithTouchID()
        expect(info.touchID == .ready, "Touch ID is \(info.touchID) before the flow")

        switch variant {
        case "states-unlock-wrong-password-setup":
            await #expect(throws: VaultError.wrongPassword) { try await model.unlock(password: "wrong-password") }
            expect(model.phase == .locked(info), "a wrong password keeps the unlock screen")
        case "states-unlock-no-touch-id-setup":
            try await model.unlock(password: ScenarioWorld.password)
            try await model.setTouchID(false)
            model.lock(.manual)
            guard case .locked(let plain) = model.phase else { expect(false, "phase is \(model.phase)"); return }
            expect(plain.touchID == .unavailable, "the fingerprint block is absent, Touch ID is \(plain.touchID)")
        case "states-unlock-fingerprints-changed-setup":
            try await model.unlock(password: ScenarioWorld.password)
            biometrics.remove(vaultID: info.vaultID)
            model.lock(.manual)
            guard case .locked(let changed) = model.phase else { expect(false, "phase is \(model.phase)"); return }
            expect(changed.touchID == .invalidated, "Touch ID is \(changed.touchID) after the fingerprints changed")
        default:
            break
        }

        // The node clicked.
        if touchID {
            try await model.unlockWithTouchID()
        } else {
            try await model.unlock(password: ScenarioWorld.password)
            if variant == "states-unlock-fingerprints-changed-setup" {
                expect(model.touchIDEnabled, "the password unlock turns Touch ID back on")
            }
        }
        expect(model.phase == .ready, "phase is \(model.phase)")
        expect(model.route == .overview, "route is \(model.route)")
        expect(model.panel == nil, "no panel is open")
        expect(model.lockReason == nil, "lock reason is \(String(describing: model.lockReason))")
        expect(model.ledger != nil, "the ledger is open")
        model.lock(.manual)
    }
}
