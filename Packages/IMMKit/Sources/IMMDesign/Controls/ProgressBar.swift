import SwiftUI

/// The design's `Progress` track and indicator: 4 px high, `muted` track, `primary` fill.
public struct ProgressBar: View {
    private let value: Double
    private let tint: Color
    private let height: CGFloat
    private let growDuration: Double?
    private let growDelay: Double?

    /// - Parameters:
    ///   - value: 0...1 (values outside are clamped).
    ///   - tint: fill colour (`primary`; budgets use chart tokens or `destructive`).
    ///   - growDelay: when set the fill plays `grow-x` with this delay (and `growDuration`, default 0.45 s).
    public init(
        value: Double, tint: Color = IMMColor.primary, height: CGFloat = 4,
        growDelay: Double? = nil, growDuration: Double = 0.45
    ) {
        self.value = value
        self.tint = tint
        self.height = height
        self.growDelay = growDelay
        self.growDuration = growDuration
    }

    public var body: some View {
        let fraction = min(1, max(0, value))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous).fill(IMMColor.muted)
            GeometryReader { proxy in
                fill(width: proxy.size.width * fraction)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous))
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int((fraction * 100).rounded())) %"))
    }

    @ViewBuilder
    private func fill(width: CGFloat) -> some View {
        if let growDelay {
            Rectangle().fill(tint).frame(width: width)
                .immGrowX(duration: growDuration, delay: growDelay)
        } else {
            Rectangle().fill(tint).frame(width: width)
        }
    }
}
