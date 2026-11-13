import Foundation

/// Locations inside the repository, derived from this file's path so tests work from any cwd.
enum RepoPaths {
    /// `<repo>/` (this file is `<repo>/Packages/IMMKit/Tests/IMMUITests/Support/RepoPaths.swift`).
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    static let referenceScreens = root.appendingPathComponent("DesignReference/screens", isDirectory: true)
    static let thresholds = root.appendingPathComponent("DesignReference/thresholds.json")
    static let diffOutput = root.appendingPathComponent("build/design-diff", isDirectory: true)
    static let diffReport = diffOutput.appendingPathComponent("report.json")
}
