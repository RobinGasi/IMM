import Foundation
import IMMLedger
import os

/// Development aids behind launch arguments (`SyncDebugOptions`). Output is one line per event on stdout, prefixed with the Unix
/// time in milliseconds, and in the unified log (subsystem `dev.gasi.imm`, category `sync-debug`): the two-device test script
/// starts the app binary with stdout redirected to a file and reads the pairing code and the remote ops from there. (A sandboxed
/// app's container is not readable from outside, so nothing is written to files.)
enum SyncDebugLog {
    private static let logger = Logger(subsystem: "dev.gasi.imm", category: "sync-debug")
    private static let lock = NSLock()

    static func write(_ line: String) {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        logger.notice("\(line, privacy: .public)")
        lock.withLock {
            FileHandle.standardOutput.write(Data("\(millis) \(line)\n".utf8))
        }
    }

    /// `pairing code=… agent=… host=… port=…` for humans and scripts.
    static func writePairing(_ offer: PairingOffer) {
        write("pairing code=\(offer.code) agent=\(offer.agentKey.hex) host=\(offer.host) port=\(offer.port)")
    }
}

/// `-IMMSyncDebugEdit YES`: edits the ledger from JSON lines on stdin, one command per line:
/// `{"tx": "<id or payee substring>", "category": "<name>", "note": "<text>"}` (category and note optional), or `{"sync": "off"}`
/// to turn sync off and unregister the agent. Each applied edit prints `local-edit …` with the time it was committed, so a script
/// can time the path to another device.
enum SyncDebugCommands {
    static func watch(
        ledger: LedgerStore, log: @Sendable @escaping (String) -> Void, syncOff: @Sendable @escaping () async -> Void
    ) async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                if Task.isCancelled { return }
                if line.contains("\"sync\"") && line.contains("\"off\"") {
                    log("sync off requested")
                    await syncOff()
                    continue
                }
                guard let data = line.data(using: .utf8), let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let query = command["tx"] else {
                    log("error bad command: \(line)")
                    continue
                }
                apply(command, query: query, ledger: ledger, log: log)
            }
        } catch {
            log("error stdin: \(error)")
        }
    }

    private static func apply(_ command: [String: String], query: String, ledger: LedgerStore, log: (String) -> Void) {
        do {
            guard let id = try SyncLookup.transactionID(in: ledger, matching: query) else {
                log("error no transaction matches \(query)")
                return
            }
            if let name = command["category"] {
                guard let categoryID = try SyncLookup.categoryID(in: ledger, named: name) else {
                    log("error no category \(name)")
                    return
                }
                try ledger.writer.setCategory(transactionID: id, categoryID: categoryID)
                log("local-edit ledger_transaction \(id) category_id \"\(categoryID)\"")
            }
            if let note = command["note"] {
                try ledger.writer.setNote(transactionID: id, note: note)
                log("local-edit ledger_transaction \(id) note \"\(note)\"")
            }
        } catch {
            log("error \(error)")
        }
    }
}
