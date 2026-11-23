import ADCore
import GRDB

public struct IndexedSessionUsageSummary: Equatable, Sendable {
    public let totals: UsageTotals
    public let hasApproximateQuote: Bool

    init(_ row: Row?) {
        guard let row else {
            totals = .empty
            hasApproximateQuote = false
            return
        }
        let counts = TokenCounts(inputFresh: row["input_fresh"], cacheRead: row["cache_read"],
                                cacheWrite: row["cache_write"], cacheWrite1h: row["cache_write_1h"],
                                output: row["output"], reasoning: row["reasoning"])
        totals = .init(counts: counts, costMicroUSD: row["cost_micro_usd"],
                       unpricedTokens: row["unpriced_tokens"], records: row["records"])
        hasApproximateQuote = (row["approximate_records"] as Int) > 0
    }
}

public struct IndexedSessionUsage: Equatable, Sendable {
    public let turns: Int
    public let summary: IndexedSessionUsageSummary
    public var totals: UsageTotals { summary.totals }
    public var hasApproximateQuote: Bool { summary.hasApproximateQuote }
}

public struct SessionTokenBucket: Identifiable, Equatable, Sendable {
    public var id: Int64 { timestamp }
    public let timestamp: Int64
    public let callTokens: Int64
    public let coarseTokens: Int64
}

public extension AgentStore {
    /// Aggregate only the selected session, from committed token events and
    /// their stored quotes. No source path or transcript text is read.
    func sessionUsageUpdates(in session: SessionKey)
    -> some AsyncSequence<IndexedSessionUsage?, any Error> & Sendable {
        ValueObservation.tracking { db in
            guard let id = try Self.usageSessionID(session, db: db) else { return nil as IndexedSessionUsage? }
            let turns = try Int.fetchOne(db, sql: """
                SELECT count(DISTINCT seq) FROM events WHERE session_id=? AND kind='user'
                """, arguments: [id]) ?? 0
            let row = try Row.fetchOne(db, sql: "SELECT * FROM session_usage_rollup WHERE session_id=?", arguments: [id])
            return IndexedSessionUsage(turns: turns, summary: .init(row))
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    /// At most 72 points across the observed span, separating coarse usage.
    /// An unknown timestamp contributes to totals but cannot be plotted.
    func sessionTokenChartUpdates(in session: SessionKey)
    -> some AsyncSequence<[SessionTokenBucket], any Error> & Sendable {
        ValueObservation.tracking { db in
            guard let id = try Self.usageSessionID(session, db: db),
                  let bounds = try Row.fetchOne(db, sql: """
                      SELECT min(ts) AS first,max(ts) AS last FROM token_events WHERE session_id=? AND ts<>0
                      """, arguments: [id]),
                  let first: Int64 = bounds["first"], let last: Int64 = bounds["last"] else { return [] as [SessionTokenBucket] }
            let start = first / 60_000 - (first % 60_000 < 0 ? 1 : 0)
            let end = last / 60_000 - (last % 60_000 < 0 ? 1 : 0)
            let width = (end - start) / 72 + 1
            return try Row.fetchAll(db, sql: """
                WITH volumes AS (
                    SELECT ts, (ts/60000-(ts%60000<0)-?)/? AS bucket,precision,
                        input_fresh+cache_read+cache_write+cache_write_1h+output AS tokens
                    FROM token_events WHERE session_id=? AND ts<>0
                )
                SELECT min(ts) AS ts,
                       coalesce(sum(tokens) FILTER(WHERE precision='call'),0) AS calls,
                       coalesce(sum(tokens) FILTER(WHERE precision<>'call'),0) AS coarse
                FROM volumes GROUP BY bucket ORDER BY bucket
                """, arguments: [start, width, id]).map {
                    SessionTokenBucket(timestamp: $0["ts"], callTokens: $0["calls"], coarseTokens: $0["coarse"])
                }
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    private static func usageSessionID(_ key: SessionKey, db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE agent=? AND native_id=?",
                           arguments: [key.agent.rawValue, key.nativeID])
    }
}
