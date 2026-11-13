import SwiftUI

private struct IMMWindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1440
}

extension EnvironmentValues {
    /// Width of the main window in points. The design's `vw` units (`clamp(20px, 2.2vw, 32px)`, hero
    /// figures, sidebar) are relative to it: pass it to `IMMLayout.contentPadding(windowWidth:)` and
    /// `IMMLayout.heroFontSize(windowWidth:)`. Screenshot tests set it to the artboard width.
    public var immWindowWidth: CGFloat {
        get { self[IMMWindowWidthKey.self] }
        set { self[IMMWindowWidthKey.self] = newValue }
    }
}
