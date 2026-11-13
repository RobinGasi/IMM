import IMMDesign
import SwiftUI

/// The "Setup titlebar" component: 52 px, window-chrome background, bottom rule, centred title and the
/// step on the right. The real window buttons sit at the left (120 px are reserved for them).
///
/// Every setup screen starts with one: `SetupTitlebar(step: "Step 1 of 3", title: "Set up IMM")`.
public struct SetupTitlebar: View {
    private let step: String
    private let title: String

    public init(step: String, title: String) {
        self.step = step
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 120)
            Text(verbatim: title)
                .immFont(.bodySemibold)
                .foregroundStyle(IMMColor.foreground)
                .frame(maxWidth: .infinity)
            Text(verbatim: step)
                .immFont(IMMFont.small.tabular)
                .foregroundStyle(IMMColor.mutedForeground)
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: IMMLayout.setupTitlebarHeight)
        .background(IMMColor.windowChrome)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle().fill(IMMColor.border).frame(height: 1)
        }
    }
}
