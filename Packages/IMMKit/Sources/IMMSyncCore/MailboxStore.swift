import CryptoKit
import Foundation

public enum MailboxError: Error, Equatable, Sendable {
    case invalidPeerID
    case invalidRange
    case blobTooLarge(Int)
    /// The per-peer or global quota would be exceeded (after expired entries were evicted).
    case quotaExceeded
    case notFound
    case io(String)
}

/// Directory name of one peer's mailbox: lower-case hex of its Noise static public key, or any `[A-Za-z0-9_-]{1,64}`.
public struct MailboxPeerID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard (1...64).contains(rawValue.utf8.count), rawValue.utf8.allSatisfy({
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x5f
        }) else { return nil }
        self.rawValue = rawValue
    }

    public init(staticKey: Data) {
        self.rawValue = staticKey.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { rawValue }
}

public struct MailboxEntry: Hashable, Sendable {
    public let peer: MailboxPeerID
    /// Device whose ops the blob contains.
    public let sender: UInt64
    public let seqFrom: Int64
    public let seqTo: Int64
    public let size: Int
    public let storedAt: Date

    var fileName: String { MailboxStore.fileName(sender: sender, seqFrom: seqFrom, seqTo: seqTo) }
}

/// The agent's blind store of sealed batches: one directory per peer, one file per `(sender, seqFrom…seqTo)`.
/// It never opens a blob's payload (only `fetch` returns bytes, untouched); metadata comes from file names and
/// attributes. Writes are atomic (temp file in the same directory, `fsync`, `rename`). Duplicates of the same range are
/// idempotent (first writer wins). Entries older than the TTL are evicted; a write that would exceed the quota fails
/// with `.quotaExceeded` rather than dropping un-acked data.
public final class MailboxStore: @unchecked Sendable {
    public struct Limits: Sendable {
        public var quotaBytesPerPeer: Int
        public var totalQuotaBytes: Int?
        public var ttl: TimeInterval
        public var maxBlobBytes: Int

        public init(
            quotaBytesPerPeer: Int = 50 << 20, totalQuotaBytes: Int? = nil, ttl: TimeInterval = 90 * 86_400,
            maxBlobBytes: Int = SealedEnvelope.maxEncodedSize
        ) {
            self.quotaBytesPerPeer = quotaBytesPerPeer
            self.totalQuotaBytes = totalQuotaBytes
            self.ttl = ttl
            self.maxBlobBytes = maxBlobBytes
        }
    }

    public let root: URL
    public let limits: Limits
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private static let suffix = ".blob"
    private static let tempPrefix = ".tmp-"

    public init(root: URL, limits: Limits = Limits(), clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.root = root
        self.limits = limits
        self.clock = clock
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw MailboxError.io("cannot create mailbox root: \(error.localizedDescription)")
        }
    }

    static func fileName(sender: UInt64, seqFrom: Int64, seqTo: Int64) -> String {
        String(format: "%016llx-%020lld-%020lld", sender, seqFrom, seqTo) + suffix
    }

    private static func parse(fileName: String) -> (sender: UInt64, seqFrom: Int64, seqTo: Int64)? {
        guard fileName.hasSuffix(suffix), !fileName.hasPrefix(".") else { return nil }
        let parts = fileName.dropLast(suffix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 16, let sender = UInt64(parts[0], radix: 16),
              let from = Int64(parts[1]), let to = Int64(parts[2]), from >= 0, from <= to else { return nil }
        return (sender, from, to)
    }

    private func directory(_ peer: MailboxPeerID) -> URL { root.appendingPathComponent(peer.rawValue, isDirectory: true) }

    // MARK: Write

    /// Stores `blob` for `peer` under `(sender, seqFrom…seqTo)`; returns the existing entry when that range is already stored.
    @discardableResult
    public func put(_ blob: Data, peer: MailboxPeerID, sender: UInt64, seqFrom: Int64, seqTo: Int64) throws -> MailboxEntry {
        guard seqFrom >= 0, seqFrom <= seqTo else { throw MailboxError.invalidRange }
        guard blob.count <= limits.maxBlobBytes else { throw MailboxError.blobTooLarge(blob.count) }
        lock.lock()
        defer { lock.unlock() }

        let dir = directory(peer)
        let name = Self.fileName(sender: sender, seqFrom: seqFrom, seqTo: seqTo)
        let target = dir.appendingPathComponent(name)
        if let existing = try entry(at: target, peer: peer) { return existing }

        try ensureDirectory(dir)
        if try wouldExceedQuota(peer: peer, adding: blob.count) {
            _ = try evictExpiredLocked()
            if try wouldExceedQuota(peer: peer, adding: blob.count) { throw MailboxError.quotaExceeded }
        }

        let now = clock()
        let temp = dir.appendingPathComponent(Self.tempPrefix + UUID().uuidString)
        do {
            try writeAtomically(blob, temp: temp, target: target, modified: now)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw MailboxError.io("write failed: \(error.localizedDescription)")
        }
        return MailboxEntry(peer: peer, sender: sender, seqFrom: seqFrom, seqTo: seqTo, size: blob.count, storedAt: now)
    }

    /// Stores an encoded `SealedEnvelope` under the sender/sequence range of its (unauthenticated) header.
    @discardableResult
    public func put(envelope bytes: Data, peer: MailboxPeerID) throws -> MailboxEntry {
        let header: SealedEnvelope.Header
        do { header = try SealedEnvelope.peekHeader(bytes) } catch { throw MailboxError.invalidRange }
        return try put(bytes, peer: peer, sender: header.device, seqFrom: header.seqFrom, seqTo: header.seqTo)
    }

    private func ensureDirectory(_ dir: URL) throws {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw MailboxError.io("cannot create peer directory: \(error.localizedDescription)")
        }
    }

    private func writeAtomically(_ blob: Data, temp: URL, target: URL, modified: Date) throws {
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw MailboxError.io("open: \(String(cString: strerror(errno)))") }
        var closed = false
        defer { if !closed { close(fd) } }
        try blob.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MailboxError.io("write: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw MailboxError.io("fsync: \(String(cString: strerror(errno)))") }
        let times = [timespec(tv_sec: Int(modified.timeIntervalSince1970), tv_nsec: 0), timespec(tv_sec: Int(modified.timeIntervalSince1970), tv_nsec: 0)]
        _ = futimens(fd, times)
        closed = true
        guard close(fd) == 0 else { throw MailboxError.io("close: \(String(cString: strerror(errno)))") }
        guard rename(temp.path, target.path) == 0 else { throw MailboxError.io("rename: \(String(cString: strerror(errno)))") }
        let dirFD = open(target.deletingLastPathComponent().path, O_RDONLY)
        if dirFD >= 0 {
            _ = fsync(dirFD)
            close(dirFD)
        }
    }

    // MARK: Read

    public func peers() throws -> [MailboxPeerID] {
        lock.lock()
        defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(MailboxPeerID.init).sorted { $0.rawValue < $1.rawValue }
    }

    /// Entries of `peer`, ordered by sender, then sequence range.
    public func list(peer: MailboxPeerID) throws -> [MailboxEntry] {
        lock.lock()
        defer { lock.unlock() }
        return try listLocked(peer: peer)
    }

    public func fetch(_ entry: MailboxEntry) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let url = directory(entry.peer).appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MailboxError.notFound }
        do { return try Data(contentsOf: url) } catch { throw MailboxError.io("read: \(error.localizedDescription)") }
    }

    public func usedBytes(peer: MailboxPeerID) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try usedBytesLocked(peer: peer)
    }

    // MARK: Delete / evict

    public func delete(_ entry: MailboxEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = directory(entry.peer).appendingPathComponent(entry.fileName)
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile { return } catch {
            throw MailboxError.io("delete: \(error.localizedDescription)")
        }
    }

    /// Deletes the peer's whole mailbox (device removed).
    public func deleteAll(peer: MailboxPeerID) throws {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory(peer))
    }

    /// Removes entries older than the TTL (and abandoned temp files); returns how many entries were removed.
    @discardableResult
    public func evictExpired() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try evictExpiredLocked()
    }

    // MARK: Internals (lock held)

    private func entry(at url: URL, peer: MailboxPeerID) throws -> MailboxEntry? {
        guard let parsed = Self.parse(fileName: url.lastPathComponent),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        return MailboxEntry(
            peer: peer, sender: parsed.sender, seqFrom: parsed.seqFrom, seqTo: parsed.seqTo, size: size,
            storedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0))
    }

    private func listLocked(peer: MailboxPeerID) throws -> [MailboxEntry] {
        let dir = directory(peer)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { try? entry(at: dir.appendingPathComponent($0), peer: peer) }
    }

    private func usedBytesLocked(peer: MailboxPeerID) throws -> Int {
        try listLocked(peer: peer).reduce(0) { $0 + $1.size }
    }

    private func wouldExceedQuota(peer: MailboxPeerID, adding: Int) throws -> Bool {
        if try usedBytesLocked(peer: peer) + adding > limits.quotaBytesPerPeer { return true }
        guard let total = limits.totalQuotaBytes else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let used = try names.compactMap(MailboxPeerID.init).reduce(0) { $0 + (try usedBytesLocked(peer: $1)) }
        return used + adding > total
    }

    private func evictExpiredLocked() throws -> Int {
        let cutoff = clock().addingTimeInterval(-limits.ttl)
        var removed = 0
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for peer in names.compactMap(MailboxPeerID.init) {
            let dir = directory(peer)
            for entry in try listLocked(peer: peer) where entry.storedAt < cutoff {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry.fileName))
                removed += 1
            }
            // Abandoned temp files (crash between create and rename).
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(Self.tempPrefix) {
                let url = dir.appendingPathComponent(name)
                if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   modified < clock().addingTimeInterval(-3_600) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        return removed
    }
}
