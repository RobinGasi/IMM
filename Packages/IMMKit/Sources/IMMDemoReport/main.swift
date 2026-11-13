import Foundation
import GRDB
import IMMBanking
import IMMLedger
import IMMVault

// imm-demo-report: builds a temporary encrypted vault, imports the demo data set the way the app does
// and prints one JSON object with every figure the screens show, keyed `<screen>.<figure>`.
// Every figure is read back from the ledger (IMMLedger definitions and SQL), never from the data-set DTOs.
//
// `imm-demo-report --open <data.sqlite> --raw-key <64 hex digits>` reports an existing database instead (after running
// pending ledger migrations on a copy): used to check that a vault created before a schema change keeps its figures.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func reportOfExistingDatabase(path: String, rawKey: String) throws -> Data {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("imm-demo-report-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let copy = directory.appendingPathComponent("data.sqlite")
    try FileManager.default.copyItem(atPath: path, toPath: copy.path)
    var configuration = Configuration()
    configuration.prepareDatabase { db in try db.usePassphrase("x'" + rawKey + "'") }
    let pool = try DatabasePool(path: copy.path, configuration: configuration)
    let store = try LedgerStore(database: pool)
    let report = try store.database.read { db in try ReportBuilder.build(db) }
    return try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
}

let arguments = CommandLine.arguments
if let open = arguments.firstIndex(of: "--open"), let key = arguments.firstIndex(of: "--raw-key"),
   arguments.indices.contains(open + 1), arguments.indices.contains(key + 1) {
    do {
        FileHandle.standardOutput.write(try reportOfExistingDatabase(path: arguments[open + 1], rawKey: arguments[key + 1]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    } catch {
        fail("imm-demo-report failed: \(error)")
    }
}

do {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("imm-demo-report-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let vault = try Vault.create(at: directory.appendingPathComponent("Report.imm"), password: "demo-demo")
    defer { vault.lock() }
    let store = try LedgerStore(database: vault.database)
    let bank = try DemoDataset.load()
    try LedgerImporter.importSnapshot(bank.snapshot, profile: bank.profile, into: store)

    let report = try store.database.read { db in try ReportBuilder.build(db) }
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("imm-demo-report failed: \(error)")
}
