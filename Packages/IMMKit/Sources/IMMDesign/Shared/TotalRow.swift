import SwiftUI

/// A total: 1 px rule above, 3 px double rule below, 36 px high including both.
public struct TotalRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            DoubleRule()
        }
        .frame(height: 36)
    }
}

extension TotalRow where Content == TotalRowText {
    /// "Total" and an amount in a 100 px right-aligned column (13/20 semibold, tabular).
    public init(_ label: Text, amount: String, amountWidth: CGFloat = 100) {
        self.init {
            TotalRowText(label: label, amount: amount, amountWidth: amountWidth)
        }
    }
}

public struct TotalRowText: View {
    let label: Text
    let amount: String
    let amountWidth: CGFloat

    public var body: some View {
        HStack(spacing: 12) {
            label
                .immFont(.bodySemibold)
                .foregroundStyle(IMMColor.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: amount)
                .immFont(IMMFont.bodySemibold.tabular)
                .foregroundStyle(IMMColor.foreground)
                .frame(width: amountWidth, alignment: .trailing)
        }
    }
}
