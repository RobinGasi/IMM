import Foundation
import Testing
@testable import IMMVault

/// Runs `body` with a fresh temporary directory and removes it afterwards.
func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("IMMVaultTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

func vaultURL(in directory: URL) -> URL {
    directory.appendingPathComponent("Moneten.imm", isDirectory: true)
}

/// Rewrites `vault.json` through a mutable JSON dictionary.
func mutateHeader(at package: URL, _ change: (inout [String: Any]) -> Void) throws {
    let url = package.appendingPathComponent("vault.json")
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    change(&object)
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

func mutateSlot(at package: URL, _ change: (inout [String: Any]) -> Void) throws {
    try mutateHeader(at: package) { header in
        var slots = header["slots"] as! [[String: Any]]
        change(&slots[0])
        header["slots"] = slots
    }
}

func mutateKDF(at package: URL, _ change: (inout [String: Any]) -> Void) throws {
    try mutateSlot(at: package) { slot in
        var kdf = slot["kdf"] as! [String: Any]
        change(&kdf)
        slot["kdf"] = kdf
    }
}
