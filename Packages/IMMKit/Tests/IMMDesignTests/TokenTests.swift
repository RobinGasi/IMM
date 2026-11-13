import AppKit
import Foundation
import Testing

@testable import IMMDesign

private struct TokenFile {
    let light: [String: String]
    let dark: [String: String]
    let theme: [String: String]

    static func load() throws -> TokenFile {
        // Tests/IMMDesignTests/TokenTests.swift -> repository root is five levels up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("DesignReference/imm.json")
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let vars = root["cssVars"] as? [String: Any],
            let light = vars["light"] as? [String: String],
            let dark = vars["dark"] as? [String: String]
        else {
            throw TokenTestError.malformed
        }
        return TokenFile(light: light, dark: dark, theme: (vars["theme"] as? [String: String]) ?? [:])
    }

    var colorNames: [String] { light.keys.filter { $0 != "radius" }.sorted() }

    func hex(_ token: String, dark isDark: Bool) -> String {
        (isDark ? dark[token] : nil) ?? light[token] ?? ""
    }
}

private enum TokenTestError: Error {
    case malformed
}

private func parseHex(_ hex: String) -> (Double, Double, Double, Double)? {
    var s = hex.lowercased()
    guard s.hasPrefix("#") else { return nil }
    s.removeFirst()
    guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
    if s.count == 6 {
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
    }
    return (
        Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255,
        Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255
    )
}

@MainActor
private func resolve(_ color: NSColor, dark isDark: Bool) -> (Double, Double, Double, Double) {
    var out: (Double, Double, Double, Double) = (-1, -1, -1, -1)
    let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
    appearance.performAsCurrentDrawingAppearance {
        if let c = color.usingColorSpace(.sRGB) {
            out = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
        }
    }
    return out
}

@MainActor
@Suite struct TokenTests {
    @Test func tokenSetMatchesRegistry() throws {
        let file = try TokenFile.load()
        #expect(IMMColor.tokenNames == file.colorNames)
        #expect(!file.colorNames.isEmpty)
        for name in file.colorNames {
            #expect(IMMColor.tokenValues[name]?.light == file.hex(name, dark: false), "light raw \(name)")
            #expect(IMMColor.tokenValues[name]?.dark == file.hex(name, dark: true), "dark raw \(name)")
            _ = IMMColor.named(name)
        }
    }

    @Test func generatedComponentsEqualRegistryValues() throws {
        let file = try TokenFile.load()
        for name in file.colorNames {
            for isDark in [false, true] {
                let hex = file.hex(name, dark: isDark)
                let expected = try #require(parseHex(hex), "unsupported colour format \(hex) for \(name)")
                let c = try #require(IMMColor.resolved(name, dark: isDark))
                #expect(abs(c.r - expected.0) < 1e-6, "\(name) \(isDark ? "dark" : "light") red")
                #expect(abs(c.g - expected.1) < 1e-6, "\(name) \(isDark ? "dark" : "light") green")
                #expect(abs(c.b - expected.2) < 1e-6, "\(name) \(isDark ? "dark" : "light") blue")
                #expect(abs(c.a - expected.3) < 1e-6, "\(name) \(isDark ? "dark" : "light") alpha")
            }
        }
    }

    @Test func dynamicColorsResolvePerAppearance() throws {
        let file = try TokenFile.load()
        for name in file.colorNames {
            let ns = try #require(IMMColor.nsColor(named: name))
            for isDark in [false, true] {
                let expected = try #require(parseHex(file.hex(name, dark: isDark)))
                let got = resolve(ns, dark: isDark)
                #expect(abs(got.0 - expected.0) < 1e-4, "\(name) \(isDark ? "dark" : "light") red")
                #expect(abs(got.1 - expected.1) < 1e-4, "\(name) \(isDark ? "dark" : "light") green")
                #expect(abs(got.2 - expected.2) < 1e-4, "\(name) \(isDark ? "dark" : "light") blue")
                #expect(abs(got.3 - expected.3) < 1e-4, "\(name) \(isDark ? "dark" : "light") alpha")
            }
        }
    }

    @Test func lightDiffersFromDarkWhereRegistryDiffers() throws {
        let file = try TokenFile.load()
        var differing = 0
        for name in file.colorNames {
            let registryDiffers = file.hex(name, dark: false) != file.hex(name, dark: true)
            let ns = try #require(IMMColor.nsColor(named: name))
            let l = resolve(ns, dark: false)
            let d = resolve(ns, dark: true)
            let resolvedDiffers = abs(l.0 - d.0) + abs(l.1 - d.1) + abs(l.2 - d.2) + abs(l.3 - d.3) > 1e-6
            #expect(resolvedDiffers == registryDiffers, "\(name)")
            if registryDiffers { differing += 1 }
        }
        #expect(differing > 20)
    }

    @Test func radiiFollowBaseRadius() throws {
        let file = try TokenFile.load()
        #expect(file.light["radius"] == "0.45rem")
        #expect(abs(IMMRadius.base - 7.2) < 1e-9)
        #expect(abs(IMMRadius.lg - 7.2) < 1e-9)
        #expect(abs(IMMRadius.md - 5.76) < 1e-9)
        #expect(abs(IMMRadius.sm - 4.32) < 1e-9)
        #expect(abs(IMMRadius.xl - 10.08) < 1e-9)
    }

    @Test func derivedColorsResolve() {
        // color-mix(in oklab, #11604A 86%, black) scales L, a and b by 0.86 -> about #0C4D3B.
        let light = IMMColorMath.mixWithBlack(IMMRGBA(r: 17 / 255, g: 96 / 255, b: 74 / 255, a: 1), keep: 0.86)
        #expect(abs(light.r - 12 / 255) < 1.5 / 255)
        #expect(abs(light.g - 77 / 255) < 1.5 / 255)
        #expect(abs(light.b - 59 / 255) < 1.5 / 255)
    }
}
