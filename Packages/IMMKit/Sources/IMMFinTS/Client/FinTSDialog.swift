import Foundation
import IMMBanking

// One FinTS dialog: the dialog id, the message counter, signing, sending, return-code handling and the strong
// customer authentication (decoupled approval) that `HKTAN` triggers.

/// What the dialog needs to know about the chosen TAN method to run `HKTAN`.
struct FinTSSCAConfiguration: Sendable, Equatable {
    /// `HKTAN` segment version (6 or 7), the `HITANS` version the bank announced.
    var tanVersion = 7
    /// *Bezeichnung des TAN-Mediums*; nil when the bank does not need one.
    var mediumName: String?
    var maxStatusRequests = 60
    var secondsBeforeFirstStatus = 5
    var secondsBetweenStatus = 2

    init() {}

    /// Defaults apply where the bank states nothing; the waits are clamped to 1…10 s so a wrong value cannot stall the
    /// dialog or hammer the bank.
    init(tanVersion: Int, mediumName: String?, method: FinTSTANMethod?) {
        self.tanVersion = (6...7).contains(tanVersion) ? tanVersion : 7
        self.mediumName = mediumName
        if let polls = method?.maxStatusRequests, polls > 0 { maxStatusRequests = polls }
        if let wait = method?.secondsBeforeFirstStatus { secondsBeforeFirstStatus = min(max(wait, 1), 10) }
        if let wait = method?.secondsBetweenStatus { secondsBetweenStatus = min(max(wait, 1), 10) }
    }
}

/// The answers to one logical request: the first answer and, when strong customer authentication ran, every status
/// answer after it (job data arrives with the last one).
struct FinTSExchange: Sendable {
    var responses: [FinTSResponse]

    func segments(_ type: String) -> [FinTSSegment] {
        responses.flatMap { $0.segments(type) }
    }

    /// The touchdown point the bank attached to request segment `number`; nil when the answer is complete.
    func touchdown(for number: Int) -> String? {
        responses.lazy.compactMap { $0.touchdown(for: number) }.first
    }
}

actor FinTSDialog {
    private let builder: FinTSMessageBuilder
    private let pin: String
    private let url: URL
    private let transport: any FinTSTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private(set) var dialogID = "0"
    private var messageNumber = 0
    private var sca = FinTSSCAConfiguration()

    init(endpoint: FinTSEndpoint, userID: String, pin: String, systemID: String, securityFunction: String,
         transport: any FinTSTransport, sleep: @escaping @Sendable (Duration) async throws -> Void,
         now: @escaping @Sendable () -> Date) {
        builder = FinTSMessageBuilder(bankCode: endpoint.bankCode, userID: userID, systemID: systemID,
                                      securityFunction: securityFunction, clock: now)
        self.pin = pin
        url = endpoint.url
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    func configure(_ configuration: FinTSSCAConfiguration) {
        sca = configuration
    }

    // MARK: Sending

    /// Signs and sends one message, then maps error return codes (9xxx) onto `FinTSError`.
    func send(_ payload: [FinTSSegment]) async throws -> FinTSResponse {
        messageNumber += 1
        let message = builder.message(dialogID: dialogID, messageNumber: messageNumber, pin: pin, payload: payload)
        let data: Data
        do {
            data = try await transport.send(message, to: url)
        } catch {
            throw FinTSError.wrapping(error)
        }
        let response: FinTSResponse
        do {
            response = try FinTSResponse(data: data)
        } catch {
            throw FinTSError.malformedResponse("\(error)")
        }
        if dialogID == "0", response.dialogID != "0" { dialogID = response.dialogID }
        if let error = FinTSReturnCodeMapper.error(in: response) { throw error }
        return response
    }

    /// Sends `payload`. With `segmentType` the message ends with `HKTAN` process 4 for that job (or for `HKIDN` when
    /// the dialog initialisation itself needs authentication) and a decoupled approval is run when the bank asks
    /// for one:
    ///
    /// - `3076`: no strong customer authentication needed.
    /// - `0030` (or `3955`) with `HITAN`: the user approves in the bank's app. `onApproval(.waiting)` is reported, the
    ///   client waits, then polls with `HKTAN` process `S` (v7) / `2` (v6) and the task reference until `3956`
    ///   ("still pending") is gone, and reports `.confirmed`.
    func submit(_ payload: [FinTSSegment], authenticating segmentType: String?,
                onApproval: @Sendable (ApprovalState) -> Void) async throws -> FinTSExchange {
        var segments = payload
        if let segmentType {
            segments.append(tanSegment(process: "4", segmentType: segmentType, mediumName: sca.mediumName))
        }
        let first = try await send(segments)
        var exchange = FinTSExchange(responses: [first])
        guard segmentType != nil else { return exchange }

        let codes = first.allCodes.map(\.code)
        if codes.contains(3076) { return exchange }
        guard codes.contains(30) || codes.contains(3955) else { return exchange }
        guard let reference = first.first("HITAN")?.string(2) else {
            throw FinTSError.malformedResponse("The bank asked for approval but sent no task reference (HITAN).")
        }

        let sentAt = now()
        onApproval(.waiting(sentAt: sentAt))
        let process = sca.tanVersion >= 7 ? "S" : "2"
        for attempt in 1...max(sca.maxStatusRequests, 1) {
            try await pause(seconds: attempt == 1 ? sca.secondsBeforeFirstStatus : sca.secondsBetweenStatus)
            let status = try await send([tanSegment(process: process, taskReference: reference)])
            exchange.responses.append(status)
            if !status.allCodes.contains(where: { $0.code == 3956 }) {
                onApproval(.confirmed(at: now()))
                return exchange
            }
        }
        throw FinTSError.approvalTimedOut(sentAt: sentAt)
    }

    /// `HKEND`; errors are ignored, the dialog is over either way.
    func end() async {
        guard dialogID != "0" else { return }
        _ = try? await send([FinTSSegment(type: "HKEND", version: 1, elements: [.value(dialogID)])])
    }

    // MARK: Helpers

    private func pause(seconds: Int) async throws {
        do {
            try await sleep(.seconds(seconds))
        } catch {
            throw FinTSError.wrapping(error)
        }
    }

    /// `HKTAN` v6/v7: process, segment type, account, job hash, task reference, further TAN follows, cancel, SMS
    /// account, challenge class, challenge class parameters, TAN medium name.
    private func tanSegment(process: String, segmentType: String? = nil, taskReference: String? = nil,
                            mediumName: String? = nil) -> FinTSSegment {
        var elements = [FinTSElement](repeating: .empty, count: 11)
        elements[0] = .value(process)
        elements[1] = .text(segmentType)
        elements[4] = .text(taskReference)
        if taskReference != nil { elements[5] = "N" }
        elements[10] = .text(mediumName)
        return FinTSSegment(type: "HKTAN", version: sca.tanVersion, elements: elements)
    }
}

// MARK: - Errors

extension FinTSError {
    /// Any error as a `FinTSError`: the client throws nothing else.
    static func wrapping(_ error: any Error) -> FinTSError {
        if let error = error as? FinTSError { return error }
        if error is CancellationError { return .transport(message: "The request was cancelled.", offline: false) }
        return .transport(message: error.localizedDescription, offline: false)
    }
}

/// Turns the 9xxx return codes of an answer into one `FinTSError`.
///
/// - PIN / login (`.pinRejected`): 9340, 9930, 9931, 9932, 9933, 9934, 9942 always; 9910 and 9050 only when the bank's
///   text names the PIN — both are generic codes banks also use for other faults, so the list is conservative.
/// - Maintenance (`.maintenance`): any error whose text says *Wartung* or *maintenance*.
/// - Everything else is `.bankRejected` with the most specific text: segment-level codes (`HIRMS`) before
///   message-level ones (`HIRMG`). 9800 (dialog aborted) keeps its code so the client can reopen the dialog.
enum FinTSReturnCodeMapper {
    static let pinCodes: Set<Int> = [9340, 9930, 9931, 9932, 9933, 9934, 9942]
    static let dialogAbortedCode = 9800

    static func error(in response: FinTSResponse) -> FinTSError? {
        let errors = response.allCodes.filter(\.isError)
        guard !errors.isEmpty else { return nil }
        let ordered = errors.filter { $0.segmentReference != nil } + errors.filter { $0.segmentReference == nil }

        if let code = ordered.first(where: isPINRejection) {
            return .pinRejected(code: code.code, message: text(of: code))
        }
        if let code = ordered.first(where: isMaintenance) {
            return .maintenance(message: text(of: code))
        }
        let primary = ordered.first { $0.code == dialogAbortedCode } ?? ordered[0]
        return .bankRejected(code: primary.code, message: text(of: primary))
    }

    private static func isPINRejection(_ code: FinTSReturnCode) -> Bool {
        if pinCodes.contains(code.code) { return true }
        return (code.code == 9910 || code.code == 9050) && mentionsPIN(code.text)
    }

    private static func isMaintenance(_ code: FinTSReturnCode) -> Bool {
        let text = code.text.lowercased()
        return text.contains("wartung") || text.contains("maintenance")
    }

    private static func mentionsPIN(_ text: String) -> Bool {
        text.range(of: #"\bpin\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func text(of code: FinTSReturnCode) -> String {
        code.text.isEmpty ? "Return code \(code.code)" : code.text
    }
}
