import Foundation
import GRDB
import IMMLedger
@testable import IMMSync
import IMMSyncCore
import Testing

/// End to end: the Mac's `SyncService` (real XPC link) with an in-process `AgentServer` on loopback, and peers that dial it over
/// real TCP with the real Noise sessions.
@Suite(.serialized) @MainActor struct TransportTests {
    // MARK: Pairing

    @Test func pairingBootstrapsASnapshotAndEditsConvergeBothWays() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        let peer = try TestPeer(name: "Peer")

        let report = try await mac.pair(peer)
        #expect(report.bootstrapped)
        // Both screens showed the same code.
        #expect(peer.codes.code != nil)
        #expect(try mac.device.converged() == peer.device.converged(), "snapshot bootstrap: same rows and field clocks")
        #expect(await eventuallyMain { mac.service.devices.count == 1 })
        #expect(mac.service.devices.first?.route == "Tailscale")

        // Peer → Mac, live (the Mac app is attached).
        let rewe = try mac.device.transactionID("REWE")
        let other = try mac.device.categoryID("Other")
        try peer.device.store.writer.setCategory(transactionID: rewe, categoryID: other)
        let up = try await peer.sync(port: harness.port)
        #expect(up.opsSent == 1, "the hub's own hello must not make the client push the same batch twice")
        #expect(await eventuallyMain { (try? mac.device.summary("REWE").category) == "Other" })

        // Mac → peer, relayed live while the peer session is open (the session ends when the test cancels it, not on a timer).
        let session = Task { try await peer.sync(port: harness.port, watch: TestLimits.condition) }
        #expect(await eventually { await harness.server.status().connectedPeers.count == 1 }, "the peer's session is open")
        try mac.device.store.writer.setNote(transactionID: rewe, note: "from the Mac")
        #expect(await eventually { (try? peer.device.summary("REWE").note) == "from the Mac" }, "the edit arrives while the peer session is open")
        session.cancel()
        _ = await session.result

        #expect(try mac.device.converged() == peer.device.converged())
        mac.lock()
    }

    @Test func pairingByTypedCodeAloneWorksWithoutPinningTheAgentKey() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        #expect(await mac.waitListening())
        let offer = try await mac.service.beginPairing()
        let peer = try TestPeer(name: "Other Mac")
        async let report = peer.pair(offer: offer, port: harness.port, viaQR: false)
        #expect(await eventuallyMain { if case .confirming = mac.service.pairing { return true } else { return false } })
        try await mac.service.confirmPairing()
        #expect(try await report.bootstrapped)
        // The pin was learned from the authenticated handshake: later sessions use IK.
        #expect(try peer.engine.secrets.read(SyncSecretName.agentStatic) == offer.agentKey)
        mac.lock()
    }

    @Test func wrongCodeNeverReachesTheConfirmationScreen() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        #expect(await mac.waitListening())
        let offer = try await mac.service.beginPairing()
        let peer = try TestPeer(name: "Intruder")
        let guessed = PairingInvite(secret: .generate(), agentKey: offer.agentKey)
        await #expect(throws: (any Error).self) {
            _ = try await peer.client.pair(invite: guessed, host: "127.0.0.1", port: harness.port, options: .init(timeout: TestLimits.run))
        }
        if case .confirming = mac.service.pairing { Issue.record("a wrong code produced a confirmation") }
        #expect(try mac.device.store.writer.cursors().allSatisfy { $0.device == mac.device.node }, "nothing was exchanged")
        mac.lock()
    }

    @Test func unpinnedAgentKeyFromAForgedQRIsRefusedBeforeMessageThree() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        #expect(await mac.waitListening())
        let offer = try await mac.service.beginPairing()
        var invite = try PairingInvite(parsing: offer.qrPayload)
        invite.agentKey = Data(repeating: 0xEE, count: 32)   // a QR that names another Mac's key
        let peer = try TestPeer(name: "Careful")
        await #expect(throws: NoiseSessionError.pinMismatch) {
            _ = try await peer.client.pair(invite: invite, host: "127.0.0.1", port: harness.port, options: .init(timeout: TestLimits.run))
        }
        if case .confirming = mac.service.pairing { Issue.record("the Mac saw a handshake that the joiner aborted") }
        mac.lock()
    }

    @Test func typedConfirmationCodeMustMatchAndRejectIsReported() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        #expect(await mac.waitListening())
        let offer = try await mac.service.beginPairing()
        let peer = try TestPeer(name: "Peer")
        let outcome = Task { try await peer.pair(offer: offer, port: harness.port) }
        #expect(await eventuallyMain { if case .confirming = mac.service.pairing { return true } else { return false } })
        guard case .confirming(let name, let code) = mac.service.pairing else {
            Issue.record("not confirming")
            return
        }
        #expect(name == "Peer")
        let wrong = code.value == 0 ? "000001" : "000000"
        await #expect(throws: SyncError.pairingCodeMismatch) { try await mac.service.confirmPairing(wrong) }
        await mac.service.rejectPairing()
        await #expect(throws: SyncError.pairingRejected) { _ = try await outcome.value }
        #expect(mac.service.pairing == .idle)
        #expect(try mac.device.store.writer.cursors().count == 1)
        mac.lock()
    }

    @Test func aDoubleConfirmationSendsOneGrantAndTheJoinerStillFinishes() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        #expect(await mac.waitListening())
        let offer = try await mac.service.beginPairing()
        let peer = try TestPeer(name: "Peer")
        let outcome = Task { try await peer.pair(offer: offer, port: harness.port) }
        #expect(await eventuallyMain { if case .confirming = mac.service.pairing { return true } else { return false } })
        // The confirmation screen can fire twice (the handshake notice and the joiner's identity message both refresh it).
        async let first: Void = mac.service.confirmPairing()
        async let second: Void = mac.service.confirmPairing()
        var succeeded = 0
        do { try await first; succeeded += 1 } catch {}
        do { try await second; succeeded += 1 } catch {}
        #expect(succeeded == 1)
        let report = try await outcome.value
        #expect(report.bootstrapped)
        mac.lock()
    }

    // MARK: Locked app and mailbox

    @Test func editsWhileTheMacIsLockedWaitInTheMailboxAndApplyAtUnlock() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        let peer = try TestPeer(name: "Peer")
        _ = try await mac.pair(peer)

        mac.lock()
        #expect(await mac.waitAttached(false))

        let tx = try mac.device.transactionID("REWE")
        try peer.device.store.writer.setCategory(transactionID: tx, categoryID: try mac.device.categoryID("Other"))
        try peer.device.store.writer.setNote(transactionID: tx, note: "typed while locked")
        let report = try await peer.sync(port: harness.port)
        #expect(report.opsSent == 2)
        #expect(await harness.server.status().inboxBatches >= 1, "the sealed batch sits in the agent's inbox")
        #expect(try mac.device.summary("REWE").note != "typed while locked", "the locked app has not applied anything")

        await mac.unlock(enable: false)
        #expect(await eventuallyMain { (try? mac.device.summary("REWE").note) == "typed while locked" })
        #expect(try mac.device.summary("REWE").category == "Other")
        #expect(await eventually { await harness.server.status().inboxBatches == 0 }, "applied batches leave the inbox")
        mac.lock()
    }

    @Test func macEditsPublishedWhileAttachedAreServedFromTheOutboxAfterDetach() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        let peer = try TestPeer(name: "Peer")
        _ = try await mac.pair(peer)

        // The peer is offline; the Mac edits; the debounced publish fills the peer's outbox.
        let tx = try mac.device.transactionID("Lieferando")
        try mac.device.store.writer.setNote(transactionID: tx, note: "for the phone")
        #expect(await eventually { await harness.server.status().outboxBatches >= 1 })
        mac.lock()
        #expect(await mac.waitAttached(false))

        let report = try await peer.sync(port: harness.port)
        #expect(report.opsApplied >= 1)
        #expect(try peer.device.summary("Lieferando").note == "for the phone")
        // The peer's ack frees the outbox.
        #expect(await eventually { await harness.server.status().outboxBatches == 0 })
    }

    /// A peer greets with a stale `hello` and hangs up at once. The Mac answers with what the peer lacks; that answer goes to a
    /// session that is closing, so it must also land in the peer's outbox. Before, the answer raised the "already sent" marker
    /// and nothing else, so the next publish found nothing to do and the edit stayed on the Mac until it was unlocked with the
    /// peer connected. (The debounce is made long so that only the `hello` can have handled the edit.)
    @Test func aBatchAnsweredToAHelloThatHungUpStillReachesTheOutbox() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness, publishDelay: .seconds(300))
        await mac.unlock()
        let peer = try TestPeer(name: "Peer")
        _ = try await mac.pair(peer)

        let tx = try mac.device.transactionID("Lieferando")
        try mac.device.store.writer.setNote(transactionID: tx, note: "answered to a closing session")

        let agentKey = try #require(try peer.engine.secrets.read(SyncSecretName.agentStatic))
        let stream = try await NWConnectionStream.connect(host: "127.0.0.1", port: harness.port)
        let session = try await NoiseSession.connect(
            over: stream, localStatic: await peer.engine.identity.x25519, pinnedResponderStatic: agentKey)
        try await session.send(try await peer.engine.hello())
        await session.close()

        #expect(await eventually { await harness.server.status().outboxBatches >= 1 }, "the answer to the hello is in the peer's outbox")
        mac.lock()
        #expect(await mac.waitAttached(false))
        let report = try await peer.sync(port: harness.port)
        #expect(report.opsApplied >= 1)
        #expect(try peer.device.summary("Lieferando").note == "answered to a closing session")
    }

    // MARK: Shutdown order

    /// The app locks the moment an edit was committed: the 300 ms debounce has not fired, the observation may still be delivering.
    /// `stop()` must leave nothing running on the ledger, because the vault closes right after; the pending publish is dropped (the
    /// batch is published at the next unlock, from the markers).
    @Test func lockingWhileAPublishIsPendingLeavesNothingRunningOnTheLedger() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        let peer = try TestPeer(name: "Peer")
        _ = try await mac.pair(peer)

        try mac.device.store.writer.setNote(transactionID: try mac.device.transactionID("Lieferando"), note: "typed just before locking")
        mac.lockLikeTheApp()
        let afterClose = mac.device.statements.count

        // Longer than the debounce plus a publish.
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(mac.device.statements.count == afterClose, "nothing ran on the ledger after the app stopped sync")
        #expect(await harness.server.status().outboxBatches == 0, "the pending publish was dropped, not run against a closed database")
        #expect(await mac.waitAttached(false), "the agent was told that the app is gone")
    }

    /// A step of the coordinator that was already queued when the app locks must do nothing once the stop was requested. (The
    /// observation's own reads belong to `quiesce`, which waits for them; the steps are what the flag guards.)
    @Test func aStoppedCoordinatorDoesNotTouchTheLedger() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let device = try TestDevice(demo: true)
        let engine = try SyncEngine(ledger: device.store, deviceName: "Mac")
        let coordinator = SyncCoordinator(
            engine: engine, makeClient: harness.makeClient, resolveHost: { $0 }, report: { _ in })
        try await coordinator.start()

        coordinator.requestStop()   // synchronous, from any thread
        await coordinator.quiesce()
        // A read that GRDB had already scheduled for the (now cancelled) observation may still land; wait until it has.
        var before = device.statements.count
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if device.statements.count == before { break }
            before = device.statements.count
        }
        await coordinator.publishAll(hello: true)
        await coordinator.drainInbox()
        await coordinator.publishNow()
        #expect(device.statements.count == before, "publish and inbox steps are no-ops once stop was requested")
        await coordinator.stop()
        #expect(await harness.server.status().appAttached == false)
    }

    @Test func aLockedMacAnswersSnapshotRequestsWithAnErrorNotSilence() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        let peer = try TestPeer(name: "Peer")
        _ = try await mac.pair(peer)
        try peer.engine.secrets.remove(SyncSecretName.bootstrapDone)   // pretend the peer still needs the snapshot
        mac.lock()
        #expect(await mac.waitAttached(false))
        await #expect(throws: SyncError.self) { _ = try await peer.sync(port: harness.port) }
    }

    // MARK: Removal

    @Test func removingADeviceRotatesTheKeyAndLocksItOut() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        let removed = try TestPeer(name: "Lost phone")
        let kept = try TestPeer(name: "Other Mac")
        _ = try await mac.pair(removed)
        _ = try await mac.pair(kept)
        let secrets = SyncSecretStore(ledger: mac.device.store)
        let before = try #require(try secrets.loadGroup())
        let removedGroup = try #require(await removed.engine.group)
        #expect(removedGroup.id == before.id)

        try await mac.service.remove(device: removed.node)
        let after = try #require(try secrets.loadGroup())
        #expect(after.id != before.id, "a new group id on rotation")
        #expect(!after.key.isEqual(to: before.key))
        #expect(await eventuallyMain { mac.service.devices.map(\.id) == [kept.node] })

        // New batches are sealed under the new key: the removed device cannot open them.
        let tx = try mac.device.transactionID("REWE")
        try mac.device.store.writer.setNote(transactionID: tx, note: "after removal")
        let macEngine = try SyncEngine(ledger: mac.device.store, deviceName: "x")
        let keptRef = SyncPeer(staticKey: await kept.engine.identity.x25519Public, node: kept.node)
        let published = try await macEngine.batches(for: keptRef, cursors: [])
        let envelope = try #require(published.last)
        #expect(envelope.header.group == after.id)
        #expect(throws: SealedEnvelopeError.self) { try envelope.open(key: removedGroup.key) }
        let outcome = try BatchApplier(ledger: removed.device.store).apply(envelope, group: removedGroup)
        #expect(outcome.outcome == .staleGroup(after.id))
        #expect(try removed.device.summary("REWE").note != "after removal")

        // The removed device is off the allow-list: its handshake is refused.
        await #expect(throws: (any Error).self) { _ = try await removed.sync(port: harness.port) }

        // The remaining device learns the new key and keeps syncing.
        let report = try await kept.sync(port: harness.port)
        #expect(report.opsApplied >= 1)
        #expect(await kept.engine.group?.id == after.id)
        #expect(try kept.device.summary("REWE").note == "after removal")
        mac.lock()
    }

    // MARK: Service status

    @Test func statusFollowsTheRegistrationAndTheAgent() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }

        // Needs approval in Login Items.
        let pending = try MacRig(harness: harness, registrar: FakeRegistrar(.requiresApproval))
        pending.service.start(ledger: pending.device.store, vaultID: pending.vaultID)
        await pending.service.setEnabled(true)
        #expect(await eventuallyMain { pending.service.status == .needsApproval })
        #expect(pending.registrar.openedSettings == 1)
        // The user allows it: the service notices and finishes starting.
        pending.registrar.state = .enabled
        #expect(await eventuallyMain { if case .listening = pending.service.status { return true } else { return false } })
        pending.lock()

        // Off.
        let off = try MacRig(harness: harness)
        off.service.start(ledger: off.device.store, vaultID: off.vaultID)
        #expect(off.service.status == .off && !off.service.isEnabled)

        // Missing helper in the bundle.
        let missing = try MacRig(harness: harness, registrar: FakeRegistrar(.notFound))
        await missing.unlock()
        #expect(await eventuallyMain { if case .error = missing.service.status { return true } else { return false } })
        missing.lock()
    }

    @Test func statusReportsNoTailscaleWhenTheAgentHasNoListener() async throws {
        final class NoTailnet: TailnetProviding, @unchecked Sendable {
            func start(onChange: @escaping @Sendable (TailnetInterface?) -> Void) { onChange(nil) }
            func stop() {}
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imm-agent-\(UUID().uuidString)", isDirectory: true)
        let server = try AgentServer(configuration: AgentConfiguration(
            storage: AgentStorage(groupContainer: directory), binding: .tailnet(port: 0), build: "test", tailnet: NoTailnet()))
        try await server.start()
        let xpc = AgentXPCService(server: server, listener: .anonymous(), requirement: nil)
        xpc.resume()
        defer {
            xpc.invalidate()
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: directory)
        }
        let device = try TestDevice(demo: true)
        let endpoint = xpc.endpoint
        let service = SyncService(
            registrar: FakeRegistrar(), defaults: UserDefaults(suiteName: "imm-sync-test-\(UUID().uuidString)")!,
            makeClient: { AgentXPCClient(listenerEndpoint: endpoint, endpoint: $0) }, deviceName: "Mac", resolveHost: { $0 }, requiresSigning: false)
        service.start(ledger: device.store, vaultID: UUID())
        await service.setEnabled(true)
        #expect(await eventuallyMain { service.status == .noTailscale })
        await #expect(throws: SyncError.noTailscale) { _ = try await service.beginPairing() }
        service.stop()
    }

    @Test func agentIsReRegisteredWhenTheBuildChanged() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let registrar = FakeRegistrar(.enabled)
        let defaults = UserDefaults(suiteName: "imm-sync-test-\(UUID().uuidString)")!
        defaults.set("1", forKey: "syncAgentRegisteredBuild")
        let device = try TestDevice(demo: true)
        let id = UUID()
        let service = SyncService(
            registrar: registrar, defaults: defaults, makeClient: harness.makeClient, bundleVersion: "2", deviceName: "Mac",
            resolveHost: { $0 }, requiresSigning: false)
        defaults.set(true, forKey: "syncEnabled.\(id.uuidString)")
        service.start(ledger: device.store, vaultID: id)
        #expect(await eventuallyMain { if case .listening = service.status { return true } else { return false } })
        #expect(registrar.unregisters == 1 && registrar.registers == 1, "an update re-registers the agent so launchd re-pins its checksum")
        #expect(defaults.string(forKey: "syncAgentRegisteredBuild") == "2")
        service.stop()

        // Same build again: no churn.
        let again = SyncService(
            registrar: registrar, defaults: defaults, makeClient: harness.makeClient, bundleVersion: "2", deviceName: "Mac",
            resolveHost: { $0 }, requiresSigning: false)
        again.start(ledger: device.store, vaultID: id)
        #expect(await eventuallyMain { if case .listening = again.status { return true } else { return false } })
        #expect(registrar.unregisters == 1 && registrar.registers == 1)
        again.stop()
    }

    @Test func turningSyncOffUnregistersTheAgentAndDetaches() async throws {
        let harness = try await AgentHarness()
        defer { Task { await harness.cleanup() } }
        let mac = try MacRig(harness: harness)
        await mac.unlock()
        #expect(await mac.waitListening())
        #expect(await mac.waitAttached(true))
        let before = mac.registrar.unregisters
        await mac.service.setEnabled(false)
        #expect(mac.service.status == .off)
        #expect(mac.registrar.unregisters == before + 1)
        #expect(mac.registrar.state == .notRegistered)
        #expect(await mac.waitAttached(false))
        mac.lock()
    }
}
