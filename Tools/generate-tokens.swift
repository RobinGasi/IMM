#!/usr/bin/env swift
// Generates Packages/IMMKit/Sources/IMMDesign/Generated/Tokens.swift from the design system registry.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Tools/generate-tokens.swift
//
// Run from the repository root. Optional arguments: <imm.json> <output.swift>.
// Tokens are never typed by hand: change imm.json (re-export the design) and run this script again.

import Foundation

struct RGBA {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-tokens: \(message)\n".utf8))
    exit(1)
}

// MARK: - Colour parsing

func parseNumber(_ s: String) -> Double? {
    var text = s.trimmingCharacters(in: .whitespaces)
    var scale = 1.0
    if text.hasSuffix("%") {
        text.removeLast()
        scale = 0.01
    }
    guard let v = Double(text) else { return nil }
    return v * scale
}

func linearToSRGB(_ x: Double) -> Double {
    let a = abs(x)
    let v = a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1.0 / 2.4) - 0.055
    return x < 0 ? -v : v
}

/// OKLCH to linear sRGB (not clipped).
func oklchToLinear(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
    let hr = h * Double.pi / 180
    let a = c * cos(hr)
    let b = c * sin(hr)
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let lc = l_ * l_ * l_
    let mc = m_ * m_ * m_
    let sc = s_ * s_ * s_
    let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
    let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
    let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
    return (r, g, bl)
}

func inGamut(_ rgb: (Double, Double, Double)) -> Bool {
    let e = 0.000001
    return rgb.0 >= -e && rgb.0 <= 1 + e && rgb.1 >= -e && rgb.1 <= 1 + e && rgb.2 >= -e && rgb.2 <= 1 + e
}

func oklchToSRGB(l: Double, c: Double, h: Double) -> RGBA {
    var rgb = oklchToLinear(l: l, c: c, h: h)
    if !inGamut(rgb) {
        // Gamut mapping: keep lightness and hue, reduce chroma by bisection.
        var lo = 0.0
        var hi = c
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if inGamut(oklchToLinear(l: l, c: mid, h: h)) { lo = mid } else { hi = mid }
        }
        rgb = oklchToLinear(l: l, c: lo, h: h)
    }
    func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    return RGBA(r: clamp(linearToSRGB(rgb.0)), g: clamp(linearToSRGB(rgb.1)), b: clamp(linearToSRGB(rgb.2)), a: 1)
}

func parseColor(_ raw: String) -> RGBA {
    let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if s.hasPrefix("#") {
        var hex = String(s.dropFirst())
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { fail("bad hex colour \(raw)") }
        if hex.count == 6 {
            return RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: 1)
        }
        return RGBA(
            r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
            b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
    }
    if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
        let fn = String(s[s.startIndex..<open])
        let inner = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        let alphaSplit = inner.split(separator: "/", maxSplits: 1).map(String.init)
        let parts = alphaSplit[0]
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
        var alpha = 1.0
        var parts2 = parts
        if alphaSplit.count == 2 {
            guard let a = parseNumber(alphaSplit[1]) else { fail("bad alpha in \(raw)") }
            alpha = a
        } else if fn == "rgba", parts.count == 4 {
            guard let a = parseNumber(parts[3]) else { fail("bad alpha in \(raw)") }
            alpha = a
            parts2 = Array(parts.prefix(3))
        }
        switch fn {
        case "rgb", "rgba":
            guard parts2.count == 3 else { fail("bad rgb colour \(raw)") }
            let comps = parts2.map { p -> Double in
                guard let v = parseNumber(p) else { fail("bad rgb component in \(raw)") }
                return p.hasSuffix("%") ? v : v / 255
            }
            return RGBA(r: comps[0], g: comps[1], b: comps[2], a: alpha)
        case "oklch":
            guard parts2.count == 3,
                let l = parseNumber(parts2[0]),
                let c = parseNumber(parts2[1]),
                let h = parseNumber(parts2[2].replacingOccurrences(of: "deg", with: ""))
            else { fail("bad oklch colour \(raw)") }
            var out = oklchToSRGB(l: l, c: c, h: h)
            out.a = alpha
            return out
        default:
            fail("unsupported colour function in \(raw)")
        }
    }
    fail("unsupported colour value \(raw)")
}

// MARK: - Naming and number formatting

func camelCase(_ token: String) -> String {
    let parts = token.split(separator: "-").map(String.init)
    guard let first = parts.first else { return token }
    return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}

func num(_ x: Double) -> String {
    let rounded = (x * 1_000_000_000).rounded() / 1_000_000_000
    var s = "\(rounded)"
    if s.hasSuffix(".0") { s.removeLast(2); s += ".0" }
    return s
}

func rgbaLiteral(_ c: RGBA) -> String {
    "IMMRGBA(r: \(num(c.r)), g: \(num(c.g)), b: \(num(c.b)), a: \(num(c.a)))"
}

// MARK: - Load

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let args = CommandLine.arguments
let inputURL = args.count > 1
    ? URL(fileURLWithPath: args[1], relativeTo: cwd)
    : cwd.appendingPathComponent("DesignReference/imm.json")
let outputURL = args.count > 2
    ? URL(fileURLWithPath: args[2], relativeTo: cwd)
    : cwd.appendingPathComponent("Packages/IMMKit/Sources/IMMDesign/Generated/Tokens.swift")

guard let data = try? Data(contentsOf: inputURL),
    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let cssVars = root["cssVars"] as? [String: Any],
    let light = cssVars["light"] as? [String: String],
    let dark = cssVars["dark"] as? [String: String]
else { fail("cannot read cssVars.light / cssVars.dark from \(inputURL.path) (run from the repository root)") }
let theme = (cssVars["theme"] as? [String: String]) ?? [:]

// Colour tokens: every light key except `radius`; dark falls back to light when absent.
let radiusKey = "radius"
let tokenNames = light.keys.filter { $0 != radiusKey }.sorted()
guard !tokenNames.isEmpty else { fail("no colour tokens found") }
for name in dark.keys where name != radiusKey && light[name] == nil {
    fail("token \(name) exists only in the dark scheme")
}

// MARK: - Radius

func remToPx(_ s: String) -> Double {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.hasSuffix("rem"), let v = Double(t.dropLast(3)) { return v * 16 }
    if t.hasSuffix("px"), let v = Double(t.dropLast(2)) { return v }
    fail("unsupported radius value \(s)")
}

guard let radiusRaw = light[radiusKey] else { fail("cssVars.light.radius missing") }
let baseRadius = remToPx(radiusRaw)
// theme: "--radius-md": "calc(var(--radius) * 0.8)" or "var(--radius)"
var radii: [(name: String, value: Double)] = []
for key in theme.keys.sorted() where key.hasPrefix("--radius-") {
    let suffix = String(key.dropFirst("--radius-".count))
    let expr = theme[key] ?? ""
    var factor = 1.0
    if expr.hasPrefix("calc("), let star = expr.lastIndex(of: "*") {
        let tail = expr[expr.index(after: star)...].replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)
        guard let f = Double(tail) else { fail("bad radius expression \(expr)") }
        factor = f
    } else if expr != "var(--radius)" {
        fail("unsupported radius expression \(expr)")
    }
    let swiftName: String
    switch suffix {
    case "sm", "md", "lg", "xl": swiftName = suffix
    case "2xl": swiftName = "xl2"
    case "3xl": swiftName = "xl3"
    case "4xl": swiftName = "xl4"
    default: fail("unknown radius step \(suffix)")
    }
    radii.append((swiftName, baseRadius * factor))
}
let radiusOrder = ["sm", "md", "lg", "xl", "xl2", "xl3", "xl4"]
radii.sort { (radiusOrder.firstIndex(of: $0.name) ?? 99) < (radiusOrder.firstIndex(of: $1.name) ?? 99) }

// MARK: - Emit

var out = ""
out += """
// Generated by Tools/generate-tokens.swift from DesignReference/imm.json.
// Do not edit by hand: change the design system and re-run the script.

import AppKit
import SwiftUI

/// sRGB components with alpha, 0...1.
public struct IMMRGBA: Sendable, Equatable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// Design-system colour tokens, light and dark, following the system appearance.
public enum IMMColor {

"""
out += "\n"
for name in tokenNames {
    let l = parseColor(light[name]!)
    let d = parseColor(dark[name] ?? light[name]!)
    out += "    /// `--\(name)`: light \(light[name]!), dark \(dark[name] ?? light[name]!)\n"
    out += "    public static let \(camelCase(name)): Color = dynamicColor(\(rgbaLiteral(l)), \(rgbaLiteral(d)))\n"
}
out += "\n    /// Every token name as written in CSS (`chart-1`, `muted-foreground`, ...), sorted.\n"
out += "    public static let tokenNames: [String] = [\n"
for name in tokenNames { out += "        \"\(name)\",\n" }
out += "    ]\n\n"

out += "    /// Raw values exactly as exported in imm.json.\n"
out += "    public static let tokenValues: [String: (light: String, dark: String)] = [\n"
for name in tokenNames {
    out += "        \"\(name)\": (light: \"\(light[name]!)\", dark: \"\(dark[name] ?? light[name]!)\"),\n"
}
out += "    ]\n\n"

out += "    /// sRGB components after conversion, per token and scheme.\n"
out += "    public static let components: [String: (light: IMMRGBA, dark: IMMRGBA)] = [\n"
for name in tokenNames {
    let l = parseColor(light[name]!)
    let d = parseColor(dark[name] ?? light[name]!)
    out += "        \"\(name)\": (light: \(rgbaLiteral(l)), dark: \(rgbaLiteral(d))),\n"
}
out += "    ]\n\n"

out += """
    /// The colour for a CSS token name such as `"chart-1"`, `"muted-foreground"` or `"credit"`.
    public static func named(_ token: String) -> Color {
        switch token {

"""
for name in tokenNames { out += "        case \"\(name)\": return \(camelCase(name))\n" }
out += """
        default:
            assertionFailure("Unknown design token \\(token)")
            return Color.red
        }
    }

    /// The same token as a dynamic `NSColor` (for AppKit views), or nil for an unknown name.
    public static func nsColor(named token: String) -> NSColor? {
        guard let pair = components[token] else { return nil }
        return makeNSColor(pair.light, pair.dark)
    }

    /// The token resolved for a given appearance.
    public static func resolved(_ token: String, dark isDark: Bool) -> IMMRGBA? {
        guard let pair = components[token] else { return nil }
        return isDark ? pair.dark : pair.light
    }

    private static func makeNSColor(_ light: IMMRGBA, _ dark: IMMRGBA) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
    }

    private static func dynamicColor(_ light: IMMRGBA, _ dark: IMMRGBA) -> Color {
        Color(nsColor: makeNSColor(light, dark))
    }
}

/// Corner radii in points (`--radius` 0.45rem at 16 px per rem).
public enum IMMRadius {
    /// `--radius`
    public static let base: CGFloat = \(num(baseRadius))

"""
for r in radii { out += "    public static let \(r.name): CGFloat = \(num(r.value))\n" }
out += """
    /// `rounded-full`
    public static let full: CGFloat = 9999
}

"""

let parent = outputURL.deletingLastPathComponent()
do {
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try out.write(to: outputURL, atomically: true, encoding: .utf8)
} catch {
    fail("cannot write \(outputURL.path): \(error)")
}
print("wrote \(outputURL.path) (\(tokenNames.count) tokens, \(radii.count) radii)")
