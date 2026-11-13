import CloudKit
import Foundation
import IMMLedger
import IMMSyncCore

/// The relay on CloudKit: one `CKSyncEngine` over the private database, one custom zone, one immutable `SealedBatch` record
/// per sealed envelope.
///
/// - Record: `SealedBatch` with `blob` (bytes, up to `inlineLimit`; larger envelopes go to `asset` as a `CKAsset`), `group`
///   (16 bytes), `device` (node id as the bit pattern of an `Int64`), `seqFrom`, `seqTo`. The record name is a random UUID.
///   The envelope is sealed under the group key before it gets here, so CloudKit sees ciphertext, the group id, the node id
///   and sequence numbers, never ledger content. The schema is forward-only in Production: new information goes into the
///   sealed envelope, not into new fields.
/// - Immutable: records are inserted and deleted, never updated. `serverRecordChanged` on a save means the record already
///   exists (an earlier attempt got through): the pending upload is dropped.
/// - Durable: an envelope waiting for upload (`outbox`), an item fetched but not yet applied (`inbox`) and the engine's state
///   live in `persistence` (the vault's local sync tables), so a crash between any two steps loses nothing.
/// - Account: `accountChange` signOut / switchAccounts wipes the local relay state and tells the lane (`accountLost` /
///   `reset`); the live lane never depends on this store.
///
/// Construction touches nothing: the container and the engine are created by `start()` after the entitlement check.
public actor CloudKitRelayStore: RelayStore, CKSyncEngineDelegate {
    public static let recordType = "SealedBatch"
    public static let defaultZoneName = "imm-sync"

    public nonisolated let events: AsyncStream<RelayStoreEvent>
    private let continuation: AsyncStream<RelayStoreEvent>.Continuation

    private let zoneID: CKRecordZone.ID
    private let device: DeviceNodeID
    private let persistence: any RelayPersistence
    private let automaticallySync: Bool
    private let inlineLimit: Int
    private let containerIdentifier: String?
    private var container: CKContainer?
    private var engine: CKSyncEngine?
    private var stopped = false

    /// - Parameters:
    ///   - containerIdentifier: nil takes the first container of the app's entitlement.
    ///   - zoneName: `imm-sync` in the app; the self-test uses its own zone so it can delete it afterwards.
    ///   - device: this device's node id: records it uploaded itself are not delivered back.
    ///   - automaticallySync: false for tests that drive `sendChanges`/`fetchChanges` by hand (the explicit calls still work with true).
    ///   - inlineLimit: envelopes above this many bytes travel as `CKAsset`.
    public init(
        containerIdentifier: String? = nil, zoneName: String = CloudKitRelayStore.defaultZoneName, device: DeviceNodeID,
        persistence: any RelayPersistence, automaticallySync: Bool = true, inlineLimit: Int = 256 * 1024
    ) {
        self.containerIdentifier = containerIdentifier
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.device = device
        self.persistence = persistence
        self.automaticallySync = automaticallySync
        self.inlineLimit = inlineLimit
        (events, continuation) = AsyncStream<RelayStoreEvent>.makeStream()
    }

    private var prefix: String { "relay.ck.\(zoneID.zoneName)." }
    private var stateKey: String { prefix + "state" }
    private var outboxPrefix: String { prefix + "outbox." }
    private var inboxPrefix: String { prefix + "inbox." }

    // MARK: Engine

    private func ensureEngine() throws -> CKSyncEngine {
        if let engine { return engine }
        let created = try makeEngine()
        engine = created
        return created
    }

    private func makeEngine() throws -> CKSyncEngine {
        guard !stopped else { throw RelayError.unavailable("The relay was stopped.") }
        guard let identifier = containerIdentifier ?? CloudKitAvailability.entitledContainer, CloudKitAvailability.entitledContainer != nil else {
            throw RelayError.unavailable(CloudKitAvailability.unsignedMessage)
        }
        let container = CKContainer(identifier: identifier)
        self.container = container
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: loadState(), delegate: self)
        configuration.automaticallySync = automaticallySync
        let created = CKSyncEngine(configuration)
        let pending = created.state.pendingDatabaseChanges
        if !pending.contains(where: { if case .saveZone(let zone) = $0 { return zone.zoneID == zoneID } else { return false } }) {
            created.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        // The engine's state already lists these, but the outbox is the truth: re-queue anything the state lost.
        let queued = Set(created.state.pendingRecordZoneChanges.compactMap { change -> String? in
            if case .saveRecord(let id) = change { return id.recordName } else { return nil }
        })
        let missing = persistence.names(prefix: outboxPrefix).map { String($0.dropFirst(outboxPrefix.count)) }.filter { !queued.contains($0) }
        if !missing.isEmpty {
            created.state.add(pendingRecordZoneChanges: missing.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
        }
        return created
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = persistence.read(stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    /// Creates the engine (and so the zone and the subscription). Called by the lane; every other method does it on demand.
    public func start() async throws {
        _ = try ensureEngine()
    }

    // MARK: RelayStore

    public func upload(_ envelopes: [SealedEnvelope], from device: DeviceNodeID) async throws -> [String] {
        let engine = try ensureEngine()
        var names: [String] = []
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for envelope in envelopes {
            let name = UUID().uuidString
            persistence.write(outboxPrefix + name, envelope.encoded())
            names.append(name)
            changes.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
        }
        guard !changes.isEmpty else { return [] }
        engine.state.add(pendingRecordZoneChanges: changes)
        // The envelopes are durable now; a failed send is retried by the engine (or the next explicit call).
        do { try await engine.sendChanges() } catch { report(error, doing: "sending") }
        return names
    }

    public func fetchNew() async throws -> [RelayItem] {
        let engine = try ensureEngine()
        do { try await engine.fetchChanges() } catch { report(error, doing: "fetching") }
        return persistence.names(prefix: inboxPrefix).compactMap { name -> RelayItem? in
            guard let data = persistence.read(name), let stored = try? JSONDecoder().decode(StoredItem.self, from: data),
                  let envelope = try? SealedEnvelope(decoding: stored.envelope)
            else {
                persistence.write(name, nil)   // unreadable: never deliverable
                return nil
            }
            return RelayItem(recordID: String(name.dropFirst(inboxPrefix.count)), envelope: envelope, uploadedAt: stored.uploadedAt)
        }.sorted { ($0.uploadedAt, $0.recordID) < ($1.uploadedAt, $1.recordID) }
    }

    public func acknowledge(_ items: [RelayItem]) async throws {
        for item in items { persistence.write(inboxPrefix + item.recordID, nil) }
    }

    public func delete(recordIDs: [String]) async throws {
        guard !recordIDs.isEmpty else { return }
        let engine = try ensureEngine()
        var deletes: [CKSyncEngine.PendingRecordZoneChange] = []
        var cancelledSaves: [CKSyncEngine.PendingRecordZoneChange] = []
        for name in recordIDs {
            let id = CKRecord.ID(recordName: name, zoneID: zoneID)
            if persistence.read(outboxPrefix + name) != nil {
                // Never sent: cancel the upload instead of deleting something that does not exist.
                persistence.write(outboxPrefix + name, nil)
                cancelledSaves.append(.saveRecord(id))
            }
            deletes.append(.deleteRecord(id))
        }
        if !cancelledSaves.isEmpty { engine.state.remove(pendingRecordZoneChanges: cancelledSaves) }
        engine.state.add(pendingRecordZoneChanges: deletes)
        do { try await engine.sendChanges() } catch { report(error, doing: "deleting") }
    }

    public func resetState() async throws {
        if let engine { await engine.cancelOperations() }
        wipe()
        engine = nil
    }

    public func stop() async {
        stopped = true
        if let engine { await engine.cancelOperations() }
        engine = nil
        continuation.finish()
    }

    /// Test and self-test hook: pushes and pulls right now.
    public func sync() async throws {
        let engine = try ensureEngine()
        try await engine.sendChanges()
        try await engine.fetchChanges()
    }

    /// Self-test hook: deletes the whole zone from the server (and this store's local state).
    public func deleteZone() async throws {
        let engine = try ensureEngine()
        engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
        try await engine.sendChanges()
        wipe()
    }

    private func wipe() {
        for name in persistence.names(prefix: prefix) { persistence.write(name, nil) }
    }

    private func report(_ error: Error, doing action: String) {
        continuation.yield(.failure("iCloud relay: \(action) failed: \(Self.describe(error))"))
    }

    static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return "\(error.localizedDescription)" }
        return "\(ck.code) \(ck.localizedDescription)"
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) { persistence.write(stateKey, data) }

        case .accountChange(let change):
            handleAccountChange(change, engine: syncEngine)

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                // The zone is gone (deleted, purged, or the user reset their iCloud data): start over and tell the lane.
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                requeueOutbox(syncEngine)
                continuation.yield(.reset)
            }

        case .fetchedRecordZoneChanges(let changes):
            var stored = false
            for modification in changes.modifications {
                let record = modification.record
                guard record.recordType == Self.recordType, record.recordID.zoneID == zoneID, let item = decode(record) else { continue }
                guard item.envelope.header.device != device else { continue }   // our own upload, echoed
                persistence.write(inboxPrefix + record.recordID.recordName, try? JSONEncoder().encode(item.stored))
                stored = true
            }
            if stored { continuation.yield(.remoteChange) }

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords { finishUpload(record.recordID.recordName) }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            var needsZone = false
            for failure in sent.failedRecordSaves {
                let name = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    finishUpload(name)   // immutable records: an earlier attempt already stored it
                case .zoneNotFound:
                    needsZone = true
                    retry.append(.saveRecord(failure.record.recordID))
                case .unknownItem:
                    finishUpload(name)
                case .quotaExceeded:
                    continuation.yield(.failure("iCloud storage is full: the relay cannot upload."))
                    retry.append(.saveRecord(failure.record.recordID))
                case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy, .notAuthenticated,
                    .operationCancelled, .accountTemporarilyUnavailable:
                    break   // the engine reschedules these itself
                default:
                    continuation.yield(.failure("iCloud relay could not save a batch: \(Self.describe(failure.error))"))
                    finishUpload(name)
                }
            }
            if needsZone { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            for (id, error) in sent.failedRecordDeletes {
                guard error.code != .unknownItem else { continue }
                continuation.yield(.failure("iCloud relay could not delete \(id.recordName): \(Self.describe(error))"))
            }

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                continuation.yield(.failure("iCloud relay could not create its zone: \(Self.describe(failure.error))"))
            }

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges,
            .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        var records: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            guard case .saveRecord(let id) = change else { continue }
            if let record = makeRecord(id) { records[id] = record } else { syncEngine.state.remove(pendingRecordZoneChanges: [change]) }
        }
        let built = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending.filter { change in
            if case .saveRecord(let id) = change { return built[id] != nil }
            return true
        }) { built[$0] }
    }

    // MARK: Account

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange, engine: CKSyncEngine) {
        switch change.changeType {
        case .signIn:
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            requeueOutbox(engine)
            continuation.yield(.accountAvailable)
            continuation.yield(.reset)
        case .signOut:
            wipe()
            continuation.yield(.accountLost("Signed out of iCloud: the iCloud relay is paused."))
        case .switchAccounts:
            // The new account has none of our records: start over there.
            wipe()
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            continuation.yield(.accountAvailable)
            continuation.yield(.reset)
        @unknown default:
            break
        }
    }

    private func requeueOutbox(_ engine: CKSyncEngine) {
        let names = persistence.names(prefix: outboxPrefix).map { String($0.dropFirst(outboxPrefix.count)) }
        if !names.isEmpty {
            engine.state.add(pendingRecordZoneChanges: names.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
        }
    }

    // MARK: Records

    private func makeRecord(_ id: CKRecord.ID) -> CKRecord? {
        guard let data = persistence.read(outboxPrefix + id.recordName), let header = try? SealedEnvelope.peekHeader(data) else { return nil }
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        if data.count <= inlineLimit {
            record["blob"] = data as CKRecordValue
        } else {
            let url = Self.assetURL(for: id.recordName)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { return nil }
            record["asset"] = CKAsset(fileURL: url)
        }
        record["group"] = header.group as CKRecordValue
        record["device"] = Int64(bitPattern: header.device) as CKRecordValue
        record["seqFrom"] = header.seqFrom as CKRecordValue
        record["seqTo"] = header.seqTo as CKRecordValue
        return record
    }

    private func finishUpload(_ name: String) {
        persistence.write(outboxPrefix + name, nil)
        try? FileManager.default.removeItem(at: Self.assetURL(for: name))
    }

    private static func assetURL(for name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imm-relay-assets", isDirectory: true)
            .appendingPathComponent(name + ".bin")
    }

    private struct StoredItem: Codable {
        var envelope: Data
        var uploadedAt: Date
    }

    private struct Decoded {
        var envelope: SealedEnvelope
        var uploadedAt: Date
        var stored: StoredItem { StoredItem(envelope: envelope.encoded(), uploadedAt: uploadedAt) }
    }

    private func decode(_ record: CKRecord) -> Decoded? {
        let data: Data?
        if let blob = record["blob"] as? Data {
            data = blob
        } else if let asset = record["asset"] as? CKAsset, let url = asset.fileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = nil
        }
        guard let data, let envelope = try? SealedEnvelope(decoding: data) else {
            continuation.yield(.failure("iCloud relay: a record is not a sealed batch (\(record.recordID.recordName))"))
            return nil
        }
        return Decoded(envelope: envelope, uploadedAt: record.creationDate ?? Date())
    }
}
