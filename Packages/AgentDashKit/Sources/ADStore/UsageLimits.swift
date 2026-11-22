import ADCore
import GRDB

public struct AgentThroughputSample: Equatable, Sendable {
    public let agent: AgentKind
    public let tokensPerMinute: Int64

    public init(agent: AgentKind, tokensPerMinute: Int64) {
        self.agent = agent; self.tokensPerMinute = tokensPerMinute
    }
}

public struct UsageLimitReadings: Equatable, Sendable {
    public let measuredAt: Int64
    public let codex: [UsageHeadroom]
    public let throughput: [AgentThroughputSample]
}

public extension AgentStore {
    /// Settings live in app-owned metadata; no source files are touched.
    func usageRedlines() throws -> [AgentKind: Int64] {
        try databasePool.read(UsageLimitsStore.readRedlines)
    }

    /// Redline edits do not change the chart data revision. Observe them
    /// independently so displayed guides and headroom can update in place.
    func usageRedlineUpdates() -> some AsyncSequence<[AgentKind: Int64], any Error> & Sendable {
        ValueObservation.tracking(UsageLimitsStore.readRedlines)
            .removeDuplicates()
            .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    /// Atomically replace just the explicit per-agent settings. An omitted key
    /// means no Redline; zero and negative limits are invalid.
    func setUsageRedlines(_ limits: [AgentKind: Int64]) throws {
        guard limits.values.allSatisfy({ $0 > 0 }) else { throw StoreError.invalidUsageRedline }
        try databasePool.write { db in
            for agent in AgentKind.allCases {
                let key = UsageLimitsStore.redlinePrefix + agent.rawValue
                if let limit = limits[agent] {
                    try db.execute(sql: """
                        INSERT INTO app_meta(key,value) VALUES(?,?)
                        ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE app_meta.value<>excluded.value
                        """, arguments: [key, String(limit)])
                } else {
                    try db.execute(sql: "DELETE FROM app_meta WHERE key=?", arguments: [key])
                }
            }
        }
    }

    /// Short, agent-wide current snapshot. The trailing 60 seconds do not
    /// reset at a wall-clock minute, and coarse estimates are never counted.
    func usageLimitReadings(now: Int64, agent: AgentKind?, includeThroughput: Bool) throws -> UsageLimitReadings {
        try databasePool.read { db in
            let codex = agent == nil || agent == .codex ? try UsageLimitsStore.codexHeadroom(db, now: now) : []
            let rates = includeThroughput ? try UsageLimitsStore.throughput(db, now: now, agent: agent) : []
            return UsageLimitReadings(measuredAt: now, codex: codex, throughput: rates)
        }
    }
}

enum UsageLimitsStore {
    static let redlinePrefix = "usage_redline."

    static func readRedlines(_ db: Database) throws -> [AgentKind: Int64] {
        let rows = try Row.fetchAll(db, sql: "SELECT key,value FROM app_meta WHERE key GLOB 'usage_redline.*'")
        var result: [AgentKind: Int64] = [:]
        for row in rows {
            let key: String = row["key"]
            let value: String = row["value"]
            guard key.hasPrefix(redlinePrefix),
                  let agent = AgentKind(rawValue: String(key.dropFirst(redlinePrefix.count))),
                  let limit = Int64(value), limit > 0 else { continue }
            result[agent] = limit
        }
        return result
    }

    static func codexHeadroom(_ db: Database, now: Int64) throws -> [UsageHeadroom] {
        let earliest = now.subtractingReportingOverflow(86_400_000)
        return try Row.fetchAll(db, sql: """
            WITH observed AS (
                SELECT window,used_percent,resets_at,ts,ROW_NUMBER() OVER (PARTITION BY limit_id,window ORDER BY ts DESC) AS seq
                FROM rate_limit_snapshots WHERE agent='codex' AND ts>? AND ts<=?
            ), tightest AS (
                SELECT window,used_percent,resets_at,ROW_NUMBER() OVER (PARTITION BY window ORDER BY used_percent DESC,ts DESC) AS pick
                FROM observed WHERE seq=1 AND used_percent>=0 AND (resets_at IS NULL OR resets_at>?)
            )
            SELECT window,used_percent,resets_at FROM tightest WHERE pick=1 ORDER BY window
            """, arguments: [earliest.overflow ? Int64.min : earliest.partialValue, now, now]).map { row in
                guard let window = RateLimitSnapshot.Window(rawValue: row["window"]) else { throw StoreError.invalidStoredValue }
                return UsageHeadroom(window: window, usedPercent: row["used_percent"], resetAt: row["resets_at"])
            }
    }

    static func totalThroughput(_ rates: [AgentThroughputSample]) throws -> Int64 {
        try rates.reduce(Int64(0)) { total, rate in
            let (value, overflow) = total.addingReportingOverflow(rate.tokensPerMinute)
            guard !overflow else { throw StoreError.invalidTokenCounts }
            return value
        }
    }

    static func throughput(_ db: Database, now: Int64, agent: AgentKind?) throws -> [AgentThroughputSample] {
        let earliest = now.subtractingReportingOverflow(60_000)
        var args: StatementArguments = [earliest.overflow ? Int64.min : earliest.partialValue, now]
        if let agent { args += [agent.rawValue] }
        return try Row.fetchAll(db, sql: """
            SELECT agent,sum(input_fresh+cache_read+cache_write+cache_write_1h+output) AS tokens
            FROM token_events WHERE ts>=? AND ts<? AND precision='call' \(agent == nil ? "" : "AND agent=?")
            GROUP BY agent HAVING tokens>0 ORDER BY agent
            """, arguments: args).map { row in
                guard let kind = AgentKind(rawValue: row["agent"]) else { throw StoreError.invalidStoredValue }
                return AgentThroughputSample(agent: kind, tokensPerMinute: row["tokens"])
            }
    }
}
