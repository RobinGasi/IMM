import Foundation

/// SplitMix64: a fixed, documented algorithm so the demo data never depends on the Swift runtime's generator.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform integer in `range` (modulo bias is irrelevant for demo data).
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    /// Uniform value in -1 ... 1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 52) - 1.0
    }

    /// Four upper-case alphanumeric characters, a dash and three more: `4KX9-22T`.
    mutating func orderCode() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        var out = ""
        for index in 0..<7 {
            if index == 4 { out.append("-") }
            out.append(alphabet[int(0...(alphabet.count - 1))])
        }
        return out
    }

    /// A digit string of the given length.
    mutating func digits(_ length: Int) -> String {
        var out = ""
        for _ in 0..<length { out.append(String(int(0...9))) }
        return out
    }
}
