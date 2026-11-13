import SwiftUI

/// The design's `Field`: label, control, optional description and error, 8 px apart.
/// An error turns the label red and marks the control inside as invalid (`immFieldInvalid`).
public struct Field<Content: View>: View {
    private let label: Text?
    private let description: Text?
    private let error: Text?
    private let content: Content

    public init(
        label: Text? = nil, description: Text? = nil, error: Text? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.description = description
        self.error = error
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                label
                    .immFont(.label)
                    .foregroundStyle(error == nil ? IMMColor.foreground : IMMColor.destructive)
            }
            content
                .environment(\.immFieldInvalid, error != nil)
            if let description {
                description
                    .immFont(.controlRegular)
                    .foregroundStyle(IMMColor.mutedForeground)
            }
            if let error {
                error
                    .immFont(.controlRegular)
                    .foregroundStyle(IMMColor.destructive)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
