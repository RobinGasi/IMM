import Foundation
import IMMLedger

/// Spoken value of a chart: what a sighted reader gets from the line without the axis labels.
enum AccessibilitySummary {
    /// "From Dec 31.617,25 € to Nov 63.058,54 €, lowest 31.617,25 €, highest 63.058,54 €." `values` are
    /// minor units in chronological order; `startLabel` and `endLabel` name the first and the last point.
    /// Empty for fewer than two values.
    static func series(startLabel: String, endLabel: String, values: [Int], currency: String = "EUR") -> String {
        guard values.count >= 2, let first = values.first, let last = values.last,
              let low = values.min(), let high = values.max() else { return "" }
        let start = MoneyFormatter.string(first, currency: currency)
        let end = MoneyFormatter.string(last, currency: currency)
        let lowest = MoneyFormatter.string(low, currency: currency)
        let highest = MoneyFormatter.string(high, currency: currency)
        return String(
            localized: "From \(startLabel) \(start) to \(endLabel) \(end), lowest \(lowest), highest \(highest).",
            bundle: .module)
    }
}
