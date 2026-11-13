import AppKit
import Testing

@testable import IMMDesign

@Suite struct SymbolTests {
    /// The design's icon mapping: design icon -> symbol.
    private static let planned: [String: String] = [
        "layout-dashboard": "square.grid.2x2", "list": "list.bullet", "check-check": "checklist",
        "book-open": "book", "landmark": "building.columns", "piggy-bank": "banknote",
        "credit-card": "creditcard", "trending-up": "chart.line.uptrend.xyaxis",
        "wallet": "wallet.bifold", "target": "target", "repeat-2": "repeat", "file-text": "doc.text",
        "pie-chart": "chart.pie", "receipt": "receipt", "refresh": "arrow.triangle.2.circlepath",
        "search": "magnifyingglass", "arrow-up-right": "arrow.up.right", "chevron-right": "chevron.right",
        "chevron-left": "chevron.left", "chevron-down": "chevron.down", "plus": "plus",
        "check": "checkmark", "x": "xmark", "file": "doc", "triangle-alert": "exclamationmark.triangle",
        "download": "arrow.down.to.line", "circle-check": "checkmark.circle",
        "circle-alert": "exclamationmark.circle", "clock": "clock", "lock": "lock",
        "settings": "gearshape", "tag": "tag", "share": "square.and.arrow.up",
        "calendar": "calendar.badge.clock", "fingerprint": "touchid", "cpu": "cpu",
        "laptop": "laptopcomputer", "split": "arrow.triangle.branch", "attach": "paperclip",
    ]

    @Test func tableMatchesThePlan() {
        for (icon, symbol) in Self.planned {
            #expect(IMMSymbol.table[icon]?.symbol == symbol, "\(icon)")
        }
        #expect(IMMSymbol.table["wallet"]?.fallback == "wallet.pass")
        #expect(IMMSymbol.table["receipt"]?.fallback == "doc.plaintext")
    }

    @Test func everyMappedSymbolOrItsFallbackResolves() {
        for (icon, entry) in IMMSymbol.table {
            let direct = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) != nil
            let viaFallback = entry.fallback.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } != nil
            #expect(direct || viaFallback, "\(icon) -> \(entry.symbol)")
            #expect(IMMSymbol.resolvedName(for: icon) != nil, "\(icon)")
        }
    }

    @Test func unknownIconHasNoSymbol() {
        #expect(IMMSymbol.resolvedName(for: "no-such-icon") == nil)
    }
}
