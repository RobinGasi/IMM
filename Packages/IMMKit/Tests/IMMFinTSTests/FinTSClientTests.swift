import Foundation
import IMMBanking
import IMMLedger
import Testing
@testable import IMMFinTS

// MARK: - Scripted bank

/// 2024-01-15 10:30:45 Europe/Berlin.
private let fixedNow = Date(timeIntervalSince1970: 1_705_311_045)
private let bankURL = URL(string: "https://bank.example/fints30")!

private let urn052 = "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08"
private let urn053 = "urn:iso:std:iso:20022:tech:xsd:camt.053.001.08"

/// One request as the bank sees it: the envelope removed, the business segments decoded.
private struct SentMessage: Sendable {
    let raw: String
    let response: FinTSResponse

    var types: [String] { response.segments.map(\.type) }
    var dialogID: String { response.dialogID }
    var messageNumber: Int? { response.messageNumber }
    func segment(_ type: String) -> FinTSSegment? { response.first(type) }
}

/// A `FinTSTransport` that answers request after request from a script and records every request. Each step names
/// the business segment types the request must contain, in order.
private final class ScriptedBank: FinTSTransport, @unchecked Sendable {
    struct Step {
        var expect: [String]
        var reply: @Sendable (SentMessage) -> Data
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var sent: [SentMessage] = []

    init(_ steps: [Step]) { self.steps = steps }

    var requests: [SentMessage] { lock.withLock { sent } }
    var remainingSteps: Int { lock.withLock { steps.count } }

    func send(_ message: Data, to url: URL) async throws -> Data {
        let request = SentMessage(raw: String(decoding: message, as: UTF8.self), response: try FinTSResponse(data: message))
        let step: Step? = lock.withLock {
            sent.append(request)
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        #expect(url == bankURL)
        guard let step else {
            Issue.record("Unscripted request with segments \(request.types)")
            throw FinTSError.transport(message: "no scripted answer", offline: false)
        }
        #expect(request.types == step.expect)
        return step.reply(request)
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    func record(_ value: Value) { lock.withLock { items.append(value) } }
    var values: [Value] { lock.withLock { items } }
}

// MARK: - Bank answers

private struct Code {
    var code: Int
    var text: String
    var params: [String]
}

private func code(_ code: Int, _ text: String = "", _ params: String...) -> Code {
    Code(code: code, text: text, params: params)
}

private func element(_ code: Code) -> FinTSElement {
    var parts: [FinTSElement] = [.value(String(format: "%04d", code.code)), .empty, .text(code.text)]
    parts += code.params.map { FinTSElement.value($0) }
    return .group(parts)
}

private func hirmg(_ codes: Code...) -> FinTSSegment {
    FinTSSegment(type: "HIRMG", version: 2, elements: codes.map(element))
}

private func hirms(_ reference: Int, _ codes: Code...) -> FinTSSegment {
    FinTSSegment(type: "HIRMS", version: 2, reference: reference, elements: codes.map(element))
}

/// The answer envelope a bank sends: `HNHBK`, `HNVSK`, `HNVSD` around the business segments, `HNHBS`.
private func bankMessage(dialog: String, number: Int, _ body: [FinTSSegment]) -> Data {
    var numbered: [FinTSSegment] = []
    for (index, segment) in body.enumerated() {
        var copy = segment
        copy.number = 3 + index
        numbered.append(copy)
    }
    let envelope: [FinTSSegment] = [
        FinTSSegment(type: "HNHBK", number: 1, version: 3, elements: [.value("000000000000"), "300", .text(dialog), .number(number)]),
        FinTSSegment(type: "HNVSK", number: 998, version: 3, elements: [.group(of: ["PIN", "2"]), "998", "1"]),
        FinTSSegment(type: "HNVSD", number: 999, version: 1, elements: [.binary(FinTSSyntax.encode(numbered))]),
        FinTSSegment(type: "HNHBS", number: 4 + body.count, version: 1, elements: [.number(number)]),
    ]
    return FinTSSyntax.encode(envelope)
}

private func hitan(reference: Int, task: String) -> FinTSSegment {
    FinTSSegment(type: "HITAN", version: 7, reference: reference,
                 elements: ["4", .empty, .text(task), "Bitte in der App freigeben"])
}

// MARK: Parameter segments

private struct MethodSpec {
    var code: String
    var name: String
    var technicalID: String
    var procedureID: String?
    var maxInput: String?
    var polls = 5
    var secondsFirst = 3
    var secondsNext = 4

    static let push = MethodSpec(code: "923", name: "pushTAN 2.0", technicalID: "pushTAN", procedureID: "Decoupled")
    static let chipTAN = MethodSpec(code: "910", name: "chipTAN manuell", technicalID: "HHD1.3.0", maxInput: "6")
    static let photoTAN = MethodSpec(code: "920", name: "photoTAN", technicalID: "HHD1.4", maxInput: "6")
}

private func hitans(version: Int = 7, _ methods: [MethodSpec]) -> FinTSSegment {
    var parts = ["J", "N", "0"]
    for method in methods {
        parts += [
            method.code, "2", method.technicalID, method.procedureID ?? "", "", method.name, method.maxInput ?? "",
            "1", "", "", "N", "2", "N", "N", "N", "0", "N", "N", "00", "0", "N", "1",
        ]
        if version >= 7 {
            parts += [String(method.polls), String(method.secondsFirst), String(method.secondsNext), "N", "J"]
        }
    }
    return FinTSSegment(type: "HITANS", version: version, elements: ["1", "1", "2", .group(of: parts)])
}

private func parameterSegment(_ type: String, version: Int, _ parameters: [String]) -> FinTSSegment {
    FinTSSegment(type: type, version: version, elements: ["1", "1", "1", .group(of: parameters)])
}

private func hipins(required: Set<String>) -> FinTSSegment {
    var parts = ["5", "20", "6", "Benutzerkennung", "Kunden-ID"]
    for job in ["HKSPA", "HKSAL", "HKCAZ", "HKKAZ"] { parts += [job, required.contains(job) ? "J" : "N"] }
    return parameterSegment("HIPINS", version: 1, parts)
}

private func hiupd(number: String, iban: String, type: Int, product: String) -> FinTSSegment {
    var elements: [FinTSElement] = [
        .group(of: [number, "", "280", "12345678"]), .text(iban), "testuser", .number(type), "EUR", "Max Mustermann",
        .empty, .text(product), .empty,
    ]
    elements += ["HKSAK", "HKSAL", "HKKAZ"].map { FinTSElement.group(of: [$0, "1"]) }
    return FinTSSegment(type: "HIUPD", version: 6, elements: elements)
}

/// BPD and UPD as a bank sends them in the first answer of a dialog.
private func bpd(methods: [MethodSpec] = [.push, .chipTAN], tanRequired: Set<String> = [], camt: Bool = false,
                 spa: Bool = true) -> [FinTSSegment] {
    var segments: [FinTSSegment] = [
        FinTSSegment(type: "HIBPA", version: 3, elements: ["1", .group(of: ["280", "12345678"]), "Testbank"]),
        hitans(methods),
        hipins(required: tanRequired),
        parameterSegment("HISALS", version: 7, ["365", "N", "N"]),
        parameterSegment("HIKAZS", version: 7, ["90", "N", "N"]),
    ]
    if spa { segments.append(parameterSegment("HISPAS", version: 1, ["J", "J", "N", "N"])) }
    if camt { segments.append(parameterSegment("HICAZS", version: 1, ["365", "N", "J", urn052, urn053])) }
    segments += [
        FinTSSegment(type: "HIUPA", version: 4, elements: ["testuser", "3", "1"]),
        hiupd(number: "1234567", iban: "DE02120300000000202051", type: 1, product: "Girokonto"),
        hiupd(number: "9876543", iban: "DE89370400440532013000", type: 51, product: "Visa Card"),
    ]
    return segments
}

private let hisyn = FinTSSegment(type: "HISYN", version: 4, reference: 5, elements: ["SYS42"])

// MARK: Steps

private func step(_ expect: [String], _ reply: @escaping @Sendable (SentMessage) -> Data) -> ScriptedBank.Step {
    ScriptedBank.Step(expect: expect, reply: reply)
}

/// A request inside an open dialog.
private func jobStep(_ expect: [String], dialog: String = "DLG1",
                     _ body: @escaping @Sendable (SentMessage) -> [FinTSSegment]) -> ScriptedBank.Step {
    step(expect) { request in
        #expect(request.dialogID == dialog)
        return bankMessage(dialog: dialog, number: request.messageNumber ?? 1, body(request))
    }
}

/// Synchronisation dialog (one-step function 999) followed by its `HKEND`.
private func syncSteps(methods: [MethodSpec] = [.push, .chipTAN], allowed: [String] = ["910", "923"]) -> [ScriptedBank.Step] {
    [
        step(["HKIDN", "HKVVB", "HKSYN"]) { request in
            #expect(request.dialogID == "0")
            #expect(request.messageNumber == 1)
            #expect(request.raw.contains("HNSHK:2:4+PIN:1+999+"))
            let identification = request.segment("HKIDN")
            #expect(identification?.string(0, component: 1) == "12345678")
            #expect(identification?.string(1) == "testuser")
            #expect(identification?.string(2) == "0")
            #expect(request.segment("HKVVB")?.string(3) == "IMM-TEST")
            #expect(request.segment("HKVVB")?.string(4) == "0.1")
            #expect(request.segment("HKSYN")?.string(0) == "0")
            let body = [
                hirmg(code(10, "Nachricht entgegengenommen"),
                      Code(code: 3920, text: "Zugelassene Zwei-Schritt-Verfahren", params: allowed)),
                hirms(3, code(20, "Auftrag ausgefuehrt")),
            ] + bpd(methods: methods) + [hisyn]
            return bankMessage(dialog: "SYNC", number: 1, body)
        },
        step(["HKEND"]) { request in
            #expect(request.dialogID == "SYNC")
            #expect(request.segment("HKEND")?.string(0) == "SYNC")
            return bankMessage(dialog: "SYNC", number: 2, [hirmg(code(10, "Dialog beendet"))])
        },
    ]
}

/// Dialog initialisation with the chosen function; `body` builds the answer.
private func initStep(function: String = "923", systemID: String = "SYS42",
                      _ body: @escaping @Sendable (SentMessage) -> [FinTSSegment]) -> ScriptedBank.Step {
    step(["HKIDN", "HKVVB", "HKTAN"]) { request in
        #expect(request.dialogID == "0")
        #expect(request.messageNumber == 1)
        #expect(request.raw.contains("HNSHK:2:4+PIN:2+\(function)+"))
        #expect(request.segment("HKIDN")?.string(2) == systemID)
        let tan = request.segment("HKTAN")
        #expect(tan?.version == 7)
        #expect(tan?.string(0) == "4")
        #expect(tan?.string(1) == "HKIDN")
        #expect(tan?.number == FinTSMessageBuilder.firstSignedPayloadNumber + 2)
        return bankMessage(dialog: "DLG1", number: 1, body(request))
    }
}

/// The answer of a bank that needs no strong customer authentication for the dialog: `3076`, plus BPD/UPD.
private func openAnswer(_ parameters: [FinTSSegment]) -> @Sendable (SentMessage) -> [FinTSSegment] {
    { _ in [hirmg(code(10, "Nachricht entgegengenommen")), hirms(5, code(3076, "Keine starke Kundenauthentifizierung notwendig"))] + parameters }
}

private func endStep(dialog: String = "DLG1") -> ScriptedBank.Step {
    jobStep(["HKEND"], dialog: dialog) { request in
        #expect(request.segment("HKEND")?.string(0) == dialog)
        return [hirmg(code(10, "Dialog beendet"))]
    }
}

/// A `HKTAN` status request; `pending` answers `3956`, else `0020`.
private func pollStep(task: String, pending: Bool, extra: [FinTSSegment] = [], expectedMessageNumber: Int? = nil) -> ScriptedBank.Step {
    jobStep(["HKTAN"]) { request in
        let tan = request.segment("HKTAN")
        #expect(tan?.string(0) == "S")
        #expect(tan?.string(4) == task)
        #expect(tan?.string(5) == "N")
        if let expectedMessageNumber { #expect(request.messageNumber == expectedMessageNumber) }
        let status = pending
            ? hirms(3, code(3956, "Starke Kundenauthentifizierung noch ausstehend"))
            : hirms(3, code(20, "Auftrag ausgefuehrt"))
        return [hirmg(code(10, "Nachricht entgegengenommen")), status] + extra
    }
}

// MARK: Fixtures and harness

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
}

private let girokonto = FinTSSEPAAccount(
    iban: "DE02120300000000202051", bic: "BYLADEM1001", accountNumber: "1234567", subaccount: nil, bankCode: "12345678",
    productName: "Girokonto", ownerName: "Max Mustermann", currency: "EUR", accountType: 1)

private struct Harness {
    let bank: ScriptedBank
    let store: InMemoryFinTSStateStore
    let sleeps: Recorder<Duration>
    let approvals: Recorder<ApprovalState>
    let client: FinTSClient

    func accounts() async throws -> [FinTSSEPAAccount] {
        let log = approvals
        return try await client.accounts { log.record($0) }
    }

    func balance(of account: FinTSSEPAAccount) async throws -> FinTSBalance {
        let log = approvals
        return try await client.balance(of: account) { log.record($0) }
    }

    func statements(of account: FinTSSEPAAccount, from: LocalDate) async throws -> [StatementEntry] {
        let log = approvals
        return try await client.statements(of: account, from: from) { log.record($0) }
    }
}

/// `stored`: the system id and TAN method are already known, so no synchronisation dialog runs.
private func harness(_ steps: [ScriptedBank.Step], stored: Bool = true, productID: String = "IMM-TEST") -> Harness {
    let store = InMemoryFinTSStateStore()
    if stored {
        store.setSystemID("SYS42", bankCode: "12345678", loginName: "testuser")
        store.setTANMethod("923", bankCode: "12345678", loginName: "testuser")
    }
    let bank = ScriptedBank(steps)
    let sleeps = Recorder<Duration>()
    let client = FinTSClient(
        endpoint: FinTSEndpoint(bankCode: "12345678", url: bankURL),
        user: FinTSUser(loginName: "testuser", pin: "12345"),
        product: FinTSProduct(id: productID, version: "0.1"),
        stateStore: store, transport: bank,
        sleep: { sleeps.record($0) },
        now: { fixedNow })
    return Harness(bank: bank, store: store, sleeps: sleeps, approvals: Recorder<ApprovalState>(), client: client)
}

private let expectedAccounts = [
    FinTSSEPAAccount(iban: "DE02120300000000202051", bic: "BYLADEM1001", accountNumber: "1234567", subaccount: nil,
                     bankCode: "12345678", productName: "Girokonto", ownerName: "Max Mustermann", currency: "EUR",
                     accountType: 1),
    FinTSSEPAAccount(iban: "DE89370400440532013000", bic: "COBADEFFXXX", accountNumber: "9876543", subaccount: nil,
                     bankCode: "12345678", productName: "Visa Card", ownerName: "Max Mustermann", currency: "EUR",
                     accountType: 51),
]

private let hispa = FinTSSegment(type: "HISPA", version: 1, reference: 3, elements: [
    .group(of: ["J", "DE02120300000000202051", "BYLADEM1001", "1234567", "", "280", "12345678"]),
    .group(of: ["J", "DE89370400440532013000", "COBADEFFXXX", "9876543", "", "280", "12345678"]),
])

private func accountsStep() -> ScriptedBank.Step {
    jobStep(["HKSPA"]) { _ in [hirmg(code(10, "ok")), hirms(3, code(20, "Auftrag ausgefuehrt")), hispa] }
}

// MARK: - Tests

@Suite struct FinTSClientTests {
    // MARK: 1. First use

    @Test func firstUseSynchronisesStoresSystemIDAndTANMethodThenListsAccounts() async throws {
        let h = harness(
            syncSteps()
                + [
                    initStep(openAnswer([])),
                    jobStep(["HKSPA"]) { request in
                        #expect(request.messageNumber == 2)
                        #expect(request.segment("HKSPA")?.version == 1)
                        #expect(request.segment("HKSPA")?.elements.isEmpty == true)
                        return [hirmg(code(10, "ok")), hirms(3, code(20, "Auftrag ausgefuehrt")), hispa]
                    },
                    endStep(),
                ],
            stored: false)

        #expect(await h.client.tanMethodName() == nil)
        let accounts = try await h.accounts()
        #expect(accounts == expectedAccounts)

        #expect(h.store.systemID(bankCode: "12345678", loginName: "testuser") == "SYS42")
        #expect(h.store.tanMethod(bankCode: "12345678", loginName: "testuser") == "923")
        #expect(await h.client.tanMethodName() == "pushTAN 2.0")
        // No decoupled approval: nothing reported, nothing slept.
        #expect(h.approvals.values.isEmpty)
        #expect(h.sleeps.values.isEmpty)

        await h.client.close()
        await h.client.close()
        #expect(h.bank.remainingSteps == 0)
        #expect(h.bank.requests.count == 5)
    }

    // MARK: 2. Decoupled approval

    @Test func decoupledApprovalPollsWithBankTimings() async throws {
        let h = harness(
            syncSteps()
                + [
                    initStep { _ in
                        [hirmg(code(10, "ok")), hirms(5, code(30, "Auftrag empfangen - Sicherheitsfreigabe erforderlich")),
                         hitan(reference: 5, task: "REF123")]
                    },
                    pollStep(task: "REF123", pending: true, expectedMessageNumber: 2),
                    pollStep(task: "REF123", pending: true, expectedMessageNumber: 3),
                    pollStep(task: "REF123", pending: false, expectedMessageNumber: 4),
                    jobStep(["HKSPA"]) { request in
                        #expect(request.messageNumber == 5)
                        return [hirmg(code(10, "ok")), hirms(3, code(20, "Auftrag ausgefuehrt")), hispa]
                    },
                    endStep(),
                ],
            stored: false)

        let accounts = try await h.accounts()
        #expect(accounts == expectedAccounts)
        #expect(h.approvals.values == [.waiting(sentAt: fixedNow), .confirmed(at: fixedNow)])
        // HITANS v7: 3 s before the first status request, 4 s between the following ones.
        #expect(h.sleeps.values == [.seconds(3), .seconds(4), .seconds(4)])

        await h.client.close()
        #expect(h.bank.remainingSteps == 0)
    }

    // MARK: 3. Approval timeout

    @Test func approvalTimesOutAfterTheBankMaximum() async throws {
        let pending = (0..<5).map { _ in pollStep(task: "REF123", pending: true) }
        let h = harness(
            syncSteps()
                + [
                    initStep { _ in
                        [hirmg(code(10, "ok")), hirms(5, code(30, "Sicherheitsfreigabe erforderlich")),
                         hitan(reference: 5, task: "REF123")]
                    },
                ]
                + pending
                + [endStep()],
            stored: false)

        await #expect(throws: FinTSError.approvalTimedOut(sentAt: fixedNow)) {
            try await h.accounts()
        }
        #expect(h.approvals.values == [.waiting(sentAt: fixedNow)])
        // HITANS announces at most 5 status requests.
        #expect(h.sleeps.values == [.seconds(3), .seconds(4), .seconds(4), .seconds(4), .seconds(4)])
        #expect(h.bank.remainingSteps == 0)
    }

    // MARK: 4. HKCAZ with touchdown

    @Test func camtStatementsFollowTouchdownAcrossTwoPages() async throws {
        let booked1 = try fixture("camt053-v02.xml")
        let booked2 = try fixture("camt053-v08.xml")
        let pendingDocument = try fixture("camt052-pending.xml")
        let kti = FinTSElement.group(of: ["DE02120300000000202051", "BYLADEM1001", "1234567", "", "280", "12345678"])

        let h = harness([
            initStep(openAnswer(bpd(camt: true))),
            jobStep(["HKCAZ"]) { request in
                #expect(request.messageNumber == 2)
                let job = request.segment("HKCAZ")
                #expect(job?.version == 1)
                #expect(job?.string(0, component: 0) == "DE02120300000000202051")
                #expect(job?.string(1) == urn052)
                #expect(job?.string(2) == urn053)
                #expect(job?.string(3) == "N")
                #expect(job?.string(4) == "20240101")
                #expect(job?.elements.count == 5)
                return [
                    hirmg(code(10, "ok")),
                    hirms(3, code(20, "Auftrag ausgefuehrt"), code(3040, "Es liegen weitere Informationen vor", "TD1")),
                    FinTSSegment(type: "HICAZ", version: 1, reference: 3, elements: [kti, .value(urn053), .binary(booked1)]),
                ]
            },
            jobStep(["HKCAZ"]) { request in
                #expect(request.messageNumber == 3)
                let job = request.segment("HKCAZ")
                #expect(job?.elements.count == 8)
                #expect(job?.string(7) == "TD1")
                return [
                    hirmg(code(10, "ok")),
                    hirms(3, code(20, "Auftrag ausgefuehrt")),
                    FinTSSegment(type: "HICAZ", version: 1, reference: 3, elements: [
                        kti, .value(urn053), .group([.binary(booked2)]), .binary(pendingDocument),
                    ]),
                ]
            },
            endStep(),
        ])

        let entries = try await h.statements(of: girokonto, from: LocalDate(year: 2024, month: 1, day: 1))

        let first = try CamtParser.parse(booked1)
        let second = try CamtParser.parse(booked2)
        let pending = try CamtParser.parse(pendingDocument).map { entry -> StatementEntry in
            var copy = entry
            copy.isPending = true
            return copy
        }
        #expect(entries == first + second + pending)
        #expect(entries.count == 4 + 2 + 3)
        #expect(entries.prefix(6).allSatisfy { !$0.isPending })
        #expect(entries.suffix(3).allSatisfy { $0.isPending })

        await h.client.close()
        #expect(h.bank.remainingSteps == 0)
    }

    // MARK: 5. HKKAZ fallback

    @Test func mt940FallbackWhenTheBankHasNoCamt() async throws {
        let booked = try fixture("mt940-sparkasse.sta")
        let pendingBlob = try fixture("mt942-pending.sta")

        let h = harness([
            initStep(openAnswer(bpd(camt: false))),
            jobStep(["HKKAZ"]) { request in
                let job = request.segment("HKKAZ")
                #expect(job?.version == 7)
                #expect(job?.string(0, component: 0) == "DE02120300000000202051")
                #expect(job?.string(1) == "N")
                #expect(job?.string(2) == "20240101")
                #expect(job?.elements.count == 3)
                return [
                    hirmg(code(10, "ok")),
                    hirms(3, code(20, "Auftrag ausgefuehrt")),
                    FinTSSegment(type: "HIKAZ", version: 7, reference: 3, elements: [.binary(booked), .binary(pendingBlob)]),
                ]
            },
            endStep(),
        ])

        let entries = try await h.statements(of: girokonto, from: LocalDate(year: 2024, month: 1, day: 1))
        let expected = try MT940Parser.parse(booked, pending: false) + MT940Parser.parse(pendingBlob, pending: true)
        #expect(entries == expected)
        #expect(entries.count == 4 + 2)
        #expect(entries.prefix(4).allSatisfy { !$0.isPending })
        #expect(entries.suffix(2).allSatisfy { $0.isPending })

        await h.client.close()
        #expect(h.bank.remainingSteps == 0)
    }

    // MARK: 6. HKSAL

    @Test func balanceParsesCreditAndDebitWithPendingAndCreditLine() async throws {
        let kti = FinTSElement.group(of: ["DE02120300000000202051", "BYLADEM1001", "1234567", "", "280", "12345678"])
        let h = harness([
            initStep(openAnswer(bpd())),
            jobStep(["HKSAL"]) { request in
                let job = request.segment("HKSAL")
                #expect(job?.version == 7)
                #expect(job?.string(0, component: 0) == "DE02120300000000202051")
                #expect(job?.string(1) == "N")
                return [
                    hirmg(code(10, "ok")),
                    hirms(3, code(20, "Auftrag ausgefuehrt")),
                    FinTSSegment(type: "HISAL", version: 7, reference: 3, elements: [
                        kti, "Girokonto", "EUR",
                        .group(of: ["C", "1234,56", "EUR", "20240115", "103000"]),
                        .group(of: ["C", "100,", "EUR", "20240115"]),
                        .group(of: ["500,", "EUR"]),
                    ]),
                ]
            },
            jobStep(["HKSAL"]) { _ in
                [
                    hirmg(code(10, "ok")),
                    hirms(3, code(20, "Auftrag ausgefuehrt")),
                    FinTSSegment(type: "HISAL", version: 7, reference: 3, elements: [
                        kti, "Girokonto", "EUR",
                        .group(of: ["D", "50,5", "EUR", "20240114"]),
                        .group(of: ["D", "0,01", "EUR", "20240115"]),
                    ]),
                ]
            },
            endStep(),
        ])

        let credit = try await h.balance(of: girokonto)
        #expect(credit == FinTSBalance(booked: 123_456, currency: "EUR", date: LocalDate(year: 2024, month: 1, day: 15),
                                       pending: 10_000, creditLine: 50_000))
        let debit = try await h.balance(of: girokonto)
        #expect(debit == FinTSBalance(booked: -5_050, currency: "EUR", date: LocalDate(year: 2024, month: 1, day: 14),
                                      pending: -1, creditLine: nil))

        await h.client.close()
        #expect(h.bank.remainingSteps == 0)
    }

    // MARK: 7. Errors

    @Test func wrongPINIsRejected() async throws {
        let h = harness([
            initStep { _ in [hirmg(code(9931, "PIN gesperrt"))] },
        ])
        await #expect(throws: FinTSError.pinRejected(code: 9931, message: "PIN gesperrt")) {
            try await h.accounts()
        }
        // No `HKEND` for a dialog the bank refused.
        #expect(h.bank.requests.count == 1)
        #expect(h.bank.remainingSteps == 0)
    }

    @Test func onlyTANMethodsThatNeedInputAreUnsupported() async throws {
        let h = harness(syncSteps(methods: [.chipTAN, .photoTAN], allowed: ["910", "920"]), stored: false)
        await #expect(throws: FinTSError.unsupportedTANMethods(["chipTAN manuell", "photoTAN"])) {
            try await h.accounts()
        }
        #expect(h.bank.remainingSteps == 0)
        #expect(h.store.systemID(bankCode: "12345678", loginName: "testuser") == "SYS42")
        #expect(h.store.tanMethod(bankCode: "12345678", loginName: "testuser") == nil)
    }

    @Test func emptyProductIDFailsBeforeAnyRequest() async throws {
        let h = harness([], productID: "")
        await #expect(throws: FinTSError.productNotRegistered) {
            try await h.accounts()
        }
        await #expect(throws: FinTSError.productNotRegistered) {
            try await h.balance(of: girokonto)
        }
        #expect(h.bank.requests.isEmpty)
    }

    @Test func maintenanceAndSegmentErrorsAreMapped() async throws {
        let maintenance = try FinTSResponse(data: bankMessage(dialog: "0", number: 1, [
            hirmg(code(9050, "Die Nachricht enthaelt Fehler."), code(9010, "Wegen Wartungsarbeiten nicht erreichbar")),
        ]))
        #expect(FinTSReturnCodeMapper.error(in: maintenance) == .maintenance(message: "Wegen Wartungsarbeiten nicht erreichbar"))

        // The segment-level text wins over the generic message-level one.
        let rejected = try FinTSResponse(data: bankMessage(dialog: "D", number: 2, [
            hirmg(code(9050, "Die Nachricht enthaelt Fehler.")),
            hirms(3, code(9210, "Auftrag nicht zulaessig")),
        ]))
        #expect(FinTSReturnCodeMapper.error(in: rejected) == .bankRejected(code: 9210, message: "Auftrag nicht zulaessig"))

        // 9910 is a PIN problem only when the text says so.
        let generic = try FinTSResponse(data: bankMessage(dialog: "D", number: 3, [hirmg(code(9910, "Fehler im Auftrag"))]))
        #expect(FinTSReturnCodeMapper.error(in: generic) == .bankRejected(code: 9910, message: "Fehler im Auftrag"))
        let pin = try FinTSResponse(data: bankMessage(dialog: "D", number: 4, [hirmg(code(9910, "PIN ungueltig"))]))
        #expect(FinTSReturnCodeMapper.error(in: pin) == .pinRejected(code: 9910, message: "PIN ungueltig"))
    }

    // MARK: 8. Stored system id

    @Test func storedSystemIDSkipsTheSynchronisation() async throws {
        // No HISPAS: the accounts come from HIUPD, so the initialisation is the only request.
        let h = harness([initStep(openAnswer(bpd(spa: false)))])
        let accounts = try await h.accounts()

        #expect(accounts.map(\.iban) == ["DE02120300000000202051", "DE89370400440532013000"])
        #expect(accounts.map(\.productName) == ["Girokonto", "Visa Card"])
        #expect(accounts.map(\.accountType) == [1, 51])
        #expect(h.bank.requests.count == 1)
        #expect(!h.bank.requests.contains { $0.types.contains("HKSYN") })
        #expect(await h.client.tanMethodName() == "pushTAN 2.0")
        #expect(h.bank.remainingSteps == 0)
    }

    // MARK: Further behaviour

    @Test func jobNeedingATANAttachesHKTANAndReadsTheResultFromTheStatusAnswer() async throws {
        let kti = FinTSElement.group(of: ["DE02120300000000202051", "BYLADEM1001", "1234567", "", "280", "12345678"])
        let h = harness([
            initStep(openAnswer(bpd(tanRequired: ["HKSAL"]))),
            jobStep(["HKSAL", "HKTAN"]) { request in
                let tan = request.segment("HKTAN")
                #expect(tan?.string(0) == "4")
                #expect(tan?.string(1) == "HKSAL")
                #expect(tan?.number == request.segment("HKSAL").map { $0.number + 1 })
                return [hirmg(code(10, "ok")), hirms(4, code(30, "Sicherheitsfreigabe erforderlich")),
                        hitan(reference: 4, task: "REF9")]
            },
            pollStep(task: "REF9", pending: false, extra: [
                FinTSSegment(type: "HISAL", version: 7, reference: 3, elements: [
                    kti, "Girokonto", "EUR", .group(of: ["C", "10,", "EUR", "20240115"]),
                ]),
            ]),
            endStep(),
        ])

        let balance = try await h.balance(of: girokonto)
        #expect(balance.booked == 1_000)
        #expect(h.approvals.values == [.waiting(sentAt: fixedNow), .confirmed(at: fixedNow)])
        #expect(h.sleeps.values == [.seconds(3)])

        await h.client.close()
        #expect(h.bank.remainingSteps == 0)
    }

    @Test func aDialogTheBankEndedIsReopenedOnce() async throws {
        let h = harness([
            initStep(openAnswer(bpd())),
            jobStep(["HKSPA"]) { _ in [hirmg(code(9800, "Dialog abgebrochen"))] },
            initStep(openAnswer(bpd())),
            accountsStep(),
            endStep(),
        ])
        let accounts = try await h.accounts()
        #expect(accounts == expectedAccounts)
        await h.client.close()
        #expect(h.bank.remainingSteps == 0)
    }

    @Test func version6TANMethodsAreDecoupledWhenTheyTakeNoInput() throws {
        var parameters = FinTSParameters()
        let silent = MethodSpec(code: "942", name: "App-Freigabe", technicalID: "AppTAN")
        let response = try FinTSResponse(data: bankMessage(dialog: "D", number: 1, [
            hitans(version: 6, [.chipTAN, silent]),
        ]))
        parameters.absorb(response)

        #expect(parameters.tanVersion == 6)
        #expect(parameters.tanMethods.map(\.securityFunction) == ["910", "942"])
        #expect(parameters.tanMethods.map(\.isDecoupled) == [false, true])
        #expect(parameters.tanMethods.allSatisfy { $0.maxStatusRequests == nil })
    }

    @Test func version7TANMethodsReadDecoupledTimings() throws {
        var parameters = FinTSParameters()
        let response = try FinTSResponse(data: bankMessage(dialog: "D", number: 1, [hitans([.chipTAN, .push])]))
        parameters.absorb(response)

        #expect(parameters.tanMethods.map(\.name) == ["chipTAN manuell", "pushTAN 2.0"])
        let push = try #require(parameters.tanMethod(code: "923"))
        #expect(push.isDecoupled)
        #expect(push.supportsProcess4)
        #expect(push.maxStatusRequests == 5)
        #expect(push.secondsBeforeFirstStatus == 3)
        #expect(push.secondsBetweenStatus == 4)
        #expect(parameters.tanMethod(code: "910")?.isDecoupled == false)
    }

    @Test func amountsParseToExactMinorUnits() {
        #expect(FinTSValueFormat.minorUnits("1234,56") == 123_456)
        #expect(FinTSValueFormat.minorUnits("0,05") == 5)
        #expect(FinTSValueFormat.minorUnits("12,3") == 1_230)
        #expect(FinTSValueFormat.minorUnits("12,") == 1_200)
        #expect(FinTSValueFormat.minorUnits("12") == 1_200)
        #expect(FinTSValueFormat.minorUnits("12,345") == nil)
        #expect(FinTSValueFormat.minorUnits("1.5") == nil)
        #expect(FinTSValueFormat.minorUnits("") == nil)
    }
}
