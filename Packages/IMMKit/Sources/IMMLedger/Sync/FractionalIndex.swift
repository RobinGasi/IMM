import Foundation

/// Order keys that can always be squeezed between two neighbours (`category.sort_order`).
///
/// A key is a string over base 62 (`0-9A-Za-z`, ASCII order) without a trailing `0`; keys compare as plain
/// strings, so `ORDER BY sort_order` is the order. `between(a, b)` returns a key strictly between `a` and `b`
/// (`nil` = no bound). Midpoint algorithm after David Greenspan's "Implementing Fractional Indexing" as used by
/// Rocicorp's `fractional-indexing`, reduced to the fractional part.
public enum FractionalIndex {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let zero = digits[0]

    /// The key of a list with one element.
    public static let midpoint = "V"

    /// A key strictly between `lower` and `upper` (both optional).
    public static func between(_ lower: String?, _ upper: String?) -> String {
        let a = Array(lower ?? "")
        let b = upper.map { Array($0) }
        if let b, !a.isEmpty || !b.isEmpty {
            precondition(String(a) < String(b), "FractionalIndex.between needs lower < upper")
        }
        return String(mid(a, b))
    }

    /// `count` ascending keys, evenly spread.
    public static func keys(count: Int) -> [String] {
        guard count > 0 else { return [] }
        var result = [String](repeating: "", count: count)
        func fill(_ lo: Int, _ hi: Int, _ lower: String?, _ upper: String?) {
            guard lo <= hi else { return }
            let m = (lo + hi) / 2
            let key = between(lower, upper)
            result[m] = key
            fill(lo, m - 1, lower, key)
            fill(m + 1, hi, key, upper)
        }
        fill(0, count - 1, nil, nil)
        return result
    }

    private static func digit(_ c: Character) -> Int { digits.firstIndex(of: c) ?? 0 }

    private static func mid(_ a: [Character], _ b: [Character]?) -> [Character] {
        precondition(a.last != zero && b?.last != zero, "fractional keys never end in 0")
        if let b {
            // Common prefix (a is padded with zeros), then recurse on the remainder.
            var n = 0
            while n < b.count, (n < a.count ? a[n] : zero) == b[n] { n += 1 }
            if n > 0 {
                return Array(b[0..<n]) + mid(n < a.count ? Array(a[n...]) : [], Array(b[n...]))
            }
        }
        let digitA = a.isEmpty ? 0 : digit(a[0])
        let digitB = b.map { digit($0[0]) } ?? digits.count
        if digitB - digitA > 1 {
            return [digits[(digitA + digitB + 1) / 2]]
        }
        if let b, b.count > 1 {
            return [b[0]]
        }
        return [digits[digitA]] + mid(a.isEmpty ? [] : Array(a.dropFirst()), nil)
    }
}
