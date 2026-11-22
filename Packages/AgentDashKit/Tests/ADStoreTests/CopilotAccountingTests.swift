import ADCore
import Foundation
import GRDB
import Testing
@testable import ADStore

@Test("ADP-CP: an earlier actual call replaces checkpoint volume atomically and keeps its timestamp")
func reconcileCopilotLateCall() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-copilot-account-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let basis = TokenRateBasis(reference: "synthetic-original", bytes: Data([2]))
    _ = try store.activatePricing { input, original in
        .init(microUSD: input.counts.total * 2,
              status: input.precision == .call ? .priced : .approximate, basis: original ?? basis)
    }
    let sourceID = try store.upsertSource(.init(agent: .copilot, label: "Synthetic", rootURL: temp))
    let key = SessionKey(agent: .copilot, nativeID: "synthetic-accounting")
    let sample = CopilotUsageSnapshot(session: key, model: "model", sequence: 10, timestamp: 500,
                                      counts: .init(inputFresh: 20, cacheRead: 8, cacheWrite: 2, output: 9, reasoning: 3),
                                      dedupeKey: "synthetic-cumulative")
    try store.write([.session(.init(key: key, sourceID: sourceID, environment: "Synthetic")), .copilotUsageSnapshot(sample)])
    let replacement = TokenRateBasis(reference: "synthetic-current", bytes: Data([3]))
    _ = try store.activatePricing { input, original in
        let saved = original ?? replacement
        return .init(microUSD: input.counts.total * Int64(saved.bytes.first ?? 0),
                     status: input.precision == .call ? .priced : .approximate, basis: saved)
    }
    let call = TokenEvent(session: key, timestamp: 200, model: "model",
                          counts: .init(inputFresh: 11, cacheRead: 4, cacheWrite: 1, output: 5, reasoning: 2),
                          dedupeKey: "synthetic-earlier-call", sourceSequence: 4)
    try store.write([.tokens(call), .tokens(call)])

    try store.databasePool.read { db throws -> Void in
        let rows = try Row.fetchAll(db, sql: "SELECT precision,ts,input_fresh,output,cache_read,cache_write,reasoning,cost_micro_usd,price_ref FROM token_events ORDER BY ts")
        #expect(rows.count == 2)
        let actual = try #require(rows.first)
        let coarse = try #require(rows.last)
        for (field, expected) in [("input_fresh",20), ("cache_read",8), ("cache_write",2), ("output",9), ("reasoning",3)] {
            #expect(rows.reduce(0) { $0 + ($1[field] as Int) } == expected)
        }
        #expect(actual["precision"] == "call" && actual["ts"] == 200 && actual["input_fresh"] == 11 && actual["output"] == 5)
        #expect(coarse["precision"] == "checkpoint" && coarse["ts"] == 500 && coarse["input_fresh"] == 9 && coarse["output"] == 4)
        #expect((actual["cost_micro_usd"] as Int) == 63 && (actual["price_ref"] as String) == replacement.reference)
        #expect((coarse["cost_micro_usd"] as Int) == 36 && (coarse["price_ref"] as String) == basis.reference)
    }
}
