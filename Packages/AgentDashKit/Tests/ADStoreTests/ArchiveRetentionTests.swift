import ADCore
import ADPricing
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("FR-STO-1: archive expiry keeps exact partial ranges and prices through rebuild, with no replay double-counting")
func expiredArchivePreservesExactUsageAndBlocksReplay() throws {
    let box = try RetentionFixture()
    defer { box.remove() }
    let old = try box.seed("expired", path: "/workspace/expired", ts: box.stamp, deleted: box.stamp)
    let active = try box.seed("active", path: "/workspace/active", ts: box.stamp + 100, deleted: nil)
    let young = try box.seed("young", path: "/workspace/young", ts: box.stamp + 200, deleted: box.now - 60_000)
    let range = try UsageRange(lowerBound: box.stamp - 2, upperBound: box.stamp + 1)
    let tiny = try UsageWindow.make(.custom, now: box.now, custom: range, timeZone: .gmt)
    let minute = try UsageWindow.make(.hour, now: box.stamp + 60_000, timeZone: .gmt)
    let prior = try box.store.usage(window: tiny, metric: .cost)
    let before = try box.store.usage(window: minute)
    #expect(prior.totals.counts.total == 9 && prior.totals.costMicroUSD == 19)
    #expect(prior.cacheSavings?.microUSD == 9 && prior.peak?.value == 19)
    #expect(before.totals.counts.total == 27)
    #expect(try box.store.archiveRetention() == .forever)
    #expect(try box.store.expireArchivedSessions(now: box.now, hostHome: nil) == 0)
    #expect(try box.store.setArchiveRetention(.quarterYear, now: box.now, hostHome: nil) == 1)
    #expect(try box.store.events(in: old).isEmpty)
    #expect(try box.store.events(in: active).count == 1 && box.store.events(in: young).count == 1)
    #expect(try box.store.searchIndex(SearchQuery.parse("expired"), scope: box.scope).matchCount == 0)
    #expect(try box.store.firstUsageTimestamp() == box.stamp)
    let all = try box.store.usageChart(period: .all, now: box.now, timeZone: .gmt)
    #expect(all.window.range.lowerBound == box.stamp)
    let retained = try box.store.usage(window: tiny, metric: .cost)
    #expect(retained.totals == prior.totals && retained.peak == prior.peak && retained.cacheSavings == prior.cacheSavings)
    #expect(retained.chart.points == prior.chart.points && retained.sessionCount == 0)
    #expect(try box.store.usage(window: minute).totals == before.totals)

    let stored = try AgentStore(databaseURL: box.index)
    #expect(try stored.archiveRetention() == .quarterYear)
    // A retained key may reappear as a copied response under another owner.
    try stored.write(box.records(for: old, path: "/workspace/expired", ts: box.stamp))
    try stored.write([.tokens(box.token(for: active, ts: box.stamp, dedupe: old.nativeID))])
    #expect(try stored.events(in: old).isEmpty)
    #expect(try stored.usage(window: minute).totals == before.totals)
    _ = try stored.rebuildIndex(scoring: .init(counts: { _ in [:] }, top: { _, _, _ in [] }))
    #expect(try stored.usage(window: tiny, metric: .cost).totals == prior.totals)
    #expect(try stored.usage(window: minute).totals == before.totals)
    #expect(try stored.expireArchivedSessions(now: box.now, hostHome: nil) == 0)
}

@Test("FR-STO-1: a retained-only project can be explicitly cleared without touching the other aggregate",
      .timeLimit(.minutes(1)))
func retainedOnlyProjectClearHasIndependentAttribution() async throws {
    let box = try RetentionFixture()
    defer { box.remove() }
    _ = try box.seed("former", path: "/workspace/removed", ts: box.stamp, deleted: box.stamp)
    _ = try box.seed("other", path: "/workspace/keep", ts: box.stamp, deleted: box.stamp)
    #expect(try box.store.setArchiveRetention(.halfYear, now: box.now, hostHome: nil) == 0)
    #expect(try box.store.setArchiveRetention(.quarterYear, now: box.now, hostHome: nil) == 2)
    var choices = box.store.indexClearChoices(hostHome: nil).makeAsyncIterator()
    let options = try #require(try await choices.next())
    let target = try #require(options.first { $0.location == "/mapped/removed" })
    let plan = try box.store.prepareIndexClear(target.id, hostHome: nil)
    #expect(plan.sessionCount == 0 && plan.retainedRecordCount == 1)
    _ = try box.store.clearIndex(plan, hostHome: nil)
    let hour = try UsageWindow.make(.hour, now: box.stamp + 60_000, timeZone: .gmt)
    #expect(try box.store.usage(window: hour).totals.counts.total == 9)
    let result = try box.store.replaceSessionExclusions(["/mapped/keep/**"], hostHome: nil)
    #expect(result.removedSessions == 0)
    #expect(try box.store.usage(window: hour).totals.counts.total == 0)
}

private struct RetentionFixture {
    let directory: URL
    let index: URL
    let store: AgentStore
    let sourceID: Int64
    let stamp: Int64 = 1_770_000_012_345
    var now: Int64 { stamp + 100 * 86_400_000 }
    var scope: IndexedSearchScope { .init(now: now, timeZone: .gmt) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        index = directory.appendingPathComponent("index.sqlite")
        store = try AgentStore(databaseURL: index)
        sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic retention", rootURL: directory,
                                               pathMappings: [.init(from: "/workspace", to: "/mapped")]))
        let table = try PriceTable.decode(Data(#"{"schemaVersion":1,"currency":"USD","unit":"per_million_tokens","updatedAt":"2026-01-01","models":[{"id":"synthetic-model","vendor":"fixture","displayName":"Synthetic","prices":[{"effectiveFrom":"2020-01-01","input":4,"output":2,"cacheRead":1,"source":"https://example.invalid/","checkedAt":"2020-01-01"}]}]}"#.utf8))
        _ = try store.activatePricing(TokenQuoteEngine.make(table: table))
    }

    func token(for key: SessionKey, ts: Int64, dedupe: String) -> TokenEvent {
        .init(session: key, timestamp: ts, model: "synthetic-model", counts: .init(inputFresh: 2, cacheRead: 3, output: 4),
              dedupeKey: "synthetic:retention:usage:" + dedupe)
    }

    func records(for key: SessionKey, path: String, ts: Int64) -> [NormalizedRecord] {
        [.session(.init(key: key, sourceID: sourceID, environment: "Synthetic", cwd: path, lastEventAt: ts)),
         .event(.init(session: key, sequence: 0, timestamp: ts, kind: .user, text: "synthetic " + key.nativeID,
                      dedupeKey: "synthetic:retention:event:" + key.nativeID)),
         .tokens(token(for: key, ts: ts, dedupe: key.nativeID))]
    }

    func seed(_ id: String, path: String, ts: Int64, deleted: Int64?) throws -> SessionKey {
        let key = SessionKey(agent: .codex, nativeID: id)
        try store.write(records(for: key, path: path, ts: ts))
        if let deleted {
            try store.databasePool.write { db in
                try db.execute(sql: "UPDATE sessions SET source_deleted_at=? WHERE native_id=?", arguments: [deleted, id])
            }
        }
        return key
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
