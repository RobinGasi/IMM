import Foundation
import Testing
@testable import IMMLedger

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct HLCTests {
    @Test func bytesRoundTripAndLayout() throws {
        let hlc = HLC(millis: 0x0123_4567_89AB, counter: 0xCDEF, node: 0x0011_2233_4455_6677)
        #expect(hlc.bytes == Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]))
        #expect(HLC(bytes: hlc.bytes) == hlc)
        #expect(HLC(bytes: Data(repeating: 0, count: 15)) == nil)
        #expect(HLC(bytes: Data(repeating: 0, count: 17)) == nil)
        let json = try JSONEncoder().encode(hlc)
        #expect(try JSONDecoder().decode(HLC.self, from: json) == hlc)
        #expect(hlc.description == "0123456789ab-cdef-0011223344556677")
    }

    @Test func byteOrderIsTupleOrder() {
        var rng = SeededRandom(state: 7)
        for _ in 0..<2000 {
            // Few distinct values force ties on every field.
            func make() -> HLC {
                HLC(millis: UInt64.random(in: 0...3, using: &rng) << 40, counter: UInt16.random(in: 0...2, using: &rng),
                    node: UInt64.random(in: 0...2, using: &rng) << 56)
            }
            let a = make(), b = make()
            let byTuple = (a.millis, a.counter, a.node) < (b.millis, b.counter, b.node)
            #expect((a < b) == byTuple)
            #expect(a.bytes.lexicographicallyPrecedes(b.bytes) == byTuple)
        }
    }

    @Test func sendIsStrictlyMonotone() throws {
        var clock = HLCClock(node: 9, now: 1_000)
        var previous = clock.last
        // Same millisecond: the counter climbs.
        for _ in 0..<5 {
            let next = try clock.send(now: 1_000)
            #expect(next > previous)
            #expect(next.millis == 1_000)
            previous = next
        }
        #expect(previous.counter == 5)
        // Wall clock moves forward: counter resets.
        let later = try clock.send(now: 2_000)
        #expect(later == HLC(millis: 2_000, counter: 0, node: 9))
        // Wall clock moves backwards: the clock keeps its millis and counts.
        let back = try clock.send(now: 1_500)
        #expect(back == HLC(millis: 2_000, counter: 1, node: 9))
    }

    @Test func counterOverflowRollsIntoNextMillisecond() throws {
        var clock = HLCClock(last: HLC(millis: 5_000, counter: .max, node: 3))
        let next = try clock.send(now: 5_000)
        #expect(next == HLC(millis: 5_001, counter: 0, node: 3))
        #expect(next > HLC(millis: 5_000, counter: .max, node: 3))
        // Receive overflows the same way.
        var other = HLCClock(last: HLC(millis: 5_000, counter: .max, node: 3))
        let merged = try other.receive(HLC(millis: 5_000, counter: .max, node: 4), now: 5_000)
        #expect(merged == HLC(millis: 5_001, counter: 0, node: 3))
    }

    @Test func localDriftIsRefused() throws {
        var clock = HLCClock(last: HLC(millis: 10_000_000, counter: 0, node: 1))
        // Wall clock more than five minutes behind the clock's own millis.
        #expect(throws: HLCError.localDrift(ahead: HLCClock.maxDrift + 1)) {
            _ = try clock.send(now: 10_000_000 - HLCClock.maxDrift - 1)
        }
        #expect(clock.last == HLC(millis: 10_000_000, counter: 0, node: 1))
        // Exactly five minutes is fine.
        _ = try clock.send(now: 10_000_000 - HLCClock.maxDrift)
    }

    @Test func remoteDriftIsRejectedBeforeAnyArithmetic() throws {
        var clock = HLCClock(node: 1, now: 100_000)
        let before = clock
        let limit = 100_000 + HLCClock.maxDrift
        _ = try clock.receive(HLC(millis: limit, counter: 0, node: 2), now: 100_000)   // exactly +5 min: accepted
        var fresh = before
        #expect(throws: HLCError.remoteDrift(ahead: HLCClock.maxDrift + 1)) {
            _ = try fresh.receive(HLC(millis: limit + 1, counter: 0, node: 2), now: 100_000)
        }
        #expect(fresh == before)
    }

    /// Kulkarni et al., Figure 5, receive rule, written out literally.
    private func paperReceive(l: UInt64, c: UInt16, lm: UInt64, cm: UInt16, pt: UInt64) -> (UInt64, UInt32) {
        let lNew = max(l, lm, pt)
        if lNew == l && l == lm { return (lNew, UInt32(max(c, cm)) + 1) }
        if lNew == l { return (lNew, UInt32(c) + 1) }
        if lNew == lm { return (lNew, UInt32(cm) + 1) }
        return (lNew, 0)
    }

    @Test func receiveMatchesTheFigureFive() throws {
        var rng = SeededRandom(state: 42)
        for _ in 0..<5000 {
            let l = UInt64.random(in: 1...6, using: &rng), lm = UInt64.random(in: 1...6, using: &rng)
            let pt = UInt64.random(in: 1...6, using: &rng)
            let c = UInt16.random(in: 0...3, using: &rng), cm = UInt16.random(in: 0...3, using: &rng)
            var clock = HLCClock(last: HLC(millis: l, counter: c, node: 1))
            let got = try clock.receive(HLC(millis: lm, counter: cm, node: 2), now: pt)
            let (expectedMillis, expectedCounter) = paperReceive(l: l, c: c, lm: lm, cm: cm, pt: pt)
            #expect(got.millis == expectedMillis)
            #expect(got.counter == UInt16(expectedCounter))
            #expect(got > HLC(millis: lm, counter: cm, node: 2))   // later than what it absorbed
            #expect(got.node == 1)
        }
    }

    @Test func clockDoesNotAdvanceOnFailure() {
        var clock = HLCClock(last: HLC(millis: HLC.maxMillis, counter: .max, node: 1))
        let before = clock
        #expect(throws: HLCError.self) { _ = try clock.send(now: 1) }
        #expect(clock == before)
    }
}
