import SwiftUI

/// The design's select trigger (28 px, small 24 px) opening a standard macOS menu with the
/// current choice checked. The opened list is system-drawn.
public struct SelectTrigger<Value: Hashable>: View {
    public enum Size: Sendable, Equatable {
        case `default`, sm

        var height: CGFloat { self == .sm ? 24 : 28 }
    }

    @Binding private var selection: Value
    private let options: [IMMOption<Value>]
    private let placeholder: Text?
    private let size: Size
    private let width: CGFloat?
    private let isError: Bool

    @State private var hovering = false
    @Environment(\.immFieldInvalid) private var fieldInvalid

    /// - Parameter width: fixed width (the design uses `w-35` = 140 and `w-37.5` = 150); nil hugs the content.
    public init(
        selection: Binding<Value>, options: [IMMOption<Value>], placeholder: Text? = nil,
        size: Size = .default, width: CGFloat? = nil, isError: Bool = false
    ) {
        self._selection = selection
        self.options = options
        self.placeholder = placeholder
        self.size = size
        self.width = width
        self.isError = isError
    }

    public var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options) { option in
                    option.title.tag(option.value)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            trigger
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .fixedSize(horizontal: width == nil, vertical: true)
        .onHover { hovering = $0 }
    }

    private var currentTitle: Text? {
        options.first(where: { $0.value == selection })?.title ?? placeholder
    }

    private var trigger: some View {
        HStack(spacing: 6) {
            Group {
                if let currentTitle {
                    currentTitle
                } else {
                    Text(verbatim: "")
                }
            }
            .immFont(.controlRegular)
            .foregroundStyle(options.contains(where: { $0.value == selection }) ? IMMColor.foreground : IMMColor.mutedForeground)
            .lineLimit(1)
            Spacer(minLength: 0)
            IMMIcon("chevron-down", size: 14, color: IMMColor.mutedForeground)
        }
        .frame(width: width.map { max(0, $0 - 16) })
        .modifier(IMMInputChrome(focused: false, invalid: isError || fieldInvalid, height: size.height, hovering: hovering))
    }
}
