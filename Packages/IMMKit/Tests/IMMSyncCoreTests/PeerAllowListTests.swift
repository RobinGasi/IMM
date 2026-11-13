import CryptoKit
import Foundation
import Testing

@testable import IMMSyncCore

struct PeerAllowListTests {
    private let owner = Curve25519.Signing.PrivateKey()

    private func peer(_ name: String) -> PeerAllowList.Peer {
        PeerAllowList.Peer(publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, name: name)
    }

    @Test func signVerifyRoundTrip() throws {
        let iPhone = peer("iPhone"), mac = peer("Mac mini")
        let list = PeerAllowList(version: 3, issuedAt: Date(timeIntervalSince1970: 1_800_000_000), peers: [iPhone, mac])
        let signed = try SignedPeerAllowList.sign(list, with: owner)
        let verified = try signed.verify(ownerPublicKey: owner.publicKey.rawRepresentation)
        #expect(verified == list)
        #expect(verified.contains(staticKey: iPhone.publicKey))
        #expect(verified.name(forStaticKey: mac.publicKey) == "Mac mini")
        #expect(!verified.contains(staticKey: Data(repeating: 1, count: 32)))
        // Persist and reload (what the agent does).
        let reloaded = try SignedPeerAllowList(decoding: try signed.encoded())
        #expect(try reloaded.verify(ownerPublicKey: owner.publicKey.rawRepresentation) == list)
    }

    @Test func signingIsDeterministicForTheSameList() throws {
        let list = PeerAllowList(version: 1, issuedAt: Date(timeIntervalSince1970: 0), peers: [peer("a")])
        #expect(try SignedPeerAllowList.sign(list, with: owner).payload == SignedPeerAllowList.sign(list, with: owner).payload)
    }

    @Test func forgeriesAreRejected() throws {
        let list = PeerAllowList(version: 1, issuedAt: Date(timeIntervalSince1970: 0), peers: [peer("phone")])
        let signed = try SignedPeerAllowList.sign(list, with: owner)
        let ownerKey = owner.publicKey.rawRepresentation

        // Wrong owner key.
        #expect(throws: PeerAllowListError.invalidSignature) {
            try signed.verify(ownerPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        }
        // Tampered payload: attacker appends his own key.
        let evil = PeerAllowList(version: 1, issuedAt: Date(timeIntervalSince1970: 0), peers: list.peers + [peer("evil")])
        let evilPayload = try SignedPeerAllowList.sign(evil, with: Curve25519.Signing.PrivateKey()).payload
        #expect(throws: PeerAllowListError.invalidSignature) {
            try SignedPeerAllowList(payload: evilPayload, signature: signed.signature).verify(ownerPublicKey: ownerKey)
        }
        // Tampered signature.
        var sig = signed.signature
        sig[0] ^= 1
        #expect(throws: PeerAllowListError.invalidSignature) {
            try SignedPeerAllowList(payload: signed.payload, signature: sig).verify(ownerPublicKey: ownerKey)
        }
        // Signature without the domain prefix (e.g. reused from another signing context) does not verify.
        let bare = try owner.signature(for: signed.payload)
        #expect(throws: PeerAllowListError.invalidSignature) {
            try SignedPeerAllowList(payload: signed.payload, signature: bare).verify(ownerPublicKey: ownerKey)
        }
        #expect(throws: PeerAllowListError.invalidKey) { try signed.verify(ownerPublicKey: Data(count: 5)) }
    }

    @Test func rollbackAndMalformedKeys() throws {
        let old = PeerAllowList(version: 2, issuedAt: Date(timeIntervalSince1970: 0), peers: [peer("phone")])
        let signed = try SignedPeerAllowList.sign(old, with: owner)
        #expect(throws: PeerAllowListError.rolledBack(version: 2, minimum: 3)) {
            try signed.verify(ownerPublicKey: owner.publicKey.rawRepresentation, minimumVersion: 3)
        }
        _ = try signed.verify(ownerPublicKey: owner.publicKey.rawRepresentation, minimumVersion: 2)
        let bad = PeerAllowList(version: 1, issuedAt: Date(timeIntervalSince1970: 0), peers: [.init(publicKey: Data(count: 31), name: "x")])
        #expect(throws: PeerAllowListError.invalidKey) { try SignedPeerAllowList.sign(bad, with: owner) }
        // A validly signed but garbage payload is malformed, not accepted.
        let junk = Data("not json".utf8)
        let junkSigned = SignedPeerAllowList(payload: junk, signature: try owner.signature(for: SignedPeerAllowList.domain + junk))
        #expect(throws: PeerAllowListError.malformed) { try junkSigned.verify(ownerPublicKey: owner.publicKey.rawRepresentation) }
        #expect(throws: PeerAllowListError.malformed) { try SignedPeerAllowList(decoding: Data("{}".utf8)) }
    }
}
