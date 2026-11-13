import CryptoKit
import Foundation

public enum PeerAllowListError: Error, Equatable, Sendable {
    case invalidSignature
    case malformed
    case invalidKey
    /// Verified, but older than the version the verifier already holds (replay of a stale list).
    case rolledBack(version: UInt64, minimum: UInt64)
}

/// The static public keys (and display names) of the devices that may talk to the keyless agent.
/// The app signs the list with the owner's Ed25519 key (`SignedPeerAllowList`) and hands it to the agent, which
/// verifies it with the owner public key it was configured with and persists the signed form.
public struct PeerAllowList: Codable, Equatable, Sendable {
    public struct Peer: Codable, Equatable, Hashable, Sendable {
        /// 32-byte X25519 Noise static public key.
        public var publicKey: Data
        public var name: String
        public init(publicKey: Data, name: String) {
            self.publicKey = publicKey
            self.name = name
        }
    }

    /// Monotonically increasing; the verifier rejects lists older than the one it holds.
    public var version: UInt64
    public var issuedAt: Date
    public var peers: [Peer]

    public init(version: UInt64, issuedAt: Date, peers: [Peer]) {
        self.version = version
        self.issuedAt = issuedAt
        self.peers = peers
    }

    public func contains(staticKey: Data) -> Bool { peers.contains { $0.publicKey == staticKey } }

    public func name(forStaticKey key: Data) -> String? { peers.first { $0.publicKey == key }?.name }

    func validate() throws {
        guard peers.allSatisfy({ $0.publicKey.count == 32 }) else { throw PeerAllowListError.invalidKey }
    }
}

/// An allow-list with the owner's Ed25519 signature over `"imm/v1/allowlist" ‖ payload` (payload = canonical JSON,
/// sorted keys). Signing the exact bytes avoids any canonicalisation ambiguity on the verifier's side.
public struct SignedPeerAllowList: Codable, Equatable, Sendable {
    static let domain = Data("imm/v1/allowlist".utf8)

    public let payload: Data
    public let signature: Data

    public init(payload: Data, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func sign(_ list: PeerAllowList, with owner: Curve25519.Signing.PrivateKey) throws -> SignedPeerAllowList {
        try list.validate()
        let payload = try encoder().encode(list)
        let signature = try owner.signature(for: domain + payload)
        return SignedPeerAllowList(payload: payload, signature: signature)
    }

    /// Checks the signature against `ownerPublicKey` (32-byte Ed25519) and returns the list.
    /// - Parameter minimumVersion: the version of the list the verifier already holds; older lists are rejected.
    public func verify(ownerPublicKey: Data, minimumVersion: UInt64 = 0) throws -> PeerAllowList {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: ownerPublicKey) else {
            throw PeerAllowListError.invalidKey
        }
        guard key.isValidSignature(signature, for: Self.domain + payload) else { throw PeerAllowListError.invalidSignature }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode(PeerAllowList.self, from: payload) else { throw PeerAllowListError.malformed }
        try list.validate()
        guard list.version >= minimumVersion else {
            throw PeerAllowListError.rolledBack(version: list.version, minimum: minimumVersion)
        }
        return list
    }

    public func encoded() throws -> Data { try Self.encoder().encode(self) }

    public init(decoding data: Data) throws {
        guard let value = try? JSONDecoder().decode(SignedPeerAllowList.self, from: data) else {
            throw PeerAllowListError.malformed
        }
        self = value
    }
}
