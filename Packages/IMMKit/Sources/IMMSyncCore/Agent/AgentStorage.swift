import CryptoKit
import Foundation

/// Where the agent keeps its state: `<app group container>/Sync/`.
///
/// ```
/// agent-identity     32 raw bytes, Curve25519 static key (transport identity of this Mac), created on first run, mode 0600
/// owner-public-key   32 raw bytes, Ed25519 key that verifies the allow-list; written by the app
/// allow-list.json    SignedPeerAllowList, verified and persisted by the agent
/// inbox/<peer>/      sealed batches from `peer` waiting for the app (applied at next unlock)
/// outbox/<peer>/     sealed batches the app published for `peer`
/// ```
/// `<peer>` is the lower-case hex of the peer's static public key. The agent never holds a key that opens a batch.
public struct AgentStorage: Sendable {
    public let root: URL
    public var identityURL: URL { root.appendingPathComponent("agent-identity") }
    public var ownerKeyURL: URL { root.appendingPathComponent("owner-public-key") }
    public var allowListURL: URL { root.appendingPathComponent("allow-list.json") }
    public var inboxURL: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var outboxURL: URL { root.appendingPathComponent("outbox", isDirectory: true) }

    /// - Parameter groupContainer: the app-group container directory (or any directory in tests).
    public init(groupContainer: URL) {
        self.root = groupContainer.appendingPathComponent("Sync", isDirectory: true)
    }

    /// The container of `AgentConstants.appGroup`, or `nil` when the process lacks the entitlement.
    public static func groupContainerURL(identifier: String = AgentConstants.appGroup) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static func appGroup() throws -> AgentStorage {
        guard let url = groupContainerURL() else { throw AgentError.groupContainerUnavailable }
        return AgentStorage(groupContainer: url)
    }

    /// Whether this process can create the `Sync` directory. `false` in ad-hoc signed (`Debug-Unsigned`) builds: the group
    /// container path resolves, but a team-prefixed group needs a signature that carries the Team ID, so every write fails with
    /// EPERM (measured). The app disables "Sync over Tailscale" with an explanation in that case, like Touch ID.
    public func isWritable() -> Bool { (try? ensureRoot()) != nil }

    func ensureRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw AgentError.io("cannot create \(root.path): \(error.localizedDescription)")
        }
    }

    // MARK: Identity

    /// Loads the agent's Noise static key, creating it on first run. A present but malformed file is an error: silently
    /// replacing it would break every peer's pin.
    public func loadOrCreateIdentity() throws -> Curve25519.KeyAgreement.PrivateKey {
        try ensureRoot()
        if let data = try? Data(contentsOf: identityURL) {
            guard data.count == 32, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
                throw AgentError.corruptIdentity
            }
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try Self.writeAtomically(key.rawRepresentation, to: identityURL)
        return key
    }

    // MARK: Owner key

    public func readOwnerPublicKey() -> Data? {
        guard let data = try? Data(contentsOf: ownerKeyURL), data.count == 32 else { return nil }
        return data
    }

    /// Called by the app (same container) once it has an owner signing key.
    public func writeOwnerPublicKey(_ key: Data) throws {
        guard key.count == 32 else { throw PeerAllowListError.invalidKey }
        try ensureRoot()
        try Self.writeAtomically(key, to: ownerKeyURL)
    }

    // MARK: Allow-list

    /// The persisted allow-list, verified again against the owner key (a list that no longer verifies is ignored).
    func loadAllowList() -> (list: PeerAllowList, signed: SignedPeerAllowList)? {
        guard let owner = readOwnerPublicKey(), let data = try? Data(contentsOf: allowListURL),
              let signed = try? SignedPeerAllowList(decoding: data), let list = try? signed.verify(ownerPublicKey: owner)
        else { return nil }
        return (list, signed)
    }

    func persistAllowList(_ signed: SignedPeerAllowList) throws {
        try ensureRoot()
        try Self.writeAtomically(try signed.encoded(), to: allowListURL)
    }

    // MARK: Files

    /// Temp file in the same directory, `fsync`, `rename`; mode 0600.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw AgentError.io("open: \(String(cString: strerror(errno)))") }
        var closed = false
        defer {
            if !closed { close(fd) }
            if !closed || access(temp.path, F_OK) == 0 { unlink(temp.path) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentError.io("write: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw AgentError.io("fsync: \(String(cString: strerror(errno)))") }
        closed = true
        guard close(fd) == 0 else { throw AgentError.io("close: \(String(cString: strerror(errno)))") }
        guard rename(temp.path, url.path) == 0 else { throw AgentError.io("rename: \(String(cString: strerror(errno)))") }
    }
}
