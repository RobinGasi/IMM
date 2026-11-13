import CryptoKit
import Foundation
import GRDB
import IMMBanking
import IMMLedger
@testable import IMMSync
import IMMSyncCore
import Testing

/// An encrypted, migrated ledger in a temporary directory (one device's database).
final class TestDevice: Sendable {
    let directory: URL
    let store: LedgerStore
    /// SQL statements that ran on this device's connections (reads and writes).
    let statements = StatementCounter()

    init(demo: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("imm-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        let statements = statements
        configuration.prepareDatabase { db in
            try db.usePassphrase("x'" + String(repeating: "cd", count: 32) + "'")
            db.trace { _ in statements.increment() }
        }
        let pool = try DatabasePool(path: directory.appendingPathComponent("data.sqlite").path, configuration: configuration)
        store = try LedgerStore(database: pool)
        if demo {
            let bank = try DemoDataset.load()
            try LedgerImporter.importSnapshot(bank.snapshot, profile: bank.profile, into: store)
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var node: DeviceNodeID { store.writer.localNode }

    func transactionID(_ query: String) throws -> String {
        let id = try SyncLookup.transactionID(in: store, matching: query)
        return try #require(id)
    }

    func categoryID(_ name: String) throws -> String {
        let id = try SyncLookup.categoryID(in: store, named: name)
        return try #require(id)
    }

    func summary(_ query: String) throws -> SyncLookup.TransactionSummary {
        let found = try SyncLookup.summary(in: store, matching: query)
        return try #require(found)
    }

    func converged() throws -> LedgerSnapshot { try store.writer.snapshot().converged }
}

final class StatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// A second device with its own ledger, engine and client.
struct TestPeer: Sendable {
    let device: TestDevice
    let engine: SyncEngine
    let client: SyncClient
    let codes: CodeBox

    init(name: String, log: @escaping @Sendable (SyncClientEvent) -> Void = { _ in }) throws {
        device = try TestDevice()
        engine = try SyncEngine(ledger: device.store, deviceName: name)
        client = SyncClient(engine: engine, log: log)
        codes = CodeBox()
    }

    var node: DeviceNodeID { device.node }

    func pair(offer: PairingOffer, port: UInt16, viaQR: Bool = true) async throws -> SyncReport {
        let invite: PairingInvite
        if viaQR {
            invite = try PairingInvite(parsing: offer.qrPayload)
        } else {
            let bytes = try #require(PairingCodeFormat.decode(offer.code))
            invite = PairingInvite(secret: try #require(PairingSecret(bytes: bytes)), agentKey: offer.agentKey)
        }
        let codes = codes
        return try await client.pair(invite: invite, host: "127.0.0.1", port: port, options: .init(timeout: TestLimits.run)) { code in
            codes.set(code)
        }
    }

    func sync(port: UInt16, watch: Duration? = nil) async throws -> SyncReport {
        try await client.sync(host: "127.0.0.1", port: port, options: .init(watch: watch, timeout: TestLimits.run + (watch ?? .zero)))
    }
}

final class CodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _code: ShortAuthCode?
    func set(_ code: ShortAuthCode) { lock.withLock { _code = code } }
    var code: ShortAuthCode? { lock.withLock { _code } }
}

/// The agent in loopback mode with an XPC listener the service connects to (same wiring as the real Mach service, minus launchd).
struct AgentHarness {
    let directory: URL
    let server: AgentServer
    let xpc: AgentXPCService
    let port: UInt16

    init(directory existing: URL? = nil) async throws {
        directory = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("imm-agent-\(UUID().uuidString)", isDirectory: true)
        server = try AgentServer(configuration: AgentConfiguration(
            storage: AgentStorage(groupContainer: directory), binding: .loopback(port: 0), build: "test", handshakeTimeout: TestLimits.run))
        try await server.start()
        port = try #require(await server.boundPort)
        xpc = AgentXPCService(server: server, listener: .anonymous(), requirement: nil)
        xpc.resume()
    }

    func cleanup() async {
        xpc.invalidate()
        await server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    var makeClient: @Sendable (any AgentAppEndpoint) -> AgentXPCClient {
        let endpoint = xpc.endpoint
        return { AgentXPCClient(listenerEndpoint: endpoint, endpoint: $0) }
    }
}

final class FakeRegistrar: AgentRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: AgentRegistrationStatus
    private var _registers = 0
    private var _unregisters = 0
    private var _openedSettings = 0

    init(_ state: AgentRegistrationStatus = .enabled) { _state = state }

    var state: AgentRegistrationStatus {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var registers: Int { lock.withLock { _registers } }
    var unregisters: Int { lock.withLock { _unregisters } }
    var openedSettings: Int { lock.withLock { _openedSettings } }

    func status() -> AgentRegistrationStatus { state }
    func register() throws {
        lock.withLock {
            _registers += 1
            _state = .enabled
        }
    }
    func unregister() async throws {
        lock.withLock {
            _unregisters += 1
            _state = .notRegistered
        }
    }
    func openApprovalSettings() { lock.withLock { _openedSettings += 1 } }
}

/// The Mac side: a device with the demo ledger and a `SyncService` wired to the in-process agent.
@MainActor
final class MacRig {
    let device: TestDevice
    let harness: AgentHarness
    let service: SyncService
    let registrar: FakeRegistrar
    let vaultID = UUID()

    init(
        harness: AgentHarness, registrar: FakeRegistrar = FakeRegistrar(), bundleVersion: String = "1",
        publishDelay: Duration = .milliseconds(300)
    ) throws {
        self.harness = harness
        self.registrar = registrar
        device = try TestDevice(demo: true)
        let defaults = UserDefaults(suiteName: "imm-sync-test-\(UUID().uuidString)")!
        service = SyncService(
            registrar: registrar, defaults: defaults, makeClient: harness.makeClient, bundleVersion: bundleVersion, deviceName: "Test Mac",
            resolveHost: { $0 }, requiresSigning: false, publishDelay: publishDelay)
    }

    /// Unlock: switch on (the first time) and start.
    func unlock(enable: Bool = true) async {
        service.start(ledger: device.store, vaultID: vaultID)
        if enable, !service.isEnabled { await service.setEnabled(true) }
    }

    func lock() { service.stop() }

    /// What `AppModel.lock` does: stop sync, then close the database.
    func lockLikeTheApp() {
        service.stop()
        try? device.store.database.close()
    }

    func waitListening() async -> Bool {
        let ok = await eventuallyMain { if case .listening = self.service.status { return true } else { return false } }
        if !ok {
            let agent = await harness.server.status()
            Issue.record("not listening: status \(service.status), error \(String(describing: service.lastError)), agent listening \(agent.listening) attached \(agent.appAttached) host \(String(describing: agent.host))")
        }
        return ok
    }

    func waitAttached(_ attached: Bool) async -> Bool {
        await eventually { await self.harness.server.status().appAttached == attached }
    }

    func pair(_ peer: TestPeer) async throws -> SyncReport {
        let listening = await waitListening()
        #expect(listening, "status \(service.status), error \(String(describing: service.lastError))")
        let offer = try await service.beginPairing()
        async let report = peer.pair(offer: offer, port: harness.port)
        #expect(await eventuallyMain { if case .confirming = self.service.pairing { return true } else { return false } })
        guard case .confirming(_, let code) = service.pairing else { throw SyncError.pairingNotActive }
        try await service.confirmPairing(code.digits)
        return try await report
    }
}

/// Limits for waiting on things that happen on their own schedule. They are failure detectors for a hung test, not
/// performance assertions: generous, because the suite also runs while other builds saturate the machine, and measured in
/// awake time (`AwakeClock`), because the Mac may sleep, or the process stall, in the middle of a run.
enum TestLimits {
    /// One client run (pairing, sync) from start to finish.
    static let run: Duration = .seconds(60)
    /// A condition that follows from something the test just did.
    static let condition: Duration = .seconds(30)
}

@MainActor
func eventuallyMain(timeout: Duration = TestLimits.condition, _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = AwakeClock()
    while clock.elapsed < timeout {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
        clock.observe()
    }
    return condition()
}

func eventually(timeout: Duration = TestLimits.condition, _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = AwakeClock()
    while clock.elapsed < timeout {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
        clock.observe()
    }
    return await condition()
}
