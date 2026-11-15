import Foundation

/// Builds complete FinTS 3.0 PIN/TAN request messages around business segments.
///
/// A signed message (FinTS 3.0 *Sicherheitsverfahren PIN/TAN*) is laid out as:
///
///     HNHBK  message header (number 1, carries the total byte length)
///     HNVSK  encryption header (998), a dummy: PIN/TAN messages are not encrypted, only TLS protects them
///     HNVSD  encrypted data (999), a binary element holding, in order:
///       HNSHK  signature header (2)
///       …      payload segments, numbered from 3
///       HNSHA  signature trailer, carries PIN and TAN
///     HNHBS  message trailer
///
/// The security profile is `PIN:1` for the one-step method (function `999`) and `PIN:2` for any two-step method
/// (function `9xx`, the TAN method code from `HIRMS 3920`).
public struct FinTSMessageBuilder: Sendable {
    /// Bank code (*Bankleitzahl*) written into the key names.
    public var bankCode: String
    /// *Benutzerkennung*, written into the key names.
    public var userID: String
    /// System id from the synchronisation dialog; `"0"` before the first sync.
    public var systemID: String
    /// `"999"` for the one-step method, otherwise the TAN method code such as `"921"`.
    public var securityFunction: String
    /// Source of the security timestamp (`HNVSK`, `HNSHK`). Injected for deterministic tests.
    public var clock: @Sendable () -> Date
    /// Source of the signature control reference (*Sicherheitskontrollreferenz*) shared by `HNSHK` and `HNSHA`.
    /// Called once per signed message. Default: a random seven-digit number.
    public var securityReference: @Sendable () -> String

    /// Number of the first payload segment in a signed message (`HNHBK` is 1, `HNSHK` is 2).
    public static let firstSignedPayloadNumber = 3
    /// Number of the first payload segment in an anonymous message (`HNHBK` is 1).
    public static let firstAnonymousPayloadNumber = 2

    public init(
        bankCode: String,
        userID: String,
        systemID: String = "0",
        securityFunction: String = "999",
        clock: @escaping @Sendable () -> Date = { Date() },
        securityReference: @escaping @Sendable () -> String = { String(Int.random(in: 1_000_000...9_999_999)) }
    ) {
        self.bankCode = bankCode
        self.userID = userID
        self.systemID = systemID
        self.securityFunction = securityFunction
        self.clock = clock
        self.securityReference = securityReference
    }

    /// A signed PIN/TAN message.
    ///
    /// - Parameters:
    ///   - dialogID: `"0"` to open a new dialog, otherwise the id the bank assigned.
    ///   - messageNumber: Counts from 1 within a dialog.
    ///   - pin: The PIN, sent in `HNSHA`.
    ///   - tan: The TAN for a pending two-step order, sent as second component in `HNSHA`.
    ///   - payload: Business segments; their `number` is overwritten, counting from ``firstSignedPayloadNumber``.
    ///     `reference` and elements are kept.
    /// - Returns: The message bytes. The 12-digit length in `HNHBK` equals the byte count.
    public func message(dialogID: String = "0", messageNumber: Int, pin: String, tan: String? = nil,
                        payload: [FinTSSegment]) -> Data {
        let (date, time) = Self.timestamp(clock())
        let reference = securityReference()
        let profile = FinTSElement.group(of: ["PIN", securityFunction == "999" ? "1" : "2"])
        let sender = FinTSElement.group(of: ["1", nil, systemID])
        let stamp = FinTSElement.group(of: ["1", date, time])

        var signedSegments: [FinTSSegment] = []
        signedSegments.reserveCapacity(payload.count + 2)
        signedSegments.append(FinTSSegment(type: "HNSHK", number: 2, version: 4, elements: [
            profile,
            .text(securityFunction),
            .text(reference),
            "1",
            "1",
            sender,
            "1",
            stamp,
            .group(of: ["1", "999", "1"]),
            .group(of: ["6", "10", "16"]),
            keyName(type: "S"),
        ]))
        signedSegments += Self.numbered(payload, from: Self.firstSignedPayloadNumber)
        let signatureNumber = Self.firstSignedPayloadNumber + payload.count
        signedSegments.append(FinTSSegment(type: "HNSHA", number: signatureNumber, version: 2, elements: [
            .text(reference),
            .empty,
            .group(of: [pin, tan]),
        ]))
        let inner = FinTSSyntax.encode(signedSegments)

        let encryptionHeader = FinTSSegment(type: "HNVSK", number: 998, version: 3, elements: [
            profile,
            "998",
            "1",
            sender,
            stamp,
            .group([.value("2"), .value("2"), .value("13"), .binary(Data("00000000".utf8)), .value("5"), .value("1")]),
            keyName(type: "V"),
            "0",
        ])
        let encryptedData = FinTSSegment(type: "HNVSD", number: 999, version: 1, elements: [.binary(inner)])
        let trailer = Self.trailer(number: signatureNumber + 1, messageNumber: messageNumber)
        return Self.assemble(dialogID: dialogID, messageNumber: messageNumber,
                             segments: [encryptionHeader, encryptedData, trailer])
    }

    /// An unsigned, unencrypted message (`HNHBK`, payload, `HNHBS`) for anonymous dialogs.
    ///
    /// - Parameter payload: Business segments; their `number` is overwritten, counting from
    ///   ``firstAnonymousPayloadNumber``.
    public static func anonymousMessage(dialogID: String = "0", messageNumber: Int, payload: [FinTSSegment]) -> Data {
        let body = numbered(payload, from: firstAnonymousPayloadNumber)
        let end = trailer(number: firstAnonymousPayloadNumber + payload.count, messageNumber: messageNumber)
        return assemble(dialogID: dialogID, messageNumber: messageNumber, segments: body + [end])
    }

    // MARK: Helpers

    /// `280:<bankCode>:<userID>:<keyType>:0:0` — country code 280 (Germany), key number 0, key version 0.
    private func keyName(type: String) -> FinTSElement {
        .group(of: ["280", bankCode, userID, type, "0", "0"])
    }

    private static func numbered(_ segments: [FinTSSegment], from first: Int) -> [FinTSSegment] {
        segments.enumerated().map { index, segment in
            var copy = segment
            copy.number = first + index
            return copy
        }
    }

    private static func trailer(number: Int, messageNumber: Int) -> FinTSSegment {
        FinTSSegment(type: "HNHBS", number: number, version: 1, elements: [.number(messageNumber)])
    }

    /// Prepends `HNHBK` and fixes its length field to the final byte count.
    private static func assemble(dialogID: String, messageNumber: Int, segments: [FinTSSegment]) -> Data {
        func header(length: Int) -> FinTSSegment {
            FinTSSegment(type: "HNHBK", number: 1, version: 3, elements: [
                .value(String(format: "%012ld", length)),
                "300",
                .text(dialogID),
                .number(messageNumber),
            ])
        }
        let body = FinTSSyntax.encode(segments)
        let headerLength = FinTSSyntax.encode(header(length: 0)).count
        var message = FinTSSyntax.encode(header(length: headerLength + body.count))
        message.append(body)
        return message
    }

    /// `YYYYMMDD` and `HHMMSS` in Europe/Berlin time, the time zone German banks expect.
    static func timestamp(_ date: Date) -> (date: String, time: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (
            String(format: "%04ld%02ld%02ld", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1),
            String(format: "%02ld%02ld%02ld", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        )
    }
}
