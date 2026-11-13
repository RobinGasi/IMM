import Foundation
import GRDB
import Testing
@testable import IMMLedger

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random edits on 2–5 replicas, exchanged in random order with duplicates and random batch splits, must leave every
/// replica with identical synced tables and field clocks.
@Suite struct ConvergenceTests {
    /// What the random runs exercised, so the test cannot pass vacuously.
    private final class Stats: @unchecked Sendable {
        var ops = 0, applied = 0, ignored = 0, quarantined = 0, drifted = 0
    }
    private let stats = Stats()

    private let categories = (0..<4).map { "cat-\($0)" }
    private let accounts = ["acc-0", "acc-1"]

    private func randomEdit(_ replica: Replica, rng: inout SeededRandom, step: Int) throws {
        let writer = replica.writer
        replica.clock.advance(by: UInt64.random(in: 0...40, using: &rng))
        func pick(_ table: String, live: Bool = false) throws -> String? {
            try replica.database.read {
                try String.fetchAll($0, sql: "SELECT id FROM \"\(table)\"\(live ? " WHERE deleted_at IS NULL" : "") ORDER BY id").randomElement(using: &rng)
            }
        }
        switch Int.random(in: 0..<14, using: &rng) {
        case 0:
            let id = categories.randomElement(using: &rng)!
            try writer.insertImmutable(table: "category", row: categoryRow(id, name: "n\(step)", sort: ["V", "k", "A", "z"].randomElement(using: &rng)!))
        case 1:
            let id = accounts.randomElement(using: &rng)!
            try writer.insertImmutable(table: "account", row: accountRow(id, name: "name\(step)", balance: step))
        case 2, 3:
            // The same booking on several devices: identical identity columns, device-specific attributes.
            let index = Int.random(in: 0..<12, using: &rng)
            let account = accounts[index % 2]
            guard try replica.count("account", where: "id = '\(account)'") == 1 else { return }
            try writer.insertImmutable(table: "ledger_transaction", row: transactionRow(
                "booking-\(index)", account: account, day: "2026-11-\(String(format: "%02d", index + 1))", amount: -(index + 1) * 100,
                isNew: Bool.random(using: &rng), shortName: "attr\(step)"))
        case 4:
            guard let id = try pick("ledger_transaction"), let category = categories.randomElement(using: &rng) else { return }
            if Bool.random(using: &rng) {
                try writer.setCategory(transactionID: id, categoryID: nil)
            } else if try replica.count("category", where: "id = '\(category)'") == 1 {
                try writer.setCategory(transactionID: id, categoryID: category)
            }
        case 5:
            guard let id = try pick("ledger_transaction") else { return }
            try writer.setNote(transactionID: id, note: Bool.random(using: &rng) ? nil : "note\(step)")
        case 6:
            guard let id = try pick("ledger_transaction") else { return }
            try writer.markSeen(transactionID: id)
        case 7:
            guard let id = try pick("category") else { return }
            try writer.set(table: "category", rowID: id, column: ["name", "color_token", "sort_order"].randomElement(using: &rng)!, to: .text("v\(step)"))
        case 8:
            guard let id = try pick("category", live: true) else { return }
            try writer.delete(table: "category", rowID: id)
        case 9:
            guard let id = try pick("ledger_transaction", live: true) else { return }
            try writer.delete(table: "ledger_transaction", rowID: id)
        case 10:
            guard let category = categories.randomElement(using: &rng), try replica.count("category", where: "id = '\(category)'") == 1 else { return }
            try writer.addRule(pattern: "pattern\(Int.random(in: 0..<3, using: &rng))", categoryID: category)
        case 11:
            guard let id = try pick("rule") else { return }
            try writer.setRule(id: id, enabled: Bool.random(using: &rng))
        case 12:
            try writer.setSetting(.rolloverEnabled, ["0", "1", nil].randomElement(using: &rng)!)
        default:
            guard let id = try pick("account") else { return }
            try writer.set(table: "account", rowID: id, column: "balance", to: .integer(Int64.random(in: -1000...1000, using: &rng)))
        }
    }

    /// Delivers everything `others` authored (and relays what `target` knows of third devices) in a shuffled,
    /// duplicated and re-batched stream.
    private func deliver(from sources: [Replica], to target: Replica, rng: inout SeededRandom) throws {
        var stream: [SyncOp] = []
        for source in sources where source !== target {
            // Everything the source's log holds, authored by itself or relayed from third devices.
            for known in try source.writer.cursors() where known.device != target.node {
                let have = try target.writer.cursors().first { $0.device == known.device }?.appliedSeq ?? 0
                let all = try source.writer.ops(from: known.device, after: Bool.random(using: &rng) ? 0 : have, limit: .max)
                stream += all
                stream += all.filter { _ in Int.random(in: 0..<4, using: &rng) == 0 }   // duplicates
            }
        }
        stream.shuffle(using: &rng)
        var index = 0
        while index < stream.count {
            let size = Int.random(in: 1...9, using: &rng)
            let result = try target.writer.applyRemote(Array(stream[index..<min(stream.count, index + size)]))
            stats.applied += result.applied
            stats.ignored += result.ignored
            stats.quarantined += result.quarantined
            index += size
        }
    }

    private func run(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        let clock = TestClock()
        let count = Int.random(in: 2...5, using: &rng)
        let replicas = try (0..<count).map { _ in try Replica(clock: clock) }
        var step = 0
        for round in 0..<2 {
            for _ in 0..<(50 + 20 * count) {
                step += 1
                try randomEdit(replicas.randomElement(using: &rng)!, rng: &rng, step: step)
            }
            // Partial exchange in the first round, full exchange at the end.
            for target in replicas where round == 1 || Bool.random(using: &rng) {
                try deliver(from: replicas, to: target, rng: &rng)
            }
        }
        for _ in 0..<2 {     // second pass: relays of what other devices received in the first
            for target in replicas { try deliver(from: replicas, to: target, rng: &rng) }
        }

        let reference = try replicas[0].writer.snapshot().converged
        for (index, replica) in replicas.enumerated() {
            let snapshot = try replica.writer.snapshot().converged
            #expect(snapshot == reference, "replica \(index) diverged, seed \(seed)")
            #expect(try replica.writer.quarantinedOps().isEmpty, "quarantine not empty on replica \(index), seed \(seed)")
        }
        // Idempotence: delivering everything again changes nothing.
        for target in replicas { try deliver(from: replicas, to: target, rng: &rng) }
        for replica in replicas { #expect(try replica.writer.snapshot().converged == reference) }
        // And every replica holds a contiguous cursor over every device's ops.
        let heads = try Dictionary(uniqueKeysWithValues: replicas.map { ($0.node, try $0.ownOps().count) })
        stats.ops += heads.values.reduce(0, +)
        for replica in replicas {
            for cursor in try replica.writer.cursors() { #expect(Int(cursor.appliedSeq) == heads[cursor.device]) }
        }
    }

    @Test func randomEditsConvergeOnEveryReplica() throws {
        for seed in 1...16 { try run(seed: UInt64(seed)) }
        #expect(stats.ops > 1_500)
        #expect(stats.applied > 1_500)
        #expect(stats.ignored > 1_500)         // duplicates and losers
        #expect(stats.quarantined > 50)       // out-of-order delivery produced orphans that later resolved
    }

    @Test func aReplicaBootstrappedFromASnapshotJoinsTheConvergence() throws {
        var rng = SeededRandom(seed: 1234)
        let clock = TestClock()
        let replicas = try (0..<3).map { _ in try Replica(clock: clock) }
        for step in 0..<80 { try randomEdit(replicas[step % 2], rng: &rng, step: step) }
        try deliver(from: replicas, to: replicas[0], rng: &rng)
        try deliver(from: replicas, to: replicas[1], rng: &rng)
        // The third device joins from a snapshot of the first, then both keep editing.
        try replicas[2].writer.applySnapshot(try replicas[0].writer.snapshot())
        for step in 80..<140 { try randomEdit(replicas[step % 3], rng: &rng, step: step) }
        for _ in 0..<2 { for target in replicas { try deliver(from: replicas, to: target, rng: &rng) } }
        let reference = try replicas[0].writer.snapshot().converged
        for replica in replicas { #expect(try replica.writer.snapshot().converged == reference) }
    }
}
