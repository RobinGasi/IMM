import CryptoKit
import Foundation
import Network
import Testing

@testable import IMMSyncCore

struct AgentServerTests {
    let phone = Curve25519.KeyAgreement.PrivateKey()
    var phoneKey: Data { phone.publicKey.rawRepresentation }

    // MARK: Identity and storage

    @Test func transportIdentityIsCreatedOnceAndPersisted() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        let again = try AgentServer(configuration: AgentConfiguration(storage: rig.storage, binding: .loopback(port: 0)))
        #expect(again.staticPublicKey == rig.server.staticPublicKey)
        #expect(rig.server.staticPublicKey.count == 32)
        let attributes = try FileManager.default.attributesOfItem(atPath: rig.storage.identityURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(rig.storage.isWritable())
        // A corrupt identity is an error, never a silent new key.
        try Data([1, 2, 3]).write(to: rig.storage.identityURL)
        #expect(throws: AgentError.corruptIdentity) {
            try AgentServer(configuration: AgentConfiguration(storage: rig.storage, binding: .loopback(port: 0)))
        }
    }

    @Test func firstHandshakeMessageLengthTellsPairingFromReconnect() async throws {
        let responder = Curve25519.KeyAgreement.PrivateKey()
        let (a, b) = InMemoryDuplexStream.makePair()
        let secret = Data(repeating: 5, count: 32)
        let pairing = Task {
            try? await NoiseSession.initiatePairing(
                over: a, localStatic: phone, pairingSecret: secret, expectedResponderStatic: responder.publicKey.rawRepresentation)
        }
        let first = try await b.receive()
        #expect(first.count == AgentServer.pairingMessage1Length)
        await b.close()
        _ = await pairing.value

        let (c, d) = InMemoryDuplexStream.makePair()
        let reconnect = Task {
            try? await NoiseSession.connect(over: c, localStatic: phone, pinnedResponderStatic: responder.publicKey.rawRepresentation)
        }
        #expect(try await d.receive().count == AgentServer.liveMessage1Length)
        await d.close()
        _ = await reconnect.value
    }

    @Test func garbageAndSilentConnectionsAreDropped() async throws {
        let rig = try await AgentRig(handshakeTimeout: .milliseconds(300))
        defer { Task { await rig.cleanup() } }
        let garbage = try await rig.connect()
        try await garbage.send(Data(repeating: 7, count: 33))
        await #expect(throws: (any Error).self) { _ = try await garbage.receive() }
        let silent = try await rig.connect()
        await #expect(throws: (any Error).self) { _ = try await silent.receive() }
    }

    // MARK: Allow-list

    @Test func allowListNeedsOwnerKeyValidSignatureAndNoRollback() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        #expect(try await rig.allow([phone], version: 5).ok)

        let list = PeerAllowList(version: 4, issuedAt: Date(), peers: [])
        let stale = try SignedPeerAllowList.sign(list, with: rig.owner)
        #expect(await rig.server.publishAllowList(try stale.encoded()).error == "rolledBack")

        let forged = try SignedPeerAllowList.sign(PeerAllowList(version: 9, issuedAt: Date(), peers: []), with: Curve25519.Signing.PrivateKey())
        #expect(await rig.server.publishAllowList(try forged.encoded()).error == "invalidSignature")
        #expect(await rig.server.publishAllowList(Data("nope".utf8)).error == "malformed")
        #expect(await rig.server.status().allowListVersion == 5)

        // It survives a restart (verified against the owner key again).
        let restarted = try AgentServer(configuration: AgentConfiguration(storage: rig.storage, binding: .loopback(port: 0)))
        #expect(await restarted.status().allowListVersion == 5)

        // Without an owner key nothing is accepted.
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("agent-bare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bare) }
        let noOwner = try AgentServer(configuration: AgentConfiguration(storage: AgentStorage(groupContainer: bare), binding: .loopback(port: 0)))
        #expect(await noOwner.publishAllowList(try stale.encoded()).error == "ownerKeyMissing")
    }

    // MARK: Pairing

    @Test func pairingOfferRunsXXpsk3AndHandsTheCodeToTheApp() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        let app = AgentFakeApp()
        _ = await rig.server.attach(app)
        let secret = Data((0..<32).map { UInt8($0 &* 7) })
        #expect(await rig.server.setPairingOffer(secret: secret, expiry: Date().addingTimeInterval(120)))
        #expect(await rig.server.status().pairingActive)

        let joiner = try await NoiseSession.initiatePairing(
            over: try await rig.connect(), localStatic: phone, pairingSecret: secret, expectedResponderStatic: rig.server.staticPublicKey)
        #expect(await eventually { !app.pairingEvents.isEmpty })
        let event = try #require(app.pairingEvents.first)
        #expect(event.peer == phoneKey)
        #expect(event.code == joiner.pairingCode?.digits)
        #expect(event.handshakeHash == joiner.handshakeHash)
        // The offer was used up.
        #expect(await rig.server.status().pairingActive == false)

        // The user confirmed: the app sends the grant through the agent, and the allow-list admits the phone.
        let grant = Data("group key and roster".utf8)
        #expect(await rig.server.forward(.pairingGrant(grant), to: phoneKey))
        #expect(try await joiner.receive() == .pairingGrant(grant))
        #expect(try await rig.allow([phone]).ok)

        // A joiner that has not been allow-listed yet reaches the app, never the mailbox.
        try await joiner.send(.hello(.init(device: 1, group: Data(repeating: 0, count: 16), cursors: [])))
        #expect(await eventually { app.received.contains { $0.peer == self.phoneKey } })
    }

    @Test func pairingNeedsAnActiveOfferTheRightSecretAndIsLimited() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        let secret = Data(repeating: 0x11, count: 32)

        // No offer: the agent closes without answering.
        await #expect(throws: (any Error).self) {
            _ = try await NoiseSession.initiatePairing(
                over: try await rig.connect(), localStatic: phone, pairingSecret: secret, expectedResponderStatic: rig.server.staticPublicKey)
        }

        // Offers need an attached app and a future expiry.
        #expect(await rig.server.setPairingOffer(secret: secret, expiry: Date().addingTimeInterval(60)) == false)
        let app = AgentFakeApp()
        let token = await rig.server.attach(app)
        #expect(await rig.server.setPairingOffer(secret: secret, expiry: Date().addingTimeInterval(-1)) == false)
        #expect(await rig.server.setPairingOffer(secret: Data(repeating: 1, count: 5), expiry: Date().addingTimeInterval(60)) == false)
        #expect(await rig.server.setPairingOffer(secret: secret, expiry: Date().addingTimeInterval(60)))

        // Wrong secret: the responder rejects message 3; no event; the offer stays until the failure limit.
        let attacker = try await NoiseSession.initiatePairing(
            over: try await rig.connect(), localStatic: phone, pairingSecret: Data(repeating: 0x22, count: 32),
            expectedResponderStatic: rig.server.staticPublicKey)
        await #expect(throws: (any Error).self) { _ = try await attacker.receive() }
        #expect(app.pairingEvents.isEmpty)
        #expect(await rig.server.status().pairingActive)

        // Detaching withdraws the offer.
        await rig.server.detach(token)
        #expect(await rig.server.status().pairingActive == false)
    }

    @Test func offerIsWithdrawnAfterTooManyFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AgentStorage(groupContainer: directory)
        let server = try AgentServer(configuration: AgentConfiguration(storage: storage, binding: .loopback(port: 0), maxPairingFailures: 2))
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort)
        _ = await server.attach(AgentFakeApp())
        #expect(await server.setPairingOffer(secret: Data(repeating: 3, count: 32), expiry: Date().addingTimeInterval(60)))
        for _ in 0..<2 {
            let stream = try await NWConnectionStream.connect(host: "127.0.0.1", port: port)
            let session = try await NoiseSession.initiatePairing(
                over: stream, localStatic: phone, pairingSecret: Data(repeating: 4, count: 32), expectedResponderStatic: server.staticPublicKey)
            _ = try? await session.receive()
        }
        #expect(await eventually { await server.status().pairingActive == false })
    }

    // MARK: Live sessions and mailbox

    @Test func unknownKeyIsRejectedAndRemovedDeviceLosesSessionAndMailbox() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        try await rig.allow([phone])
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        await #expect(throws: (any Error).self) { _ = try await rig.live(stranger) }

        let session = try await rig.live(phone)
        _ = try await session.drainUntilPong()
        try await session.send(.batch(try rig.envelope(from: 1, to: 3)))
        #expect(try await session.receive() == .ack(device: 0xA1, throughSeq: 3))
        #expect(await rig.server.status().inboxBatches == 1)
        #expect(await rig.server.status().connectedPeers == [MailboxPeerID(staticKey: phoneKey).rawValue])

        // The next list drops the phone: its session ends, its mailbox is deleted, reconnecting fails.
        #expect(try await rig.allow([], version: 2).ok)
        await #expect(throws: (any Error).self) { _ = try await session.receive() }
        #expect(await rig.server.status().inboxBatches == 0)
        await #expect(throws: (any Error).self) { _ = try await rig.live(phone) }
    }

    @Test func inboundBatchIsStoredWhileNoAppIsConnectedAndFetchedWhenItAttaches() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        try await rig.allow([phone])
        let session = try await rig.live(phone)
        let batch = try rig.envelope(from: 1, to: 4)
        try await session.send(.batch(batch))
        #expect(try await session.receive() == .ack(device: 0xA1, throughSeq: 4))

        // The Mac app unlocks later: it attaches, sees the batch and removes it after applying.
        let app = AgentFakeApp()
        _ = await rig.server.attach(app)
        let items = await rig.server.fetchInbox(peer: nil, maxBytes: 1 << 20)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.peer == phoneKey && item.sender == 0xA1 && item.seqFrom == 1 && item.seqTo == 4)
        #expect(try SealedEnvelope(decoding: item.envelope) == batch)
        #expect(await rig.server.deleteInbox([.init(peer: item.peer, sender: item.sender, seqFrom: item.seqFrom, seqTo: item.seqTo)]) == 1)
        #expect(await rig.server.fetchInbox(peer: nil, maxBytes: 1 << 20).isEmpty)
    }

    @Test func largestBatchCrossesTheSocketAndIsStoredIntact() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        try await rig.allow([phone])
        let session = try await rig.live(phone)
        let batch = try rig.envelope(from: 1, to: 50, size: SealedEnvelope.maxPayloadSize)
        try await session.send(.batch(batch))
        #expect(try await session.receive() == .ack(device: 0xA1, throughSeq: 50))
        let stored = await rig.server.fetchInbox(peer: nil, maxBytes: 4 << 20)
        #expect(try stored.first.map { try SealedEnvelope(decoding: $0.envelope) } == batch)
        // And the way back: the same batch from the outbox arrives in one piece.
        #expect(await rig.server.publishOutbox(peer: phoneKey, envelopes: [batch.encoded()]) == .success(1))
        try await session.send(.hello(.init(device: 0xA1, group: Data(repeating: 9, count: 16), cursors: [])))
        #expect(try await session.drainUntilPong() == [.batch(batch)])
    }

    @Test func listenerClosesConnectionsBeyondItsLimit() async throws {
        let accepted = Counter()
        let listener = try AgentListener(
            binding: .loopback, port: 0, maxOpenConnections: 2,
            onConnection: { stream in
                accepted.increment()
                Task { _ = try? await stream.receive() }
            },
            onState: { _ in })
        listener.start()
        defer { listener.cancel() }
        guard case .ready(let port) = listener.state else { Issue.record("listener not ready"); return }
        let first = try await NWConnectionStream.connect(host: "127.0.0.1", port: port)
        let second = try await NWConnectionStream.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { accepted.value == 2 })
        let third = try await NWConnectionStream.connect(host: "127.0.0.1", port: port)
        await #expect(throws: (any Error).self) { _ = try await third.receive() }
        #expect(accepted.value == 2)
        await first.close()
        await second.close()
        // A slot frees up when a connection ends.
        #expect(await eventually {
            guard let again = try? await NWConnectionStream.connect(host: "127.0.0.1", port: port) else { return false }
            defer { Task { await again.close() } }
            return await eventually(timeout: .milliseconds(300)) { accepted.value == 3 }
        })
    }

    @Test func replayedBatchIsStoredOnceAndAcknowledgedBothTimes() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        try await rig.allow([phone])
        let session = try await rig.live(phone)
        let batch = try rig.envelope(from: 5, to: 9)
        for _ in 0..<2 {
            try await session.send(.batch(batch))
            #expect(try await session.receive() == .ack(device: 0xA1, throughSeq: 9))
        }
        #expect(await rig.server.status().inboxBatches == 1)
        #expect(await rig.server.fetchInbox(peer: phoneKey, maxBytes: 1 << 20).count == 1)
    }

    @Test func quotaExceededAnswersWithAnErrorMessage() async throws {
        let batchSize = try await AgentRig().envelope(from: 1, to: 1, size: 1_000).encoded().count
        let rig = try await AgentRig(limits: .init(quotaBytesPerPeer: batchSize + batchSize / 2))
        defer { Task { await rig.cleanup() } }
        try await rig.allow([phone])
        let session = try await rig.live(phone)
        try await session.send(.batch(try rig.envelope(from: 1, to: 1, size: 1_000)))
        #expect(try await session.receive() == .ack(device: 0xA1, throughSeq: 1))
        try await session.send(.batch(try rig.envelope(from: 2, to: 2, size: 1_000)))
        guard case .error(let code, _) = try await session.receive() else {
            Issue.record("expected an error message")
            return
        }
        #expect(code == .quotaExceeded)
        #expect(await rig.server.status().inboxBatches == 1)
        // The session survives.
        _ = try await session.drainUntilPong()
    }

    @Test func outboxIsServedByCursorAndFreedByAck() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        try await rig.allow([phone])
        let mac: UInt64 = 0xB2
        let first = try rig.envelope(device: mac, from: 1, to: 5)
        let second = try rig.envelope(device: mac, from: 6, to: 10)
        let third = try rig.envelope(device: mac, from: 11, to: 12)
        let published = await rig.server.publishOutbox(peer: phoneKey, envelopes: [first, second, third].map { $0.encoded() })
        #expect(published == .success(3))
        #expect(await rig.server.publishOutbox(peer: phoneKey, envelopes: [first.encoded()]) == .success(1))  // idempotent
        #expect(await rig.server.status().outboxBatches == 3)

        let session = try await rig.live(phone)
        try await session.send(.hello(.init(device: 0xA1, group: Data(repeating: 9, count: 16), cursors: [.init(device: mac, appliedSeq: 5)])))
        let served = try await session.drainUntilPong()
        #expect(served == [.batch(second), .batch(third)])

        try await session.send(.ack(device: mac, throughSeq: 10))
        #expect(await eventually { await rig.server.status().outboxBatches == 1 })
        // A peer with no cursor gets what is left.
        try await session.send(.hello(.init(device: 0xA1, group: Data(repeating: 9, count: 16), cursors: [])))
        #expect(try await session.drainUntilPong() == [.batch(third)])
    }

    @Test func snapshotRequestWithoutAppGetsAnUnavailableError() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        try await rig.allow([phone])
        let session = try await rig.live(phone)
        try await session.send(.snapshotRequest(requestID: 7))
        guard case .error(let code, _) = try await session.receive() else {
            Issue.record("expected an error message")
            return
        }
        #expect(code == .appUnavailable)
    }

    @Test func connectedAppGetsMessagesLiveAndAnswersThroughForward() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        try await rig.allow([phone])
        let app = AgentFakeApp()
        let token = await rig.server.attach(app)
        let session = try await rig.live(phone)
        #expect(await eventually { app.connections.contains { $0.peer == self.phoneKey && $0.connected } })

        let hello = SyncMessage.hello(.init(device: 0xA1, group: Data(repeating: 9, count: 16), cursors: []))
        let batch = try rig.envelope(from: 1, to: 2)
        try await session.send(hello)
        try await session.send(.batch(batch))
        try await session.send(.ack(device: 0xB2, throughSeq: 3))
        try await session.send(.snapshotRequest(requestID: 1))
        #expect(await eventually { app.received.count == 4 })
        #expect(app.received.map(\.message) == [hello, .batch(batch), .ack(device: 0xB2, throughSeq: 3), .snapshotRequest(requestID: 1)])
        #expect(app.received.allSatisfy { $0.peer == self.phoneKey })
        // Relayed batches are not stored; the app acknowledges them itself.
        #expect(await rig.server.status().inboxBatches == 0)

        let reply = try rig.envelope(device: 0xB2, from: 1, to: 1)
        #expect(await rig.server.forward(.batch(reply), to: phoneKey))
        #expect(try await session.receive() == .batch(reply))
        #expect(await rig.server.forward(.ping(token: 1), to: Data(repeating: 0, count: 32)) == false)

        // When the app declines (locked), the agent stores instead.
        app.handles = false
        try await session.send(.batch(try rig.envelope(from: 3, to: 3)))
        #expect(try await session.receive() == .ack(device: 0xA1, throughSeq: 3))
        #expect(await rig.server.status().inboxBatches == 1)

        // After detach it behaves as without an app.
        await rig.server.detach(token)
        try await session.send(.batch(try rig.envelope(from: 4, to: 4)))
        #expect(try await session.receive() == .ack(device: 0xA1, throughSeq: 4))
        #expect(app.received.count == 5)
        #expect(await rig.server.status().appAttached == false)
    }

    @Test func newConnectionOfTheSamePeerReplacesTheOldSession() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        try await rig.allow([phone])
        let old = try await rig.live(phone)
        _ = try await old.drainUntilPong()
        let fresh = try await rig.live(phone)
        _ = try await fresh.drainUntilPong()
        await #expect(throws: (any Error).self) { _ = try await old.receive() }
        #expect(await rig.server.status().connectedPeers.count == 1)
    }

    // MARK: Listener binding

    @Test func noTailnetMeansNoListener() async throws {
        final class FakeTailnet: TailnetProviding, @unchecked Sendable {
            func start(onChange: @escaping @Sendable (TailnetInterface?) -> Void) { onChange(nil) }
            func stop() {}
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-notailnet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try AgentServer(configuration: AgentConfiguration(
            storage: AgentStorage(groupContainer: directory), binding: .tailnet(port: 0), tailnet: FakeTailnet()))
        try await server.start()
        try await Task.sleep(for: .milliseconds(200))
        let status = await server.status()
        #expect(status.listening == false && status.host == nil && status.port == nil && status.tailnetInterface == nil)
        #expect(await server.boundPort == nil)
        await server.stop()
    }

    @Test func tailnetAddressRangeAndInterfaceSelection() {
        #expect(TailnetAddress.isTailnetIPv4("100.64.0.1"))
        #expect(TailnetAddress.isTailnetIPv4("100.98.12.34"))
        #expect(TailnetAddress.isTailnetIPv4("100.127.255.254"))
        #expect(!TailnetAddress.isTailnetIPv4("100.63.255.255"))
        #expect(!TailnetAddress.isTailnetIPv4("100.128.0.1"))
        #expect(!TailnetAddress.isTailnetIPv4("192.168.1.2"))
        #expect(!TailnetAddress.isTailnetIPv4("100.98.12"))
        #expect(!TailnetAddress.isTailnetIPv4("fd7a:115c:a1e0::1"))
        // Interfaces that carry the address but are not in the path (no NWInterface) are not selectable.
        #expect(TailnetAddress.select(addresses: [("utun4", "100.98.12.34"), ("en0", "192.168.1.5")], available: []) == nil)
    }

    @Test func requirementStringsPinTeamAndIdentifier() {
        #expect(
            AgentXPCRequirements.strict(teamIdentifier: "HHK7S6D2TR", identifier: "dev.gasi.imm")
                == "anchor apple generic and certificate leaf[subject.OU] = \"HHK7S6D2TR\" and identifier \"dev.gasi.imm\"")
        let signed = AgentXPCRequirements.requirement(forPeerIdentifier: "dev.gasi.imm.sync-agent", ownTeam: "HHK7S6D2TR")
        #expect(!signed.relaxed && signed.text.contains("HHK7S6D2TR") && signed.text.contains("dev.gasi.imm.sync-agent"))
        let unsigned = AgentXPCRequirements.requirement(forPeerIdentifier: "dev.gasi.imm", ownTeam: nil)
        #expect(unsigned.relaxed && unsigned.text == "identifier \"dev.gasi.imm\"")
    }

    // MARK: XPC

    @Test func xpcRoundTripCarriesPairingRelayAndMailboxCalls() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        let service = AgentXPCService(server: rig.server, listener: .anonymous(), requirement: nil)
        service.resume()
        defer { service.invalidate() }
        let app = AgentFakeApp()
        let client = AgentXPCClient(listenerEndpoint: service.endpoint, endpoint: app)
        defer { client.invalidate() }

        let status = try await client.attach()
        #expect(status.appAttached && status.staticPublicKey == rig.server.staticPublicKey && status.protocolVersion == 1)
        #expect(status.listening && status.host == "127.0.0.1" && status.port == rig.port)

        // Allow-list and pairing offer through XPC.
        let list = PeerAllowList(version: 1, issuedAt: Date(), peers: [.init(publicKey: phoneKey, name: "phone")])
        #expect(try await client.publishAllowList(try SignedPeerAllowList.sign(list, with: rig.owner)).ok)
        let secret = Data(repeating: 0x42, count: 32)
        #expect(try await client.setPairingOffer(secret: secret, expiry: Date().addingTimeInterval(120)))
        let joiner = try await NoiseSession.initiatePairing(
            over: try await rig.connect(), localStatic: Curve25519.KeyAgreement.PrivateKey(), pairingSecret: secret,
            expectedResponderStatic: rig.server.staticPublicKey)
        #expect(await eventually { !app.pairingEvents.isEmpty })
        #expect(app.pairingEvents.first?.code == joiner.pairingCode?.digits)
        try await client.closeSession(peer: try #require(app.pairingEvents.first).peer)
        await #expect(throws: (any Error).self) { _ = try await joiner.receive() }

        // Live relay both ways over XPC.
        let session = try await rig.live(phone)
        #expect(await eventually { app.connections.contains { $0.peer == self.phoneKey && $0.connected } })
        try await session.send(.ping(token: 1))
        #expect(try await session.receive() == .pong(token: 1))  // answered by the agent itself
        let hello = SyncMessage.hello(.init(device: 0xA1, group: Data(repeating: 9, count: 16), cursors: [.init(device: 3, appliedSeq: 9)]))
        try await session.send(hello)
        #expect(await eventually { app.received.map(\.message) == [hello] })
        let batch = try rig.envelope(device: 0xB2, from: 1, to: 1)
        #expect(try await client.forward(.batch(batch), to: phoneKey))
        #expect(try await session.receive() == .batch(batch))
        #expect(try await client.forward(.ping(token: 2), to: Data(repeating: 1, count: 32)) == false)

        // Outbox and inbox calls.
        #expect(try await client.publishOutbox(peer: phoneKey, envelopes: [batch]) == .success(1))
        app.handles = false
        let inbound = try rig.envelope(from: 1, to: 2)
        try await session.send(.batch(inbound))
        #expect(try await session.receive() == .ack(device: 0xA1, throughSeq: 2))
        let items = try await client.fetchInbox()
        #expect(items.map(\.seqTo) == [2])
        #expect(try await client.deleteInbox(items.map { .init(peer: $0.peer, sender: $0.sender, seqFrom: $0.seqFrom, seqTo: $0.seqTo) }) == 1)
        #expect(try await client.wipeMailbox() == 1)  // the outbox batch
        try await client.detach()
        #expect(try await client.status().appAttached == false)
    }

    @Test func xpcConnectionDropDetachesTheApp() async throws {
        let rig = try await AgentRig()
        defer { Task { await rig.cleanup() } }
        let service = AgentXPCService(server: rig.server, listener: .anonymous(), requirement: nil)
        service.resume()
        defer { service.invalidate() }
        let client = AgentXPCClient(listenerEndpoint: service.endpoint, endpoint: AgentFakeApp())
        try await client.attach()
        #expect(await rig.server.status().appAttached)
        client.invalidate()
        #expect(await eventually { await rig.server.status().appAttached == false })
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
