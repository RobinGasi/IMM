#if DEBUG
import CloudKit
import Foundation
import GRDB
import IMMLedger
import IMMVault

/// `-IMMCloudKitSelfTest YES` (development builds only): two temporary vaults A and B with the demo ledger and one shared group key
/// (a completed pairing, done with the real grant and snapshot messages) exchange edits through the real CloudKit relay, each
/// with its own `CloudKitRelayStore` (separate engine state) on the same container and a dedicated zone `imm-sync-selftest`.
/// The engines are driven by hand (`automaticallySync = false`: explicit `sendChanges` / `fetchChanges`), so the run checks
/// correctness and measures round trips, not push latency (CloudKit never pushes to the device that made the change).
///
/// Everything it creates in the Development environment is deleted at the end: the zone, the vaults, the temporary files.
/// Output is one line per step on stdout, ending in `CLOUDKIT SELFTEST PASS` or `CLOUDKIT SELFTEST FAIL: <reason>`.
public enum CloudKitSelfTest {
    public static let zoneName = "imm-sync-selftest"

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data("CLOUDKIT SELFTEST \(line)\n".utf8))
        fflush(stdout)
    }

    /// - Parameter importDemo: fills a fresh ledger with the demo profile (IMMBanking is not a dependency of this module).
    /// - Returns: whether every step passed.
    public static func run(importDemo: @escaping @Sendable (LedgerStore) throws -> Void) async -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imm-ck-selftest-\(UUID().uuidString)", isDirectory: true)
        var container: String?
        var cleanupNeeded = false
        var result: Bool
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard case .available(let id) = await CloudKitAvailability.check() else {
                let reason: String
                if case .unavailable(let text) = await CloudKitAvailability.check() { reason = text } else { reason = "unknown" }
                throw Failure("CloudKit is not available: \(reason)")
            }
            container = id
            say("container \(id), zone \(zoneName), environment per entitlement, push entitlement \(CloudKitAvailability.canReceivePushes)")
            cleanupNeeded = true
            try await scenario(container: id, directory: directory, importDemo: importDemo)
            result = true
        } catch {
            say("FAIL: \(error)")
            result = false
        }
        if let container, cleanupNeeded {
            do {
                try await deleteZone(container: container)
                say("zone \(zoneName) deleted")
            } catch {
                say("zone cleanup failed: \(error)")
                result = false
            }
        }
        try? FileManager.default.removeItem(at: directory)
        say("temporary vaults deleted")
        say(result ? "PASS" : "FAIL: see the lines above")
        return result
    }

    // MARK: Scenario

    private struct Device {
        let name: String
        let vault: UnlockedVault
        let ledger: LedgerStore
        let engine: SyncEngine
        let store: CloudKitRelayStore
        let lane: RelayLane
        let log: LaneLog

        var node: DeviceNodeID { ledger.writer.localNode }
    }

    private final class LaneLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func record(_ update: RelayLane.Update) {
            switch update {
            case .status(let status): lock.withLock { lines.append("status \(status)") }
            case .applied(let ops): lock.withLock { lines.append("applied \(ops.count) ops") }
            case .failure(let text): lock.withLock { lines.append("failure \(text)") }
            }
        }
        var failures: [String] { lock.withLock { lines.filter { $0.hasPrefix("failure") } } }
    }

    private static func makeDevice(
        _ name: String, container: String, directory: URL, demo: Bool, importDemo: @Sendable (LedgerStore) throws -> Void
    ) async throws -> Device {
        let vault = try Vault.create(at: directory.appendingPathComponent("\(name).imm", isDirectory: true), password: "selftest-\(name)")
        let ledger = try LedgerStore(database: vault.database)
        if demo { try importDemo(ledger) }
        let engine = try SyncEngine(ledger: ledger, deviceName: "Self-test \(name)")
        let store = CloudKitRelayStore(
            containerIdentifier: container, zoneName: zoneName, device: ledger.writer.localNode,
            persistence: LedgerRelayPersistence(ledger: ledger), automaticallySync: false)
        let log = LaneLog()
        let lane = RelayLane(engine: engine, store: store, report: { log.record($0) })
        return Device(name: name, vault: vault, ledger: ledger, engine: engine, store: store, lane: lane, log: log)
    }

    private static func scenario(
        container: String, directory: URL, importDemo: @escaping @Sendable (LedgerStore) throws -> Void
    ) async throws {
        let a = try await makeDevice("A", container: container, directory: directory, demo: true, importDemo: importDemo)
        let b = try await makeDevice("B", container: container, directory: directory, demo: false, importDemo: importDemo)
        say("vaults A and B created (A holds the demo ledger)")

        // A completed pairing: group key, roster and snapshot through the real hand-over messages.
        _ = try await a.engine.ensureGroup()
        let entry = await b.engine.identity.rosterEntry
        let grant = try await a.engine.makeGrant(for: entry)
        let hub = SyncPeer(staticKey: Data(repeating: 1, count: 32))
        _ = try await b.engine.handle(grant, from: hub, fromHub: true)
        for chunk in try await a.engine.snapshotMessages(requestID: 1, for: SyncPeer(staticKey: entry.x25519, node: entry.node)) {
            _ = try await b.engine.handle(chunk, from: hub, fromHub: true)
        }
        guard try a.ledger.writer.snapshot().converged == b.ledger.writer.snapshot().converged else { throw Failure("snapshot did not equalise A and B") }
        say("pairing simulated: B bootstrapped from A's snapshot, ledgers equal")

        try await a.store.start()
        try await b.store.start()
        await a.lane.start()
        await b.lane.start()
        say("engines started (separate state, same container)")

        // Round 1: A -> B.
        let tx1 = try SyncLookup.transactionID(in: a.ledger, matching: "REWE").unwrapped("transaction REWE")
        let tx2 = try SyncLookup.transactionID(in: a.ledger, matching: "dm").unwrapped("transaction dm")
        let category = try SyncLookup.categoryID(in: a.ledger, named: "Leisure & eating out").unwrapped("category")
        let aToB = try await roundTrip(
            label: "A -> B", from: a, to: b,
            edit: {
                try a.ledger.writer.setNote(transactionID: tx1, note: "self-test note from A")
                try a.ledger.writer.setCategory(transactionID: tx2, categoryID: category)
            },
            visible: {
                let r1 = try SyncLookup.summary(in: b.ledger, matching: tx1)?.note
                let r2 = try SyncLookup.summary(in: b.ledger, matching: tx2)?.category
                return r1 == "self-test note from A" && r2 == "Leisure & eating out"
            })

        // Round 2: B -> A.
        let bToA = try await roundTrip(
            label: "B -> A", from: b, to: a,
            edit: { try b.ledger.writer.setNote(transactionID: tx2, note: "self-test note from B") },
            visible: { try SyncLookup.summary(in: a.ledger, matching: tx2)?.note == "self-test note from B" })

        // Round 3: an envelope above the inline limit travels as a CKAsset.
        let big = String(repeating: "0123456789abcdef", count: 24_000)   // 384 KB of note text, above the 256 KiB inline limit
        let large = try await roundTrip(
            label: "A -> B (CKAsset, \(big.utf8.count / 1024) KB note)", from: a, to: b,
            edit: { try a.ledger.writer.setNote(transactionID: tx1, note: big) },
            visible: { try SyncLookup.summary(in: b.ledger, matching: tx1)?.note == big })

        // The figures both devices show are the same.
        let sa = try a.ledger.writer.snapshot().converged, sb = try b.ledger.writer.snapshot().converged
        guard sa == sb else { throw Failure("ledgers differ after the rounds") }
        say("converged ledgers equal (\(sa.tables.values.reduce(0) { $0 + $1.count }) rows in synced tables)")

        // Acks and cleanup: let both sides read each other's acks, then count what is left on the server.
        for _ in 0..<3 {
            await a.lane.pull()
            await b.lane.pull()
            try await a.store.sync()
            try await b.store.sync()
        }
        let left = try await recordCounts(container: container)
        say("records left in the zone after acks and cleanup: \(left.batches) batch(es), \(left.acks) ack(s)")
        guard left.batches == 0 else { throw Failure("\(left.batches) batch record(s) survived the acknowledgements") }

        let failures = a.log.failures + b.log.failures
        guard failures.isEmpty else { throw Failure("lane failures: \(failures)") }

        say("timings: A->B \(format(aToB)), B->A \(format(bToA)), large A->B \(format(large))")
        await a.lane.shutdown()
        await b.lane.shutdown()
        a.vault.lock()
        b.vault.lock()
    }

    private struct Timing {
        var send: Duration
        var visible: Duration
    }

    private static func format(_ t: Timing) -> String {
        "send \(t.send.milliseconds) ms, visible after \(t.visible.milliseconds) ms"
    }

    /// `edit` runs on `from`; the lane uploads; `to` fetches (explicit `fetchChanges`) once a second until `visible` holds.
    private static func roundTrip(
        label: String, from: Device, to: Device, edit: () throws -> Void, visible: () throws -> Bool
    ) async throws -> Timing {
        let clock = ContinuousClock()
        let start = clock.now
        try edit()
        await from.lane.publish()
        let sent = clock.now - start
        var attempts = 0
        while true {
            attempts += 1
            await to.lane.pull()
            if try visible() { break }
            if clock.now - start > .seconds(90) { throw Failure("\(label): not visible on \(to.name) after 90 s (\(attempts) fetches)") }
            try await Task.sleep(for: .seconds(1))
        }
        let timing = Timing(send: sent, visible: clock.now - start)
        say("\(label): visible on \(to.name) after \(timing.visible.milliseconds) ms (publish \(sent.milliseconds) ms, \(attempts) fetch(es))")
        return timing
    }

    // MARK: Server side

    private static func recordCounts(container: String) async throws -> (batches: Int, acks: Int) {
        let database = CKContainer(identifier: container).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        var batches = 0, acks = 0
        var token: CKServerChangeToken?
        var more = true
        var live: [CKRecord.ID: Int64] = [:]
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (id, result) in changes.modificationResultsByID {
                if case .success(let modification) = result, let seqFrom = modification.record["seqFrom"] as? Int64 { live[id] = seqFrom }
            }
            for deletion in changes.deletions { live[deletion.recordID] = nil }
            token = changes.changeToken
            more = changes.moreComing
        }
        for seqFrom in live.values { if seqFrom >= RelayLane.ackBase { acks += 1 } else { batches += 1 } }
        return (batches, acks)
    }

    private static func deleteZone(container: String) async throws {
        let database = CKContainer(identifier: container).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        do { try await database.deleteRecordZone(withID: zoneID) } catch let error as CKError where error.code == .zoneNotFound { return }
        let zones = try await database.allRecordZones()
        if zones.contains(where: { $0.zoneID == zoneID }) { throw Failure("zone still listed after deletion") }
    }
}

private extension Optional {
    func unwrapped(_ what: String) throws -> Wrapped {
        guard let self else { throw CloudKitSelfTest.Failure("\(what) not found in the demo ledger") }
        return self
    }
}

private extension Duration {
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
#endif
