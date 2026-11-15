import Foundation
import IMMBanking
import IMMLedger

/// Read-only FinTS 3.0 PIN/TAN client for one login: accounts (`HKSPA`), balance (`HKSAL`) and statements
/// (`HKCAZ` with `HKKAZ` as fallback), with decoupled strong customer authentication (app approval) only.
///
/// Calls are serialised: a second call waits until the first one has finished, so one dialog is never used by two
/// requests at once. The first call opens the dialog (synchronisation when the system id is unknown, TAN method
/// selection, dialog initialisation); later calls reuse it. A dialog the bank ended (return code 9800) is reopened once.
///
/// Every error leaves this type as a `FinTSError`.
public actor FinTSClient: FinTSBankClient {
    private let endpoint: FinTSEndpoint
    private let user: FinTSUser
    private let product: FinTSProduct
    private let stateStore: any FinTSStateStore
    private let transport: any FinTSTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private var dialog: FinTSDialog?
    private var parameters = FinTSParameters()
    private var chosenMethod: FinTSTANMethod?
    private var mediumName: String?

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let berlin = TimeZone(identifier: "Europe/Berlin") ?? .current

    public init(endpoint: FinTSEndpoint, user: FinTSUser, product: FinTSProduct, stateStore: any FinTSStateStore,
                transport: any FinTSTransport = URLSessionFinTSTransport(),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.user = user
        self.product = product
        self.stateStore = stateStore
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    // MARK: FinTSBankClient

    public func tanMethodName() async -> String? {
        chosenMethod?.name
    }

    public func accounts(onApproval: @Sendable (ApprovalState) -> Void) async throws -> [FinTSSEPAAccount] {
        try await serialized {
            try await withDialog(onApproval) { dialog in
                guard let version = parameters.version(of: "HISPAS", supported: [1, 2, 3]) else {
                    // No HISPAS: the bank gives no SEPA list; the UPD accounts that carry an IBAN are all there is.
                    return accountsFromUserData()
                }
                let job = FinTSSegment(type: "HKSPA", version: version)
                let exchange = try await dialog.submit([job], authenticating: tanSegmentType(for: "HKSPA"),
                                                       onApproval: onApproval)
                absorb(exchange)
                return sepaAccounts(from: exchange)
            }
        }
    }

    public func balance(of account: FinTSSEPAAccount,
                        onApproval: @Sendable (ApprovalState) -> Void) async throws -> FinTSBalance {
        try await serialized {
            try await withDialog(onApproval) { dialog in
                let version = parameters.version(of: "HISALS", supported: [5, 6, 7]) ?? 7
                let job = FinTSSegment(type: "HKSAL", version: version,
                                       elements: [version >= 7 ? Self.kti(account) : Self.ktv(account), "N"])
                let exchange = try await dialog.submit([job], authenticating: tanSegmentType(for: "HKSAL"),
                                                       onApproval: onApproval)
                absorb(exchange)
                return try balance(from: exchange, account: account)
            }
        }
    }

    public func statements(of account: FinTSSEPAAccount, from: LocalDate,
                           onApproval: @Sendable (ApprovalState) -> Void) async throws -> [StatementEntry] {
        try await serialized {
            try await withDialog(onApproval) { dialog in
                if let version = parameters.version(of: "HICAZS", supported: [1]), !camtFormatsToRequest().isEmpty {
                    return try await camtStatements(dialog, version: version, account: account, from: from,
                                                    onApproval: onApproval)
                }
                return try await mt940Statements(dialog, account: account, from: from, onApproval: onApproval)
            }
        }
    }

    public func close() async {
        await acquire()
        defer { release() }
        guard let active = dialog else { return }
        dialog = nil
        await active.end()
    }

    // MARK: Serialisation

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            // The lock passes straight to the next caller; `isBusy` stays true.
            waiters.removeFirst().resume()
        }
    }

    private func serialized<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        do {
            return try await body()
        } catch {
            throw FinTSError.wrapping(error)
        }
    }

    // MARK: Dialog lifecycle

    /// Runs `job` in the open dialog, opening one first. A dialog the bank ended (9800) is reopened once; any other
    /// failure drops the dialog so the next call starts clean.
    private func withDialog<T>(_ onApproval: @Sendable (ApprovalState) -> Void,
                               _ job: (FinTSDialog) async throws -> T) async throws -> T {
        guard !product.id.isEmpty else { throw FinTSError.productNotRegistered }
        var reopened = false
        while true {
            let active: FinTSDialog
            if let open = dialog {
                active = open
            } else {
                active = try await openDialog(onApproval)
            }
            do {
                return try await job(active)
            } catch {
                let failure = FinTSError.wrapping(error)
                dialog = nil
                if Self.shouldEnd(after: failure) { await active.end() }
                if Self.isDialogAborted(failure), !reopened {
                    reopened = true
                    continue
                }
                throw failure
            }
        }
    }

    private static func isDialogAborted(_ error: FinTSError) -> Bool {
        if case .bankRejected(let code, _) = error { return code == FinTSReturnCodeMapper.dialogAbortedCode }
        return false
    }

    /// Whether the bank can still hold the dialog open after `error`, so an `HKEND` makes sense.
    private static func shouldEnd(after error: FinTSError) -> Bool {
        switch error {
        case .transport, .malformedResponse, .maintenance, .pinRejected: false
        case .bankRejected(let code, _): code != FinTSReturnCodeMapper.dialogAbortedCode
        default: true
        }
    }

    /// Steps 1–3 of the dialog flow: system id, TAN method, initialisation with strong customer authentication.
    private func openDialog(_ onApproval: @Sendable (ApprovalState) -> Void) async throws -> FinTSDialog {
        let bankCode = endpoint.bankCode
        let login = user.loginName

        // 1. System id.
        var systemID = stateStore.systemID(bankCode: bankCode, loginName: login)
        let storedMethod = stateStore.tanMethod(bankCode: bankCode, loginName: login)
        if systemID == nil {
            systemID = try await synchronise()
        } else if storedMethod == nil {
            // Known device, but no TAN method yet: one parameter dialog reads the methods the bank offers.
            try await fetchParameters(systemID: systemID ?? "0")
        }
        let activeSystemID = systemID ?? "0"

        // 2. TAN method. Without BPD in memory (stored system id and method after a restart) the stored code is
        // used as it is; the answer to the initialisation brings the BPD.
        let selected: String
        if parameters.tanMethods.isEmpty {
            guard let storedMethod else { throw FinTSError.unsupportedTANMethods([]) }
            selected = storedMethod
        } else {
            selected = try chooseMethod(stored: storedMethod).securityFunction
        }
        if selected != storedMethod {
            stateStore.setTANMethod(selected, bankCode: bankCode, loginName: login)
        }
        chosenMethod = parameters.tanMethod(code: selected)

        if let method = chosenMethod, method.mediumRequirement == 2, mediumName == nil {
            mediumName = try await fetchMediumName(systemID: activeSystemID)
        }

        // 3. Dialog initialisation with strong customer authentication.
        let opened = FinTSDialog(endpoint: endpoint, userID: login, pin: user.pin, systemID: activeSystemID,
                                 securityFunction: selected, transport: transport, sleep: sleep, now: now)
        await opened.configure(scaConfiguration())
        do {
            let exchange = try await opened.submit([identification(systemID: activeSystemID), processing()],
                                                   authenticating: "HKIDN", onApproval: onApproval)
            absorb(exchange)
        } catch {
            let failure = FinTSError.wrapping(error)
            if Self.shouldEnd(after: failure) { await opened.end() }
            throw failure
        }
        chosenMethod = parameters.tanMethod(code: selected) ?? chosenMethod
        await opened.configure(scaConfiguration())
        dialog = opened
        return opened
    }

    private func scaConfiguration() -> FinTSSCAConfiguration {
        FinTSSCAConfiguration(tanVersion: parameters.tanVersion ?? 7, mediumName: mediumName, method: chosenMethod)
    }

    /// The stored method if the bank still allows it; else the first decoupled one. Methods that need a typed TAN
    /// are not supported.
    private func chooseMethod(stored: String?) throws -> FinTSTANMethod {
        let allowed = parameters.allowedSecurityFunctions
        let usable = parameters.tanMethods.filter { allowed.isEmpty || allowed.contains($0.securityFunction) }
        if let stored, let method = usable.first(where: { $0.securityFunction == stored }) { return method }
        if let method = usable.first(where: \.isDecoupled) { return method }
        throw FinTSError.unsupportedTANMethods((usable.isEmpty ? parameters.tanMethods : usable).map(\.name))
    }

    // MARK: Preliminary dialogs (one-step security function 999)

    /// Synchronisation dialog: `HKIDN`, `HKVVB`, `HKSYN` with function 999. Stores and returns the system id.
    private func synchronise() async throws -> String {
        let preliminary = makePreliminaryDialog(systemID: "0")
        do {
            let response = try await preliminary.send([
                identification(systemID: "0"), processing(), FinTSSegment(type: "HKSYN", version: 3, elements: ["0"]),
            ])
            parameters.absorb(response)
        } catch {
            let failure = FinTSError.wrapping(error)
            if Self.shouldEnd(after: failure) { await preliminary.end() }
            throw failure
        }
        await preliminary.end()
        guard let id = parameters.systemID, !id.isEmpty else {
            throw FinTSError.malformedResponse("The synchronisation answer carries no system id (HISYN).")
        }
        stateStore.setSystemID(id, bankCode: endpoint.bankCode, loginName: user.loginName)
        return id
    }

    private func fetchParameters(systemID: String) async throws {
        let preliminary = makePreliminaryDialog(systemID: systemID)
        do {
            parameters.absorb(try await preliminary.send([identification(systemID: systemID), processing()]))
        } catch {
            let failure = FinTSError.wrapping(error)
            if Self.shouldEnd(after: failure) { await preliminary.end() }
            throw failure
        }
        await preliminary.end()
    }

    /// Banks that require a TAN medium name (`HITANS`: required) get one from `HKTAB`: the first active medium, else
    /// the first one listed.
    private func fetchMediumName(systemID: String) async throws -> String {
        let preliminary = makePreliminaryDialog(systemID: systemID)
        let version = parameters.version(of: "HITABS", supported: [4, 5]) ?? 4
        let response: FinTSResponse
        do {
            response = try await preliminary.send([
                identification(systemID: systemID), processing(),
                FinTSSegment(type: "HKTAB", version: version, elements: ["0", "A"]),
            ])
        } catch {
            let failure = FinTSError.wrapping(error)
            if Self.shouldEnd(after: failure) { await preliminary.end() }
            throw failure
        }
        await preliminary.end()
        parameters.absorb(response)
        if let name = Self.firstMediumName(in: response) { return name }
        let last = response.allCodes.last { $0.segmentReference != nil }
        throw FinTSError.bankRejected(code: last?.code ?? 0,
                                      message: last?.text ?? "The bank lists no TAN medium for this login.")
    }

    private func makePreliminaryDialog(systemID: String) -> FinTSDialog {
        FinTSDialog(endpoint: endpoint, userID: user.loginName, pin: user.pin, systemID: systemID, securityFunction: "999",
                    transport: transport, sleep: sleep, now: now)
    }

    /// `HITAB`: element 0 is the usage option; every further element is one medium, flattened to
    /// class, status, card data, account, validity, list number, **name**, phone numbers … Because the optional
    /// account group flattens into the same list, the name is the first free text after class and status that is
    /// neither an IBAN nor a BIC.
    static func firstMediumName(in response: FinTSResponse) -> String? {
        var candidates: [(active: Bool, name: String)] = []
        for segment in response.segments("HITAB") {
            for element in segment.elements.dropFirst() {
                let parts = element.components.map { $0.string ?? "" }
                guard parts.count > 2 else { continue }
                if let name = parts.dropFirst(2).first(where: isMediumName) {
                    candidates.append((parts[1] == "1", name))
                }
            }
        }
        return (candidates.first { $0.active } ?? candidates.first)?.name
    }

    private static func isMediumName(_ text: String) -> Bool {
        guard text.count > 1, text.contains(where: \.isLetter) else { return false }
        let iban = text.range(of: #"^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$"#, options: .regularExpression) != nil
        let bic = text.range(of: #"^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$"#, options: .regularExpression) != nil
        return !iban && !bic
    }

    // MARK: Segments

    private func identification(systemID: String) -> FinTSSegment {
        FinTSSegment(type: "HKIDN", version: 2, elements: [
            .group(of: ["280", endpoint.bankCode]), .text(user.loginName), .text(systemID), "1",
        ])
    }

    /// `HKVVB`: BPD and UPD version 0 (the client keeps no copy, so the bank always sends both), language 0, product.
    private func processing() -> FinTSSegment {
        FinTSSegment(type: "HKVVB", version: 3, elements: ["0", "0", "0", .text(product.id), .text(product.version)])
    }

    private func tanSegmentType(for job: String) -> String? {
        parameters.requiresTAN(for: job) ? job : nil
    }

    private func absorb(_ exchange: FinTSExchange) {
        for response in exchange.responses { parameters.absorb(response) }
    }

    /// `KTV`: account number, subaccount, bank (280:BLZ) — `HKSAL`/`HKKAZ` before version 7.
    private static func ktv(_ account: FinTSSEPAAccount) -> FinTSElement {
        .group(of: [account.accountNumber, account.subaccount, "280", account.bankCode])
    }

    /// `KTI`: IBAN, BIC, account number, subaccount, bank (280:BLZ) — `HKSAL`/`HKKAZ` v7 and `HKCAZ`.
    private static func kti(_ account: FinTSSEPAAccount) -> FinTSElement {
        .group(of: [account.iban, account.bic, account.accountNumber, account.subaccount, "280", account.bankCode])
    }

    // MARK: Accounts

    private func sepaAccounts(from exchange: FinTSExchange) -> [FinTSSEPAAccount] {
        var result: [FinTSSEPAAccount] = []
        for segment in exchange.segments("HISPA") {
            for element in segment.elements {
                // `J|N` ("can be used for SEPA") precedes the account fields.
                var parts = element.components.map { $0.string ?? "" }
                if let flag = parts.first, flag == "J" || flag == "N" {
                    if flag == "N" { continue }
                    parts.removeFirst()
                }
                func part(_ index: Int) -> String? { index < parts.count && !parts[index].isEmpty ? parts[index] : nil }
                let iban = part(0)
                let number = part(2)
                guard iban != nil || number != nil else { continue }
                let upd = Self.matchingUserAccount(parameters.userAccounts, iban: iban, number: number, subaccount: part(3))
                result.append(FinTSSEPAAccount(
                    iban: iban ?? upd?.iban,
                    bic: part(1),
                    accountNumber: number ?? upd?.accountNumber ?? "",
                    subaccount: part(3),
                    bankCode: part(5) ?? upd?.bankCode ?? endpoint.bankCode,
                    productName: upd?.productName,
                    ownerName: upd?.ownerName,
                    currency: upd?.currency ?? "EUR",
                    accountType: upd?.accountType))
            }
        }
        return result
    }

    private func accountsFromUserData() -> [FinTSSEPAAccount] {
        parameters.userAccounts.compactMap { upd in
            guard let iban = upd.iban else { return nil }
            return FinTSSEPAAccount(iban: iban, bic: nil, accountNumber: upd.accountNumber, subaccount: upd.subaccount,
                                    bankCode: upd.bankCode ?? endpoint.bankCode, productName: upd.productName,
                                    ownerName: upd.ownerName, currency: upd.currency ?? "EUR",
                                    accountType: upd.accountType)
        }
    }

    private static func matchingUserAccount(_ accounts: [FinTSUserAccount], iban: String?, number: String?,
                                            subaccount: String?) -> FinTSUserAccount? {
        accounts.first { upd in
            if let number, upd.accountNumber == number, (upd.subaccount ?? "") == (subaccount ?? "") { return true }
            if let iban, upd.iban == iban { return true }
            return false
        }
    }

    // MARK: Balance

    private func balance(from exchange: FinTSExchange, account: FinTSSEPAAccount) throws -> FinTSBalance {
        guard let segment = exchange.segments("HISAL").first else {
            throw FinTSError.malformedResponse("The answer to the balance request has no HISAL segment.")
        }
        guard let booked = Self.saldo(segment.element(3)) else {
            throw FinTSError.malformedResponse("HISAL carries no readable booked balance.")
        }
        let pending = Self.saldo(segment.element(4))
        let creditLine = segment.element(5)?.component(0).flatMap(FinTSValueFormat.minorUnits)
        return FinTSBalance(
            booked: booked.amount,
            currency: booked.currency ?? segment.string(2) ?? account.currency,
            date: booked.date ?? today(),
            pending: pending?.amount,
            creditLine: creditLine)
    }

    /// `C|D : amount : currency : date [: time]` → signed minor units; nil when the element has no usable amount.
    private static func saldo(_ element: FinTSElement?) -> (amount: Int, currency: String?, date: LocalDate?)? {
        guard let element else { return nil }
        let parts = element.components.map { $0.string ?? "" }
        guard parts.count >= 2, let magnitude = FinTSValueFormat.minorUnits(parts[1]) else { return nil }
        let sign: Int
        switch parts[0].uppercased() {
        case "C": sign = 1
        case "D": sign = -1
        default: return nil
        }
        let currency = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        let date = parts.count > 3 ? FinTSValueFormat.date(parts[3]) : nil
        return (sign * magnitude, currency, date)
    }

    // MARK: Statements

    private func today() -> LocalDate {
        LocalDate(now(), timeZone: Self.berlin)
    }

    /// Moves `from` forward when the bank only keeps `maxDays` of history.
    private func earliest(_ from: LocalDate, maxDays: Int?) -> LocalDate {
        guard let maxDays, maxDays > 0 else { return from }
        let limit = today().adding(days: -maxDays)
        return from < limit ? limit : from
    }

    /// The bank's camt URNs this client can parse (camt.052/053, versions 02 and 08), verbatim and in the bank's order.
    private func camtFormatsToRequest() -> [String] {
        let supported = ["camt.052.001.02", "camt.052.001.08", "camt.053.001.02", "camt.053.001.08"]
        return parameters.camtFormats.filter { urn in supported.contains { urn.hasSuffix($0) } }
    }

    private func camtStatements(_ dialog: FinTSDialog, version: Int, account: FinTSSEPAAccount, from: LocalDate,
                                onApproval: @Sendable (ApprovalState) -> Void) async throws -> [StatementEntry] {
        let formats = camtFormatsToRequest()
        let start = FinTSValueFormat.wireDate(earliest(from, maxDays: parameters.camtMaxDays))
        var entries: [StatementEntry] = []
        var touchdown: String?
        var seen: Set<String> = []
        repeat {
            // KTI, camt formats (one data element each), all accounts, from, to, max entries, touchdown point.
            var elements: [FinTSElement] = [Self.kti(account)]
            elements += formats.map { FinTSElement.value($0) }
            let tail: [FinTSElement] = ["N", .text(start), .empty, .empty, .text(touchdown)]
            elements += tail
            let job = FinTSSegment(type: "HKCAZ", version: version, elements: elements)
            let exchange = try await dialog.submit([job], authenticating: tanSegmentType(for: "HKCAZ"),
                                                   onApproval: onApproval)
            absorb(exchange)
            entries += try Self.camtEntries(in: exchange)
            touchdown = exchange.touchdown(for: FinTSMessageBuilder.firstSignedPayloadNumber)
            if let touchdown, !seen.insert(touchdown).inserted {
                throw FinTSError.malformedResponse("The bank repeated the touchdown point \(touchdown).")
            }
        } while touchdown != nil
        return entries
    }

    /// `HICAZ`: element 0 account, 1 camt format, 2 booked documents (binary elements, one camt document each),
    /// 3 pending documents (camt.052; forced `isPending`).
    private static func camtEntries(in exchange: FinTSExchange) throws -> [StatementEntry] {
        var entries: [StatementEntry] = []
        for segment in exchange.segments("HICAZ") {
            for (index, element) in segment.elements.enumerated() where index >= 2 {
                for data in element.components.compactMap(\.binaryValue) where !data.isEmpty {
                    do {
                        var parsed = try CamtParser.parse(data)
                        if index >= 3 { for i in parsed.indices { parsed[i].isPending = true } }
                        entries += parsed
                    } catch {
                        throw FinTSError.malformedResponse("The bank's camt document cannot be read: \(error)")
                    }
                }
            }
        }
        return entries
    }

    private func mt940Statements(_ dialog: FinTSDialog, account: FinTSSEPAAccount, from: LocalDate,
                                 onApproval: @Sendable (ApprovalState) -> Void) async throws -> [StatementEntry] {
        let version = parameters.version(of: "HIKAZS", supported: [5, 6, 7]) ?? 7
        let start = FinTSValueFormat.wireDate(earliest(from, maxDays: parameters.statementMaxDays))
        var entries: [StatementEntry] = []
        var touchdown: String?
        var seen: Set<String> = []
        repeat {
            // Account, all accounts, from, to, max entries, touchdown point.
            let job = FinTSSegment(type: "HKKAZ", version: version, elements: [
                version >= 7 ? Self.kti(account) : Self.ktv(account), "N", .text(start), .empty, .empty, .text(touchdown),
            ])
            let exchange = try await dialog.submit([job], authenticating: tanSegmentType(for: "HKKAZ"),
                                                   onApproval: onApproval)
            absorb(exchange)
            entries += try Self.mt940Entries(in: exchange)
            touchdown = exchange.touchdown(for: FinTSMessageBuilder.firstSignedPayloadNumber)
            if let touchdown, !seen.insert(touchdown).inserted {
                throw FinTSError.malformedResponse("The bank repeated the touchdown point \(touchdown).")
            }
        } while touchdown != nil
        return entries
    }

    /// `HIKAZ`: element 0 booked MT940, element 1 pending MT942.
    private static func mt940Entries(in exchange: FinTSExchange) throws -> [StatementEntry] {
        var entries: [StatementEntry] = []
        for segment in exchange.segments("HIKAZ") {
            for (index, pending) in [(0, false), (1, true)] {
                guard let data = segment.element(index)?.binaryValue, !data.isEmpty else { continue }
                do {
                    entries += try MT940Parser.parse(data, pending: pending)
                } catch {
                    throw FinTSError.malformedResponse("The bank's MT940 statement cannot be read: \(error)")
                }
            }
        }
        return entries
    }
}
