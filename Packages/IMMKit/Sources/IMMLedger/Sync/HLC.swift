import Foundation

/// Identifies one device in the op log and inside every HLC it issues (8 random bytes).
public typealias DeviceNodeID = UInt64

/// 16-byte hybrid logical clock: 48-bit unix milliseconds, 16-bit counter, 64-bit node id, big-endian,
/// so `memcmp` order (and SQLite's BLOB order) equals time order.
///
/// Layout and drift rule follow Evolu's `Timestamp` (6 bytes millis, 2 bytes counter, 8 bytes node id);
/// the update rules are Kulkarni et al., "Logical Physical Clocks" (OPODIS 2014), Figure 5.
public struct HLC: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// Largest millisecond value (2^48 − 1).
    public static let maxMillis: UInt64 = (1 << 48) - 1
    /// The smallest clock.
    public static let zero = HLC(millis: 0, counter: 0, node: 0)

    public let millis: UInt64
    public let counter: UInt16
    public let node: UInt64

    public init(millis: UInt64, counter: UInt16, node: UInt64) {
        precondition(millis <= HLC.maxMillis, "HLC millis exceed 48 bits")
        self.millis = millis
        self.counter = counter
        self.node = node
    }

    /// Exactly 16 bytes as produced by `bytes`.
    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        let b = Array(bytes)
        var millis: UInt64 = 0
        for i in 0..<6 { millis = millis << 8 | UInt64(b[i]) }
        var node: UInt64 = 0
        for i in 8..<16 { node = node << 8 | UInt64(b[i]) }
        self.init(millis: millis, counter: UInt16(b[6]) << 8 | UInt16(b[7]), node: node)
    }

    public var bytes: Data {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { out[i] = UInt8(truncatingIfNeeded: millis >> UInt64(8 * (5 - i))) }
        out[6] = UInt8(counter >> 8)
        out[7] = UInt8(counter & 0xff)
        for i in 0..<8 { out[8 + i] = UInt8(truncatingIfNeeded: node >> UInt64(8 * (7 - i))) }
        return Data(out)
    }

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        if lhs.millis != rhs.millis { return lhs.millis < rhs.millis }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.node < rhs.node
    }

    public var description: String {
        func hex(_ value: UInt64, _ width: Int) -> String {
            let s = String(value, radix: 16)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(hex(millis, 12))-\(hex(UInt64(counter), 4))-\(hex(node, 16))"
    }

    /// Wall-clock time of the millisecond part.
    public var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    // Codable as the 16 raw bytes (base64 in JSON).
    public init(from decoder: Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        guard let hlc = HLC(bytes: data) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an HLC is 16 bytes"))
        }
        self = hlc
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

public enum HLCError: Error, Equatable, Sendable {
    /// The local wall clock is more than `HLCClock.maxDrift` behind the clock's own state (local write refused).
    case localDrift(ahead: UInt64)
    /// A remote clock is more than `HLCClock.maxDrift` ahead of the local wall clock (quarantine, do not apply).
    case remoteDrift(ahead: UInt64)
    /// The 48-bit millisecond range is exhausted.
    case overflow
}

/// The clock of one node. A value type: load it from `hlc_state`, advance it, store it back in the same
/// transaction as the write it stamps.
public struct HLCClock: Sendable, Equatable {
    /// Five minutes in milliseconds.
    public static let maxDrift: UInt64 = 5 * 60 * 1000

    /// The last clock this node issued or absorbed; its `node` is this node's id.
    public private(set) var last: HLC

    public init(last: HLC) { self.last = last }

    public init(node: DeviceNodeID, now: UInt64) {
        last = HLC(millis: min(now, HLC.maxMillis), counter: 0, node: node)
    }

    public var node: DeviceNodeID { last.node }

    /// Stamps a local event (Kulkarni Fig. 5, send/local): `l = max(l', pt)`, `c = l == l' ? c + 1 : 0`.
    /// A counter overflow rolls into the next millisecond (counter 0), which is still strictly greater.
    public mutating func send(now: UInt64) throws -> HLC {
        var millis = max(last.millis, now)
        var counter: UInt32 = millis == last.millis ? UInt32(last.counter) + 1 : 0
        if counter > UInt32(UInt16.max) {
            millis += 1
            counter = 0
        }
        return try commit(millis: millis, counter: UInt16(counter), now: now, remote: false)
    }

    /// Absorbs a remote clock (Kulkarni Fig. 5, receive). A remote clock beyond the drift limit is
    /// rejected before any arithmetic and leaves the clock unchanged.
    @discardableResult
    public mutating func receive(_ remote: HLC, now: UInt64) throws -> HLC {
        if remote.millis > now, remote.millis - now > Self.maxDrift {
            throw HLCError.remoteDrift(ahead: remote.millis - now)
        }
        let lPrev = last.millis
        let l = max(lPrev, remote.millis, now)
        var counter: UInt32
        if l == lPrev && l == remote.millis {
            counter = UInt32(max(last.counter, remote.counter)) + 1
        } else if l == lPrev {
            counter = UInt32(last.counter) + 1
        } else if l == remote.millis {
            counter = UInt32(remote.counter) + 1
        } else {
            counter = 0
        }
        var millis = l
        if counter > UInt32(UInt16.max) {
            millis += 1
            counter = 0
        }
        return try commit(millis: millis, counter: UInt16(counter), now: now, remote: true)
    }

    private mutating func commit(millis: UInt64, counter: UInt16, now: UInt64, remote: Bool) throws -> HLC {
        guard millis <= HLC.maxMillis else { throw HLCError.overflow }
        if millis > now, millis - now > Self.maxDrift {
            throw remote ? HLCError.remoteDrift(ahead: millis - now) : HLCError.localDrift(ahead: millis - now)
        }
        last = HLC(millis: millis, counter: counter, node: last.node)
        return last
    }
}
