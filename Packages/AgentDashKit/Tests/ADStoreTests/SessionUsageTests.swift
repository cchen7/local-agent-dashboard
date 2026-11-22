import ADCore
import ADStore
import Foundation
import Testing

@Test("FR-TK / FR-COST: session totals include cache, distinguish partial quotes and update after backfill")
func selectedSessionUsageTracksItsStoredQuotes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-usage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: directory))
    let key = SessionKey(agent: .codex, nativeID: "session-facts")
    let another = SessionKey(agent: .codex, nativeID: "session-facts-other")
    let basis = TokenRateBasis(reference: "synthetic", bytes: Data([1]))
    let quote: TokenQuoter = { input, original in
        guard input.model == "known" else { return nil }
        return TokenQuote(microUSD: input.counts.total * 2, status: input.precision == .call ? .priced : .approximate,
                          basis: original ?? basis)
    }
    _ = try store.activatePricing(quote)
    try store.write([
        .session(.init(key: key, sourceID: source, environment: "Synthetic")),
        .session(.init(key: another, sourceID: source, environment: "Synthetic")),
        .event(.init(session: key, sequence: 1, timestamp: 1, kind: .user, text: "first block", dedupeKey: "facts:first")),
        .event(.init(session: key, sequence: 1, timestamp: 1, kind: .user, text: "second block", dedupeKey: "facts:second")),
        .event(.init(session: key, sequence: 2, timestamp: 2, kind: .assistant, text: "reply", dedupeKey: "facts:reply")),
        .tokens(.init(session: key, timestamp: 1, model: "known",
                      counts: .init(inputFresh: 10, cacheRead: 20, cacheWrite: 5, cacheWrite1h: 3, output: 7, reasoning: 2),
                      dedupeKey: "facts:call")),
        .tokens(.init(session: key, timestamp: 61_000, model: "known",
                      counts: .init(inputFresh: 5), precision: .checkpoint, dedupeKey: "facts:coarse")),
        .tokens(.init(session: key, timestamp: 0, model: "later",
                      counts: .init(inputFresh: 1), dedupeKey: "facts:untimed")),
        .tokens(.init(session: another, timestamp: 1, model: "known", counts: .init(inputFresh: 900),
                      dedupeKey: "facts:other")),
    ])
    var facts = store.sessionUsageUpdates(in: key).makeAsyncIterator()
    let partial = try #require(try await facts.next() ?? nil)
    #expect(partial.turns == 1 && partial.totals.counts.total == 51)
    #expect(partial.totals.costMicroUSD == 100 && partial.totals.unpricedTokens == 1 && partial.hasApproximateQuote)
    var chart = store.sessionTokenChartUpdates(in: key).makeAsyncIterator()
    let buckets = try #require(try await chart.next())
    #expect(buckets.map(\.callTokens) == [45, 0])
    #expect(buckets.map(\.coarseTokens) == [0, 5])
    let sweep = try store.activatePricing { input, original in
        if input.model == "later" { return .init(microUSD: 4, status: .priced, basis: basis) }
        return quote(input, original)
    }
    _ = try store.backfillUnpriced(sweep)
    let full = try #require(try await facts.next() ?? nil)
    #expect(full.totals.counts == partial.totals.counts)
    #expect(full.totals.costMicroUSD == 104 && full.totals.unpricedTokens == 0)
}

@Test("FR-TK: a long-running session returns at most 72 ordered chart buckets")
func sessionTokenTimelineBoundsLongSessions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-chart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let id = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic", rootURL: directory))
    let key = SessionKey(agent: .claudeCode, nativeID: "synthetic-long")
    try store.write([.session(.init(key: key, sourceID: id, environment: "Synthetic"))] + (1...200).map {
        .tokens(.init(session: key, timestamp: Int64($0) * 60_000, counts: .init(cacheRead: 2),
                      dedupeKey: "synthetic:chart:\($0)"))
    })
    var chart = store.sessionTokenChartUpdates(in: key).makeAsyncIterator()
    let points = try #require(try await chart.next())
    #expect(points.count > 1 && points.count <= 72)
    #expect(points.map(\.timestamp) == points.map(\.timestamp).sorted())
    #expect(points.reduce(0) { $0 + $1.callTokens + $1.coarseTokens } == 400)
}
