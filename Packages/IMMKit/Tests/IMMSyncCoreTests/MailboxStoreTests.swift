import Foundation
import Testing

@testable import IMMSyncCore

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
    var date: Date { lock.lock(); defer { lock.unlock() }; return now }
    func advance(_ seconds: TimeInterval) { lock.lock(); now = now.addingTimeInterval(seconds); lock.unlock() }
}

struct MailboxStoreTests {
    private func makeStore(_ limits: MailboxStore.Limits = .init(), clock: TestClock = TestClock()) throws -> (MailboxStore, URL, TestClock) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imm-mailbox-\(UUID().uuidString)")
        return (try MailboxStore(root: root, limits: limits, clock: { clock.date }), root, clock)
    }

    private let peer = MailboxPeerID("peer-a")!
    private let other = MailboxPeerID("peer-b")!

    @Test func putListFetchDelete() throws {
        let (store, root, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobA = Data("sealed-a".utf8), blobB = Data("sealed-b".utf8), blobC = Data("sealed-c".utf8)
        try store.put(blobB, peer: peer, sender: 2, seqFrom: 1, seqTo: 10)
        try store.put(blobA, peer: peer, sender: 1, seqFrom: 11, seqTo: 12)
        try store.put(blobC, peer: peer, sender: 1, seqFrom: 2, seqTo: 10)
        try store.put(blobA, peer: other, sender: 1, seqFrom: 1, seqTo: 1)

        let entries = try store.list(peer: peer)
        #expect(entries.map { [$0.sender, UInt64($0.seqFrom), UInt64($0.seqTo)] } == [[1, 2, 10], [1, 11, 12], [2, 1, 10]])
        #expect(try store.fetch(entries[0]) == blobC)
        #expect(try store.fetch(entries[2]) == blobB)
        #expect(entries.allSatisfy { $0.size > 0 })
        #expect(try store.usedBytes(peer: peer) == blobA.count + blobB.count + blobC.count)
        #expect(try store.peers() == [peer, other])

        try store.delete(entries[1])
        #expect(try store.list(peer: peer).count == 2)
        try store.delete(entries[1])  // deleting twice is fine
        #expect(throws: MailboxError.notFound) { try store.fetch(entries[1]) }
        try store.deleteAll(peer: peer)
        #expect(try store.list(peer: peer).isEmpty)
        #expect(try store.list(peer: other).count == 1)
    }

    @Test func listOrderIsNumericNotLexicographic() throws {
        let (store, root, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for from in [100, 9, 20] as [Int64] { try store.put(Data([1]), peer: peer, sender: 1, seqFrom: from, seqTo: from + 1) }
        #expect(try store.list(peer: peer).map(\.seqFrom) == [9, 20, 100])
    }

    @Test func duplicateRangeIsIdempotentFirstWriterWins() throws {
        let (store, root, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.put(Data("first".utf8), peer: peer, sender: 1, seqFrom: 1, seqTo: 5)
        let second = try store.put(Data("second-longer".utf8), peer: peer, sender: 1, seqFrom: 1, seqTo: 5)
        #expect(first == second)
        #expect(try store.list(peer: peer).count == 1)
        #expect(try store.fetch(first) == Data("first".utf8))
    }

    @Test func writesAreAtomicAndLeaveNoTempFiles() throws {
        let (store, root, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.put(Data(count: 500_000), peer: peer, sender: 1, seqFrom: 1, seqTo: 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(peer.rawValue).path)
        #expect(names.count == 1)
        #expect(names.allSatisfy { !$0.hasPrefix(".") && $0.hasSuffix(".blob") })
        // A stray temp file from a crash is neither listed nor counted.
        let stray = root.appendingPathComponent(peer.rawValue).appendingPathComponent(".tmp-crash")
        try Data(count: 10).write(to: stray)
        #expect(try store.list(peer: peer).count == 1)
        #expect(try store.usedBytes(peer: peer) == 500_000)
        // Junk file names are ignored too.
        try Data(count: 10).write(to: root.appendingPathComponent(peer.rawValue).appendingPathComponent("notes.txt"))
        #expect(try store.list(peer: peer).count == 1)
    }

    @Test func perPeerQuotaIsEnforced() throws {
        let (store, root, _) = try makeStore(.init(quotaBytesPerPeer: 100))
        defer { try? FileManager.default.removeItem(at: root) }
        try store.put(Data(count: 60), peer: peer, sender: 1, seqFrom: 1, seqTo: 1)
        #expect(throws: MailboxError.quotaExceeded) { try store.put(Data(count: 41), peer: peer, sender: 1, seqFrom: 2, seqTo: 2) }
        try store.put(Data(count: 40), peer: peer, sender: 1, seqFrom: 2, seqTo: 2)  // exactly full
        #expect(throws: MailboxError.quotaExceeded) { try store.put(Data(count: 1), peer: peer, sender: 1, seqFrom: 3, seqTo: 3) }
        try store.put(Data(count: 100), peer: other, sender: 1, seqFrom: 1, seqTo: 1)  // other peers are separate
        // Freeing space helps.
        try store.delete(try store.list(peer: peer)[0])
        try store.put(Data(count: 41), peer: peer, sender: 1, seqFrom: 3, seqTo: 3)
    }

    @Test func totalQuotaIsEnforced() throws {
        let (store, root, _) = try makeStore(.init(quotaBytesPerPeer: 1000, totalQuotaBytes: 150))
        defer { try? FileManager.default.removeItem(at: root) }
        try store.put(Data(count: 100), peer: peer, sender: 1, seqFrom: 1, seqTo: 1)
        #expect(throws: MailboxError.quotaExceeded) { try store.put(Data(count: 51), peer: other, sender: 1, seqFrom: 1, seqTo: 1) }
        try store.put(Data(count: 50), peer: other, sender: 1, seqFrom: 1, seqTo: 1)
    }

    @Test func ttlEvictionDropsOldEntriesAndFreesQuota() throws {
        let (store, root, clock) = try makeStore(.init(quotaBytesPerPeer: 100, ttl: 1000))
        defer { try? FileManager.default.removeItem(at: root) }
        try store.put(Data(count: 60), peer: peer, sender: 1, seqFrom: 1, seqTo: 1)
        clock.advance(600)
        try store.put(Data(count: 30), peer: peer, sender: 1, seqFrom: 2, seqTo: 2)
        #expect(try store.evictExpired() == 0)
        clock.advance(500)  // first entry is 1100 s old, second 500 s
        #expect(try store.evictExpired() == 1)
        #expect(try store.list(peer: peer).map(\.seqFrom) == [2])
        // Quota pressure triggers eviction implicitly.
        clock.advance(100)
        try store.put(Data(count: 60), peer: peer, sender: 1, seqFrom: 3, seqTo: 3)
        clock.advance(950)  // seq 2 (1550 s) and 3 (950 s)
        // 30 + 60 + 40 > 100: the write evicts the expired seq 2 on the way and then fits (60 + 40).
        try store.put(Data(count: 40), peer: peer, sender: 1, seqFrom: 4, seqTo: 4)
        #expect(try store.list(peer: peer).map(\.seqFrom) == [3, 4])
        // Nothing expired left to free: a further write fails.
        #expect(throws: MailboxError.quotaExceeded) { try store.put(Data(count: 1), peer: peer, sender: 1, seqFrom: 5, seqTo: 5) }
    }

    @Test func storedAtComesFromTheClock() throws {
        let (store, root, clock) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try store.put(Data([1]), peer: peer, sender: 1, seqFrom: 1, seqTo: 1)
        #expect(entry.storedAt == clock.date)
        #expect(try store.list(peer: peer)[0].storedAt == clock.date)
    }

    @Test func rejectsBadInput() throws {
        let (store, root, _) = try makeStore(.init(maxBlobBytes: 10))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: MailboxError.invalidRange) { try store.put(Data([1]), peer: peer, sender: 1, seqFrom: 3, seqTo: 2) }
        #expect(throws: MailboxError.invalidRange) { try store.put(Data([1]), peer: peer, sender: 1, seqFrom: -1, seqTo: 2) }
        #expect(throws: MailboxError.blobTooLarge(11)) { try store.put(Data(count: 11), peer: peer, sender: 1, seqFrom: 1, seqTo: 1) }
        // Peer ids cannot escape the root.
        for bad in ["", "..", "../x", "a/b", ".hidden", "a b", String(repeating: "a", count: 65)] {
            #expect(MailboxPeerID(bad) == nil, "\(bad)")
        }
        #expect(MailboxPeerID(staticKey: Data(repeating: 0xab, count: 32)).rawValue == String(repeating: "ab", count: 32))
    }

    @Test func storesEnvelopesUnderTheirHeader() throws {
        let (store, root, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let envelope = try SealedEnvelope.seal(
            payload: Data("secret ops".utf8),
            header: SealedEnvelope.Header(group: Data(repeating: 3, count: 16), device: 0xabc, seqFrom: 7, seqTo: 9),
            key: SyncGroupKey.generate())
        let entry = try store.put(envelope: envelope.encoded(), peer: peer)
        #expect(entry.sender == 0xabc && entry.seqFrom == 7 && entry.seqTo == 9)
        #expect(try store.fetch(entry) == envelope.encoded())
        #expect(throws: MailboxError.invalidRange) { try store.put(envelope: Data(count: 5), peer: peer) }
        // The file name carries the metadata; the content is opaque bytes on disk.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(peer.rawValue).path)
        #expect(names == ["0000000000000abc-00000000000000000007-00000000000000000009.blob"])
    }

    @Test func survivesReopen() throws {
        let (store, root, clock) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.put(Data("kept".utf8), peer: peer, sender: 1, seqFrom: 1, seqTo: 1)
        let reopened = try MailboxStore(root: root, clock: { clock.date })
        let entries = try reopened.list(peer: peer)
        #expect(entries.count == 1)
        #expect(try reopened.fetch(entries[0]) == Data("kept".utf8))
    }
}
