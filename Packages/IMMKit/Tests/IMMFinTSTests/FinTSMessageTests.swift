import Foundation
import Testing
@testable import IMMFinTS

private func latin1(_ text: String) -> Data {
    text.data(using: .isoLatin1)!
}

private func ascii(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

/// 2024-01-15 10:30:45 Europe/Berlin.
private let fixedDate = Date(timeIntervalSince1970: 1_705_311_045)

private func builder(systemID: String = "0", securityFunction: String = "999") -> FinTSMessageBuilder {
    FinTSMessageBuilder(bankCode: "12030000", userID: "testuser", systemID: systemID, securityFunction: securityFunction,
                        clock: { fixedDate }, securityReference: { "4711" })
}

/// Identification and processing preparation with deliberately wrong numbers: the builder renumbers.
private func payload(systemID: String) -> [FinTSSegment] {
    [
        FinTSSegment(type: "HKIDN", number: 77, version: 2, elements: [
            .group(of: ["280", "12030000"]), "testuser", .text(systemID), "1",
        ]),
        FinTSSegment(type: "HKVVB", number: 0, version: 3, elements: ["0", "0", "0", "IMMTest", "0.1"]),
    ]
}

/// The 12-digit length field of the leading `HNHBK`.
private func declaredLength(_ message: Data) -> Int? {
    let text = ascii(message)
    guard text.hasPrefix("HNHBK:1:3+") else { return nil }
    return Int(text.dropFirst("HNHBK:1:3+".count).prefix(12))
}

@Suite struct FinTSMessageTests {
    // MARK: Builder

    @Test func oneStepMessageIsByteExact() {
        let message = builder().message(messageNumber: 1, pin: "12345", payload: payload(systemID: "0"))
        let expected =
            "HNHBK:1:3+000000000345+300+0+1'"
            + "HNVSK:998:3+PIN:1+998+1+1::0+1:20240115:103045+2:2:13:@8@00000000:5:1+280:12030000:testuser:V:0:0+0'"
            + "HNVSD:999:1+@184@"
            + "HNSHK:2:4+PIN:1+999+4711+1+1+1::0+1+1:20240115:103045+1:999:1+6:10:16+280:12030000:testuser:S:0:0'"
            + "HKIDN:3:2+280:12030000+testuser+0+1'"
            + "HKVVB:4:3+0+0+0+IMMTest+0.1'"
            + "HNSHA:5:2+4711++12345''"
            + "HNHBS:6:1+1'"
        #expect(ascii(message) == expected)
        #expect(message.count == 345)
        #expect(declaredLength(message) == message.count)
    }

    @Test func twoStepMessageWithTANIsByteExact() {
        let message = builder(systemID: "SYS1", securityFunction: "921")
            .message(dialogID: "DLG4711", messageNumber: 3, pin: "12345", tan: "123456", payload: payload(systemID: "SYS1"))
        let expected =
            "HNHBK:1:3+000000000367+300+DLG4711+3'"
            + "HNVSK:998:3+PIN:2+998+1+1::SYS1+1:20240115:103045+2:2:13:@8@00000000:5:1+280:12030000:testuser:V:0:0+0'"
            + "HNVSD:999:1+@197@"
            + "HNSHK:2:4+PIN:2+921+4711+1+1+1::SYS1+1+1:20240115:103045+1:999:1+6:10:16+280:12030000:testuser:S:0:0'"
            + "HKIDN:3:2+280:12030000+testuser+SYS1+1'"
            + "HKVVB:4:3+0+0+0+IMMTest+0.1'"
            + "HNSHA:5:2+4711++12345:123456''"
            + "HNHBS:6:1+3'"
        #expect(ascii(message) == expected)
        #expect(declaredLength(message) == message.count)
    }

    @Test func segmentNumbersAreContiguousAndPayloadIsRenumbered() throws {
        let message = builder().message(messageNumber: 2, pin: "1", payload: payload(systemID: "0") + payload(systemID: "0"))
        let outer = try FinTSSyntax.decode(message)
        #expect(outer.map(\.type) == ["HNHBK", "HNVSK", "HNVSD", "HNHBS"])
        #expect(outer.map(\.number) == [1, 998, 999, 8])
        let inner = try FinTSSyntax.decode(try #require(outer[2].element(0)?.binaryValue))
        #expect(inner.map(\.type) == ["HNSHK", "HKIDN", "HKVVB", "HKIDN", "HKVVB", "HNSHA"])
        #expect(inner.map(\.number) == [2, 3, 4, 5, 6, 7])
        #expect(inner.first(where: { $0.type == "HNSHA" })?.string(0) == "4711")
        #expect(inner.first(where: { $0.type == "HNSHK" })?.string(2) == "4711")
    }

    @Test func payloadKeepsReferenceAndElements() throws {
        let tanSegment = FinTSSegment(type: "HKTAN", number: 0, version: 7, reference: 5, elements: ["2", .empty, "ABC"])
        let message = builder().message(messageNumber: 1, pin: "1", payload: [tanSegment])
        let inner = try FinTSResponse(data: message).segments
        #expect(inner == [FinTSSegment(type: "HKTAN", number: 3, version: 7, reference: 5, elements: ["2", .empty, "ABC"])])
    }

    @Test func lengthFieldMatchesByteCountForTrickyContent() {
        // Latin-1 text (one byte per character), delimiters in the PIN, and binary payload with delimiters.
        let segments = [
            FinTSSegment(type: "HKX", number: 0, version: 1, elements: [.value("Müller & Söhne?"), .binary(Data("'+:@?".utf8))]),
        ]
        for pin in ["12345", "12?3'4+5:6@7", "pässword"] {
            let message = builder().message(messageNumber: 12, pin: pin, tan: "9'9", payload: segments)
            #expect(declaredLength(message) == message.count, "pin \(pin)")
        }
    }

    @Test func pinWithDelimitersIsReleased() throws {
        let message = builder().message(messageNumber: 1, pin: "a?b'c+d:e@f", tan: nil, payload: [])
        let inner = try FinTSSyntax.decode(try #require(try FinTSSyntax.decode(message)[2].element(0)?.binaryValue))
        #expect(inner.map(\.type) == ["HNSHK", "HNSHA"])
        #expect(inner[1].number == 3)
        #expect(inner[1].element(1) == .empty)   // validation result is not sent
        #expect(inner[1].string(2) == "a?b'c+d:e@f")
        // The wire form really carries released delimiters.
        let wire = ascii(message)
        #expect(wire.contains("++a??b?'c?+d?:e?@f'"))
    }

    @Test func emptyPayloadStillBuildsValidMessage() {
        let message = builder().message(messageNumber: 1, pin: "1", payload: [])
        #expect(ascii(message).hasSuffix("HNSHA:3:2+4711++1''HNHBS:4:1+1'"))
        #expect(declaredLength(message) == message.count)
    }

    @Test func anonymousMessageHasNoSecurityEnvelope() throws {
        let message = FinTSMessageBuilder.anonymousMessage(messageNumber: 2, payload: payload(systemID: "0"))
        let expected =
            "HNHBK:1:3+000000000107+300+0+2'"
            + "HKIDN:2:2+280:12030000+testuser+0+1'"
            + "HKVVB:3:3+0+0+0+IMMTest+0.1'"
            + "HNHBS:4:1+2'"
        #expect(ascii(message) == expected)
        #expect(message.count == 107)
        #expect(declaredLength(message) == message.count)
        let segments = try FinTSSyntax.decode(message)
        #expect(segments.map(\.number) == [1, 2, 3, 4])
    }

    @Test func timestampUsesBerlinTime() {
        // Winter: UTC+1.
        #expect(FinTSMessageBuilder.timestamp(Date(timeIntervalSince1970: 1_705_311_045)) == ("20240115", "103045"))
        // Summer: UTC+2; 2024-07-01 22:30:00 UTC is already 2024-07-02 in Berlin.
        #expect(FinTSMessageBuilder.timestamp(Date(timeIntervalSince1970: 1_719_873_000)) == ("20240702", "003000"))
    }

    @Test func defaultSecurityReferenceIsSevenDigits() throws {
        let plain = FinTSMessageBuilder(bankCode: "12030000", userID: "testuser")
        let message = plain.message(messageNumber: 1, pin: "1", payload: [])
        let inner = try FinTSSyntax.decode(try #require(try FinTSSyntax.decode(message)[2].element(0)?.binaryValue))
        let reference = try #require(inner[0].string(2))
        #expect(reference.count == 7)
        #expect(Int(reference) != nil)
        #expect(inner[1].string(0) == reference)
    }

    // MARK: Response

    /// Wraps `inner` in the envelope a bank puts around its answer.
    private func bankResponse(inner: String, dialogID: String = "DLG0123456789") -> Data {
        let innerData = latin1(inner)
        var body = latin1("HNVSK:998:3+PIN:1+998+1+2::sys0001+1:20240115:103046+2:2:13:@8@00000000:5:1+280:12030000:testuser:V:0:0+0'")
        body.append(latin1("HNVSD:999:1+@\(innerData.count)@"))
        body.append(innerData)
        body.append(latin1("'HNHBS:8:1+1'"))
        func header(length: Int) -> Data {
            latin1("HNHBK:1:3+\(String(format: "%012ld", length))+300+\(dialogID)+1+\(dialogID):1'")
        }
        var message = header(length: header(length: 0).count + body.count)
        message.append(body)
        return message
    }

    private let sampleInner =
        "HNSHK:2:4+PIN:1+999+9988776+1+2+1::sys0001+1+1:20240115:103046+1:999:1+6:10:16+280:12030000:testuser:S:0:0'"
        + "HIRMG:3:2+0010::Nachricht entgegengenommen.'"
        + "HIRMS:4:2:3+0020::Der Auftrag wurde ausgeführt.+3920::Zugelassene Zwei-Schritt-Verfahren für den Benutzer.:921:923'"
        + "HIRMS:5:2:4+0020::Umsatzabruf erfolgreich.+3040::Es liegen weitere Informationen vor.:TOUCH?:123?+45'"
        + "HIKAZ:6:7:4+@8@x'+:@y?z'"
        + "HNSHA:7:2+9988776'"

    @Test func parsesEnvelopeAndNestedSegments() throws {
        let response = try FinTSResponse(data: bankResponse(inner: sampleInner))
        #expect(response.dialogID == "DLG0123456789")
        #expect(response.messageNumber == 1)
        #expect(response.segments.map(\.type) == ["HIRMG", "HIRMS", "HIRMS", "HIKAZ"])
        #expect(response.segments("HIRMS").count == 2)
        #expect(response.segments("HNVSD").isEmpty)
        #expect(response.first("HIRMS")?.number == 4)
        #expect(response.first("HIXXX") == nil)
        let statements = try #require(response.first("HIKAZ"))
        #expect(statements.reference == 4)
        #expect(statements.element(0)?.binaryValue == Data("x'+:@y?z".utf8))
    }

    @Test func exposesReturnCodes() throws {
        let response = try FinTSResponse(data: bankResponse(inner: sampleInner))
        #expect(response.globalCodes == [
            FinTSReturnCode(code: 10, elementReference: nil, text: "Nachricht entgegengenommen.", parameters: [],
                            segmentReference: nil),
        ])
        #expect(response.allCodes.map(\.code) == [10, 20, 3920, 20, 3040])
        let first = response.segmentCodes(for: 3)
        #expect(first.map(\.code) == [20, 3920])
        #expect(first[0].text == "Der Auftrag wurde ausgeführt.")
        #expect(first[0].segmentReference == 3)
        #expect(first[1].parameters == ["921", "923"])
        #expect(response.segmentCodes(for: 4).map(\.code) == [20, 3040])
        #expect(response.segmentCodes(for: 99).isEmpty)
        #expect(response.hasError == false)
        #expect(response.allowedSecurityFunctions == ["921", "923"])
        #expect(response.touchdown(for: 4) == "TOUCH:123+45")
        #expect(response.touchdown(for: 3) == nil)
        #expect(response.allCodes.first { $0.code == 3920 }?.isWarning == true)
    }

    @Test func detectsErrorCodesAndElementReferences() throws {
        let inner = "HIRMG:2:2+9050::Die Nachricht enthält Fehler.+9800::Dialog abgebrochen.'"
            + "HIRMS:3:2:2+9942:3:PIN falsch.+0030::TAN erforderlich.:4711'"
        let response = try FinTSResponse(data: bankResponse(inner: inner))
        #expect(response.hasError)
        #expect(response.globalCodes.map(\.code) == [9050, 9800])
        #expect(response.globalCodes.allSatisfy { $0.isError })
        let codes = response.segmentCodes(for: 2)
        #expect(codes[0].elementReference == "3")
        #expect(codes[0].text == "PIN falsch.")
        #expect(codes[1].parameters == ["4711"])
        #expect(codes[1].isError == false)
    }

    @Test func warningsAreNotErrors() throws {
        let response = try FinTSResponse(data: bankResponse(inner: "HIRMG:2:2+3060::Bitte beachten Sie die Warnungen.'"))
        #expect(!response.hasError)
        #expect(response.globalCodes.first?.isWarning == true)
    }

    @Test func parsesResponseWithoutEncryptedData() throws {
        let plain = latin1("HNHBK:1:3+000000000090+300+0+1+0:1'HIRMG:2:2+9000::Nachricht nicht verständlich.'HNHBS:3:1+1'")
        let response = try FinTSResponse(data: plain)
        #expect(response.dialogID == "0")
        #expect(response.segments.map(\.type) == ["HIRMG"])
        #expect(response.hasError)
    }

    @Test func parsesOwnSignedMessageAsResponse() throws {
        let message = builder().message(dialogID: "42", messageNumber: 1, pin: "12345", payload: payload(systemID: "0"))
        let response = try FinTSResponse(data: message)
        #expect(response.dialogID == "42")
        #expect(response.segments.map(\.type) == ["HKIDN", "HKVVB"])
        #expect(response.segments.map(\.number) == [3, 4])
        #expect(response.allCodes.isEmpty)
    }

    @Test func responseRejectsMalformedInput() {
        // No HNHBK first.
        #expect(throws: FinTSResponseError.missingMessageHeader) {
            try FinTSResponse(data: latin1("HIRMG:2:2+0010::OK'"))
        }
        #expect(throws: FinTSResponseError.missingMessageHeader) {
            try FinTSResponse(data: Data())
        }
        // HNVSD without binary content.
        #expect(throws: FinTSResponseError.malformedEncryptedData) {
            try FinTSResponse(data: latin1("HNHBK:1:3+000000000000+300+0+1'HNVSD:999:1+notbinary'"))
        }
        // Unterminated outer segment.
        #expect(throws: FinTSSyntaxError.self) {
            try FinTSResponse(data: latin1("HNHBK:1:3+000000000000+300+0+1"))
        }
        // Inner payload is malformed: unterminated segment inside HNVSD.
        let brokenInner = latin1("HNHBK:1:3+000000000000+300+0+1'HNVSD:999:1+@14@HIRMG:2:2+0010'HNHBS:3:1+1'")
        #expect(throws: FinTSSyntaxError.self) {
            try FinTSResponse(data: brokenInner)
        }
        // Binary length announces more bytes than the message holds.
        #expect(throws: FinTSSyntaxError.self) {
            try FinTSResponse(data: latin1("HNHBK:1:3+000000000000+300+0+1'HNVSD:999:1+@500@abc'"))
        }
    }
}
