import Testing
@testable import IMMFinTS

@Suite struct StateStoreTests {
    @Test func keepsValuesPerLogin() {
        let store = InMemoryFinTSStateStore()
        store.setSystemID("SYS1", bankCode: "12030000", loginName: "a")
        store.setTANMethod("921", bankCode: "12030000", loginName: "a")
        #expect(store.systemID(bankCode: "12030000", loginName: "a") == "SYS1")
        #expect(store.systemID(bankCode: "12030000", loginName: "b") == nil)
        #expect(store.tanMethod(bankCode: "12030000", loginName: "a") == "921")
    }
}
