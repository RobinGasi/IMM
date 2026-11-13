import Foundation
import IMMLedger

/// Holdings, cash and the daily value history of the ING depot.
enum DemoDepot {
    static let priceTime = Date(timeIntervalSince1970: 1_794_501_000)   // 12.11.2026 17:30 in Köln

    static let world = BankSecurity(name: "iShares Core MSCI World", isin: "IE00B4L5Y983", wkn: "A0RPWH", kind: .etf)
    static let allWorld = BankSecurity(name: "Vanguard FTSE All-World", isin: "IE00BK5BQT80", wkn: "A2PKXG", kind: .etf)
    static let emerging = BankSecurity(name: "iShares Core MSCI EM IMI", isin: "IE00BKM4GZ66", wkn: "A111X9", kind: .etf)

    /// Holdings (quantity × price) plus cash add up to 48.912,40 €. The per-fund cost bases are chosen so that
    /// together with the cash (cost = value) the cost basis is 41.594,18 € and the total gain 7.318,22 €.
    static func holdings() -> [BankHolding] {
        let account = DemoAccountID.depot
        return [
            BankHolding(accountID: account, security: world, quantity: 182, price: 10_845, priceTime: priceTime, costBasis: 1_656_200),
            BankHolding(accountID: account, security: allWorld, quantity: 118, price: 13_210, priceTime: priceTime, costBasis: 1_321_600),
            BankHolding(accountID: account, security: emerging, quantity: 290, price: 3_462, priceTime: priceTime, costBasis: 826_928),
            BankHolding(accountID: account, security: nil, quantity: 1, price: 354_690, priceTime: nil, costBasis: 354_690),
        ]
    }

    static let regionWeights: [DemoFundRegionWeights] = [
        DemoFundRegionWeights(isin: world.isin, northAmerica: 700, europe: 155, emergingMarkets: 0, japanPacific: 145),
        DemoFundRegionWeights(isin: allWorld.isin, northAmerica: 680, europe: 140, emergingMarkets: 100, japanPacific: 80),
        DemoFundRegionWeights(isin: emerging.isin, northAmerica: 0, europe: 0, emergingMarkets: 1000, japanPacific: 0),
    ]

    /// y coordinates of the drawn 1Y polyline (viewBox 716 × 176); grid lines at y 8 (50.000) and y 145,1 (38.000).
    static let polylineY: [Double] = [
        146.3, 141.5, 137.7, 133.9, 131.4, 137.1, 140.6, 132.6, 124.6, 116.6, 109.7, 115.4, 118.9,
        107.4, 97.1, 93.7, 86.9, 77.7, 69.7, 66.3, 61.7, 49.1, 40, 29.7, 20.4,
    ]

    static let oneYearStart = LocalDate(year: 2025, month: 11, day: 12)
    static let historyStart = LocalDate(year: 2025, month: 1, day: 1)

    /// The 25 vertices of the 1Y polyline: date and value in minor units. The first is 37.900,00 € (12.11.2025)
    /// and the last 48.912,40 € (12.11.2026).
    static func vertices() -> [(LocalDate, Int)] {
        var out: [(LocalDate, Int)] = []
        for (index, y) in polylineY.enumerated() {
            let days = Int((Double(index) * 365.0 / 24.0).rounded())
            let date = oneYearStart.adding(days: days)
            var value = Int((5_000_000.0 - (y - 8.0) * (1_200_000.0 / 137.1)).rounded())
            if index == 0 { value = 3_790_000 }
            if index == polylineY.count - 1 { value = 4_891_240 }
            out.append((date, value))
        }
        return out
    }

    /// Daily total depot value from 01.01.2025 to 12.11.2026. The 25 polyline vertices are exact; the days in
    /// between follow a straight line plus small deterministic noise that is zero at every vertex.
    static func history() -> [BankDepotValuePoint] {
        var anchors: [(LocalDate, Int)] = [
            (LocalDate(year: 2025, month: 1, day: 1), 2_540_000),
            (LocalDate(year: 2025, month: 4, day: 1), 2_930_000),
            (LocalDate(year: 2025, month: 7, day: 1), 3_160_000),
            (LocalDate(year: 2025, month: 10, day: 1), 3_590_000),
        ]
        anchors.append(contentsOf: vertices())
        var rng = SplitMix64(seed: 0xDE90_7001)
        var out: [BankDepotValuePoint] = []
        for segment in 0..<(anchors.count - 1) {
            let (startDate, startValue) = anchors[segment]
            let (endDate, endValue) = anchors[segment + 1]
            let length = endDate - startDate
            guard length > 0 else { continue }
            for offset in 0..<length {
                let t = Double(offset) / Double(length)
                var value = Double(startValue) + (Double(endValue) - Double(startValue)) * t
                if offset > 0 {
                    value += rng.unit() * 0.002 * value * sin(Double.pi * t)
                } else {
                    _ = rng.unit()
                }
                out.append(BankDepotValuePoint(accountID: DemoAccountID.depot, date: startDate.adding(days: offset),
                                               value: Int(value.rounded())))
            }
        }
        let last = anchors[anchors.count - 1]
        out.append(BankDepotValuePoint(accountID: DemoAccountID.depot, date: last.0, value: last.1))
        return out
    }
}
