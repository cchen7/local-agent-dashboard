import ADCore
import GRDB

public struct IndexedSessionUsage: Equatable, Sendable {
    public let turns: Int
    public let totals: UsageTotals
    public let hasApproximateQuote: Bool
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
            guard let row = try Row.fetchOne(db, sql: """
                SELECT coalesce(sum(input_fresh),0) AS fresh,coalesce(sum(cache_read),0) AS reads,
                       coalesce(sum(cache_write),0) AS writes,coalesce(sum(cache_write_1h),0) AS hour_writes,
                       coalesce(sum(output),0) AS output,coalesce(sum(reasoning),0) AS reasoning,
                       coalesce(sum(CASE WHEN price_status<>'unpriced' THEN cost_micro_usd ELSE 0 END),0) AS cost,
                       coalesce(sum(CASE WHEN price_status='unpriced'
                           THEN input_fresh+cache_read+cache_write+cache_write_1h+output ELSE 0 END),0) AS unpriced,
                       count(*) AS records,coalesce(max(price_status='approx'),0) AS approximate
                FROM token_events WHERE session_id=?
                """, arguments: [id]) else { return nil }
            let counts = TokenCounts(inputFresh: row["fresh"], cacheRead: row["reads"], cacheWrite: row["writes"],
                                     cacheWrite1h: row["hour_writes"], output: row["output"], reasoning: row["reasoning"])
            return IndexedSessionUsage(turns: turns,
                                       totals: .init(counts: counts, costMicroUSD: row["cost"],
                                                     unpricedTokens: row["unpriced"], records: row["records"]),
                                       hasApproximateQuote: row["approximate"])
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
