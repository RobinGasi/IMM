import Foundation
import IMMLedger
@testable import IMMSync
import IMMSyncCore
import Testing

/// What a lane reported.
final class LaneLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [RelayStatus] = []
    private var _applied: [SyncOp] = []
    private var _failures: [String] = []
    var statuses: [RelayStatus] { lock.withLock { _statuses } }
    var applied: [SyncOp] { lock.withLock { _applied } }
    var failures: [String] { lock.withLock { _failures } }
    func record(_ update: RelayLane.Update) {
        lock.withLock {
            switch update {
            case .status(let status): _statuses.append(status)
            case .applied(let ops): _applied += ops
            case .failure(let text): _failures.append(text)
            }
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(days: Double) { lock.withLock { date = date.addingTimeInterval(days * 86400) } }
}

/// One device in a relay test: ledger, engine, an in-memory relay replica and the lane on top.
struct RelayReplica {
    let device: TestDevice
    let engine: SyncEngine
    let store: InMemoryRelayStore
    let lane: RelayLane
    let log: LaneLog

    init(
        cloud: InMemoryRelayCloud, name: String, demo: Bool = false, clock: TestClock = TestClock(), budget: Int = SealedEnvelope.maxPayloadSize,
        device existing: TestDevice? = nil
    ) throws {
        device = try existing ?? TestDevice(demo: demo)
        engine = try SyncEngine(ledger: device.store, deviceName: name, payloadBudget: budget)
        store = InMemoryRelayStore(cloud: cloud, device: device.node)
        let log = LaneLog()
        self.log = log
        lane = RelayLane(engine: engine, store: store, now: { clock.now }, report: { log.record($0) })
    }

    var node: DeviceNodeID { device.node }
}

@Suite struct RelayTests {
    /// The group hand-over and snapshot a pairing does, without sockets: `joiner` ends up with the hub's data and group.
    func pair(hub: RelayReplica, joiner: RelayReplica) async throws {
        _ = try await hub.engine.ensureGroup()
        let entry = await joiner.engine.identity.rosterEntry
        let grant = try await hub.engine.makeGrant(for: entry)
        let hubKey = SyncPeer(staticKey: Data(repeating: 1, count: 32))
        _ = try await joiner.engine.handle(grant, from: hubKey, fromHub: true)
        let chunks = try await hub.engine.snapshotMessages(requestID: 1, for: SyncPeer(staticKey: entry.x25519, node: entry.node))
        for chunk in chunks { _ = try await joiner.engine.handle(chunk, from: hubKey, fromHub: true) }
    }

    /// Every device knows every other (roster) and treats it as bootstrapped.
    func link(_ replicas: [RelayReplica]) async throws {
        for x in replicas {
            for y in replicas where y.node != x.node {
                let entry = await y.engine.identity.rosterEntry
                try x.engine.secrets.upsert(entry)
                try x.engine.secrets.write(SyncSecretName.bootstrapped(peer: entry.x25519), Data([1]))
            }
        }
    }

    func trio(demo: Bool = true, clock: TestClock = TestClock()) async throws -> (cloud: InMemoryRelayCloud, a: RelayReplica, b: RelayReplica, c: RelayReplica) {
        let cloud = InMemoryRelayCloud(now: { clock.now })
        let a = try RelayReplica(cloud: cloud, name: "A", demo: demo, clock: clock)
        let b = try RelayReplica(cloud: cloud, name: "B", clock: clock)
        let c = try RelayReplica(cloud: cloud, name: "C", clock: clock)
        try await pair(hub: a, joiner: b)
        try await pair(hub: a, joiner: c)
        try await link([a, b, c])
        return (cloud, a, b, c)
    }

    func duo(demo: Bool = true, clock: TestClock = TestClock(), budget: Int = SealedEnvelope.maxPayloadSize) async throws
        -> (cloud: InMemoryRelayCloud, a: RelayReplica, b: RelayReplica)
    {
        let cloud = InMemoryRelayCloud(now: { clock.now })
        let a = try RelayReplica(cloud: cloud, name: "A", demo: demo, clock: clock, budget: budget)
        let b = try RelayReplica(cloud: cloud, name: "B", clock: clock, budget: budget)
        try await pair(hub: a, joiner: b)
        try await link([a, b])
        return (cloud, a, b)
    }

    func batchRecords(_ cloud: InMemoryRelayCloud) async -> [SealedEnvelope] {
        await cloud.envelopes().filter { $0.header.seqFrom < SyncEngine.controlSequenceBase }
    }

    // MARK: Convergence through the relay only

    @Test func twoReplicasConvergeThroughTheRelayWithoutAnyLiveSession() async throws {
        let (_, a, b) = try await duo()
        try #require(try a.device.converged() == b.device.converged(), "the snapshot made them equal")

        // A edits while B is "asleep": nothing connects them but the relay.
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "from A")
        try a.device.store.writer.setCategory(transactionID: try a.device.transactionID("Lieferando"), categoryID: try a.device.categoryID("Groceries"))
        await a.lane.publish()
        await b.lane.pull()
        #expect(try b.device.summary("REWE").note == "from A")
        #expect(try b.device.summary("Lieferando").category == "Groceries")
        #expect(try a.device.converged() == b.device.converged())

        // And back.
        try b.device.store.writer.setNote(transactionID: try b.device.transactionID("dm"), note: "from B")
        await b.lane.publish()
        await a.lane.pull()
        #expect(try a.device.summary("dm").note == "from B")
        #expect(try a.device.converged() == b.device.converged())
        #expect(!b.log.applied.isEmpty && !a.log.applied.isEmpty)
    }

    @Test func aJoinedDeviceAndItsHubSyncThroughTheRelayRightAfterPairing() async throws {
        let cloud = InMemoryRelayCloud()
        let hub = try RelayReplica(cloud: cloud, name: "Hub", demo: true)
        let joiner = try RelayReplica(cloud: cloud, name: "Joiner")
        try await pair(hub: hub, joiner: joiner)   // no manual roster or marker set-up: only what pairing leaves behind
        try joiner.device.store.writer.setNote(transactionID: try joiner.device.transactionID("REWE"), note: "from the joiner")
        try hub.device.store.writer.setNote(transactionID: try hub.device.transactionID("dm"), note: "from the hub")
        await joiner.lane.publish()
        await hub.lane.publish()
        await hub.lane.pull()
        await joiner.lane.pull()
        #expect(try hub.device.summary("REWE").note == "from the joiner")
        #expect(try joiner.device.summary("dm").note == "from the hub")
        #expect(try hub.device.converged() == joiner.device.converged())
    }

    @Test func threeReplicasConvergeThroughTheRelay() async throws {
        let (_, a, b, c) = try await trio()
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "from A")
        try b.device.store.writer.setNote(transactionID: try b.device.transactionID("dm"), note: "from B")
        try c.device.store.writer.setNote(transactionID: try c.device.transactionID("Lieferando"), note: "from C")
        // C edits the same field as A, later: last writer wins on every replica.
        try c.device.store.writer.setNote(transactionID: try c.device.transactionID("REWE"), note: "C wins")
        for replica in [a, b, c] { await replica.lane.publish() }
        for replica in [a, b, c] { await replica.lane.pull() }
        let reference = try a.device.converged()
        #expect(try b.device.converged() == reference)
        #expect(try c.device.converged() == reference)
        #expect(try a.device.summary("REWE").note == "C wins")
        #expect(try b.device.summary("dm").note == "from B")
        #expect(try a.device.summary("Lieferando").note == "from C")
    }

    @Test func manyBatchesAndSmallPayloadBudgetsStillConverge() async throws {
        let (cloud, a, b) = try await duo(budget: 400)
        for i in 0..<12 { try a.device.store.writer.setSetting(.rolloverEnabled, i % 2 == 0 ? "1" : "0") }
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "many")
        await a.lane.publish()
        #expect(await batchRecords(cloud).count > 3, "a 400-byte budget splits the ops over many records")
        await b.lane.pull()
        #expect(try a.device.converged() == b.device.converged())
    }

    // MARK: Publishing

    @Test func publishingSendsOnlyNewOpsAndNothingWithoutAPairedDevice() async throws {
        let cloud = InMemoryRelayCloud()
        let lonely = try RelayReplica(cloud: cloud, name: "Lonely", demo: true)
        _ = try await lonely.engine.ensureGroup()
        await lonely.lane.publish()
        #expect(await cloud.recordIDs.isEmpty, "nobody could use it: no relay traffic before a device is paired")

        let (cloud2, a, _) = try await duo()
        await a.lane.publish()
        #expect(await cloud2.recordIDs.isEmpty, "the snapshot already gave B everything up to now")
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "one")
        await a.lane.publish()
        let uploaded = await a.store.uploadCount
        #expect(uploaded == 1)
        await a.lane.publish()
        #expect(await a.store.uploadCount == uploaded, "the marker keeps the same ops from going up twice")
    }

    @Test func aReplicaNeverReadsItsOwnUploads() async throws {
        let (_, a, b) = try await duo()
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "mine")
        await a.lane.publish()
        await a.lane.pull()
        #expect(a.log.applied.isEmpty)
        await b.lane.pull()
        #expect(!b.log.applied.isEmpty)
    }

    // MARK: Live and relay together

    @Test func batchesArrivingOverBothLanesApplyOnce() async throws {
        let (_, a, b) = try await duo()
        let peerA = SyncPeer(staticKey: await a.engine.identity.x25519Public, node: a.node)
        let peerB = SyncPeer(staticKey: await b.engine.identity.x25519Public, node: b.node)

        // 1. live first, relay second
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "one")
        var firstLive = 0
        for envelope in try await a.engine.batches(for: peerB, cursors: []) {   // history first (duplicates), then the new op
            firstLive += try await b.engine.handle(.batch(envelope), from: peerA).appliedOps.count
        }
        #expect(firstLive > 0)
        await a.lane.publish()
        await b.lane.pull()
        #expect(b.log.applied.isEmpty, "the relay copy is a duplicate: nothing is applied again")

        // 2. relay first, live second
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("dm"), note: "two")
        await a.lane.publish()
        await b.lane.pull()
        #expect(!b.log.applied.isEmpty)
        var liveApplied = 0
        for envelope in try await a.engine.batches(for: peerB, cursors: []) {
            liveApplied += try await b.engine.handle(.batch(envelope), from: peerA).appliedOps.count
        }
        #expect(liveApplied == 0)
        #expect(try a.device.converged() == b.device.converged())
    }

    // MARK: Cleanup

    @Test func aBatchIsDeletedOnceEveryOtherDeviceAcknowledgedIt() async throws {
        let (cloud, a, b, c) = try await trio()
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "ack me")
        await a.lane.publish()
        #expect(await batchRecords(cloud).count == 1)

        await b.lane.pull()    // B applies and publishes its ack
        await a.lane.pull()    // A reads B's ack: C is still missing
        #expect(await batchRecords(cloud).count == 1, "C has not acknowledged yet")

        await c.lane.pull()
        await a.lane.pull()
        #expect(await batchRecords(cloud).isEmpty, "both others acknowledged: the batch is gone")
        // The acks stay until superseded; they carry no ledger data and are tiny.
        let remaining = await cloud.envelopes()
        #expect(remaining.allSatisfy { $0.header.seqFrom >= RelayLane.ackBase })
        #expect(try a.device.converged() == c.device.converged())
    }

    @Test func twoDevicesCleanUpAsSoonAsTheReceiverApplied() async throws {
        let (cloud, a, b) = try await duo()
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "x")
        await a.lane.publish()
        await b.lane.pull()
        #expect(await batchRecords(cloud).isEmpty, "the only other device has it: the receiver deletes right away")
    }

    @Test func oldBatchesAreDeletedAfterNinetyDaysEvenWithoutAcks() async throws {
        let clock = TestClock()
        let (cloud, a, _, _) = try await trio(clock: clock)
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "old")
        await a.lane.publish()
        clock.advance(days: 89)
        await a.lane.cleanup()
        #expect(await batchRecords(cloud).count == 1)
        clock.advance(days: 2)
        await a.lane.cleanup()
        #expect(await batchRecords(cloud).isEmpty)
    }

    @Test func acksAreSupersededByTheNextAck() async throws {
        let (cloud, a, b) = try await duo()
        for round in 0..<3 {
            try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "round \(round)")
            await a.lane.publish()
            await b.lane.pull()
            await a.lane.pull()   // reads the ack, which also lets B's ack be superseded on B's next round
        }
        let acks = await cloud.envelopes().filter { $0.header.seqFrom >= RelayLane.ackBase && $0.header.device == b.node }
        #expect(acks.count <= 2, "old acks do not pile up (found \(acks.count))")
    }

    // MARK: Account, reset, groups

    @Test func losingTheAccountStopsTheRelayButNotTheLiveLane() async throws {
        let (cloud, a, b) = try await duo()
        let peerA = SyncPeer(staticKey: await a.engine.identity.x25519Public, node: a.node)
        let peerB = SyncPeer(staticKey: await b.engine.identity.x25519Public, node: b.node)
        await b.lane.start()
        await b.store.simulateAccountLoss("Signed out of iCloud.")
        #expect(await eventually { await b.lane.isSuspended })
        #expect(b.log.statuses.last == .unavailable("Signed out of iCloud."))

        // Relay calls do nothing and raise nothing ...
        try b.device.store.writer.setNote(transactionID: try b.device.transactionID("dm"), note: "offline edit")
        await b.lane.publish()
        await b.lane.pull()
        #expect(await cloud.recordIDs.isEmpty)

        // ... while the live lane keeps working on the same engine.
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "live while relay is down")
        for envelope in try await a.engine.batches(for: peerB, cursors: []) { _ = try await b.engine.handle(.batch(envelope), from: peerA) }
        #expect(try b.device.summary("REWE").note == "live while relay is down")
        for envelope in try await b.engine.batches(for: peerA, cursors: []) { _ = try await a.engine.handle(.batch(envelope), from: peerB) }
        #expect(try a.device.summary("dm").note == "offline edit")

        // The account comes back: the lane resumes by itself.
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("Lieferando"), note: "after return")
        await a.lane.publish()
        await b.store.simulateAccountReturn()
        #expect(await eventually { (try? b.device.summary("Lieferando").note) == "after return" })
        #expect(b.log.statuses.contains(.ready))
        await b.lane.shutdown()
    }

    @Test func aStoreThatThrowsUnavailableSuspendsTheLane() async throws {
        let (_, a, b) = try await duo()
        await b.store.simulateAccountLoss("No iCloud account.")
        try b.device.store.writer.setNote(transactionID: try b.device.transactionID("dm"), note: "x")
        await b.lane.publish()
        #expect(await b.lane.isSuspended)
        #expect(b.log.statuses.last == .unavailable("No iCloud account."))
        await a.lane.pull()
        #expect(a.log.applied.isEmpty)
    }

    @Test func aWipedRelayIsRepublishedForDevicesThatDidNotGetIt() async throws {
        let (cloud, a, b) = try await duo()
        await a.lane.start()
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "lost in the zone")
        await a.lane.publish()
        #expect(!(await cloud.recordIDs.isEmpty))
        // The user resets iCloud data before B ever fetched.
        await a.store.simulateZoneLoss()
        #expect(await eventually { !(await self.batchRecords(cloud).isEmpty) }, "the lane publishes the recent batches again")
        await b.lane.pull()
        #expect(try b.device.summary("REWE").note == "lost in the zone")
        await a.lane.shutdown()
    }

    @Test func batchesOfAnotherGroupAreIgnoredAndNeverDeletedByOthers() async throws {
        let (cloud, a, b) = try await duo()
        // A device outside the group (a removed one, or garbage) puts a batch on the relay.
        let outsider = SyncGroup.generate()
        let op = try #require(try a.device.store.writer.ops(from: a.node, after: 0, limit: 1).first)
        let foreign = try SealedEnvelope.seal(
            payload: try JSONEncoder().encode([op]), header: .init(group: outsider.id, device: 0xDEAD, seqFrom: op.seq, seqTo: op.seq),
            key: outsider.key)
        let intruder = InMemoryRelayStore(cloud: cloud, device: 0xDEAD)
        _ = try await intruder.upload([foreign], from: 0xDEAD)
        let before = try b.device.converged()
        await b.lane.pull()
        #expect(b.log.applied.isEmpty)
        #expect(try b.device.converged() == before)
        #expect(await batchRecords(cloud).count == 1, "it is not ours to delete: it stays until it expires")
        #expect(b.log.failures.isEmpty)
    }

    @Test func afterAKeyRotationTheOldBatchesAreRemovedAndNewOnesUseTheNewGroup() async throws {
        let (cloud, a, b) = try await duo()
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("REWE"), note: "before rotation")
        await a.lane.publish()
        let oldGroup = try #require(await a.engine.group).id
        _ = try await a.engine.rotateGroup()
        try a.device.store.writer.setNote(transactionID: try a.device.transactionID("dm"), note: "after rotation")
        await a.lane.publish()
        await a.lane.cleanup()
        let groups = Set(await batchRecords(cloud).map(\.header.group))
        let newGroup = try #require(await a.engine.group).id
        #expect(groups == [newGroup], "the batch sealed for the old group is gone, new ones use the new group (old: \(oldGroup.hex.prefix(6)))")

        // B still holds the old key until the live rekey reaches it: it ignores the new-group batches and does not delete them.
        await b.lane.pull()
        #expect(b.log.applied.isEmpty)
        #expect(!(await batchRecords(cloud).isEmpty))
    }

    // MARK: Store contract

    @Test func anItemIsDeliveredAgainUntilItIsAcknowledged() async throws {
        let cloud = InMemoryRelayCloud()
        let sender = InMemoryRelayStore(cloud: cloud, device: 1)
        let receiver = InMemoryRelayStore(cloud: cloud, device: 2)
        let group = SyncGroup.generate()
        let envelope = try SealedEnvelope.seal(payload: Data("[]".utf8), header: .init(group: group.id, device: 1, seqFrom: 1, seqTo: 1), key: group.key)
        let ids = try await sender.upload([envelope], from: 1)
        let first = try await receiver.fetchNew()
        #expect(first.map(\.recordID) == ids)
        #expect(try await receiver.fetchNew().map(\.recordID) == ids, "a crash before applying must not lose it")
        try await receiver.acknowledge(first)
        #expect(try await receiver.fetchNew().isEmpty)
        #expect(try await sender.fetchNew().isEmpty, "own uploads never come back")
        try await receiver.resetState()
        #expect(try await receiver.fetchNew().map(\.recordID) == ids, "after a reset the relay content is delivered again")
    }
}
