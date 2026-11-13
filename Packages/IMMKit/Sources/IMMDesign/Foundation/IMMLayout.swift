import CoreGraphics

/// Fixed sizes and the fluid `clamp()` values of the design (there are no breakpoints).
public enum IMMLayout {
    /// Main window toolbar and sidebar header.
    public static let toolbarHeight: CGFloat = 56
    /// Setup window title bar.
    public static let setupTitlebarHeight: CGFloat = 52

    /// `clamp(min, fraction × width, max)`; `fraction` is 0.175 for `17.5vw`.
    public static func clamp(_ minimum: CGFloat, fraction: CGFloat, of width: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, fraction * width))
    }

    /// `clamp(212px, 17.5vw, 252px)`
    public static func sidebarWidth(windowWidth: CGFloat) -> CGFloat {
        clamp(212, fraction: 0.175, of: windowWidth, maximum: 252)
    }

    /// `clamp(20px, 2.2vw, 32px)`
    public static func contentPadding(windowWidth: CGFloat) -> CGFloat {
        clamp(20, fraction: 0.022, of: windowWidth, maximum: 32)
    }

    /// `clamp(26px, 2.3vw, 32px)`
    public static func heroFontSize(windowWidth: CGFloat) -> CGFloat {
        clamp(26, fraction: 0.023, of: windowWidth, maximum: 32)
    }

    /// `clamp(300px, 25vw, 360px)` of the window width.
    public static func inspectorWidth(windowWidth: CGFloat) -> CGFloat {
        clamp(300, fraction: 0.25, of: windowWidth, maximum: 360)
    }
}
