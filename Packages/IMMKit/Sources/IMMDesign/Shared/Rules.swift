import SwiftUI

/// A 1 px horizontal rule in the `border` token.
public struct Rule: View {
    private let color: Color

    public init(color: Color = IMMColor.border) {
        self.color = color
    }

    public var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

/// The 3 px double rule closing a total (two 1 px lines with a 1 px gap), `border-b-[3px] border-double`.
public struct DoubleRule: View {
    private let color: Color

    public init(color: Color = IMMColor.border) {
        self.color = color
    }

    public var body: some View {
        VStack(spacing: 1) {
            Rectangle().fill(color).frame(height: 1)
            Rectangle().fill(color).frame(height: 1)
        }
        .frame(height: 3, alignment: .top)
    }
}

/// A 1 px vertical rule (toolbar separators), 16 px high by default.
public struct VerticalRule: View {
    private let height: CGFloat
    private let color: Color

    public init(height: CGFloat = 16, color: Color = IMMColor.border) {
        self.height = height
        self.color = color
    }

    public var body: some View {
        Rectangle().fill(color).frame(width: 1, height: height)
    }
}
