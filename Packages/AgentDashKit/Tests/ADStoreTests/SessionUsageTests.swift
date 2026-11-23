import ADCore
import GRDB
@testable import ADStore
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
        .tokens(.init(session: another, timestamp: 1, model: "later", counts: .init(output: 2),
                      dedupeKey: "facts:other-unpriced")),
    ])
    var facts = store.sessionUsageUpdates(in: key).makeAsyncIterator()
    var library = store.indexedSessionUpdates().makeAsyncIterator()
    let partial = try #require(try await facts.next() ?? nil)
    #expect(partial.turns == 1 && partial.totals.counts.total == 51)
    #expect(partial.totals.costMicroUSD == 100 && partial.totals.unpricedTokens == 1 && partial.hasApproximateQuote)
    let before = try #require(try await library.next())
    #expect(before.first { $0.id == key }?.usage == partial.summary)
    let unrelatedPartial = try #require(before.first { $0.id == another }?.usage?.totals)
    #expect(unrelatedPartial.counts.total == 902 && unrelatedPartial.unpricedTokens == 2)
    #expect(unrelatedPartial.costMicroUSD == 1800)
    var chart = store.sessionTokenChartUpdates(in: key).makeAsyncIterator()
    let buckets = try #require(try await chart.next())
    #expect(buckets.map(\.callTokens) == [45, 0])
    #expect(buckets.map(\.coarseTokens) == [0, 5])
    let sweep = try store.activatePricing { input, original in
        if input.model == "later" {
            return .init(microUSD: 4, status: input.counts.total > 1 ? .approximate : .priced, basis: basis)
        }
        return quote(input, original)
    }
    _ = try store.backfillUnpriced(sweep)
    let full = try #require(try await facts.next() ?? nil)
    #expect(full.totals.counts == partial.totals.counts)
    #expect(full.totals.costMicroUSD == 104 && full.totals.unpricedTokens == 0)
    let after = try #require(try await library.next())
    #expect(after.map(\.id) == before.map(\.id))
    #expect(after.first { $0.id == key }?.usage == full.summary)
    let unrelatedFull = try #require(after.first { $0.id == another }?.usage)
    #expect(unrelatedFull.totals.counts == unrelatedPartial.counts && unrelatedFull.totals.unpricedTokens == 0)
    #expect(unrelatedFull.totals.costMicroUSD == 1804 && unrelatedFull.hasApproximateQuote)
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

@Test("§11.2: replay transfers stored usage to its verified owner; removal leaves no row usage",
      .timeLimit(.minutes(1)))
func sessionUsageFollowsReplayAndRemoval() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-move-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic", rootURL: directory))
    let copy = SessionKey(agent: .claudeCode, nativeID: "synthetic-copy")
    let original = SessionKey(agent: .claudeCode, nativeID: "synthetic-original")
    let basis = TokenRateBasis(reference: "synthetic", bytes: Data([2]))
    _ = try store.activatePricing { input, _ in
        .init(microUSD: input.counts.total * 3, status: .approximate, basis: basis)
    }
    try store.write([
        .session(.init(key: copy, sourceID: source, environment: "Synthetic")),
        .session(.init(key: original, sourceID: source, environment: "Synthetic")),
        .tokens(.init(session: copy, timestamp: 1, model: "fixture", counts: .init(cacheRead: 5, output: 2),
                      dedupeKey: "copied-fact")),
        .tokens(.init(session: original, timestamp: 2, model: "fixture", counts: .init(inputFresh: 3),
                      dedupeKey: "original-fact")),
    ])
    var library = store.indexedSessionUpdates().makeAsyncIterator()
    let first = try #require(try await library.next())
    #expect(first.first { $0.id == copy }?.usage?.totals.costMicroUSD == 21)
    #expect(first.first { $0.id == original }?.usage?.totals.counts.total == 3)

    let corrected: NormalizedRecord = .tokens(.init(session: original, timestamp: 1, model: "fixture",
        counts: .init(cacheRead: 5, output: 4), dedupeKey: "copied-fact", recordedOwnership: .original))
    try store.write([corrected, corrected])
    let moved = try #require(try await library.next())
    #expect(moved.first { $0.id == copy }?.usage?.totals == .empty)
    let owner = try #require(moved.first { $0.id == original }?.usage)
    #expect(owner.totals.counts.total == 12 && owner.totals.costMicroUSD == 36)
    #expect(owner.totals.records == 2 && owner.hasApproximateQuote)

    try await store.databasePool.write { db in
        try db.execute(sql: "DELETE FROM token_events WHERE dedupe_key=?", arguments: ["copied-fact"])
    }
    let reduced = try #require(try await library.next())
    #expect(reduced.first { $0.id == original }?.usage?.totals.costMicroUSD == 9)
    try await store.databasePool.write { db in
        try db.execute(sql: "DELETE FROM sessions WHERE native_id=?", arguments: [original.nativeID])
    }
    let remaining = try #require(try await library.next())
    #expect(remaining.map(\.id) == [copy])
    try await store.databasePool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM session_usage_rollup") == 0)
        #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
}
