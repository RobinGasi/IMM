import AppKit
import SwiftUI

/// A named text style from the design inventory (size, weight, tracking, line height).
///
/// Use `Text("…").immFont(.body)`; the modifier applies the font, tracking and line height.
/// `tabular` returns the same style with tabular figures (amounts, dates, counts).
public struct IMMFont: Sendable, Equatable {
    public enum Weight: Sendable, Equatable {
        case regular, medium, semibold
    }

    public enum Family: Sendable, Equatable {
        case sans, mono
    }

    public let name: String
    public let size: CGFloat
    public let weight: Weight
    public let family: Family
    /// CSS line height in points.
    public let lineHeight: CGFloat
    /// Letter spacing in em (−0.02 means −0.02 × size).
    public let tracking: CGFloat
    public let tabularDigits: Bool

    public init(
        name: String, size: CGFloat, lineHeight: CGFloat, weight: Weight = .regular,
        family: Family = .sans, tracking: CGFloat = 0, tabularDigits: Bool = false
    ) {
        self.name = name
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.family = family
        self.tracking = tracking
        self.tabularDigits = tabularDigits
    }

    public var postScriptName: String {
        switch family {
        case .mono: return "GeistMono-Regular"
        case .sans:
            switch weight {
            case .regular: return "Geist-Regular"
            case .medium: return "Geist-Medium"
            case .semibold: return "Geist-SemiBold"
            }
        }
    }

    /// The SwiftUI font (fixed size, no Dynamic Type scaling).
    public var font: Font {
        IMMFonts.registerIfNeeded()
        let base = Font.custom(postScriptName, fixedSize: size)
        return tabularDigits ? base.monospacedDigit() : base
    }

    /// The AppKit font, nil when the font files are not registered.
    public var nsFont: NSFont? {
        IMMFonts.registerIfNeeded()
        return NSFont(name: postScriptName, size: size)
    }

    /// Tracking in points.
    public var trackingPoints: CGFloat { size * tracking }

    /// Height of one line as SwiftUI lays the font out (AppKit's default line height, a whole number).
    public var naturalLineHeight: CGFloat {
        if let f = nsFont { return NSLayoutManager().defaultLineHeight(for: f) }
        return size * 1.2
    }

    public var tabular: IMMFont {
        IMMFont(
            name: name, size: size, lineHeight: lineHeight, weight: weight, family: family,
            tracking: tracking, tabularDigits: true)
    }

    public func sized(_ size: CGFloat, lineHeight: CGFloat? = nil) -> IMMFont {
        IMMFont(
            name: name, size: size, lineHeight: lineHeight ?? self.lineHeight, weight: weight,
            family: family, tracking: tracking, tabularDigits: tabularDigits)
    }

    public func weighted(_ weight: Weight) -> IMMFont {
        IMMFont(
            name: name, size: size, lineHeight: lineHeight, weight: weight, family: family,
            tracking: tracking, tabularDigits: tabularDigits)
    }

    public func withLineHeight(_ lineHeight: CGFloat) -> IMMFont {
        IMMFont(
            name: name, size: size, lineHeight: lineHeight, weight: weight, family: family,
            tracking: tracking, tabularDigits: tabularDigits)
    }

    // MARK: Styles (the design system's text styles)

    /// 32/38, 600, −0.02em, tabular (Tax return total).
    public static let display = IMMFont(
        name: "display", size: 32, lineHeight: 38, weight: .semibold, tracking: -0.02, tabularDigits: true)
    /// 32/40, 600, −0.02em, tabular. Hero figures use `clamp(26, 2.3 %, 32)`: `IMMFont.amountHero.sized(IMMLayout.heroFontSize(windowWidth:))`.
    public static let amountHero = IMMFont(
        name: "amountHero", size: 32, lineHeight: 40, weight: .semibold, tracking: -0.02, tabularDigits: true)
    /// 22/28, 600, −0.02em (screen and sheet titles).
    public static let titleXL = IMMFont(
        name: "titleXL", size: 22, lineHeight: 28, weight: .semibold, tracking: -0.02)
    /// 22/30, 500, −0.01em (October review heading).
    public static let titleXLMedium = IMMFont(
        name: "titleXLMedium", size: 22, lineHeight: 30, weight: .medium, tracking: -0.01)
    /// 20/26, 600, −0.01em (sheet titles).
    public static let titleLG = IMMFont(
        name: "titleLG", size: 20, lineHeight: 26, weight: .semibold, tracking: -0.01)
    /// 15/20, 600 (section headings).
    public static let titleMD = IMMFont(name: "titleMD", size: 15, lineHeight: 20, weight: .semibold)
    /// 15/20, 600, −0.01em (toolbar title, sidebar net worth; add `.tabular` for amounts).
    public static let titleMDTight = IMMFont(
        name: "titleMDTight", size: 15, lineHeight: 20, weight: .semibold, tracking: -0.01)
    /// 15/20, 400.
    public static let bodyLG = IMMFont(name: "bodyLG", size: 15, lineHeight: 20)
    /// 13/20, 400.
    public static let body = IMMFont(name: "body", size: 13, lineHeight: 20)
    /// 13/20, 500.
    public static let bodyMedium = IMMFont(name: "bodyMedium", size: 13, lineHeight: 20, weight: .medium)
    /// 13/20, 600.
    public static let bodySemibold = IMMFont(name: "bodySemibold", size: 13, lineHeight: 20, weight: .semibold)
    /// 12/16, 400.
    public static let small = IMMFont(name: "small", size: 12, lineHeight: 16)
    /// 12/16, 500.
    public static let smallMedium = IMMFont(name: "smallMedium", size: 12, lineHeight: 16, weight: .medium)
    /// 11/16, 400 (chart axes; add `.tabular`).
    public static let caption = IMMFont(name: "caption", size: 11, lineHeight: 16)
    /// 11/16, 600 (sidebar and list group labels).
    public static let captionSemibold = IMMFont(
        name: "captionSemibold", size: 11, lineHeight: 16, weight: .semibold)
    /// 10/10, 600 (step markers).
    public static let micro = IMMFont(name: "micro", size: 10, lineHeight: 10, weight: .semibold)
    /// 10/16, 500 (badge, kbd).
    public static let badge = IMMFont(name: "badge", size: 10, lineHeight: 16, weight: .medium)
    /// 12/19.5, 500 (button, tabs, toggle).
    public static let control = IMMFont(name: "control", size: 12, lineHeight: 19.5, weight: .medium)
    /// 12/19.5, 400 (input, select, field text and errors).
    public static let controlRegular = IMMFont(name: "controlRegular", size: 12, lineHeight: 19.5)
    /// 14/20, 400 (inputs below 768 px viewport width: the Settings window).
    public static let inputLarge = IMMFont(name: "inputLarge", size: 14, lineHeight: 20)
    /// 12/12, 500 (field label, `leading-none`).
    public static let label = IMMFont(name: "label", size: 12, lineHeight: 12, weight: .medium)
    /// 14/20, 500 (field legend).
    public static let legend = IMMFont(name: "legend", size: 14, lineHeight: 20, weight: .medium)
    /// Geist Mono 12/16 (IBAN, BLZ, file path).
    public static let mono = IMMFont(name: "mono", size: 12, lineHeight: 16, family: .mono)
    /// Geist Mono 11/16 (ISIN).
    public static let monoSmall = IMMFont(name: "monoSmall", size: 11, lineHeight: 16, family: .mono)

    /// Every named style, for tests and documentation.
    public static let allStyles: [IMMFont] = [
        display, amountHero, titleXL, titleXLMedium, titleLG, titleMD, titleMDTight, bodyLG, body,
        bodyMedium, bodySemibold, small, smallMedium, caption, captionSemibold, micro, badge, control,
        controlRegular, inputLarge, label, legend, mono, monoSmall,
    ]
}

private struct IMMFontModifier: ViewModifier {
    let style: IMMFont

    func body(content: Content) -> some View {
        // CSS line-height puts the extra space half above and half below every line. SwiftUI adds
        // `lineSpacing` between lines only, so the first and last line each get half as padding:
        // the box is lh for one line and N × lh for N lines. When lh is below the font's natural
        // height the box stays natural (no negative padding).
        let extra = max(0, style.lineHeight - style.naturalLineHeight)
        content
            .font(style.font)
            .tracking(style.trackingPoints)
            .lineSpacing(extra)
            .padding(.vertical, extra / 2)
    }
}

extension View {
    /// Applies font, tracking and line height of a design text style.
    public func immFont(_ style: IMMFont) -> some View {
        modifier(IMMFontModifier(style: style))
    }
}
