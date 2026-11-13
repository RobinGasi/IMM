import Foundation
import Security
import Testing
@testable import IMMVault

@Suite struct KeychainTests {
    @Test func pinStoreRoundTrip() throws {
        let store = KeychainPINStore(service: "dev.gasi.imm.tests.pin.\(UUID().uuidString)")
        let vaultID = UUID()
        let otherVault = UUID()
        let loginA = UUID()
        let loginB = UUID()
        defer {
            store.removeAll(vaultID: vaultID)
            store.removeAll(vaultID: otherVault)
        }

        do {
            try store.store(pin: "123456", vaultID: vaultID, loginID: loginA)
        } catch PINStoreError.keychain(let status) {
            // Keychain unavailable to the test process (no entitlement / no UI allowed): nothing to verify.
            print("KeychainTests: skipped, keychain not usable in this environment (OSStatus \(status)).")
            return
        }

        #expect(store.pin(vaultID: vaultID, loginID: loginA) == "123456")
        #expect(store.count(vaultID: vaultID) == 1)

        try store.store(pin: "654321", vaultID: vaultID, loginID: loginA)
        #expect(store.pin(vaultID: vaultID, loginID: loginA) == "654321")
        try store.store(pin: "1111", vaultID: vaultID, loginID: loginB)
        try store.store(pin: "2222", vaultID: otherVault, loginID: loginA)
        #expect(store.count(vaultID: vaultID) == 2)
        #expect(store.count(vaultID: otherVault) == 1)
        #expect(store.pin(vaultID: vaultID, loginID: UUID()) == nil)

        store.removeAll(vaultID: vaultID)
        #expect(store.count(vaultID: vaultID) == 0)
        #expect(store.pin(vaultID: vaultID, loginID: loginA) == nil)
        #expect(store.count(vaultID: otherVault) == 1)
    }

    @Test func biometricStoreReportsWithoutPrompting() throws {
        let suite = "dev.gasi.imm.tests.bio.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeychainBiometricKeyStore(defaults: defaults)

        // Any availability value is valid; the call must not crash or prompt.
        let availability = store.availability()
        #expect([.available, .noSensor, .notEnrolled, .missingEntitlement].contains(availability))

        let vaultID = UUID()
        #expect(!store.contains(vaultID: vaultID))
        #expect(!store.isInvalidated(vaultID: vaultID))
        store.remove(vaultID: vaultID)
    }
}
