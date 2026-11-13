import Foundation
import GRDB
import IMMLedger
@testable import IMMSync
import IMMSyncCore
import Testing

/// Engine-level tests: no sockets, two ledgers and the messages between them.
@Suite struct ProtocolTests {
    /// Two paired engines on fresh ledgers; `a` founded the group, `b` holds the same key. `budget` forces small batches.
    func pairedEngines(budget: Int = SealedEnvelope.maxPayloadSize) async throws -> (a: TestDevice, ea: SyncEngine, b: TestDevice, eb: SyncEngine) {
        let a = try TestDevice(), b = try TestDevice()
        let ea = try SyncEngine(ledger: a.store, deviceName: "A", payloadBudget: budget)
        let group = try await ea.ensureGroup()
        try SyncSecretStore(ledger: b.store).store(group)   // what the pairing grant delivers
        let eb = try SyncEngine(ledger: b.store, deviceName: "B", payloadBudget: budget)
        return (a, ea, b, eb)
    }

    func peerRef(of device: TestDevice, engine: SyncEngine) async -> SyncPeer {
        SyncPeer(staticKey: await engine.identity.x25519Public, node: device.node)
    }

    func flip(_ store: LedgerStore, times: Int) throws {
        for i in 0..<times { try store.writer.setSetting(.rolloverEnabled, i % 2 == 0 ? "1" : "0") }
    }

    @Test func sequenceGapAppliesAnywayRequestsRangeAndHealsOnArrival() async throws {
        let (a, ea, b, eb) = try await pairedEngines(budget: 300)
        try flip(a.store, times: 4)
        let peerB = await peerRef(of: b, engine: eb)
        let peerA = await peerRef(of: a, engine: ea)
        let envelopes = try await ea.batches(for: peerB, cursors: [])
        try #require(envelopes.count == 4, "a 300-byte budget gives one op per batch")
        #expect(envelopes.map(\.header.seqFrom) == [1, 2, 3, 4])

        // Batch 2 arrives first: batch 1 was lost.
        let first = try await eb.handle(.batch(envelopes[1]), from: peerA)
        #expect(first.replies.contains { if case .hello = $0 { return true } else { return false } }, "a gap makes the receiver send its cursors")
        #expect(first.replies.contains(.ack(device: a.node, throughSeq: 0)), "the ack only claims the contiguous prefix")
        #expect(try cursor(b, of: a) == 0)

        // The sender answers the hello with everything after the cursor: all four batches.
        let hello = try #require(first.replies.compactMap { message -> SyncMessage.Hello? in
            if case .hello(let hello) = message { return hello } else { return nil }
        }.first)
        let resend = try await ea.handle(.hello(hello), from: peerB)
        #expect(resend.replies.filter { if case .batch = $0 { return true } else { return false } }.count == 4)

        // Batch 1 arrives: the stored batch 2 joins it, the cursor jumps to 2.
        _ = try await eb.handle(.batch(envelopes[0]), from: peerA)
        #expect(try cursor(b, of: a) == 2)
        _ = try await eb.handle(.batch(envelopes[2]), from: peerA)
        _ = try await eb.handle(.batch(envelopes[3]), from: peerA)
        #expect(try cursor(b, of: a) == 4)
        #expect(try a.converged() == b.converged())
    }

    @Test func replayedBatchIsIdempotent() async throws {
        let (a, ea, b, eb) = try await pairedEngines()
        try flip(a.store, times: 3)
        let peerA = await peerRef(of: a, engine: ea)
        let peerB = await peerRef(of: b, engine: eb)
        let envelopes = try await ea.batches(for: peerB, cursors: [])
        let batch = try #require(envelopes.first)

        let once = try await eb.handle(.batch(batch), from: peerA)
        #expect(once.applyResult?.applied ?? 0 > 0)
        let before = try b.converged()
        let cursorBefore = try cursor(b, of: a)

        let again = try await eb.handle(.batch(batch), from: peerA)
        #expect(again.applyResult == nil, "nothing is applied the second time")
        #expect(again.replies == [.ack(device: a.node, throughSeq: cursorBefore)])
        #expect(try b.converged() == before)
        #expect(try cursor(b, of: a) == cursorBefore)
        // Even below the engine, re-applying the ops changes nothing.
        let ops = try a.store.writer.ops(from: a.node, after: 0, limit: 10)
        #expect(try b.store.writer.applyRemote(ops).applied == 0)
    }

    @Test func tamperedAndForeignBatchesAreRejected() async throws {
        let (a, ea, b, eb) = try await pairedEngines()
        try flip(a.store, times: 2)
        let peerA = await peerRef(of: a, engine: ea)
        let peerB = await peerRef(of: b, engine: eb)
        let envelope = try #require(try await ea.batches(for: peerB, cursors: []).first)

        // A flipped header bit: AAD no longer matches.
        var bytes = envelope.encoded()
        bytes[20] ^= 0x01   // a device-id bit
        let tampered = try SealedEnvelope(decoding: bytes)
        let result = try await eb.handle(.batch(tampered), from: peerA)
        #expect(result.events.contains { if case .batchRejected = $0 { return true } else { return false } })
        #expect(try cursor(b, of: a) == 0)

        // Sealed under another group key.
        let stranger = SyncGroup.generate()
        let foreign = try SealedEnvelope.seal(
            payload: Data("[]".utf8), header: .init(group: try #require(await eb.group).id, device: a.node, seqFrom: 1, seqTo: 1), key: stranger.key)
        let rejected = try await eb.handle(.batch(foreign), from: peerA)
        #expect(rejected.events.contains { if case .batchRejected = $0 { return true } else { return false } })

        // Header claims seq 1…1 but the ops inside are 1…2.
        let ops = try a.store.writer.ops(from: a.node, after: 0, limit: 10)
        let group = try #require(await ea.group)
        let lying = try SealedEnvelope.seal(
            payload: try JSONEncoder().encode(ops), header: .init(group: group.id, device: a.node, seqFrom: 1, seqTo: 1), key: group.key)
        let mismatch = try await eb.handle(.batch(lying), from: peerA)
        #expect(mismatch.events.contains { if case .batchRejected = $0 { return true } else { return false } })
        #expect(try cursor(b, of: a) == 0)
    }

    @Test func batchesNeverExceedOneMiB() async throws {
        let (a, ea, b, eb) = try await pairedEngines()
        let filler = String(repeating: "x", count: 5000)
        for i in 0..<600 { try a.store.writer.setSetting(.rolloverEnabled, filler + "\(i)") }
        let peerB = await peerRef(of: b, engine: eb)
        let peerA = await peerRef(of: a, engine: ea)
        let envelopes = try await ea.batches(for: peerB, cursors: [])
        #expect(envelopes.count >= 3)
        #expect(envelopes.allSatisfy { $0.encoded().count <= SealedEnvelope.maxEncodedSize })
        // Ranges are contiguous and cover 1…600.
        var next: Int64 = 1
        for envelope in envelopes {
            #expect(envelope.header.seqFrom == next)
            next = envelope.header.seqTo + 1
        }
        #expect(next == 601)
        for envelope in envelopes { _ = try await eb.handle(.batch(envelope), from: peerA) }
        #expect(try cursor(b, of: a) == 600)
        #expect(try a.converged() == b.converged())
    }

    @Test func publishingOnlySendsWhatIsNewPerMarker() async throws {
        let (a, ea, b, eb) = try await pairedEngines()
        let peerB = await peerRef(of: b, engine: eb)
        try flip(a.store, times: 3)
        let first = try await ea.batches(for: peerB)
        #expect(first.count == 1)
        try await ea.markSent(first, to: peerB)
        #expect(try await ea.batches(for: peerB).isEmpty)
        try a.store.writer.setSetting(.rolloverEnabled, "0")
        let second = try await ea.batches(for: peerB)
        #expect(second.map(\.header.seqFrom) == [4])
        // A hello with real cursors wins over the marker: the peer says it has nothing.
        let hello = SyncMessage.Hello(device: b.node, group: try #require(await eb.group).id, cursors: [])
        let resend = try await ea.handle(.hello(hello), from: peerB)
        #expect(resend.replies.count == 1, "all four ops fit one batch")
    }

    @Test func snapshotIsChunkedSealedAndBootstrapsAnEmptyLedger() async throws {
        let mac = try TestDevice(demo: true)
        let peer = try TestDevice()
        let em = try SyncEngine(ledger: mac.store, deviceName: "Mac")
        _ = try await em.ensureGroup()
        let ep = try SyncEngine(ledger: peer.store, deviceName: "Peer")
        // Pairing hand-over, without sockets.
        let join = await ep.identity.rosterEntry
        let grant = try await em.makeGrant(for: join)
        let adopted = try await ep.handle(grant, from: SyncPeer(staticKey: Data(repeating: 1, count: 32)), fromHub: true)
        #expect(adopted.events == [.paired(hub: mac.node)])

        let peerRef = SyncPeer(staticKey: join.x25519, node: join.node)
        let chunks = try await em.snapshotMessages(requestID: 7, for: peerRef)
        #expect(!chunks.isEmpty)
        for case .snapshotChunk(let chunk) in chunks {
            #expect(chunk.data.count <= SealedEnvelope.maxEncodedSize)
            #expect(chunk.requestID == 7)
        }
        var events: [SyncEvent] = []
        for chunk in chunks.shuffled() {   // chunks may arrive in any order
            events += try await ep.handle(chunk, from: SyncPeer(staticKey: Data(repeating: 1, count: 32)), fromHub: true).events
        }
        #expect(events == [.bootstrapped])
        #expect(try mac.converged() == peer.converged())
        #expect(try await em.isBootstrapped(peer: join.x25519))
        // Ops made after the snapshot are exactly what the next hello pulls.
        try mac.store.writer.setNote(transactionID: try mac.transactionID("REWE"), note: "after snapshot")
        let hello = try await ep.hello()
        let pull = try await em.handle(hello, from: peerRef)
        #expect(pull.replies.count == 1)
        for reply in pull.replies { _ = try await ep.handle(reply, from: SyncPeer(staticKey: Data(repeating: 1, count: 32)), fromHub: true) }
        #expect(try peer.summary("REWE").note == "after snapshot")
    }

    @Test func snapshotIntoALedgerWithEditsIsRefused() async throws {
        let mac = try TestDevice(demo: true)
        let peer = try TestDevice()
        let em = try SyncEngine(ledger: mac.store, deviceName: "Mac")
        _ = try await em.ensureGroup()
        let ep = try SyncEngine(ledger: peer.store, deviceName: "Peer")
        let grant = try await em.makeGrant(for: await ep.identity.rosterEntry)
        _ = try await ep.handle(grant, from: SyncPeer(staticKey: Data(repeating: 1, count: 32)), fromHub: true)
        try peer.store.writer.setSetting(.rolloverEnabled, "1")   // a local edit before the snapshot
        let chunks = try await em.snapshotMessages(requestID: 1, for: SyncPeer(staticKey: Data(repeating: 2, count: 32), node: peer.node))
        await #expect(throws: LedgerWriterError.ledgerHasLocalEdits) {
            for chunk in chunks { _ = try await ep.handle(chunk, from: SyncPeer(staticKey: Data(repeating: 1, count: 32)), fromHub: true) }
        }
    }

    @Test func grantNeedsTheHubsSignatureAndRekeyOnlyComesFromTheHub() async throws {
        let mac = try TestDevice()
        let peer = try TestDevice()
        let em = try SyncEngine(ledger: mac.store, deviceName: "Mac")
        _ = try await em.ensureGroup()
        let ep = try SyncEngine(ledger: peer.store, deviceName: "Peer")
        let join = await ep.identity.rosterEntry

        // Not from the hub session: refused.
        let grant = try await em.makeGrant(for: join)
        await #expect(throws: SyncError.self) { _ = try await ep.handle(grant, from: SyncPeer(staticKey: Data(repeating: 1, count: 32)), fromHub: false) }
        #expect(await ep.group == nil)

        // A grant whose roster was altered fails the signature.
        guard case .pairingGrant(let blob) = grant, case .grant(var body) = try PairingWire(decoding: blob) else { Issue.record("no grant"); return }
        body.hub.name = "Mallory"
        let forged = SyncMessage.pairingGrant(PairingWire.grant(body).encoded())
        await #expect(throws: SyncError.self) { _ = try await ep.handle(forged, from: SyncPeer(staticKey: Data(repeating: 1, count: 32)), fromHub: true) }
        #expect(await ep.group == nil)

        // Accepted once from the hub; a later rekey from a non-hub session is refused, from the hub accepted.
        _ = try await ep.handle(grant, from: SyncPeer(staticKey: Data(repeating: 1, count: 32)), fromHub: true)
        let rotation = try await em.rotateGroup()
        let rekey = try await em.rekeyMessage()
        await #expect(throws: SyncError.self) { _ = try await ep.handle(rekey, from: SyncPeer(staticKey: Data(repeating: 9, count: 32)), fromHub: false) }
        #expect(await ep.group?.id == rotation.old.id)
        let result = try await ep.handle(rekey, from: SyncPeer(staticKey: Data(repeating: 1, count: 32)), fromHub: true)
        #expect(result.events == [.rekeyed])
        #expect(await ep.group?.id == rotation.new.id)
    }

    @Test func rekeyNoticeEnvelopeIsOpenedUnderTheOldKeyOnly() async throws {
        let (a, ea, b, eb) = try await pairedEngines()
        let oldGroup = try #require(await ea.group)
        let rotation = try await ea.rotateGroup()
        #expect(rotation.new.id != oldGroup.id)
        #expect(rotation.notice.header.seqTo >= SyncEngine.controlSequenceBase)
        // B still holds the old group: it opens the notice and adopts the new key.
        let result = try await eb.handle(
            .batch(rotation.notice), from: SyncPeer(staticKey: await ea.identity.x25519Public, node: a.node), fromHub: true)
        #expect(result.events.contains(.rekeyed))
        #expect(await eb.group?.id == rotation.new.id)
        _ = b
        // The notice must not move any marker or cursor.
        #expect(try cursor(b, of: a) == 0)
    }

    func cursor(_ device: TestDevice, of other: TestDevice) throws -> Int64 {
        try device.store.writer.cursors().first { $0.device == other.node }?.appliedSeq ?? 0
    }
}

@Suite struct PairingCodeTests {
    @Test func codeRoundTripsInGroupsOfFour() throws {
        let secret = PairingSecret.generate()
        let code = secret.code
        let groups = code.split(separator: "-")
        #expect(groups.count == 4 && groups.allSatisfy { $0.count == 4 })
        #expect(code.allSatisfy { $0 == "-" || "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) }, "no 0, 1, 8, 9")
        #expect(PairingCodeFormat.decode(code) == secret.bytes)
        #expect(PairingCodeFormat.decode(code.lowercased().replacingOccurrences(of: "-", with: " ")) == secret.bytes)
        #expect(secret.psk.count == 32)
        #expect(secret.psk == PairingSecret(bytes: secret.bytes)!.psk)
    }

    @Test func designArtboardCodeParses() throws {
        let bytes = try #require(PairingCodeFormat.decode("K7QM-4TZP-X2WD-6HNA"))
        #expect(bytes.count == 10)
        #expect(PairingCodeFormat.encode(bytes) == "K7QM-4TZP-X2WD-6HNA")
    }

    @Test func malformedCodesAreRejected() {
        #expect(PairingCodeFormat.decode("K7QM-4TZP-X2WD") == nil)
        #expect(PairingCodeFormat.decode("K7QM-4TZP-X2WD-6HN0") == nil)
        #expect(PairingCodeFormat.decode("K7QM-4TZP-X2WD-6HN1") == nil)
        #expect(PairingCodeFormat.decode("K7QM-4TZP-X2WD-6HNA-AAAA") == nil)
        #expect(throws: SyncError.self) { try PairingInvite(parsing: "not a code") }
    }

    @Test func qrPayloadCarriesEverythingTheJoinerNeeds() throws {
        let secret = PairingSecret.generate()
        let agent = Data((0..<32).map { UInt8($0) })
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = PairingPayload.make(node: 0xAB12, agentKey: agent, secret: secret, expiry: expiry, host: "robins-macbook.tail1234.ts.net", port: 47380)
        let invite = try PairingInvite(parsing: payload)
        #expect(invite.secret == secret)
        #expect(invite.agentKey == agent)
        #expect(invite.host == "robins-macbook.tail1234.ts.net")
        #expect(invite.port == 47380)
        #expect(invite.expiry == expiry)
        #expect(invite.hubNode == 0xAB12)
        let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(json["v"] as? Int == 1)
        #expect(Set(json.keys) == ["v", "device", "agent", "secret", "expiry", "host", "port"])
    }

    @Test func offerRendersAQRImage() throws {
        let offer = PairingOffer(
            qrPayload: PairingPayload.make(node: 1, agentKey: Data(repeating: 7, count: 32), secret: .generate(), expiry: Date(), host: "h", port: 1),
            code: "AAAA-BBBB-CCCC-DDDD", expiry: Date(), host: "h", port: 1, agentKey: Data(repeating: 7, count: 32))
        let image = try #require(offer.qrImage(size: 280))
        #expect(image.width >= 100)
    }
}
