import Foundation
import GRDB
import IMMLedger
import IMMSync
import IMMSyncCore
import IMMVault

// imm-sync-peer: a headless second device for the two-device sync test. It keeps its own encrypted vault in a directory
// (`--vault <dir> --password <pw>`), pairs with the Mac through its sync agent, syncs, edits and dumps figures.
//
//   init        creates the vault and an empty ledger                         [--name <device name>]
//   pair        --host <h> --port <p> --code <code | QR JSON> [--agent-key <hex>] [--confirm <6 digits>]
//   sync        --host <h> --port <p> [--watch <seconds>]
//   set-category --tx <id | payee substring> --category <name> [--host <h> --port <p>]   (with host/port: syncs right after)
//   set-note    --tx <id | payee substring> --note <text>          [--host <h> --port <p>]
//   dump        [--tx <id | payee substring>]...                   JSON: net worth, uncategorised count, named transactions
//   devices     JSON roster
//
// Lines that start with a Unix-millisecond timestamp (`<ms> applied …`) let the test script measure latency on this Mac's clock.

struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

struct Arguments {
    var command: String
    private var options: [String: [String]] = [:]

    init(_ raw: [String]) throws {
        guard raw.count >= 2 else { throw Failure(usage) }
        command = raw[1]
        var index = 2
        while index < raw.count {
            let key = raw[index]
            guard key.hasPrefix("--") else { throw Failure("unexpected argument \(key)\n\(usage)") }
            guard index + 1 < raw.count else { throw Failure("\(key) needs a value") }
            options[String(key.dropFirst(2)), default: []].append(raw[index + 1])
            index += 2
        }
    }

    func value(_ name: String) -> String? { options[name]?.last }
    func values(_ name: String) -> [String] { options[name] ?? [] }
    func required(_ name: String) throws -> String {
        guard let value = value(name) else { throw Failure("--\(name) is required") }
        return value
    }
}

let usage = """
usage: imm-sync-peer <init|pair|sync|set-category|set-note|dump|devices> --vault <dir> --password <pw> [options]
"""

func emit(_ object: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func stamp(_ text: String) {
    let millis = Int64(Date().timeIntervalSince1970 * 1000)
    FileHandle.standardOutput.write(Data("\(millis) \(text)\n".utf8))
}

func describe(_ value: SyncValue) -> String {
    switch value {
    case .null: return "null"
    case .integer(let v): return "\(v)"
    case .real(let v): return "\(v)"
    case .text(let v): return "\"\(v)\""
    case .blob(let v): return "blob(\(v.count))"
    }
}

let logEvent: @Sendable (SyncClientEvent) -> Void = { event in
    switch event {
    case .connected(let host, let port): stamp("connected \(host):\(port)")
    case .code(let code): stamp("code \(code.formatted)")
    case .paired(let hub): stamp("paired hub=\(String(hub, radix: 16))")
    case .bootstrapped: stamp("bootstrapped")
    case .sent(let batches, let ops): stamp("sent batches=\(batches) ops=\(ops)")
    case .applied(let ops, _):
        for op in ops {
            stamp("applied \(op.table) \(op.rowID) \(op.column ?? "-") \(describe(op.value ?? .null)) device=\(String(op.device, radix: 16)) seq=\(op.seq)")
        }
    case .rekeyed: stamp("rekeyed")
    case .hubUnavailable(let text): stamp("hub-unavailable \(text)")
    }
}

func openVault(_ arguments: Arguments) throws -> UnlockedVault {
    let url = URL(fileURLWithPath: try arguments.required("vault"))
    let vault = try Vault.open(at: url, password: try arguments.required("password"))
    // Several tool processes share this vault (a `sync --watch` and the edit commands): wait for the writer instead of failing.
    try vault.database.write { try $0.execute(sql: "PRAGMA busy_timeout = 5000") }
    return vault
}

func makeEngine(_ vault: UnlockedVault, _ arguments: Arguments) throws -> (SyncEngine, LedgerStore) {
    let store = try LedgerStore(database: vault.database)
    return (try SyncEngine(ledger: store, deviceName: arguments.value("name") ?? "Peer"), store)
}

func host(_ arguments: Arguments) throws -> (String, UInt16)? {
    guard let host = arguments.value("host") else { return nil }
    guard let port = arguments.value("port").flatMap({ UInt16($0) }) else { throw Failure("--port is required with --host") }
    return (host, port)
}

func run() async throws {
    let arguments = try Arguments(CommandLine.arguments)
    switch arguments.command {
    case "init":
        let url = URL(fileURLWithPath: try arguments.required("vault"))
        let vault = try Vault.create(at: url, password: try arguments.required("password"))
        defer { vault.lock() }
        let (engine, store) = try makeEngine(vault, arguments)
        let identity = await engine.identity
        _ = store
        emit(["vault": url.path, "node": String(identity.nodeID, radix: 16), "name": identity.name, "staticKey": identity.x25519Public.hex])

    case "pair":
        let vault = try openVault(arguments)
        defer { vault.lock() }
        let (engine, _) = try makeEngine(vault, arguments)
        var invite = try PairingInvite(parsing: try arguments.required("code"))
        if let key = arguments.value("agent-key") {
            guard let data = Data(hexString: key), data.count == 32 else { throw Failure("--agent-key must be 64 hex digits") }
            invite.agentKey = data
        }
        let target: (String, UInt16)
        if let given = try host(arguments) {
            target = given
        } else if let h = invite.host, let p = invite.port {
            target = (h, p)
        } else {
            throw Failure("--host and --port are required unless the QR payload carries them")
        }
        let expected = arguments.value("confirm")
        let client = SyncClient(engine: engine, log: logEvent)
        let report = try await client.pair(invite: invite, host: target.0, port: target.1) { code in
            if let expected, ShortAuthCode(expected)?.matches(code) != true {
                throw Failure("the Mac shows \(code.formatted), expected \(expected)")
            }
        }
        emit(["paired": true, "bootstrapped": report.bootstrapped, "opsApplied": report.opsApplied, "seconds": report.duration.seconds])

    case "sync":
        let vault = try openVault(arguments)
        defer { vault.lock() }
        let (engine, _) = try makeEngine(vault, arguments)
        guard let (h, p) = try host(arguments) else { throw Failure("--host and --port are required") }
        let watch = arguments.value("watch").flatMap(Double.init)
        let client = SyncClient(engine: engine, log: logEvent)
        let report = try await client.sync(
            host: h, port: p, options: .init(watch: watch.map { .milliseconds(Int($0 * 1000)) }, timeout: .seconds((watch ?? 0) + 20)))
        emit([
            "bootstrapped": report.bootstrapped, "batchesSent": report.batchesSent, "opsSent": report.opsSent,
            "opsApplied": report.opsApplied, "hubLocked": report.hubLocked, "seconds": report.duration.seconds,
        ])

    case "set-category", "set-note":
        let vault = try openVault(arguments)
        defer { vault.lock() }
        let (engine, store) = try makeEngine(vault, arguments)
        let query = try arguments.required("tx")
        guard let id = try SyncLookup.transactionID(in: store, matching: query) else { throw Failure("no transaction matches \(query)") }
        if arguments.command == "set-category" {
            let name = try arguments.required("category")
            guard let category = try SyncLookup.categoryID(in: store, named: name) else { throw Failure("no category named \(name)") }
            try store.writer.setCategory(transactionID: id, categoryID: category)
        } else {
            try store.writer.setNote(transactionID: id, note: try arguments.required("note"))
        }
        let committed = Int64(Date().timeIntervalSince1970 * 1000)
        stamp("committed \(arguments.command) \(id)")
        var result: [String: Any] = ["tx": id, "committedAtMs": committed]
        if let (h, p) = try host(arguments) {
            let client = SyncClient(engine: engine, log: logEvent)
            let report = try await client.sync(host: h, port: p)
            stamp("pushed ops=\(report.opsSent)")
            result["pushedAtMs"] = Int64(Date().timeIntervalSince1970 * 1000)
            result["opsSent"] = report.opsSent
        }
        emit(result)

    case "dump":
        let vault = try openVault(arguments)
        defer { vault.lock() }
        let (engine, store) = try makeEngine(vault, arguments)
        let figures = try await store.database.read { db in
            (try LedgerDefinitions.netWorth(db), try LedgerDefinitions.uncategorisedCount(db), try LedgerQueries.quarantineCount(db))
        }
        var transactions: [[String: Any]] = []
        for query in arguments.values("tx") {
            if let summary = try SyncLookup.summary(in: store, matching: query) {
                transactions.append([
                    "query": query, "id": summary.id, "payee": summary.payee, "bookingDate": summary.bookingDate,
                    "category": summary.category as Any? ?? NSNull(), "note": summary.note as Any? ?? NSNull(),
                ])
            } else {
                transactions.append(["query": query, "id": NSNull()])
            }
        }
        let cursors = try store.writer.cursors().map { ["device": String($0.device, radix: 16), "appliedSeq": $0.appliedSeq] as [String: Any] }
        let node = await engine.identity.nodeID
        let paired = await engine.isPaired
        emit([
            "node": String(node, radix: 16), "paired": paired,
            "netWorthCents": figures.0, "netWorth": MoneyFormatter.string(figures.0), "uncategorised": figures.1,
            "quarantined": figures.2, "transactions": transactions, "cursors": cursors,
        ])

    case "devices":
        let vault = try openVault(arguments)
        defer { vault.lock() }
        let (engine, _) = try makeEngine(vault, arguments)
        let devices = try engine.secrets.devices(includeRevoked: true).map { device -> [String: Any] in
            [
                "node": String(device.nodeID, radix: 16), "name": device.name as Any? ?? NSNull(), "local": device.isLocal,
                "revoked": device.revokedAt != nil,
            ]
        }
        emit(["devices": devices])

    default:
        throw Failure("unknown command \(arguments.command)\n\(usage)")
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

enum LedgerQueries {
    static func quarantineCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_quarantine") ?? 0
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("imm-sync-peer: \(error)\n".utf8))
    exit(1)
}
