import SwiftUI

/// Label, large amount and caption stacked 2 px apart (net worth, balance, total).
///
/// `size` follows `clamp(26, 2.3 %, 32)`: pass `IMMLayout.heroFontSize(windowWidth:)`.
public struct HeroAmount: View {
    private let label: Text?
    private let amount: String
    private let caption: Text?
    private let size: CGFloat
    private let amountColor: Color

    public init(
        label: Text? = nil, amount: String, caption: Text? = nil, size: CGFloat = 32,
        amountColor: Color = IMMColor.foreground
    ) {
        self.label = label
        self.amount = amount
        self.caption = caption
        self.size = size
        self.amountColor = amountColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                label.immFont(.small).foregroundStyle(IMMColor.mutedForeground)
            }
            Text(verbatim: amount)
                .immFont(IMMFont.amountHero.sized(size))
                .foregroundStyle(amountColor)
            if let caption {
                caption.immFont(.small).foregroundStyle(IMMColor.mutedForeground)
            }
        }
    }
}
