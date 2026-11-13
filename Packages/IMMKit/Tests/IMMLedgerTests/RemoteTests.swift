import Foundation
import GRDB
import Testing
@testable import IMMLedger

@Suite struct RemoteTests {
    /// Two devices with a shared category, account and transaction, fully exchanged.
    private func pair() throws -> (a: Replica, b: Replica) {
        let clock = TestClock()
        let a = try Replica(clock: clock), b = try Replica(clock: clock)
        try a.writer.insertImmutable(table: "category", row: categoryRow("c1", name: "Groceries"))
        try a.writer.insertImmutable(table: "category", row: categoryRow("c2", name: "Mobility", sort: "k"))
        try a.writer.insertImmutable(table: "account", row: accountRow("a1"))
        try a.writer.insertImmutable(table: "ledger_transaction", row: transactionRow("t1", account: "a1", isNew: true))
        try b.writer.applyRemote(try a.ownOps())
        return (a, b)
    }

    private func exchange(_ a: Replica, _ b: Replica) throws {
        try b.writer.applyRemote(try a.ownOps())
        try a.writer.applyRemote(try b.ownOps())
    }

    private func converged(_ a: Replica, _ b: Replica) throws -> Bool {
        try a.writer.snapshot().converged == b.writer.snapshot().converged
    }

    @Test func remoteInsertsAndSetsArrive() throws {
        let (a, b) = try pair()
        #expect(try b.value("category", "c1", "name") == .text("Groceries"))
        #expect(try b.value("ledger_transaction", "t1", "amount") == .integer(-100))
        try a.writer.setNote(transactionID: "t1", note: "hello")
        let result = try b.writer.applyRemote(try a.ownOps())
        #expect(result.applied == 1 && result.ignored == 4 && result.quarantined == 0)
        #expect(try b.value("ledger_transaction", "t1", "note") == .text("hello"))
        #expect(try converged(a, b))
    }

    @Test func remoteApplyNeverRelogs() throws {
        let (_, b) = try pair()
        #expect(try b.ownOps().isEmpty)
        #expect(try b.writer.cursors().count == 2)    // itself and device A
    }

    @Test func latestClockWinsRegardlessOfArrivalOrder() throws {
        let (a, b) = try pair()
        a.clock.advance(by: 1_000)
        try a.writer.set(table: "category", rowID: "c1", column: "name", to: .text("from A"))
        b.clock.advance(by: 1_000)
        try b.writer.set(table: "category", rowID: "c1", column: "name", to: .text("from B"))    // later (same shared clock, B's op is newer)
        try exchange(a, b)
        #expect(try a.value("category", "c1", "name") == .text("from B"))
        #expect(try b.value("category", "c1", "name") == .text("from B"))
        #expect(try converged(a, b))
        // A's overwritten value is kept for inspection on both sides.
        let history = try a.writer.fieldHistory(table: "category", rowID: "c1", column: "name")
        #expect(history.contains { $0.value == .text("from A") })
        let bHistory = try b.writer.fieldHistory(table: "category", rowID: "c1", column: "name")
        #expect(bHistory.contains { $0.value == .text("from A") })
    }

    @Test func fieldHistoryKeepsTheLastFiveLosers() throws {
        let (a, b) = try pair()
        // B wins every time; A's ten older edits lose one after another.
        for i in 0..<10 {
            a.clock.advance(by: 10)
            try a.writer.set(table: "category", rowID: "c1", column: "name", to: .text("a\(i)"))
        }
        b.clock.advance(by: 1_000)
        try b.writer.set(table: "category", rowID: "c1", column: "name", to: .text("final"))
        try b.writer.applyRemote(try a.ownOps())
        #expect(try b.value("category", "c1", "name") == .text("final"))
        let history = try b.writer.fieldHistory(table: "category", rowID: "c1", column: "name")
        #expect(history.count == 5)
        #expect(history.map(\.value) == (5..<10).reversed().map { .text("a\($0)") })
        #expect(history.map(\.hlc) == history.map(\.hlc).sorted(by: >))
    }

    @Test func differentFieldsMergeWithoutConflict() throws {
        let (a, b) = try pair()
        try a.writer.setNote(transactionID: "t1", note: "A's note")
        try b.writer.setCategory(transactionID: "t1", categoryID: "c2")
        try exchange(a, b)
        for replica in [a, b] {
            #expect(try replica.value("ledger_transaction", "t1", "note") == .text("A's note"))
            #expect(try replica.value("ledger_transaction", "t1", "category_id") == .text("c2"))
        }
        #expect(try converged(a, b))
    }

    @Test func readWinsOverNewWhicheverArrivesFirst() throws {
        let (a, b) = try pair()
        try b.writer.markSeen(transactionID: "t1")
        // A re-sends the original insert (is_new = 1) after B read the booking: it must not come back.
        try b.writer.applyRemote(try a.ownOps())
        try b.writer.applyRemote(try a.ownOps())
        #expect(try b.value("ledger_transaction", "t1", "is_new") == .integer(0))
        try exchange(a, b)
        #expect(try a.value("ledger_transaction", "t1", "is_new") == .integer(0))
        #expect(try converged(a, b))

        // A third device that sees the read op before the insert ends the same way.
        let c = try Replica(clock: a.clock)
        try c.writer.applyRemote(try b.ownOps())     // set is_new = 0: orphan until the insert arrives
        try c.writer.applyRemote(try a.ownOps())
        #expect(try c.value("ledger_transaction", "t1", "is_new") == .integer(0))
    }

    @Test func deleteBeatsAConcurrentEditAndNothingResurrects() throws {
        let (a, b) = try pair()
        a.clock.advance(by: 100)
        try a.writer.delete(table: "ledger_transaction", rowID: "t1")
        try b.writer.setNote(transactionID: "t1", note: "edited while deleted elsewhere")
        try exchange(a, b)
        for replica in [a, b] {
            #expect(try replica.value("ledger_transaction", "t1", "deleted_at")?.isNull == false)
            #expect(try replica.value("ledger_transaction", "t1", "note") == .text("edited while deleted elsewhere"))
        }
        #expect(try converged(a, b))
        // Replaying the original insert later changes nothing.
        try a.writer.applyRemote(try b.ownOps())
        let insert = try #require(try a.ownOps().first { $0.rowID == "t1" && $0.kind == .insert })
        try b.writer.applyRemote([insert])
        #expect(try b.value("ledger_transaction", "t1", "deleted_at")?.isNull == false)
        #expect(try converged(a, b))
    }

    @Test func concurrentDeletesAgreeOnOneTombstone() throws {
        let (a, b) = try pair()
        try a.writer.delete(table: "category", rowID: "c2")
        b.clock.advance(by: 5)
        try b.writer.delete(table: "category", rowID: "c2")
        try exchange(a, b)
        #expect(try a.value("category", "c2", "deleted_at") == b.value("category", "c2", "deleted_at"))
        #expect(try converged(a, b))
    }

    @Test func duplicateInsertsOfOneBookingMergeTheirAttributes() throws {
        // Two devices fetch the same booking: same id, same identity columns, different display attributes.
        let clock = TestClock()
        let a = try Replica(clock: clock), b = try Replica(clock: clock)
        for replica in [a, b] {
            try replica.writer.insertImmutable(table: "account", row: accountRow("a1"))
        }
        try b.writer.applyRemote(try a.ownOps())
        try a.writer.applyRemote(try b.ownOps())     // account a1 inserted twice: same id on both
        try a.writer.insertImmutable(table: "ledger_transaction", row: transactionRow("t", account: "a1", shortName: "from A"))
        clock.advance(by: 50)
        try b.writer.insertImmutable(table: "ledger_transaction", row: transactionRow("t", account: "a1", shortName: "from B"))
        try exchange(a, b)
        #expect(try a.value("ledger_transaction", "t", "short_name") == .text("from B"))
        #expect(try converged(a, b))
    }

    // MARK: Quarantine

    private func op(
        _ replica: Replica, seq: Int64, kind: SyncOp.Kind = .set, table: String = "category", row: String = "c1",
        column: String? = "name", value: SyncValue? = .text("x"), insert: [String: SyncValue]? = nil, hlc: HLC? = nil, device: DeviceNodeID = 777
    ) -> SyncOp {
        SyncOp(
            device: device, seq: seq,
            hlc: hlc ?? HLC(millis: replica.clock.now + 1, counter: 0, node: device), kind: kind, table: table, rowID: row,
            column: column, value: value, row: insert)
    }

    @Test func unknownSchemaIsQuarantinedAndNothingIsApplied() throws {
        let (_, b) = try pair()
        let ops = [
            op(b, seq: 1, table: "from_the_future"),
            op(b, seq: 2, column: "from_the_future"),
            op(b, seq: 3, table: "ledger_transaction", row: "t1", column: "amount", value: .integer(1)),   // immutable
            op(b, seq: 4, table: "setting", row: "auto_lock_minutes", column: "value", value: .text("1")),  // local key
            op(b, seq: 5, kind: .insert, row: "cx", column: nil, value: nil, insert: ["id": .text("cx"), "bogus": .text("x")]),
        ]
        let result = try b.writer.applyRemote(ops)
        #expect(result == ApplyResult(applied: 0, ignored: 0, quarantined: 5))
        let parked = try b.writer.quarantinedOps()
        #expect(parked.map(\.reason) == Array(repeating: .unknownSchema, count: 5))
        #expect(try b.value("category", "c1", "name") == .text("Groceries"))
        #expect(try b.value("ledger_transaction", "t1", "amount") == .integer(-100))
        // The ops are still logged, so the cursor moves past them.
        #expect(try b.writer.cursors().first { $0.device == 777 }?.appliedSeq == 5)
        // Retrying changes nothing while the schema is unknown.
        #expect(try b.writer.retryQuarantine() == ApplyResult())
        #expect(try b.writer.quarantinedOps().count == 5)
    }

    @Test func futureClocksAreQuarantinedUntilTimeCatchesUp() throws {
        let (_, b) = try pair()
        let future = HLC(millis: b.clock.now + 10 * 60 * 1000, counter: 0, node: 777)
        let result = try b.writer.applyRemote([op(b, seq: 1, value: .text("from the future"), hlc: future)])
        #expect(result == ApplyResult(applied: 0, ignored: 0, quarantined: 1))
        #expect(try b.value("category", "c1", "name") == .text("Groceries"))
        #expect(try b.writer.quarantinedOps().first?.reason == .drift)

        // The local clock must not have absorbed the future time.
        try b.writer.set(table: "category", rowID: "c1", column: "name", to: .text("local"))
        let local = try #require(try b.ownOps().last)
        #expect(local.hlc.millis < future.millis)

        b.clock.advance(by: 6 * 60 * 1000)      // within five minutes of the op now
        let retried = try b.writer.retryQuarantine()
        #expect(retried.applied == 1)
        #expect(try b.value("category", "c1", "name") == .text("from the future"))
        #expect(try b.writer.quarantinedOps().isEmpty)
    }

    @Test func exactlyFiveMinutesAheadIsAccepted() throws {
        let (_, b) = try pair()
        let edge = HLC(millis: b.clock.now + HLCClock.maxDrift, counter: 0, node: 777)
        let result = try b.writer.applyRemote([op(b, seq: 1, value: .text("edge"), hlc: edge)])
        #expect(result.applied == 1)
        let tooFar = HLC(millis: b.clock.now + HLCClock.maxDrift + 1, counter: 0, node: 777)
        #expect(try b.writer.applyRemote([op(b, seq: 2, value: .text("far"), hlc: tooFar)]).quarantined == 1)
    }

    @Test func orphansWaitForTheirParents() throws {
        let clock = TestClock()
        let a = try Replica(clock: clock), b = try Replica(clock: clock)
        try a.writer.insertImmutable(table: "category", row: categoryRow("c1"))
        try a.writer.insertImmutable(table: "account", row: accountRow("a1"))
        try a.writer.insertImmutable(table: "ledger_transaction", row: transactionRow("t1", account: "a1", category: "c1"))
        try a.writer.setNote(transactionID: "t1", note: "n")
        try a.writer.delete(table: "ledger_transaction", rowID: "t1")
        let ops = try a.ownOps()

        // Newest first: everything but the parents is an orphan.
        let late = try b.writer.applyRemote(Array(ops.reversed().dropLast(2)))
        #expect(late.quarantined == 3 && late.applied == 0)
        #expect(try b.writer.quarantinedOps().allSatisfy { $0.reason == .orphan })
        #expect(try b.count("ledger_transaction") == 0)

        let done = try b.writer.applyRemote(Array(ops.prefix(2)))
        #expect(done.quarantined == 0)
        #expect(done.applied == 5)
        #expect(try b.writer.quarantinedOps().isEmpty)
        #expect(try b.value("ledger_transaction", "t1", "note") == .text("n"))
        #expect(try b.value("ledger_transaction", "t1", "deleted_at")?.isNull == false)
        #expect(try a.writer.snapshot().converged == b.writer.snapshot().converged)
    }

    @Test func aMissingForeignKeyParentQuarantinesTheInsert() throws {
        let (_, b) = try pair()
        let row = transactionRow("t9", account: "a1", category: "not-yet")
        let result = try b.writer.applyRemote([op(b, seq: 1, kind: .insert, table: "ledger_transaction", row: "t9", column: nil, value: nil, insert: row)])
        #expect(result.quarantined == 1)
        #expect(try b.count("ledger_transaction", where: "id = 't9'") == 0)
        try b.writer.applyRemote([op(b, seq: 2, kind: .insert, table: "category", row: "not-yet", column: nil, value: nil, insert: categoryRow("not-yet"))])
        #expect(try b.count("ledger_transaction", where: "id = 't9'") == 1)
        #expect(try b.writer.quarantinedOps().isEmpty)
    }

    @Test func constraintViolationsAreParkedAsInvalid() throws {
        let (_, b) = try pair()
        var row = categoryRow("bad")
        row["kind"] = .text("not-an-enum")                      // CHECK constraint
        let wrongType = SyncOp(device: 777, seq: 2, hlc: HLC(millis: b.clock.now, counter: 1, node: 777), kind: .set, table: "ledger_transaction", rowID: "t1", column: "booking_seq", value: .text("abc"))
        let result = try b.writer.applyRemote([
            op(b, seq: 1, kind: .insert, row: "bad", column: nil, value: nil, insert: row), wrongType,
        ])
        #expect(result.quarantined == 2)
        #expect(try b.writer.quarantinedOps().map(\.reason) == [.invalid, .invalid])
        #expect(try b.count("category", where: "id = 'bad'") == 0)
        #expect(try b.value("ledger_transaction", "t1", "booking_seq") == .integer(0))   // nothing half applied
    }

    // MARK: Idempotence, cursors, clock

    @Test func applyingTwiceChangesNothing() throws {
        let (a, b) = try pair()
        try a.writer.setNote(transactionID: "t1", note: "n")
        try a.writer.setCategory(transactionID: "t1", categoryID: "c2")
        try a.writer.delete(table: "category", rowID: "c1")
        let ops = try a.ownOps()
        try b.writer.applyRemote(ops)
        let once = try b.writer.snapshot()
        let second = try b.writer.applyRemote(ops)
        #expect(second.applied == 0 && second.quarantined == 0)
        #expect(try b.writer.snapshot() == once)
        // Also when the ops come back in a different order and batches.
        let c = try Replica(clock: a.clock)
        for op in ops.shuffled() { try c.writer.applyRemote([op, op]) }
        #expect(try c.writer.snapshot().converged == once.converged)
    }

    @Test func ownOpsComingBackAreIgnored() throws {
        let (a, b) = try pair()
        let echoed = try a.writer.applyRemote(try a.ownOps())
        #expect(echoed.applied == 0 && echoed.ignored == 4)
        _ = b
    }

    @Test func cursorsAdvanceOverContiguousSequencesOnly() throws {
        let clock = TestClock()
        let a = try Replica(clock: clock), b = try Replica(clock: clock)
        for i in 0..<5 { try a.writer.insertImmutable(table: "category", row: categoryRow("c\(i)")) }
        let ops = try a.ownOps()
        func applied() throws -> Int64? { try b.writer.cursors().first { $0.device == a.node }?.appliedSeq }
        try b.writer.applyRemote([ops[2], ops[4]])
        #expect(try applied() == 0)
        try b.writer.applyRemote([ops[0]])
        #expect(try applied() == 1)
        try b.writer.applyRemote([ops[1]])
        #expect(try applied() == 3)
        try b.writer.applyRemote([ops[3]])
        #expect(try applied() == 5)
        // Relayed: B can serve A's ops to a third device.
        #expect(try b.writer.ops(from: a.node, after: 2, limit: 10).map(\.seq) == [3, 4, 5])
    }

    @Test func localClockMovesPastEverythingItHasSeen() throws {
        let clock = TestClock()
        let a = try Replica(clock: clock), b = try Replica(clock: clock)
        try a.writer.insertImmutable(table: "category", row: categoryRow("c1"))
        // A's wall clock runs two minutes ahead of B's.
        a.clock.advance(by: 2 * 60 * 1000)
        let slow = try Replica(clock: TestClock(millis: clock.now - 2 * 60 * 1000))
        try slow.writer.applyRemote(try a.ownOps())
        try slow.writer.set(table: "category", rowID: "c1", column: "name", to: .text("after"))
        let seen = try #require(try a.ownOps().last)
        let mine = try #require(try slow.ownOps().last)
        #expect(mine.hlc > seen.hlc)
        _ = b
    }

    @Test func snapshotBootstrapsAFreshDevice() throws {
        let (a, _) = try pair()
        try a.writer.setNote(transactionID: "t1", note: "n")
        try a.writer.delete(table: "category", rowID: "c2")
        try a.writer.setSetting(.rolloverEnabled, "0")
        let snapshot = try a.writer.snapshot()
        #expect(snapshot.tables["category"]?.count == 2)
        #expect(snapshot.cursors.contains(SyncCursor(device: a.node, appliedSeq: 7)))

        let fresh = try Replica(clock: a.clock)
        try fresh.writer.applySnapshot(snapshot)
        #expect(try fresh.writer.snapshot().converged == snapshot.converged)
        #expect(try fresh.writer.cursors().contains(SyncCursor(device: a.node, appliedSeq: 7)))
        #expect(try fresh.ledger.store.setting(.rolloverEnabled) == "0")

        // Deltas after the snapshot continue from the cursor.
        try a.writer.setNote(transactionID: "t1", note: "later")
        let delta = try a.writer.ops(from: a.node, after: 7, limit: 100)
        #expect(delta.count == 1)
        try fresh.writer.applyRemote(delta)
        #expect(try fresh.value("ledger_transaction", "t1", "note") == .text("later"))
        #expect(try fresh.writer.cursors().contains(SyncCursor(device: a.node, appliedSeq: 8)))

        // The snapshot round-trips through JSON (what the transport will do).
        let decoded = try JSONDecoder().decode(LedgerSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test func snapshotNeedsALedgerWithoutLocalEdits() throws {
        let (a, _) = try pair()
        let busy = try Replica(clock: a.clock)
        try busy.writer.insertImmutable(table: "category", row: categoryRow("own"))
        #expect(throws: LedgerWriterError.ledgerHasLocalEdits) { try busy.writer.applySnapshot(try a.writer.snapshot()) }
        var wrong = try a.writer.snapshot()
        wrong.schemaVersion = 99
        let fresh = try Replica(clock: a.clock)
        #expect(throws: LedgerWriterError.snapshotSchemaMismatch(99)) { try fresh.writer.applySnapshot(wrong) }
    }

    @Test func opsRoundTripThroughJSON() throws {
        let (a, _) = try pair()
        try a.writer.set(table: "category", rowID: "c1", column: "name", to: .text("é€"))
        try a.writer.set(table: "account", rowID: "a1", column: "balance", to: .integer(-9_007_199_254_740_993))
        try a.writer.set(table: "account", rowID: "a1", column: "statement_note", to: .null)
        let ops = try a.ownOps()
        let decoded = try JSONDecoder().decode([SyncOp].self, from: JSONEncoder().encode(ops))
        #expect(decoded == ops)
        let values: [SyncValue] = [.null, .integer(Int64.min), .real(1.5), .text("x"), .blob(Data([0, 255]))]
        #expect(try JSONDecoder().decode([SyncValue].self, from: JSONEncoder().encode(values)) == values)
    }
}
