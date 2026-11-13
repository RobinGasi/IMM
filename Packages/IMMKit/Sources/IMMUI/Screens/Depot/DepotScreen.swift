import IMMDesign
import IMMLedger
import SwiftUI

/// The Depot: value and gain, the performance chart (1M, 6M, 1Y, Max), the savings plan, the
/// allocation by region and the holdings table.
///
/// The top row reflows with the window width alone (no breakpoints): the performance column has a
/// 560 pt basis, the aside 320 pt; when both do not fit the aside wraps below. The shell scrolls the
/// screen when it does not fit.
public struct DepotScreen: View {
    @Environment(AppModel.self) private var model
    @State private var depot = DepotModel()

    public init() {}

    public var body: some View {
        Group {
            if let snapshot = depot.snapshot {
                DepotLayout(snapshot: snapshot)
            } else {
                Color.clear
            }
        }
        .task(id: model.ledger.map(ObjectIdentifier.init)) {
            guard let ledger = model.ledger else { return }
            await depot.follow(ledger: ledger)
        }
    }
}

struct DepotLayout: View {
    let snapshot: DepotSnapshot

    @Environment(\.immWindowWidth) private var windowWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            DepotTopRowLayout(spacing: 32) {
                DepotPerformanceSection(snapshot: snapshot)
                DepotAside(snapshot: snapshot)
            }
            DepotHoldingsSection(snapshot: snapshot)
        }
        .padding(.horizontal, IMMLayout.contentPadding(windowWidth: windowWidth))
        .padding(.top, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Text helpers shared by the Depot sections.
enum DepotText {
    static func percent(_ num: Int, _ den: Int, signed: Bool = false) -> String {
        DepotMath.percentText(tenths: DepotMath.tenthsOfPercent(num, den), alwaysSign: signed)
    }

    /// `60 %`: `num / den` rounded half away from zero to whole percent.
    static func wholePercent(_ num: Int, _ den: Int) -> String {
        guard den != 0 else { return "0 %" }
        return "\((num * 200 + den) / (2 * den)) %"
    }

    /// Whole units without trailing zeros, comma as the decimal separator (`182`, `12,5`).
    static func quantity(_ micro: Int) -> String {
        if micro % 1_000_000 == 0 { return String(micro / 1_000_000) }
        var fraction = String(micro % 1_000_000)
        fraction = String(repeating: "0", count: 6 - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return "\(micro / 1_000_000),\(fraction)"
    }

    /// `1st`, `2nd`, `3rd`, `15th`.
    static func ordinal(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    static func color(_ amount: Int) -> Color {
        amount >= 0 ? IMMColor.credit : IMMColor.destructive
    }
}
