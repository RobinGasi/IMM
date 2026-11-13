import Foundation
import GRDB
import IMMLedger

/// The vault's device-local `sync_secret` table as `RelayPersistence`: the relay's engine state, outbox and inbox are encrypted
/// with the vault and disappear with it. `close()` (called when the app starts to lock) turns later writes into no-ops, so a
/// CloudKit callback that arrives while the vault closes cannot touch a closed pool.
public final class LedgerRelayPersistence: RelayPersistence, @unchecked Sendable {
    private let ledger: LedgerStore
    private let lock = NSLock()
    private var closed = false

    public init(ledger: LedgerStore) {
        self.ledger = ledger
    }

    public func close() { lock.withLock { closed = true } }
    private var isClosed: Bool { lock.withLock { closed } }

    public func read(_ name: String) -> Data? {
        guard !isClosed else { return nil }
        return try? ledger.database.read { try SyncSecretStore.read(name, db: $0) }
    }

    public func write(_ name: String, _ value: Data?) {
        guard !isClosed else { return }
        try? ledger.database.write { db in
            if let value {
                try SyncSecretStore.write(name, value, db: db)
            } else {
                try db.execute(sql: "DELETE FROM sync_secret WHERE name = ?", arguments: [name])
            }
        }
    }

    public func names(prefix: String) -> [String] {
        guard !isClosed else { return [] }
        let upper = prefix + "\u{10FFFF}"
        return (try? ledger.database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sync_secret WHERE name >= ? AND name < ? ORDER BY name", arguments: [prefix, upper])
        }) ?? []
    }
}

/// What the app gets when it asks for a relay.
public enum RelaySetup: Sendable {
    case ready(any RelayStore)
    case unavailable(String)
}

/// Creates the relay store of one unlocked vault. The app passes `CloudKitRelayProvider`; tests pass a provider that hands out
/// `InMemoryRelayStore`s or reports `unavailable`.
public protocol RelayProviding: Sendable {
    func makeStore(device: DeviceNodeID, persistence: any RelayPersistence) async -> RelaySetup
}

/// The production provider: entitlement and account check, then a `CloudKitRelayStore` on zone `imm-sync`.
public struct CloudKitRelayProvider: RelayProviding {
    public var zoneName: String

    public init(zoneName: String = CloudKitRelayStore.defaultZoneName) {
        self.zoneName = zoneName
    }

    public func makeStore(device: DeviceNodeID, persistence: any RelayPersistence) async -> RelaySetup {
        switch await CloudKitAvailability.check() {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .available(let container):
            let store = CloudKitRelayStore(containerIdentifier: container, zoneName: zoneName, device: device, persistence: persistence)
            do {
                try await store.start()
                return .ready(store)
            } catch {
                return .unavailable("iCloud relay could not start: \(error)")
            }
        }
    }
}

/// A provider that never offers a relay (sync tests that must not touch iCloud).
public struct NoRelayProvider: RelayProviding {
    public var reason: String

    public init(reason: String = "The iCloud relay is off.") {
        self.reason = reason
    }

    public func makeStore(device: DeviceNodeID, persistence: any RelayPersistence) async -> RelaySetup { .unavailable(reason) }
}
