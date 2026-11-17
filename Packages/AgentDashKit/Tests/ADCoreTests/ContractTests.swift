import Foundation
import Testing
import ADCore

@Test("D-4: total includes all cache, reasoning remains a subset of output")
func cacheInclusiveTotals() {
    let tokens = TokenCounts(inputFresh: 11, cacheRead: 23, cacheWrite: 5,
                             cacheWrite1h: 7, output: 13, reasoning: 3)
    #expect(tokens.total == 59)
    #expect(tokens.input == 46)
}

@Test("FR-SRC-1: source access and environment rules round trip without I/O")
func sourceRoundTrip() throws {
    let source = Source(agent: .codex, label: "Synthetic", rootURL: URL(fileURLWithPath: "/synthetic/codex"),
                        environment: "Test", pathMappings: [.init(from: "/workspace", to: "/synthetic")],
                        environmentRules: [.init(field: "model_provider", equals: "synthetic", environment: "Test")],
                        access: .bookmark(Data([1, 2, 3])))
    #expect(try JSONDecoder().decode(Source.self, from: JSONEncoder().encode(source)) == source)
}

@Test("ADP-5: checkpoints preserve integer byte offsets and UTC milliseconds")
func checkpointRoundTrip() throws {
    let value = Checkpoint(inode: 42, size: 1024, offset: 1000, parserVersion: 1,
                           sequence: 6, previousTimestamp: 1_700_000_000_123)
    #expect(try JSONDecoder().decode(Checkpoint.self, from: JSONEncoder().encode(value)) == value)
}
