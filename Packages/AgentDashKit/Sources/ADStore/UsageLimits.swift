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
    public let nextChangeAt: Int64?
}

struct UsageDeadline {
    let now: Int64
    private(set) var next: Int64?

    mutating func include(_ timestamp: Int64?, after delay: Int64 = 0) {
        guard let timestamp else { return }
        let (deadline, overflow) = timestamp.addingReportingOverflow(delay)
        guard !overflow, deadline > now, next.map({ deadline < $0 }) ?? true else { return }
        next = deadline
    }
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
            try UsageLimitsStore.snapshot(db, now: now, agent: agent, includeThroughput: includeThroughput)
        }
    }

    /// A quota-only commit can change headroom without changing the usage chart.
    func usageLimitChanges(includeThroughput: Bool) -> some AsyncSequence<Void, any Error> & Sendable {
        let quota = Table("rate_limit_snapshots")
        let observation = includeThroughput
            ? ValueObservation.tracking(region: quota, UsageLimitsStore.throughputInputs, fetch: { _ in () })
            : ValueObservation.tracking(region: quota, fetch: { _ in () })
        return observation.values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }
}

enum UsageLimitsStore {
    static let redlinePrefix = "usage_redline."
    private static let freshness: Int64 = 86_400_000
    static let minute: Int64 = 60_000

    static var throughputInputs: some DatabaseRegionConvertible {
        Table("token_events").select(Column("agent"), Column("ts"), Column("precision"), Column("input_fresh"),
                                     Column("cache_read"), Column("cache_write"), Column("cache_write_1h"), Column("output"))
    }

    static func snapshot(_ db: Database, now: Int64, agent: AgentKind?, includeThroughput: Bool) throws -> UsageLimitReadings {
        var deadline = UsageDeadline(now: now)
        let codex: [UsageHeadroom]
        if agent == nil || agent == .codex {
            let selected = try chosenCodexRows(db, now: now)
            codex = try selected.map(readHeadroom)
            for row in selected {
                deadline.include(row["resets_at"])
                deadline.include(row["ts"], after: freshness)
            }
            deadline.include(try Int64.fetchOne(db, sql: "SELECT min(ts) FROM rate_limit_snapshots WHERE agent='codex' AND ts>?",
                                                arguments: [now]))
        } else { codex = [] }
        let rates = includeThroughput ? try throughput(db, now: now, agent: agent, change: &deadline) : []
        return UsageLimitReadings(measuredAt: now, codex: codex, throughput: rates, nextChangeAt: deadline.next)
    }

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
        try chosenCodexRows(db, now: now).map(readHeadroom)
    }

    private static func readHeadroom(_ row: Row) throws -> UsageHeadroom {
        guard let window = RateLimitSnapshot.Window(rawValue: row["window"]) else { throw StoreError.invalidStoredValue }
        return UsageHeadroom(window: window, usedPercent: row["used_percent"], resetAt: row["resets_at"])
    }

    private static func chosenCodexRows(_ db: Database, now: Int64) throws -> [Row] {
        let earliest = now.subtractingReportingOverflow(freshness)
        return try Row.fetchAll(db, sql: """
            WITH observed AS (
                SELECT window,used_percent,resets_at,ts,ROW_NUMBER() OVER (PARTITION BY limit_id,window ORDER BY ts DESC) AS seq
                FROM rate_limit_snapshots WHERE agent='codex' AND ts>? AND ts<=?
            ), tightest AS (
                SELECT window,used_percent,resets_at,ts,ROW_NUMBER() OVER (PARTITION BY window ORDER BY used_percent DESC,ts DESC) AS pick
                FROM observed WHERE seq=1 AND used_percent>=0 AND (resets_at IS NULL OR resets_at>?)
            )
            SELECT window,used_percent,resets_at,ts FROM tightest WHERE pick=1 ORDER BY window
            """, arguments: [earliest.overflow ? Int64.min : earliest.partialValue, now, now])
    }

    static func totalThroughput(_ rates: [AgentThroughputSample]) throws -> Int64 {
        try rates.reduce(Int64(0)) { total, rate in
            let (value, overflow) = total.addingReportingOverflow(rate.tokensPerMinute)
            guard !overflow else { throw StoreError.invalidTokenCounts }
            return value
        }
    }

    static func throughput(_ db: Database, now: Int64, agent: AgentKind?, change: inout UsageDeadline) throws -> [AgentThroughputSample] {
        let earliest = now.subtractingReportingOverflow(minute)
        var args: StatementArguments = [earliest.overflow ? Int64.min : earliest.partialValue, now]
        if let agent { args += [agent.rawValue] }
        let agentScope = agent == nil ? "" : "AND agent=?"
        let amount = "input_fresh+cache_read+cache_write+cache_write_1h+output"
        let rows = try Row.fetchAll(db, sql: """
            SELECT agent,sum(\(amount)) AS tokens,min(ts) AS first
            FROM token_events WHERE ts>=? AND ts<? AND precision='call' AND (\(amount))>0 \(agentScope)
            GROUP BY agent ORDER BY agent
            """, arguments: args)
        var future: StatementArguments = [now]
        if let agent { future += [agent.rawValue] }
        change.include(try Int64.fetchOne(db, sql: """
            SELECT min(ts) FROM token_events WHERE ts>=? AND precision='call' AND (\(amount))>0 \(agentScope)
            """, arguments: future), after: 1)
        return try rows.map { row in
            change.include(row["first"], after: minute + 1)
            guard let kind = AgentKind(rawValue: row["agent"]) else { throw StoreError.invalidStoredValue }
            return AgentThroughputSample(agent: kind, tokensPerMinute: row["tokens"])
        }
    }
}
