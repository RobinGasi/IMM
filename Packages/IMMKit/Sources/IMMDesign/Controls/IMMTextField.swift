import SwiftUI

/// Border, fill and focus ring shared by text fields, secure fields, input groups and select triggers.
struct IMMInputChrome: ViewModifier {
    let focused: Bool
    let invalid: Bool
    let height: CGFloat
    let hovering: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.immInert) private var inert

    init(focused: Bool, invalid: Bool, height: CGFloat = 28, hovering: Bool = false) {
        self.focused = focused
        self.invalid = invalid
        self.height = height
        self.hovering = hovering
    }

    private var borderColor: Color {
        if invalid { return IMMColor.destructiveBorder }
        return focused ? IMMColor.ring : IMMColor.input
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: IMMRadius.md, style: .continuous)
        content
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(shape.fill(hovering ? IMMColor.inputFillHover : IMMColor.inputFill))
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .overlay {
                if invalid {
                    shape.stroke(IMMColor.destructiveRing, lineWidth: 2).padding(-1)
                } else if focused {
                    shape.stroke(IMMColor.focusRing, lineWidth: 2).padding(-1)
                }
            }
            .opacity(isEnabled || inert ? 1 : 0.5)
    }
}

/// Binds a field to the internal focus state, or to the caller's when one is given, and reports which one
/// is in effect. Callers that need to move focus (Unlock puts the cursor in the password field) pass a
/// `FocusState<Bool>.Binding`; everyone else leaves it out.
private struct FieldFocus: ViewModifier {
    let external: FocusState<Bool>.Binding?
    let internalFocus: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if let external {
            content.focused(external)
        } else {
            content.focused(internalFocus)
        }
    }
}

private func effectiveFocus(_ external: FocusState<Bool>.Binding?, _ internalFocus: Bool) -> Bool {
    external?.wrappedValue ?? internalFocus
}

/// The design's `Input`: 28 px, 1 px input border, error state, focus ring.
public struct IMMTextField: View {
    @Binding private var text: String
    private let prompt: Text?
    private let isError: Bool
    private let style: IMMFont
    private let externalFocus: FocusState<Bool>.Binding?
    @FocusState private var focused: Bool
    @Environment(\.immFieldInvalid) private var fieldInvalid

    /// - Parameters:
    ///   - prompt: placeholder, drawn in `muted-foreground`.
    ///   - isError: error state; also set by an enclosing `Field` that shows an error.
    ///   - style: `.controlRegular` (12/19.5, default), `.inputLarge` (Settings, 14/20) or `.mono` (IBAN).
    ///   - focused: optional focus state owned by the caller, to move or read keyboard focus.
    public init(
        text: Binding<String>, prompt: Text? = nil, isError: Bool = false, style: IMMFont = .controlRegular,
        focused: FocusState<Bool>.Binding? = nil
    ) {
        self._text = text
        self.prompt = prompt
        self.isError = isError
        self.style = style
        self.externalFocus = focused
    }

    public var body: some View {
        TextField(text: $text, prompt: prompt?.foregroundStyle(IMMColor.mutedForeground)) {
            EmptyView()
        }
        .textFieldStyle(.plain)
        .modifier(FieldFocus(external: externalFocus, internalFocus: $focused))
        .focusEffectDisabled()
        .immFont(style)
        .foregroundStyle(IMMColor.foreground)
        .tint(IMMColor.primary)
        .modifier(IMMInputChrome(
            focused: effectiveFocus(externalFocus, focused), invalid: isError || fieldInvalid))
    }
}

/// The same input for passwords and PINs.
public struct IMMSecureField: View {
    @Binding private var text: String
    private let prompt: Text?
    private let isError: Bool
    private let style: IMMFont
    private let externalFocus: FocusState<Bool>.Binding?
    @FocusState private var focused: Bool
    @Environment(\.immFieldInvalid) private var fieldInvalid

    ///   - focused: optional focus state owned by the caller, to move or read keyboard focus.
    public init(
        text: Binding<String>, prompt: Text? = nil, isError: Bool = false, style: IMMFont = .controlRegular,
        focused: FocusState<Bool>.Binding? = nil
    ) {
        self._text = text
        self.prompt = prompt
        self.isError = isError
        self.style = style
        self.externalFocus = focused
    }

    public var body: some View {
        SecureField(text: $text, prompt: prompt?.foregroundStyle(IMMColor.mutedForeground)) {
            EmptyView()
        }
        .textFieldStyle(.plain)
        .modifier(FieldFocus(external: externalFocus, internalFocus: $focused))
        .focusEffectDisabled()
        .immFont(style)
        .foregroundStyle(IMMColor.foreground)
        .tint(IMMColor.primary)
        .modifier(IMMInputChrome(
            focused: effectiveFocus(externalFocus, focused), invalid: isError || fieldInvalid))
    }
}

/// The design's `InputGroup`: an input with an addon on either side (search icon, check icon, text).
///
/// Addon content is drawn in `muted-foreground` at 12/19.5 medium; icons are 14 px (`IMMIcon`).
public struct InputGroup<Leading: View, Trailing: View>: View {
    @Binding private var text: String
    private let prompt: Text?
    private let isError: Bool
    private let secure: Bool
    private let leading: Leading
    private let trailing: Trailing
    private let externalFocus: FocusState<Bool>.Binding?
    @FocusState private var focused: Bool
    @Environment(\.immFieldInvalid) private var fieldInvalid

    public init(
        text: Binding<String>, prompt: Text? = nil, isError: Bool = false, secure: Bool = false,
        focused: FocusState<Bool>.Binding? = nil,
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) {
        self.externalFocus = focused
        self._text = text
        self.prompt = prompt
        self.isError = isError
        self.secure = secure
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 4) {
            leading
                .immFont(.smallMedium)
                .foregroundStyle(IMMColor.mutedForeground)
            field
            trailing
                .immFont(.smallMedium)
                .foregroundStyle(IMMColor.mutedForeground)
        }
        .focusEffectDisabled()
        .modifier(IMMInputChrome(focused: effectiveFocus(externalFocus, focused), invalid: isError || fieldInvalid))
    }

    @ViewBuilder
    private var field: some View {
        if secure {
            SecureField(text: $text, prompt: prompt?.foregroundStyle(IMMColor.mutedForeground)) { EmptyView() }
                .textFieldStyle(.plain)
                .modifier(FieldFocus(external: externalFocus, internalFocus: $focused))
                .immFont(.controlRegular)
                .foregroundStyle(IMMColor.foreground)
        } else {
            TextField(text: $text, prompt: prompt?.foregroundStyle(IMMColor.mutedForeground)) { EmptyView() }
                .textFieldStyle(.plain)
                .modifier(FieldFocus(external: externalFocus, internalFocus: $focused))
                .immFont(.controlRegular)
                .foregroundStyle(IMMColor.foreground)
        }
    }
}

extension InputGroup where Trailing == EmptyView {
    public init(
        text: Binding<String>, prompt: Text? = nil, isError: Bool = false, secure: Bool = false,
        focused: FocusState<Bool>.Binding? = nil,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(
            text: text, prompt: prompt, isError: isError, secure: secure, focused: focused, leading: leading
        ) { EmptyView() }
    }
}
