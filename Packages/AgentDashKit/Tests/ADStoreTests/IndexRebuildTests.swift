import ADCore
@testable import ADStore
import Foundation
import GRDB
import Testing

private let syntheticRebuildScoring = IndexTopicScoring(counts: { _ in [:] }, top: { _, _, _ in [] })

private func withRebuildStore(_ body: (AgentStore, Int64, SessionKey) throws -> Void) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-rebuild-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp))
    let fileID = try store.upsertFile(.init(sourceID: sourceID, relativePath: "rollout-synthetic.jsonl", role: .session), checkpoint: nil)
    let key = SessionKey(agent: .codex, nativeID: "synthetic-rebuild")
    let session = SessionRecord(key: key, sourceID: sourceID, fileID: fileID, environment: "Synthetic", cwd: "/synthetic/project")
    let checkpoint = Checkpoint(inode: 11, size: 12, offset: 12, parserVersion: 1, sequence: 3, previousTimestamp: 3_600_001)
    try store.write([
        .session(session),
        .event(.init(session: key, sequence: 0, timestamp: -1, kind: .user, text: "rebuildneedle preserved", dedupeKey: "synthetic:rebuild:e")),
        .tokens(.init(session: key, timestamp: -1, model: "synthetic",
                      counts: .init(inputFresh: 13, cacheRead: 7, output: 5), dedupeKey: "synthetic:rebuild:old")),
        .tokens(.init(session: key, timestamp: 3_600_001, model: "synthetic",
                      counts: .init(inputFresh: 3, output: 4), precision: .checkpoint, dedupeKey: "synthetic:rebuild:coarse")),
    ], fileID: fileID, checkpoint: checkpoint)
    try store.databasePool.write { db in
        try db.execute(sql: """
            UPDATE token_events SET price_status='priced',cost_micro_usd=31,cache_savings_micro_usd=-2
            WHERE dedupe_key='synthetic:rebuild:old'
            """)
        try UsageChartChanges.publish(db)
    }
    try body(store, fileID, key)
}

@Test("FR-STO-1: rebuild restores lost FTS and usage projections without rewriting records or checkpoints")
func rebuildIndexRestoresDerivedData() throws {
    try withRebuildStore { store, fileID, key in
        #expect(try store.indexStorageBytes() > 0)
        let query = try SearchQuery.parse("rebuildneedle")
        let context = IndexedSearchScope(now: 7_200_000, timeZone: .gmt)
        let range = try UsageRange(lowerBound: -3_600_000, upperBound: 7_200_000)
        let window = try UsageWindow.make(.custom, now: range.upperBound, custom: range, timeZone: .gmt)
        let originals = try store.events(in: key)
        let checkpoint = try store.checkpoint(for: fileID)
        let before = try store.usage(window: window, metric: .cost)
        let oldRevision = try #require(try store.databasePool.read { try UsageChartChanges.revision($0) })

        try store.databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO events_fts(events_fts) VALUES('delete-all');
                DELETE FROM token_minute;
                DELETE FROM token_usage_scope;
                DELETE FROM cache_savings_hour;
                """)
        }
        #expect(try store.searchIndex(query, scope: context).matchCount == 0)
        #expect(try store.usage(window: window, metric: .cost).totals.counts.total == 0)

        let rebuilt = try store.rebuildIndex(scoring: syntheticRebuildScoring)
        #expect(rebuilt.indexedEvents == 1 && rebuilt.usageRows == 2)
        #expect(try store.events(in: key) == originals)
        #expect(try store.checkpoint(for: fileID) == checkpoint)
        #expect(try store.searchIndex(query, scope: context).matchCount == 1)
        let after = try store.usage(window: window, metric: .cost)
        #expect(after.totals == before.totals)
        #expect(after.peak == before.peak)
        #expect(after.cacheSavings == before.cacheSavings)
        #expect(after.points == before.points)
        try store.databasePool.write { db throws -> Void in
            try db.execute(sql: "INSERT INTO events_fts(events_fts,rank) VALUES('integrity-check',1)")
            let revision = try UsageChartChanges.revision(db)
            #expect(revision == oldRevision + 1)
            guard case .reload = try UsageChartChanges.delta(db, after: oldRevision, through: revision) else {
                Issue.record("Rebuild did not invalidate earlier chart snapshots")
                return
            }
        }
        #expect(try store.rebuildIndex(scoring: syntheticRebuildScoring).usageRows == 2)
    }
}

@Test("FR-STO-1: a rebuild with usage absent from source rows preserves every projection and refuses to guess",
      arguments: ["minute", "scope", "savings", "signed"])
func rebuildRefusesUnbackedHistory(projection: String) throws {
    try withRebuildStore { store, fileID, key in
        let checkpoint = try store.checkpoint(for: fileID)
        let originals = try store.events(in: key)
        let start = try store.databasePool.read { try UsageChartChanges.revision($0) }
        try store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO events_fts(events_fts) VALUES('delete-all')")
            switch projection {
            case "minute":
                try db.execute(sql: """
                    INSERT INTO token_minute VALUES(-2,'codex',0,'retained-synthetic','call',9,0,0,0,0,0,3,0,1)
                    """)
            case "scope":
                try db.execute(sql: "UPDATE token_usage_scope SET records=records+1 WHERE grain=60")
            case "savings":
                try db.execute(sql: "UPDATE cache_savings_hour SET measured_cache_read=measured_cache_read+1")
            default:
                try db.execute(sql: "UPDATE cache_savings_hour SET savings_micro_usd=savings_micro_usd-4")
            }
        }
        let snapshot = try store.databasePool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT coalesce(sum(records),0) AS count FROM token_minute
                UNION ALL SELECT coalesce(sum(records),0) FROM token_usage_scope
                UNION ALL SELECT coalesce(sum(measured_cache_read),0) FROM cache_savings_hour
                """).map { $0["count"] as Int64 }
        }
        #expect(throws: IndexRebuildError.unbackedUsage) { try store.rebuildIndex(scoring: syntheticRebuildScoring) }
        #expect(try store.events(in: key) == originals)
        #expect(try store.checkpoint(for: fileID) == checkpoint)
        #expect(try store.searchIndex(SearchQuery.parse("rebuildneedle"), scope: .init(now: 0, timeZone: .gmt)).matchCount == 0)
        let unchanged = try store.databasePool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT coalesce(sum(records),0) AS count FROM token_minute
                UNION ALL SELECT coalesce(sum(records),0) FROM token_usage_scope
                UNION ALL SELECT coalesce(sum(measured_cache_read),0) FROM cache_savings_hour
                """).map { $0["count"] as Int64 }
        }
        #expect(unchanged == snapshot)
        #expect(try store.databasePool.read { try UsageChartChanges.revision($0) } == start)
        let temporaryTables = try store.databasePool.write { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_temp_master WHERE name GLOB 'rebuild_*'")
        }
        #expect(temporaryTables == 0)
    }
}
