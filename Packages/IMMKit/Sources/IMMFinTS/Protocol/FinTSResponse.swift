import Foundation

/// A problem with the message structure of a bank response (as opposed to its byte syntax, ``FinTSSyntaxError``).
public enum FinTSResponseError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The message does not start with `HNHBK`.
    case missingMessageHeader
    /// An `HNVSD` segment carries no binary payload.
    case malformedEncryptedData

    public var description: String {
        switch self {
        case .missingMessageHeader: "FinTS response does not start with HNHBK"
        case .malformedEncryptedData: "FinTS response has an HNVSD segment without binary content"
        }
    }
}

/// One entry of `HIRMG` (message level) or `HIRMS` (segment level): `code:elementReference:text[:parameter…]`.
public struct FinTSReturnCode: Sendable, Hashable {
    /// Four-digit code. 0xxx success, 3xxx warning, 9xxx error.
    public var code: Int
    /// *Bezugselement*: position of the element the code refers to; nil when absent.
    public var elementReference: String?
    /// Human-readable text in the bank's language.
    public var text: String
    /// *Rückmeldungsparameter*, for example the touchdown point of code 3040 or the TAN methods of code 3920.
    public var parameters: [String]
    /// For `HIRMS`: the number of the request segment the code answers; nil for `HIRMG`.
    public var segmentReference: Int?

    public init(code: Int, elementReference: String? = nil, text: String = "", parameters: [String] = [],
                segmentReference: Int? = nil) {
        self.code = code
        self.elementReference = elementReference
        self.text = text
        self.parameters = parameters
        self.segmentReference = segmentReference
    }

    /// True for codes 9000–9999.
    public var isError: Bool { (9000...9999).contains(code) }
    /// True for codes 3000–3999.
    public var isWarning: Bool { (3000...3999).contains(code) }

    /// Parses one data element of a return-code segment; nil when it carries no numeric code.
    init?(element: FinTSElement, segmentReference: Int?) {
        guard let code = element.component(0).flatMap({ Int($0) }) else { return nil }
        let parts = element.components
        self.code = code
        self.elementReference = element.component(1)
        self.text = element.component(2) ?? ""
        self.parameters = parts.dropFirst(3).map { $0.string ?? "" }
        self.segmentReference = segmentReference
    }
}

/// A bank response with the message envelope removed.
///
/// `HNHBK`, `HNVSK`, `HNVSD`, `HNHBS` and the signature segments `HNSHK`/`HNSHA` are dropped; the segments carried
/// inside `HNVSD` take the place of the `HNVSD` segment. A response without `HNVSD` (anonymous or error replies)
/// passes its segments through.
public struct FinTSResponse: Sendable {
    /// Dialog id from `HNHBK`; the bank assigns it in the first answer of a dialog (`"0"` if the dialog was refused).
    public let dialogID: String
    /// Message number from `HNHBK`, nil if absent or not numeric.
    public let messageNumber: Int?
    /// Business segments in message order, envelope removed.
    public let segments: [FinTSSegment]
    /// Every return code in message order: `HIRMG` entries and `HIRMS` entries.
    public let allCodes: [FinTSReturnCode]

    private static let envelope: Set<String> = ["HNHBK", "HNVSK", "HNVSD", "HNHBS", "HNSHK", "HNSHA"]

    /// - Throws: ``FinTSSyntaxError`` for malformed bytes, ``FinTSResponseError`` for a malformed envelope.
    public init(data: Data) throws {
        let outer = try FinTSSyntax.decode(data)
        guard let header = outer.first, header.type == "HNHBK" else { throw FinTSResponseError.missingMessageHeader }
        dialogID = header.string(2) ?? "0"
        messageNumber = header.string(3).flatMap { Int($0) }

        var unwrapped: [FinTSSegment] = []
        for segment in outer {
            if segment.type == "HNVSD" {
                guard let payload = segment.element(0)?.binaryValue else { throw FinTSResponseError.malformedEncryptedData }
                unwrapped += try FinTSSyntax.decode(payload)
            } else {
                unwrapped.append(segment)
            }
        }
        let business = unwrapped.filter { !Self.envelope.contains($0.type) }
        segments = business

        var codes: [FinTSReturnCode] = []
        for segment in business {
            let reference: Int?
            switch segment.type {
            case "HIRMG": reference = nil
            case "HIRMS": reference = segment.reference
            default: continue
            }
            codes += segment.elements.compactMap { FinTSReturnCode(element: $0, segmentReference: reference) }
        }
        allCodes = codes
    }

    /// All segments of `type`, in message order.
    public func segments(_ type: String) -> [FinTSSegment] {
        segments.filter { $0.type == type }
    }

    /// The first segment of `type`.
    public func first(_ type: String) -> FinTSSegment? {
        segments.first { $0.type == type }
    }

    /// Message-level codes (`HIRMG`).
    public var globalCodes: [FinTSReturnCode] {
        allCodes.filter { $0.segmentReference == nil }
    }

    /// Codes (`HIRMS`) answering the request segment with this number.
    public func segmentCodes(for segmentNumber: Int) -> [FinTSReturnCode] {
        allCodes.filter { $0.segmentReference == segmentNumber }
    }

    /// True when any code is in 9000–9999.
    public var hasError: Bool {
        allCodes.contains { $0.isError }
    }

    /// The touchdown point (*Aufsetzpunkt*, code 3040, first parameter) the bank sent for the request segment, which
    /// must be passed back to fetch the next chunk; nil when the answer is complete.
    public func touchdown(for segmentNumber: Int) -> String? {
        segmentCodes(for: segmentNumber).first { $0.code == 3040 }?.parameters.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// TAN method codes the user may use (code 3920 parameters), in the bank's order; empty when none were sent.
    public var allowedSecurityFunctions: [String] {
        allCodes.filter { $0.code == 3920 }.flatMap(\.parameters).filter { !$0.isEmpty }
    }
}
