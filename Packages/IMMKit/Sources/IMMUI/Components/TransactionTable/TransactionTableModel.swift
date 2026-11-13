import CoreGraphics
import Foundation

/// One transaction as the table shows it. Every string is formatted by the caller
/// (German money and dates), so the table stays free of ledger and formatting logic.
public struct TransactionRowData: Identifiable, Hashable, Sendable {
    /// Stable id: the ledger transaction id. Used for selection and diffing.
    public var id: String
    /// Draws the 6 px primary dot in the marker column (list layout only).
    public var isNew: Bool
    /// "11.11."
    public var date: String
    /// First line, 13 medium: counterparty short name.
    public var payee: String
    /// Second line, 12 muted: purpose, or the account name in the All transactions variant.
    public var secondary: String?
    /// nil draws the hollow dot and the muted "Without category".
    public var categoryName: String?
    /// Design token name of the category dot (`"chart-5"`, `"credit"`, …); nil falls back to `muted-foreground`.
    public var categoryColorToken: String?
    /// "−63,48 €" (list) or "−63,48" (inspector layout, as drawn).
    public var amount: String
    /// Income: credit colour, medium weight.
    public var isPositive: Bool
    /// Running balance, list layout with balance column only.
    public var balance: String?

    public init(
        id: String, isNew: Bool = false, date: String, payee: String, secondary: String? = nil,
        categoryName: String? = nil, categoryColorToken: String? = nil, amount: String,
        isPositive: Bool = false, balance: String? = nil
    ) {
        self.id = id
        self.isNew = isNew
        self.date = date
        self.payee = payee
        self.secondary = secondary
        self.categoryName = categoryName
        self.categoryColorToken = categoryColorToken
        self.amount = amount
        self.isPositive = isPositive
        self.balance = balance
    }
}

/// A row of the table snapshot. Ids must be unique and stable across snapshots.
public enum TransactionTableRow: Identifiable, Hashable, Sendable {
    /// Group row, 24 px, floats at the top while its month scrolls. `total` sits in the amount column.
    case monthHeader(id: String, title: String, total: String?)
    case transaction(TransactionRowData)
    /// 44 px row with a 1 px rule above and a 3 px double rule below. `date` fills the date column;
    /// `amount` sits in the last column (balance column, or amount column without balance).
    case closingBalance(id: String, label: String, amount: String, date: String? = nil)

    public var id: String {
        switch self {
        case .monthHeader(let id, _, _): return id
        case .transaction(let data): return data.id
        case .closingBalance(let id, _, _, _): return id
        }
    }

    /// The transaction id when this row can be selected.
    public var transactionID: String? {
        if case .transaction(let data) = self { return data.id }
        return nil
    }

    /// Row height in points: month header 24, transaction 44, closing balance 44.
    public var height: CGFloat {
        switch self {
        case .monthHeader: return TransactionTableMetrics.monthHeaderHeight
        case .transaction, .closingBalance: return TransactionTableMetrics.rowHeight
        }
    }
}

public enum TransactionTableLayout: Hashable, Sendable {
    /// marker 12 · date 52 · payee 1fr · category minmax(140, 0.5fr) · amount 112 · balance 112, gap 16.
    case list(showsBalance: Bool)
    /// date 56 · payee and purpose minmax(0, 1fr) · category minmax(0, 0.6fr) · amount 104, gap 16.
    case inspector

    /// Table header height: 28 (list), 32 (inspector).
    public var headerHeight: CGFloat {
        switch self {
        case .list: return 28
        case .inspector: return 32
        }
    }
}

/// Resolved column widths of one table width (CSS grid resolution of the design's `grid-cols`).
public struct TransactionColumns: Sendable, Equatable {
    /// Marker column plus gap in the list layout, 0 in the inspector layout.
    public var leading: CGFloat
    public var date: CGFloat
    public var payee: CGFloat
    public var category: CGFloat
    public var amount: CGFloat
    /// 0 when the layout has no balance column.
    public var balance: CGFloat
    public var gap: CGFloat
    public var hasMarker: Bool
    public var hasBalance: Bool

    /// - Parameter contentWidth: table width minus the horizontal padding on both sides.
    public init(layout: TransactionTableLayout, contentWidth: CGFloat) {
        let gap: CGFloat = 16
        self.gap = gap
        let width = max(0, contentWidth)
        switch layout {
        case .list(let showsBalance):
            let fixed: CGFloat = 12 + 52 + 112 + (showsBalance ? 112 : 0)
            let gaps = CGFloat(showsBalance ? 5 : 4) * gap
            let free = max(0, width - fixed - gaps)
            // minmax(0, 1fr) and minmax(140, 0.5fr): free space splits 2:1 until the category hits 140.
            var category = free / 3
            var payee = free * 2 / 3
            if category < 140 {
                category = 140
                payee = max(0, free - 140)
            }
            leading = 12 + gap
            date = 52
            self.payee = payee
            self.category = category
            amount = 112
            balance = showsBalance ? 112 : 0
            hasMarker = true
            hasBalance = showsBalance
        case .inspector:
            let free = max(0, width - 56 - 104 - 3 * gap)
            leading = 0
            date = 56
            payee = free / 1.6
            category = free * 0.6 / 1.6
            amount = 104
            balance = 0
            hasMarker = false
            hasBalance = false
        }
    }

    /// Width from the start of the date column to the end of the category column.
    public var labelSpan: CGFloat { date + gap + payee + gap + category }
}

public enum TransactionTableMetrics {
    public static let monthHeaderHeight: CGFloat = 24
    public static let rowHeight: CGFloat = 44

    /// Height of all rows together (the table's intrinsic content height).
    public static func contentHeight(of rows: [TransactionTableRow]) -> CGFloat {
        rows.reduce(0) { $0 + $1.height }
    }
}
