import SwiftUI

/// The design's `Kbd`: 20 px high key cap, 10 px medium text on `muted`.
public struct Kbd: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(verbatim: text)
            .immFont(.badge)
            .foregroundStyle(IMMColor.mutedForeground)
            .padding(.horizontal, 4)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(IMMColor.muted))
            .fixedSize()
            .accessibilityLabel(Text(verbatim: text))
    }
}
