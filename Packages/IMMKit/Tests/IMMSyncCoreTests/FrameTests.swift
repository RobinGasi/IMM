import Foundation
import Testing

@testable import IMMSyncCore

struct FrameTests {
    @Test func encodesBigEndianLengthPrefix() throws {
        let frame = try Frame.encode(Data([1, 2, 3]))
        #expect(frame == Data([0, 0, 0, 3, 1, 2, 3]))
        #expect(try Frame.encode(Data()) == Data([0, 0, 0, 0]))
        let big = try Frame.encode(Data(count: 0x0102_03))
        #expect(Data(big.prefix(4)) == Data([0, 1, 2, 3]))
    }

    @Test func decoderHandlesFragmentationAndCoalescing() throws {
        let payloads = [Data("a".utf8), Data(), Data(repeating: 7, count: 70_000), Data("tail".utf8)]
        let wire = try payloads.reduce(Data()) { $0 + (try Frame.encode($1)) }
        // Byte by byte.
        var decoder = FrameDecoder()
        var out: [Data] = []
        for byte in wire {
            decoder.append(Data([byte]))
            while let frame = try decoder.next() { out.append(frame) }
        }
        #expect(out == payloads)
        #expect(decoder.bufferedCount == 0)
        // All at once.
        decoder = FrameDecoder()
        decoder.append(wire)
        out = []
        while let frame = try decoder.next() { out.append(frame) }
        #expect(out == payloads)
        // A partial frame waits.
        decoder.append(try Frame.encode(Data("xyz".utf8)).dropLast())
        #expect(try decoder.next() == nil)
        decoder.append(Data("z".utf8))
        #expect(try decoder.next() == Data("xyz".utf8))
    }

    @Test func slicedInputAndOutputAreHandled() throws {
        let backing = Data(repeating: 0xaa, count: 10) + (try Frame.encode(Data("slice".utf8)))
        var decoder = FrameDecoder()
        decoder.append(backing.dropFirst(10))  // a Data slice with a non-zero start index
        let payload = try #require(try decoder.next())
        #expect(payload == Data("slice".utf8))
        #expect(payload.startIndex == 0)
        #expect(try Frame.encode(backing.dropFirst(14)).count == 4 + backing.count - 14)
    }

    @Test func oversizedFramesAreRejected() throws {
        #expect(throws: FrameError.tooLarge(Frame.maxPayload + 1)) { try Frame.encode(Data(count: Frame.maxPayload + 1)) }
        #expect(try Frame.encode(Data(count: Frame.maxPayload)).count == Frame.maxPayload + 4)
        // The header alone is enough to refuse: nothing is buffered for a 4 GiB claim.
        var decoder = FrameDecoder()
        decoder.append(Data([0xff, 0xff, 0xff, 0xff]))
        #expect(throws: FrameError.tooLarge(Int(UInt32.max))) { try decoder.next() }
        decoder = FrameDecoder()
        decoder.append(Data([0x00, 0x10, 0x00, 0x01]))
        #expect(throws: FrameError.tooLarge(Frame.maxPayload + 1)) { try decoder.next() }
    }
}
