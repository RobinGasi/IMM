import SwiftUI

/// A 4 px share bar: `muted` track, coloured fill of `fraction` of the width, optional `grow-x`.
public struct ShareBar: View {
    private let fraction: Double
    private let color: Color
    private let height: CGFloat
    private let growDelay: Double?
    private let growDuration: Double

    public init(
        fraction: Double, color: Color = IMMColor.primary, height: CGFloat = 4,
        growDelay: Double? = nil, growDuration: Double = 0.45
    ) {
        self.fraction = fraction
        self.color = color
        self.height = height
        self.growDelay = growDelay
        self.growDuration = growDuration
    }

    public var body: some View {
        let f = min(1, max(0, fraction))
        ZStack(alignment: .leading) {
            Capsule(style: .circular).fill(IMMColor.muted)
            GeometryReader { proxy in
                fill(width: proxy.size.width * f)
            }
        }
        .frame(height: height)
        .clipShape(Capsule(style: .circular))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func fill(width: CGFloat) -> some View {
        if let growDelay {
            Capsule(style: .circular).fill(color).frame(width: width)
                .immGrowX(duration: growDuration, delay: growDelay)
        } else {
            Capsule(style: .circular).fill(color).frame(width: width)
        }
    }
}

/// An 8 px colour dot for chart legends and category markers.
public struct LegendDot: View {
    private let color: Color
    private let size: CGFloat

    public init(_ color: Color, size: CGFloat = 8) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
