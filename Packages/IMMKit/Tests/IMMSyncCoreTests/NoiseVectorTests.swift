import CryptoKit
import Foundation
import Testing

@testable import IMMSyncCore

/// Official Noise vectors (cacophony and snow; see `Vectors/README.txt`), run end to end for every
/// `25519_ChaChaPoly_SHA256` vector whose pattern this implementation supports (fundamental patterns and `pskN`).
/// Both sides are driven from the vector's keys; every handshake and transport ciphertext and the handshake hash
/// are compared byte for byte.
struct NoiseVector: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let payload: String
        let ciphertext: String
    }

    let protocol_name: String
    let init_prologue: String
    let init_psks: [String]?
    let init_static: String?
    let init_remote_static: String?
    let init_ephemeral: String
    let resp_prologue: String
    let resp_psks: [String]?
    let resp_static: String?
    let resp_remote_static: String?
    let resp_ephemeral: String?
    let handshake_hash: String?
    let messages: [Message]

    struct File: Decodable { let vectors: [NoiseVector] }

    static func load(_ name: String) -> [NoiseVector] {
        let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Vectors")!
        return try! JSONDecoder().decode(File.self, from: Data(contentsOf: url)).vectors
    }

    var isSupported: Bool { (try? NoisePattern(protocolName: protocol_name)) != nil }
}

struct NoiseVectorCase: Sendable, CustomTestStringConvertible {
    let file: String
    let index: Int
    let vector: NoiseVector
    var testDescription: String { "\(file)#\(index) \(vector.protocol_name)" }

    static func all(_ file: String) -> [NoiseVectorCase] {
        NoiseVector.load(file).enumerated().compactMap { index, vector in
            vector.isSupported ? NoiseVectorCase(file: file, index: index, vector: vector) : nil
        }
    }
}

private func key(_ hex: String?) -> Curve25519.KeyAgreement.PrivateKey? {
    hex.map { try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: $0)) }
}

func runVector(_ v: NoiseVector) throws {
    let pattern = try NoisePattern(protocolName: v.protocol_name)
    var initiator = try NoiseHandshake(
        pattern: pattern, role: .initiator, prologue: Data(hex: v.init_prologue), localStatic: key(v.init_static),
        remoteStatic: v.init_remote_static.map { Data(hex: $0) }, psks: (v.init_psks ?? []).map { Data(hex: $0) },
        ephemeral: key(v.init_ephemeral))
    var responder = try NoiseHandshake(
        pattern: pattern, role: .responder, prologue: Data(hex: v.resp_prologue), localStatic: key(v.resp_static),
        remoteStatic: v.resp_remote_static.map { Data(hex: $0) }, psks: (v.resp_psks ?? []).map { Data(hex: $0) },
        ephemeral: key(v.resp_ephemeral))

    let handshakeMessages = pattern.messages.count
    #expect(v.messages.count > handshakeMessages)
    for index in 0..<handshakeMessages {
        let message = v.messages[index]
        let initiatorWrites = index % 2 == 0
        let ciphertext: Data
        let received: Data
        if initiatorWrites {
            ciphertext = try initiator.writeMessage(payload: Data(hex: message.payload))
            received = try responder.readMessage(ciphertext)
        } else {
            ciphertext = try responder.writeMessage(payload: Data(hex: message.payload))
            received = try initiator.readMessage(ciphertext)
        }
        #expect(ciphertext.hex == message.ciphertext, "handshake message \(index) ciphertext")
        #expect(received.hex == message.payload, "handshake message \(index) payload")
    }
    #expect(initiator.isComplete && responder.isComplete)
    if let expected = v.handshake_hash {
        #expect(initiator.handshakeHash.hex == expected, "initiator handshake hash")
        #expect(responder.handshakeHash.hex == expected, "responder handshake hash")
    }
    #expect(initiator.handshakeHash == responder.handshakeHash)

    var initiatorTransport = try initiator.split()
    var responderTransport = try responder.split()
    for index in handshakeMessages..<v.messages.count {
        let message = v.messages[index]
        // One-way patterns send everything initiator → responder; otherwise senders alternate with the index.
        let initiatorSends = pattern.isOneWay || index % 2 == 0
        let ciphertext: Data
        let received: Data
        if initiatorSends {
            ciphertext = try initiatorTransport.encrypt(Data(hex: message.payload))
            received = try responderTransport.decrypt(ciphertext)
        } else {
            ciphertext = try responderTransport.encrypt(Data(hex: message.payload))
            received = try initiatorTransport.decrypt(ciphertext)
        }
        #expect(ciphertext.hex == message.ciphertext, "transport message \(index) ciphertext")
        #expect(received.hex == message.payload, "transport message \(index) payload")
    }
}

struct NoiseVectorTests {
    @Test("cacophony vector", arguments: NoiseVectorCase.all("cacophony"))
    func cacophony(_ testCase: NoiseVectorCase) throws {
        try runVector(testCase.vector)
    }

    @Test("snow vector", arguments: NoiseVectorCase.all("snow"))
    func snow(_ testCase: NoiseVectorCase) throws {
        try runVector(testCase.vector)
    }

    @Test func coverageMatchesTheOfficialFiles() {
        // 944 / 408 vectors in the files; the 25519_ChaChaPoly_SHA256 ones with fundamental or pskN patterns
        // (deferred and fallback patterns, other suites are out of scope).
        let cacophony = NoiseVectorCase.all("cacophony")
        let snow = NoiseVectorCase.all("snow")
        #expect(NoiseVector.load("cacophony").count == 944)
        #expect(NoiseVector.load("snow").count == 408)
        #expect(cacophony.count >= 36)
        #expect(snow.count >= 28)
        for name in ["Noise_XXpsk3_25519_ChaChaPoly_SHA256", "Noise_IK_25519_ChaChaPoly_SHA256", "Noise_XX_25519_ChaChaPoly_SHA256", "Noise_NN_25519_ChaChaPoly_SHA256"] {
            #expect(cacophony.contains { $0.vector.protocol_name == name }, "missing \(name) in cacophony")
        }
        #expect(snow.contains { $0.vector.protocol_name == "Noise_IK_25519_ChaChaPoly_SHA256" })
    }
}
