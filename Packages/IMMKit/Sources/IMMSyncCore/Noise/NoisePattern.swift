import Foundation

/// Tokens of the Noise handshake pattern language (spec §7).
enum NoiseToken: Sendable, Equatable {
    case e, s, ee, es, se, ss, psk
}

/// A handshake pattern: pre-messages and the alternating message patterns, initiator first.
/// Supported: the fifteen fundamental patterns plus `pskN` modifiers (spec §7.1–7.5, §9).
/// Deferred (`NK1`, `X1N`, …) and `fallback` patterns are not implemented.
public struct NoisePattern: Sendable, Equatable {
    /// Pattern name as used in the protocol name, e.g. `XXpsk3`.
    public let name: String
    let initiatorPreMessage: [NoiseToken]
    let responderPreMessage: [NoiseToken]
    /// Message `i` is written by the initiator when `i` is even; for one-way patterns there is exactly one.
    let messages: [[NoiseToken]]
    /// Number of `psk` tokens; `HandshakeState` needs this many PSKs, in order of appearance.
    public let pskCount: Int

    public var usesPSK: Bool { pskCount > 0 }
    /// One-way patterns (`N`, `K`, `X`): all transport messages go initiator → responder.
    public var isOneWay: Bool { messages.count == 1 }
    public var protocolName: String { "Noise_\(name)_25519_ChaChaPoly_SHA256" }

    /// `Noise_XXpsk3_25519_ChaChaPoly_SHA256`: pairing (`-> e; <- e, ee, s, es; -> s, se, psk`).
    public static let xxPSK3 = try! NoisePattern(name: "XXpsk3")
    /// `Noise_IK_25519_ChaChaPoly_SHA256`: reconnect with pinned keys (`<- s; ...; -> e, es, s, ss; <- e, ee, se`).
    public static let ik = try! NoisePattern(name: "IK")
    public static let xx = try! NoisePattern(name: "XX")

    /// Parses `Noise_<pattern>_25519_ChaChaPoly_SHA256`.
    public init(protocolName: String) throws {
        let parts = protocolName.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "Noise", parts[2] == "25519", parts[3] == "ChaChaPoly", parts[4] == "SHA256" else {
            throw NoiseError.unsupportedProtocol(protocolName)
        }
        try self.init(name: String(parts[1]))
    }

    /// Parses a pattern name such as `IK`, `XX` or `XXpsk3` (`psk0+psk2` for several PSKs).
    public init(name: String) throws {
        let base: String
        let modifiers: [String]
        if let range = name.range(of: "psk") {
            base = String(name[..<range.lowerBound])
            modifiers = name[range.lowerBound...].split(separator: "+").map(String.init)
        } else {
            base = name
            modifiers = []
        }
        guard let fundamental = Self.fundamental[base] else { throw NoiseError.unsupportedProtocol(name) }
        var messages = fundamental.messages
        var positions: [Int] = []
        for modifier in modifiers {
            guard modifier.hasPrefix("psk"), let index = Int(modifier.dropFirst(3)), index >= 0, index <= messages.count else {
                throw NoiseError.unsupportedProtocol(name)
            }
            positions.append(index)
        }
        // Several modifiers on the same message keep their written order.
        for (order, index) in positions.enumerated() {
            if index == 0 {
                // psk0 goes to the front; later psk0s (not meaningful) still precede earlier ones' successors.
                let leading = positions[..<order].filter { $0 == 0 }.count
                messages[0].insert(.psk, at: leading)
            } else {
                messages[index - 1].append(.psk)
            }
        }
        self.name = name
        self.initiatorPreMessage = fundamental.initiatorPre
        self.responderPreMessage = fundamental.responderPre
        self.messages = messages
        self.pskCount = positions.count
    }

    private struct Fundamental {
        let initiatorPre: [NoiseToken]
        let responderPre: [NoiseToken]
        let messages: [[NoiseToken]]
    }

    private static let fundamental: [String: Fundamental] = [
        "N": Fundamental(initiatorPre: [], responderPre: [.s], messages: [[.e, .es]]),
        "K": Fundamental(initiatorPre: [.s], responderPre: [.s], messages: [[.e, .es, .ss]]),
        "X": Fundamental(initiatorPre: [], responderPre: [.s], messages: [[.e, .es, .s, .ss]]),
        "NN": Fundamental(initiatorPre: [], responderPre: [], messages: [[.e], [.e, .ee]]),
        "KN": Fundamental(initiatorPre: [.s], responderPre: [], messages: [[.e], [.e, .ee, .se]]),
        "NK": Fundamental(initiatorPre: [], responderPre: [.s], messages: [[.e, .es], [.e, .ee]]),
        "KK": Fundamental(initiatorPre: [.s], responderPre: [.s], messages: [[.e, .es, .ss], [.e, .ee, .se]]),
        "NX": Fundamental(initiatorPre: [], responderPre: [], messages: [[.e], [.e, .ee, .s, .es]]),
        "KX": Fundamental(initiatorPre: [.s], responderPre: [], messages: [[.e], [.e, .ee, .se, .s, .es]]),
        "XN": Fundamental(initiatorPre: [], responderPre: [], messages: [[.e], [.e, .ee], [.s, .se]]),
        "IN": Fundamental(initiatorPre: [], responderPre: [], messages: [[.e, .s], [.e, .ee, .se]]),
        "XK": Fundamental(initiatorPre: [], responderPre: [.s], messages: [[.e, .es], [.e, .ee], [.s, .se]]),
        "IK": Fundamental(initiatorPre: [], responderPre: [.s], messages: [[.e, .es, .s, .ss], [.e, .ee, .se]]),
        "XX": Fundamental(initiatorPre: [], responderPre: [], messages: [[.e], [.e, .ee, .s, .es], [.s, .se]]),
        "IX": Fundamental(initiatorPre: [], responderPre: [], messages: [[.e, .s], [.e, .ee, .se, .s, .es]]),
    ]
}
