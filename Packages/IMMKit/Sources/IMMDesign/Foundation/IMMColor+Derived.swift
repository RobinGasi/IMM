import AppKit
import SwiftUI

/// Colours the components derive from tokens (Tailwind `/NN` alpha modifiers and `color-mix`).
/// They follow the same light/dark switching as the generated tokens.
extension IMMColor {
    static func dynamicNSColor(light: IMMRGBA, dark: IMMRGBA) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
    }

    static func makeDynamic(light: IMMRGBA, dark: IMMRGBA) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    private static func rgba(_ token: String, dark: Bool, alpha: Double) -> IMMRGBA {
        guard let c = resolved(token, dark: dark) else { return IMMRGBA(r: 1, g: 0, b: 1, a: 1) }
        return IMMRGBA(r: c.r, g: c.g, b: c.b, a: alpha)
    }

    /// A token with a different alpha in light and dark.
    static func token(_ token: String, lightAlpha: Double, darkAlpha: Double) -> Color {
        makeDynamic(light: rgba(token, dark: false, alpha: lightAlpha), dark: rgba(token, dark: true, alpha: darkAlpha))
    }

    /// Input, select trigger, outline badge background: `input/20`, dark `input/30`.
    public static let inputFill: Color = token("input", lightAlpha: 0.2, darkAlpha: 0.3)
    /// Select trigger hover: light unchanged (`input/20`), dark `input/50`.
    public static let inputFillHover: Color = token("input", lightAlpha: 0.2, darkAlpha: 0.5)
    /// Outline button rest: transparent, dark `input/30`.
    public static let outlineButtonFill: Color = token("input", lightAlpha: 0, darkAlpha: 0.3)
    /// Outline button hover: `input/50`.
    public static let outlineButtonHover: Color = token("input", lightAlpha: 0.5, darkAlpha: 0.5)
    /// Ghost button hover: `muted`, dark `muted/50`.
    public static let ghostHover: Color = token("muted", lightAlpha: 1, darkAlpha: 0.5)
    /// Destructive button: `destructive/10`, dark `/20`.
    public static let destructiveFill: Color = token("destructive", lightAlpha: 0.1, darkAlpha: 0.2)
    /// Destructive button hover: `destructive/20`, dark `/30`.
    public static let destructiveFillHover: Color = token("destructive", lightAlpha: 0.2, darkAlpha: 0.3)
    /// Invalid border: `destructive`, dark `destructive/50`.
    public static let destructiveBorder: Color = token("destructive", lightAlpha: 1, darkAlpha: 0.5)
    /// Invalid ring: `destructive/20`, dark `/40`.
    public static let destructiveRing: Color = token("destructive", lightAlpha: 0.2, darkAlpha: 0.4)
    /// Focus ring 2 px: `ring/30`.
    public static let focusRing: Color = token("ring", lightAlpha: 0.3, darkAlpha: 0.3)
    /// Focus ring 3 px (badge, toggle, tabs): `ring/50`.
    public static let focusRingStrong: Color = token("ring", lightAlpha: 0.5, darkAlpha: 0.5)
    /// Switch off: `input`, dark `input/80`.
    public static let switchOff: Color = token("input", lightAlpha: 1, darkAlpha: 0.8)
    /// Inactive tab text: `foreground/60`, dark `muted-foreground`.
    public static let tabText: Color = makeDynamic(
        light: rgba("foreground", dark: false, alpha: 0.6), dark: rgba("muted-foreground", dark: true, alpha: 1))
    /// Active tab fill: `background`, dark `input/30`.
    public static let tabActiveFill: Color = makeDynamic(
        light: rgba("background", dark: false, alpha: 1), dark: rgba("input", dark: true, alpha: 0.3))
    /// Active tab border: transparent, dark `input`.
    public static let tabActiveBorder: Color = makeDynamic(
        light: rgba("input", dark: false, alpha: 0), dark: rgba("input", dark: true, alpha: 1))
    /// Scrim over the whole window: `foreground` mixed into transparent (`percent` 0...1).
    public static func scrim(_ percent: Double) -> Color {
        token("foreground", lightAlpha: percent, darkAlpha: percent)
    }

    /// Default button hover: `color-mix(in oklab, primary 86%, black)`.
    public static let primaryHover: Color = makeDynamic(
        light: IMMColorMath.mixWithBlack(rgba("primary", dark: false, alpha: 1), keep: 0.86),
        dark: IMMColorMath.mixWithBlack(rgba("primary", dark: true, alpha: 1), keep: 0.86))
    /// Secondary button hover: `secondary` mixed with 5 % `foreground`.
    public static let secondaryHover: Color = makeDynamic(
        light: IMMColorMath.mix(rgba("secondary", dark: false, alpha: 1), rgba("foreground", dark: false, alpha: 1), amount: 0.05),
        dark: IMMColorMath.mix(rgba("secondary", dark: true, alpha: 1), rgba("foreground", dark: true, alpha: 1), amount: 0.05))
}

/// Small colour arithmetic used for derived tokens.
enum IMMColorMath {
    private static func toLinear(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private static func fromLinear(_ x: Double) -> Double {
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return min(1, max(0, v))
    }

    /// Linear interpolation in sRGB: `amount` of `other` into `base`.
    static func mix(_ base: IMMRGBA, _ other: IMMRGBA, amount: Double) -> IMMRGBA {
        IMMRGBA(
            r: base.r + (other.r - base.r) * amount,
            g: base.g + (other.g - base.g) * amount,
            b: base.b + (other.b - base.b) * amount,
            a: base.a)
    }

    /// `color-mix(in oklab, c keep%, black)`: lightness and both chroma axes scale by `keep`.
    static func mixWithBlack(_ c: IMMRGBA, keep: Double) -> IMMRGBA {
        let r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s) * keep
        let A = (1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s) * keep
        let B = (0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s) * keep
        let l_ = L + 0.3963377774 * A + 0.2158037573 * B
        let m_ = L - 0.1055613458 * A - 0.0638541728 * B
        let s_ = L - 0.0894841775 * A - 1.2914855480 * B
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        return IMMRGBA(
            r: fromLinear(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
            g: fromLinear(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
            b: fromLinear(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc),
            a: c.a)
    }
}
