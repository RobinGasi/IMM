import AppKit
import CoreText
import Foundation

/// Registers the bundled Geist and Geist Mono files with Core Text for this process.
public enum IMMFonts {
    /// PostScript names of the bundled faces.
    public static let postScriptNames: [String] = [
        "Geist-Regular",
        "Geist-Medium",
        "Geist-SemiBold",
        "GeistMono-Regular",
    ]

    /// File URLs of the bundled font files.
    public static var fileURLs: [URL] {
        var urls: [URL] = []
        let subdirectories: [String?] = ["Fonts", nil]
        for subdirectory in subdirectories {
            urls += Bundle.module.urls(forResourcesWithExtension: "otf", subdirectory: subdirectory) ?? []
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    private static let registration: Bool = {
        for url in fileURLs {
            // Already-registered files report an error that is safe to ignore.
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// Idempotent and thread-safe. Call before the first text is drawn (the app does it at launch);
    /// `IMMFont` calls it too, so styles also work in tests.
    public static func registerIfNeeded() {
        _ = registration
    }

    /// True when a font with this PostScript name resolves after registration.
    public static func isAvailable(postScriptName: String) -> Bool {
        registerIfNeeded()
        return NSFont(name: postScriptName, size: 12) != nil
    }
}
