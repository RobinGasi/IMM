import Foundation
import IMMLedger
import IMMSyncCore

/// One sealed envelope that arrived through the relay: the envelope, the record it travelled in and when the relay got it.
public struct RelayItem: Sendable, Equatable, Identifiable {
    public var id: String { recordID }
    /// Opaque name of the relay record (a random UUID in CloudKit).
    public let recordID: String
    public let envelope: SealedEnvelope
    public let uploadedAt: Date

    /// The device that sealed the envelope.
    public var sender: DeviceNodeID { envelope.header.device }

    public init(recordID: String, envelope: SealedEnvelope, uploadedAt: Date) {
        self.recordID = recordID
        self.envelope = envelope
        self.uploadedAt = uploadedAt
    }
}

/// What a store reports besides the results of calls.
public enum RelayStoreEvent: Sendable, Equatable {
    /// Items may be waiting (a push arrived or a fetch brought something).
    case remoteChange
    /// The account the relay lives in is gone (signed out): the relay stops; the live lane is unaffected.
    case accountLost(String)
    /// The account is back (signed in again).
    case accountAvailable
    /// The relay lost its content (zone deleted, account switched or the user reset iCloud data): publish the recent batches again.
    case reset
    case failure(String)
}

public enum RelayError: Error, Equatable, Sendable {
    /// The relay cannot be used right now (no entitlement, no account, signed out).
    case unavailable(String)
    case malformed(String)
}

/// Where sealed batches wait for devices that are not reachable. The store only moves opaque envelopes; it never opens one.
///
/// Records are immutable: a store inserts and deletes, it never updates. Delivery is at least once and per replica: `fetchNew()`
/// returns every item that arrived from another device and was not yet acknowledged; an item is returned again until the caller
/// `acknowledge`s it, so a crash between fetching and applying loses nothing.
public protocol RelayStore: Sendable {
    var events: AsyncStream<RelayStoreEvent> { get }

    /// Hands envelopes sealed by `device` to the relay and returns their record ids, in order. Returns once the envelopes are
    /// stored durably on this device; the transfer may complete later.
    func upload(_ envelopes: [SealedEnvelope], from device: DeviceNodeID) async throws -> [String]

    /// Items from other devices not yet acknowledged. Asks the relay for news first.
    func fetchNew() async throws -> [RelayItem]

    /// This device has processed `items`; `fetchNew()` stops returning them. The items stay on the relay.
    func acknowledge(_ items: [RelayItem]) async throws

    /// Removes records from the relay (cleanup policy: everyone acknowledged them, or they are too old).
    func delete(recordIDs: [String]) async throws

    /// Forgets all local bookkeeping of this store (engine state, pending transfers, undelivered items) and starts afresh.
    func resetState() async throws

    /// Stops background work. Safe to call more than once.
    func stop() async
}

/// Small key-value storage a store keeps its durable state in: the vault's local sync tables in the app, a dictionary in tests.
public protocol RelayPersistence: Sendable {
    func read(_ name: String) -> Data?
    /// `nil` removes the entry. Writes after the owner closed the storage are dropped.
    func write(_ name: String, _ value: Data?)
    func names(prefix: String) -> [String]
}

/// What the Mac shows about the relay lane.
public enum RelayStatus: Equatable, Sendable {
    /// Not usable: unsigned build, no iCloud account, restricted account, sync switched off.
    case unavailable(String)
    case ready
    case syncing
    case error(String)
}

// MARK: - In-memory implementations

public final class InMemoryRelayPersistence: RelayPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func read(_ name: String) -> Data? { lock.withLock { values[name] } }

    public func write(_ name: String, _ value: Data?) {
        lock.withLock { values[name] = value }
    }

    public func names(prefix: String) -> [String] { lock.withLock { values.keys.filter { $0.hasPrefix(prefix) }.sorted() } }
}

/// The shared "cloud" of `InMemoryRelayStore` replicas: one record list every replica of a test talks to.
public actor InMemoryRelayCloud {
    struct Record: Sendable {
        var envelope: SealedEnvelope
        var uploader: DeviceNodeID
        var uploadedAt: Date
    }

    private var records: [String: Record] = [:]
    private var order: [String] = []
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Record ids currently on the relay, oldest first.
    public var recordIDs: [String] { order.filter { records[$0] != nil } }

    public func envelopes() -> [SealedEnvelope] { recordIDs.compactMap { records[$0]?.envelope } }

    func insert(_ envelope: SealedEnvelope, from uploader: DeviceNodeID) -> String {
        let id = UUID().uuidString
        records[id] = Record(envelope: envelope, uploader: uploader, uploadedAt: now())
        order.append(id)
        return id
    }

    func remove(_ ids: [String]) {
        for id in ids { records[id] = nil }
        order.removeAll { records[$0] == nil }
    }

    func items(notFrom device: DeviceNodeID, excluding seen: Set<String>) -> [RelayItem] {
        order.compactMap { id in
            guard let record = records[id], record.uploader != device, !seen.contains(id) else { return nil }
            return RelayItem(recordID: id, envelope: record.envelope, uploadedAt: record.uploadedAt)
        }
    }

    /// Test helper: replaces a record's upload time (retention tests).
    public func backdate(_ id: String, to date: Date) {
        records[id]?.uploadedAt = date
    }
}

/// A replica's view of an `InMemoryRelayCloud`. Behaves like the CloudKit store as far as the lane can tell: per-replica
/// delivery state, at-least-once until acknowledged, never returns the replica's own uploads, can lose its account.
public actor InMemoryRelayStore: RelayStore {
    public nonisolated let events: AsyncStream<RelayStoreEvent>
    private let continuation: AsyncStream<RelayStoreEvent>.Continuation
    private let cloud: InMemoryRelayCloud
    private let device: DeviceNodeID
    private var seen: Set<String> = []
    private var inbox: [String: RelayItem] = [:]
    private var accountLostReason: String?
    /// Uploads, fetches and deletions this replica made (tests assert on traffic).
    public private(set) var uploadCount = 0
    public private(set) var fetchCount = 0

    public init(cloud: InMemoryRelayCloud, device: DeviceNodeID) {
        self.cloud = cloud
        self.device = device
        (events, continuation) = AsyncStream<RelayStoreEvent>.makeStream()
    }

    public func upload(_ envelopes: [SealedEnvelope], from device: DeviceNodeID) async throws -> [String] {
        try checkAccount()
        uploadCount += envelopes.count
        var ids: [String] = []
        for envelope in envelopes { ids.append(await cloud.insert(envelope, from: device)) }
        return ids
    }

    public func fetchNew() async throws -> [RelayItem] {
        try checkAccount()
        fetchCount += 1
        for item in await cloud.items(notFrom: device, excluding: seen) {
            seen.insert(item.recordID)
            inbox[item.recordID] = item
        }
        return inbox.values.sorted { ($0.uploadedAt, $0.recordID) < ($1.uploadedAt, $1.recordID) }
    }

    public func acknowledge(_ items: [RelayItem]) async throws {
        for item in items { inbox[item.recordID] = nil }
    }

    public func delete(recordIDs: [String]) async throws {
        try checkAccount()
        await cloud.remove(recordIDs)
        for id in recordIDs { inbox[id] = nil }
    }

    public func resetState() async throws {
        seen = []
        inbox = [:]
    }

    public func stop() async { continuation.finish() }

    private func checkAccount() throws {
        if let accountLostReason { throw RelayError.unavailable(accountLostReason) }
    }

    // MARK: Test controls

    /// The iCloud account went away: calls throw and the lane is told.
    public func simulateAccountLoss(_ reason: String = "Signed out of iCloud.") {
        accountLostReason = reason
        continuation.yield(.accountLost(reason))
    }

    public func simulateAccountReturn() {
        accountLostReason = nil
        continuation.yield(.accountAvailable)
    }

    /// A push: tells the lane that items are waiting.
    public func simulatePush() { continuation.yield(.remoteChange) }

    /// The relay lost everything (zone deleted by the user).
    public func simulateZoneLoss() async {
        await cloud.remove(await cloud.recordIDs)
        continuation.yield(.reset)
    }
}
