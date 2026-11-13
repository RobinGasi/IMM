import AppKit
import SwiftUI

/// Design icon names (Lucide) mapped to SF Symbols.
public enum IMMSymbol {
    public struct Entry: Sendable, Equatable {
        public let symbol: String
        /// Used when `NSImage(systemSymbolName:)` returns nil for `symbol` on this macOS.
        public let fallback: String?

        public init(_ symbol: String, fallback: String? = nil) {
            self.symbol = symbol
            self.fallback = fallback
        }
    }

    public static let table: [String: Entry] = [
        "layout-dashboard": Entry("square.grid.2x2"),
        "list": Entry("list.bullet"),
        "check-check": Entry("checklist"),
        "book-open": Entry("book"),
        "landmark": Entry("building.columns"),
        "piggy-bank": Entry("banknote"),
        "credit-card": Entry("creditcard"),
        "trending-up": Entry("chart.line.uptrend.xyaxis"),
        "wallet": Entry("wallet.bifold", fallback: "wallet.pass"),
        "target": Entry("target"),
        "repeat-2": Entry("repeat"),
        "file-text": Entry("doc.text"),
        "pie-chart": Entry("chart.pie"),
        "receipt": Entry("receipt", fallback: "doc.plaintext"),
        "refresh": Entry("arrow.triangle.2.circlepath"),
        "search": Entry("magnifyingglass"),
        "arrow-up-right": Entry("arrow.up.right"),
        "chevron-right": Entry("chevron.right"),
        "chevron-left": Entry("chevron.left"),
        "chevron-down": Entry("chevron.down"),
        "plus": Entry("plus"),
        "check": Entry("checkmark"),
        "x": Entry("xmark"),
        "file": Entry("doc"),
        "triangle-alert": Entry("exclamationmark.triangle"),
        "download": Entry("arrow.down.to.line"),
        "circle-check": Entry("checkmark.circle"),
        "circle-alert": Entry("exclamationmark.circle"),
        "clock": Entry("clock"),
        "lock": Entry("lock"),
        "settings": Entry("gearshape"),
        "tag": Entry("tag"),
        "share": Entry("square.and.arrow.up"),
        "calendar": Entry("calendar.badge.clock"),
        "fingerprint": Entry("touchid"),
        "cpu": Entry("cpu"),
        "laptop": Entry("laptopcomputer"),
        "split": Entry("arrow.triangle.branch"),
        "attach": Entry("paperclip"),
    ]

    private static let resolvedTable: [String: String] = {
        var result: [String: String] = [:]
        for (icon, entry) in table {
            if NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) != nil {
                result[icon] = entry.symbol
            } else if let fallback = entry.fallback,
                NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil
            {
                result[icon] = fallback
            }
        }
        return result
    }()

    /// The symbol to draw for a design icon name: the mapped symbol, else its fallback, else nil.
    public static func resolvedName(for icon: String) -> String? {
        resolvedTable[icon]
    }
}

/// A design icon drawn as an SF Symbol: monochrome, at the design's pixel size, regular weight.
public struct IMMIcon: View {
    private let name: String
    private let size: CGFloat
    private let color: Color?

    /// - Parameters:
    ///   - name: design icon name such as `"search"` or `"chevron-right"` (see `IMMSymbol.table`).
    ///   - size: pixel size from the design (12, 14, 16, 20, 48).
    ///   - color: nil inherits the surrounding foreground style.
    public init(_ name: String, size: CGFloat, color: Color? = nil) {
        self.name = name
        self.size = size
        self.color = color
    }

    public var body: some View {
        Group {
            if let symbol = IMMSymbol.resolvedName(for: name) {
                if let color {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: size, weight: .regular))
                        .foregroundStyle(color)
                } else {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: size, weight: .regular))
                }
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
