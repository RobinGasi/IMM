import SwiftUI

/// Puts the keyboard cursor into a form's first field once, when the form appears in the key window.
///
/// The focus is set one turn after the window becomes key (the field may not be in the window yet), and
/// never in a window that is not key: an offscreen or background window keeps its fields unfocused, so
/// it draws no focus ring.
private struct InitialFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding
    let isEnabled: Bool

    @Environment(\.controlActiveState) private var activeState
    @State private var done = false

    func body(content: Content) -> some View {
        content.task(id: activeState == .key) {
            guard activeState == .key, isEnabled, !done else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            focus.wrappedValue = true
            done = true
        }
    }
}

extension View {
    /// Focuses the field behind `focus` the first time this view is in the key window.
    func initialFocus(_ focus: FocusState<Bool>.Binding, isEnabled: Bool = true) -> some View {
        modifier(InitialFocus(focus: focus, isEnabled: isEnabled))
    }
}
