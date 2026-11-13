import SwiftUI

/// Container for one or more `Banner` rows: 1 px border, large radius, rows separated by a rule.
public struct BannerGroup<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(1)
        .clipShape(RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IMMRadius.lg, style: .continuous)
                .strokeBorder(IMMColor.border, lineWidth: 1)
        )
    }
}

/// One banner row of the Sync failed screen: 16 px status icon, message (13/20), actions on the right.
///
/// Put rows in a `BannerGroup`; every row after the first sets `isFirst: false` (10 px instead of
/// 12 px vertical padding and a rule above).
public struct Banner<Message: View, Actions: View>: View {
    public enum Tone: Sendable, Equatable {
        case destructive, warning
    }

    private let tone: Tone
    private let icon: String
    private let isFirst: Bool
    private let riseDelay: Double
    private let message: Message
    private let actions: Actions

    public init(
        tone: Tone, icon: String, isFirst: Bool = true, riseDelay: Double = 0,
        @ViewBuilder message: () -> Message, @ViewBuilder actions: () -> Actions
    ) {
        self.tone = tone
        self.icon = icon
        self.isFirst = isFirst
        self.riseDelay = riseDelay
        self.message = message()
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rule()
            }
            HStack(alignment: .center, spacing: 12) {
                IMMIcon(icon, size: 16, color: tone == .destructive ? IMMColor.destructive : IMMColor.warning)
                    .frame(width: 16)
                message
                    .immFont(.body)
                    .foregroundStyle(IMMColor.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    actions
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, isFirst ? 12 : 10)
        }
        .immRiseIn(duration: 0.24, delay: riseDelay)
        .accessibilityElement(children: .contain)
    }
}
