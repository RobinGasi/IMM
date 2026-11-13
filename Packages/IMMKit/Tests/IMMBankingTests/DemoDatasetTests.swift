import Foundation
import Testing
import IMMLedger
@testable import IMMBanking

@Suite("Demo data set")
struct DemoDatasetTests {
    @Test func buildIsDeterministic() {
        let first = DemoDataset.encode(DemoDataset.build())
        let second = DemoDataset.encode(DemoDataset.build())
        #expect(!first.isEmpty)
        #expect(first == second)
        #expect(DemoDataset.build() == DemoDataset.build())
    }

    @Test func encodeDecodeRoundTrip() throws {
        let data = DemoDataset.encode(demoBank)
        let decoded = try DemoDataset.decode(data)
        #expect(decoded == demoBank)
        #expect(DemoDataset.encode(decoded) == data)
    }

    /// With `IMM_WRITE_DEMO_BANK=<path>` writes the canonical JSON there; otherwise the bundled resource must match.
    @Test func demoBankResourceMatchesBuilder() throws {
        let expected = DemoDataset.encode(DemoDataset.build())
        if let path = ProcessInfo.processInfo.environment["IMM_WRITE_DEMO_BANK"], !path.isEmpty {
            try expected.write(to: URL(fileURLWithPath: path), options: .atomic)
            return
        }
        let url = try #require(Bundle.module.url(forResource: "DemoBank", withExtension: "json"))
        let bundled = try Data(contentsOf: url)
        #expect(bundled == expected, "Resources/DemoBank.json is stale; regenerate with IMM_WRITE_DEMO_BANK=<path>")
    }

    @Test func loadReadsTheBundledResource() throws {
        if ProcessInfo.processInfo.environment["IMM_WRITE_DEMO_BANK"]?.isEmpty == false { return }
        let loaded = try DemoDataset.load()
        #expect(loaded == demoBank)
    }

    @Test func transactionCountIsPlausible() {
        let count = demoBank.snapshot.transactions.count
        #expect(count > 1_000 && count < 4_000, "\(count)")
    }
}
