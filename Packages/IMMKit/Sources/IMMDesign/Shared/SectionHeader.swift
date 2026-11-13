import SwiftUI

/// Section heading row: 24 px high, 15/20 semibold title on the left, 12/16 muted detail on the right.
public struct SectionHeader<Trailing: View>: View {
    private let title: Text
    private let trailing: Trailing

    public init(_ title: Text, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            title.immFont(.titleMD).foregroundStyle(IMMColor.foreground)
            Spacer(minLength: 0)
            trailing
        }
        .frame(height: 24, alignment: .top)
    }
}

/// The right-hand text of a `SectionHeader`: 12/16 `muted-foreground`.
public struct SectionHeaderDetail: View {
    let text: Text

    public var body: some View {
        text.immFont(.small).foregroundStyle(IMMColor.mutedForeground)
    }
}

extension SectionHeader where Trailing == SectionHeaderDetail {
    /// - Parameter detail: right-hand text such as "Synced today, 08:42".
    public init(_ title: Text, detail: Text) {
        self.init(title) {
            SectionHeaderDetail(text: detail)
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    public init(_ title: Text) {
        self.init(title) { EmptyView() }
    }
}
