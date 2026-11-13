import Foundation
import Testing

@testable import IMMSyncCore

struct SyncMessageTests {
    private func sampleEnvelope() throws -> SealedEnvelope {
        try SealedEnvelope.seal(
            payload: Data("ops".utf8), header: SealedEnvelope.Header(group: Data(repeating: 1, count: 16), device: 7, seqFrom: 1, seqTo: 4),
            key: SyncGroupKey.generate())
    }

    @Test func everyMessageRoundTrips() throws {
        let messages: [SyncMessage] = [
            .hello(.init(device: 0xdead_beef, group: Data(repeating: 9, count: 16), cursors: [.init(device: 1, appliedSeq: 5), .init(device: 2, appliedSeq: 0)])),
            .hello(.init(device: 1, group: Data(repeating: 9, count: 16), cursors: [])),
            .batch(try sampleEnvelope()),
            .ack(device: 3, throughSeq: 99),
            .snapshotRequest(requestID: 42),
            .snapshotChunk(.init(requestID: 42, index: 3, isFinal: true, data: Data(repeating: 5, count: 1000))),
            .snapshotChunk(.init(requestID: 1, index: 0, isFinal: false, data: Data())),
            .ping(token: .max),
            .pong(token: 0),
            .error(code: .quotaExceeded, message: "Mailbox full — straße"),
            .error(code: SyncErrorCode(rawValue: 4242), message: ""),
            .pairingGrant(Data("grant".utf8)),
        ]
        for message in messages {
            let encoded = message.encoded()
            #expect(encoded[0] == SyncMessage.version)
            #expect(try SyncMessage(decoding: encoded) == message)
        }
    }

    @Test func goldenBytesAreStable() throws {
        #expect(SyncMessage.ping(token: 0x0102_0304_0506_0708).encoded().hex == "0106" + "0102030405060708")
        #expect(SyncMessage.ack(device: 1, throughSeq: 2).encoded().hex == "0103" + "0000000000000001" + "0000000000000002")
        #expect(SyncMessage.snapshotRequest(requestID: 9).encoded().hex == "0104" + "0000000000000009")
        #expect(SyncMessage.error(code: .malformed, message: "no").encoded().hex == "0108" + "0003" + "00000002" + "6e6f")
        #expect(SyncMessage.hello(.init(device: 1, group: Data([0xaa]), cursors: [.init(device: 2, appliedSeq: 3)])).encoded().hex
            == "0101" + "0000000000000001" + "00000001aa" + "00000001" + "0000000000000002" + "0000000000000003")
    }

    @Test func unknownTypeAndVersionAreDistinguished() {
        #expect(throws: SyncMessageError.unknownType(200)) { try SyncMessage(decoding: Data([1, 200, 1, 2, 3])) }
        #expect(throws: SyncMessageError.unsupportedVersion(2)) { try SyncMessage(decoding: Data([2, 6, 0, 0, 0, 0, 0, 0, 0, 1])) }
        #expect(throws: SyncMessageError.truncated) { try SyncMessage(decoding: Data()) }
        #expect(throws: SyncMessageError.truncated) { try SyncMessage(decoding: Data([1])) }
        #expect(throws: SyncMessageError.truncated) { try SyncMessage(decoding: Data([1, 6, 0, 0])) }
        // A declared length beyond the message.
        #expect(throws: SyncMessageError.truncated) { try SyncMessage(decoding: Data([1, 9, 0, 0, 1, 0, 1])) }
    }

    @Test func trailingBytesFromNewerVersionsAreIgnored() throws {
        let original = SyncMessage.ack(device: 5, throughSeq: 6)
        #expect(try SyncMessage(decoding: original.encoded() + Data([1, 2, 3, 4])) == original)
    }

    @Test func hostileCursorCountDoesNotAllocate() {
        // 4 billion cursors claimed in a 20-byte message.
        var bytes = Data([1, 1]) + Data(count: 8) + Data([0, 0, 0, 0]) + Data([0xff, 0xff, 0xff, 0xff])
        bytes += Data(count: 16)
        #expect(throws: SyncMessageError.self) { try SyncMessage(decoding: bytes) }
    }

    @Test func corruptEnvelopeInBatchIsMalformed() {
        let garbage = Data([1, 2]) + Data([0, 0, 0, 3, 1, 2, 3])
        #expect(throws: SyncMessageError.self) { try SyncMessage(decoding: garbage) }
    }
}
