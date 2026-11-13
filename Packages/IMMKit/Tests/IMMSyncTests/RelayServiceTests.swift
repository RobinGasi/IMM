import Foundation
import IMMLedger
@testable import IMMSync
import IMMSyncCore
import Testing

/// Hands the service an in-memory relay replica and keeps it reachable for the test.
final class RecordingRelayProvider: RelayProviding, @unchecked Sendable {
    let cloud: InMemoryRelayCloud
    private let lock = NSLock()
    private var _store: InMemoryRelayStore?
    var store: InMemoryRelayStore? { lock.withLock { _store } }

    init(cloud: InMemoryRelayCloud) { self.cloud = cloud }

    func makeStore(device: DeviceNodeID, persistence: any RelayPersistence) async -> RelaySetup {
        let store = InMemoryRelayStore(cloud: cloud, device: device)
        lock.withLock { _store = store }
        return .ready(store)
    }
}

/// The Mac's real `SyncService` and coordinator with the relay lane plugged in.
@Suite(.serialized) @MainActor struct RelayServiceTests {
    @Test func withoutEntitlementsTheRelayIsUnavailableAndLiveSyncRuns() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        #expect(await mac.waitListening())
        #expect(await eventuallyMain { mac.service.relayStatus == .unavailable(CloudKitAvailability.unsignedMessage) })
        mac.lock()
        #expect(mac.service.relayStatus == .unavailable("Sync is off."))
    }

    @Test func relayBatchesReachTheMacThroughTheCoordinatorAndMarkTheRouteICloud() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let clock = TestClock()
        let cloud = InMemoryRelayCloud(now: { clock.now })
        let provider = RecordingRelayProvider(cloud: cloud)

        // The Mac's ledger and a second device paired offline (grant and snapshot), as after a real pairing.
        let macDevice = try TestDevice(demo: true)
        let macReplica = try RelayReplica(cloud: cloud, name: "Mac", clock: clock, device: macDevice)
        let phone = try RelayReplica(cloud: cloud, name: "Phone", clock: clock)
        try await RelayTests().pair(hub: macReplica, joiner: phone)
        try await RelayTests().link([macReplica, phone])

        let defaults = UserDefaults(suiteName: "imm-relay-test-\(UUID().uuidString)")!
        let service = SyncService(
            registrar: FakeRegistrar(), defaults: defaults, makeClient: harness.makeClient, bundleVersion: "1", deviceName: "Mac",
            resolveHost: { $0 }, requiresSigning: false, publishDelay: .milliseconds(50), relay: provider)
        service.start(ledger: macDevice.store, vaultID: UUID())
        await service.setEnabled(true)
        #expect(await eventuallyMain { service.relayStatus == .ready })
        #expect(await eventuallyMain { provider.store != nil })
        let store = try #require(provider.store)

        // The phone edits while the Mac sleeps in the sense that no live session exists; it only uploads.
        try phone.device.store.writer.setNote(transactionID: try phone.device.transactionID("REWE"), note: "via iCloud")
        await phone.lane.publish()
        await store.simulatePush()
        #expect(await eventually { (try? macDevice.summary("REWE").note) == "via iCloud" })
        #expect(await eventuallyMain { service.devices.first?.route == "iCloud" })
        #expect(await eventuallyMain { service.lastRemoteChange != nil })

        // The Mac's own edits go to the relay, debounced like the outbox.
        try macDevice.store.writer.setNote(transactionID: try macDevice.transactionID("dm"), note: "from the Mac")
        #expect(await eventually { await !cloud.envelopes().filter { $0.header.device == macDevice.node && $0.header.seqFrom < SyncEngine.controlSequenceBase }.isEmpty })
        await phone.lane.pull()
        #expect(try phone.device.summary("dm").note == "from the Mac")

        // iCloud account lost: relay status says so, the live lane stays up.
        await store.simulateAccountLoss("Signed out of iCloud.")
        #expect(await eventuallyMain { service.relayStatus == .unavailable("Signed out of iCloud.") })
        if case .listening = service.status {} else { Issue.record("live sync must keep listening, status \(service.status)") }

        service.stop()
        await harness.cleanup()
    }
}
