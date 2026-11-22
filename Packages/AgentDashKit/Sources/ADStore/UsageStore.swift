import ADCore
import Foundation
import GRDB

public enum UsageMetric: String, CaseIterable, Sendable { case tokens, output, cost }
public enum UsageGrouping: String, CaseIterable, Sendable { case agent, project, model }

public struct UsageFilter: Equatable, Sendable {
    public var agent: AgentKind?
    public var projectID: Int64?

    public init(agent: AgentKind? = nil, projectID: Int64? = nil) {
        self.agent = agent; self.projectID = projectID
    }
}

public struct UsageTotals: Equatable, Sendable {
    public let counts: TokenCounts
    public let costMicroUSD: Int64
    public let unpricedTokens: Int64
    public let records: Int

    public static let empty = Self(counts: .init(), costMicroUSD: 0, unpricedTokens: 0, records: 0)
    public var cacheHitRate: Double? { counts.input > 0 ? Double(counts.cacheRead) / Double(counts.input) : nil }
    public var hasPricedUsage: Bool { counts.total > unpricedTokens }
    /// Costs remain integer micro-USD until the presentation boundary.
    public func value(_ metric: UsageMetric) -> Int64 {
        switch metric {
        case .tokens: counts.total
        case .output: counts.output
        case .cost: costMicroUSD
        }
    }
}

public struct UsagePoint: Equatable, Sendable {
    public let timestamp: Int64
    public let agent: AgentKind
    public let coarse: Bool
    public let totals: UsageTotals
}

public struct UsageChartSnapshot: Equatable, Sendable {
    public let id: UUID
    public let window: UsageWindow
    public let points: [UsagePoint]
    /// Full buckets with identical clipped data in the requested reuse base.
    public let reusedBuckets: Set<Int64>
    public let reusedFrom: UUID?
    /// Inclusive call-precision amount in the trailing minute of a live chart.
    public let recent: UsageTotals?
    fileprivate let filter: UsageFilter
    fileprivate let origin: UUID
    fileprivate let revision: Int64?

    public func cumulative(_ metric: UsageMetric) -> Int64? {
        var amount: Int64 = 0
        for point in points {
            let next = amount.addingReportingOverflow(point.totals.value(metric))
            guard !next.overflow else { return nil }
            amount = next.partialValue
        }
        return amount
    }

    public static func == (lhs: UsageChartSnapshot, rhs: UsageChartSnapshot) -> Bool {
        lhs.window == rhs.window && lhs.filter == rhs.filter && lhs.points == rhs.points && lhs.recent == rhs.recent
    }
}

public struct UsagePeak: Equatable, Sendable {
    public let timestamp: Int64
    public let value: Int64
}

public struct UsageBreakdown: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String?
    public let agent: AgentKind?
    public let totals: UsageTotals
    public let sessions: Int
    public let peak: UsagePeak?
}

public struct UsageReport: Equatable, Sendable {
    public let window: UsageWindow
    public let totals: UsageTotals
    public let previous: UsageTotals?
    public let peak: UsagePeak?
    public let chart: UsageChartSnapshot
    public var points: [UsagePoint] { chart.points }
    public let breakdown: [UsageBreakdown]
    public let sessionCount: Int
    public let cacheSavings: UsageCacheSavings?
}

public struct UsageHeadroom: Equatable, Identifiable, Sendable {
    public let window: RateLimitSnapshot.Window
    public let usedPercent: Double
    public let resetAt: Int64?
    public var id: String { window.rawValue }
    public var remaining: Double { max(0, 100 - usedPercent) / 100 }
}

public struct MenuUsageSession: Identifiable, Equatable, Sendable {
    public var id: SessionKey { session.id }
    public let session: IndexedSession
    public let project: String?
    public let tokensPerMinute: Int64
}

public struct MenuUsageSnapshot: Sendable {
    public let today: UsageTotals
    public let chart: UsageChartSnapshot
    public let sessionsToday: Int
    public let running: Int
    public let waiting: Int
    public let currentTokens: Int64
    public let limits: UsageLimitReadings
    public let redlines: [AgentKind: Int64]
    public let sessions: [MenuUsageSession]
}

public extension AgentStore {
    /// Observe only while the panel is open. Session status changes and usage
    /// revisions both wake it, even when a session has no usage.
    func menuUsageChanges() -> some AsyncSequence<Void, any Error> & Sendable {
        ValueObservation.tracking(region: Table("sessions"), Table("projects"), Table("source_files"),
                                  Table("usage_chart_state"), Table("rate_limit_snapshots"), Table("app_meta"),
                                  fetch: { _ in () })
            .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    /// Produce the menu's local day, trailing minute and active list from one
    /// committed snapshot. No transcripts or source files are read.
    func menuUsage(now: Int64, timeZone: TimeZone, reusing chart: UsageChartSnapshot? = nil) throws -> MenuUsageSnapshot {
        let window = try UsageWindow.today(now: now, timeZone: timeZone)
        return try databasePool.read { db in
            let rates = try UsageLimitsStore.throughput(db, now: now, agent: nil)
            let current = try rates.reduce(Int64(0)) { total, rate in
                let (value, overflow) = total.addingReportingOverflow(rate.tokensPerMinute)
                guard !overflow else { throw StoreError.invalidTokenCounts }
                return value
            }
            let earliest = now.subtractingReportingOverflow(60_000)
            let sessions = try Row.fetchAll(db, sql: """
                WITH recent AS (
                    SELECT session_id,sum(input_fresh+cache_read+cache_write+cache_write_1h+output) AS tokens
                    FROM token_events WHERE ts>=? AND ts<? AND precision='call' GROUP BY session_id
                )
                SELECT s.agent,s.native_id,s.title,s.cwd,s.git_branch,s.environment,s.status,s.status_reason,
                       s.started_at,coalesce(s.last_event_at,s.started_at) AS activity,s.source_deleted_at,
                       p.display_name,coalesce(r.tokens,0) AS tokens
                FROM sessions s LEFT JOIN projects p ON p.id=s.project_id
                LEFT JOIN source_files f ON f.id=s.file_id LEFT JOIN recent r ON r.session_id=s.id
                WHERE s.status IN ('running','waiting') AND s.source_deleted_at IS NULL AND f.role IS NOT 'prompt_history'
                ORDER BY activity DESC,s.id DESC LIMIT 6
                """, arguments: [earliest.overflow ? Int64.min : earliest.partialValue, now]).map { row in
                    MenuUsageSession(session: try IndexedSession(row), project: row["display_name"],
                                     tokensPerMinute: row["tokens"])
                }
            let counts = try Row.fetchOne(db, sql: """
                SELECT count(*) FILTER(WHERE s.started_at>=? AND s.started_at<?) AS today,
                    count(*) FILTER(WHERE s.status='running' AND s.source_deleted_at IS NULL) AS running,
                    count(*) FILTER(WHERE s.status='waiting' AND s.source_deleted_at IS NULL) AS waiting
                FROM sessions s LEFT JOIN source_files f ON f.id=s.file_id
                WHERE f.role IS NOT 'prompt_history'
                """, arguments: [window.range.lowerBound, now])
            return .init(today: try UsageCoverage(window.range, filter: .init(), hourly: true).totals(db),
                         chart: try buildUsageChart(db, window: window, filter: .init(), hourly: false, reusing: chart),
                         sessionsToday: counts?["today"] ?? 0, running: counts?["running"] ?? 0,
                         waiting: counts?["waiting"] ?? 0, currentTokens: current,
                         limits: .init(measuredAt: now, codex: try UsageLimitsStore.codexHeadroom(db, now: now), throughput: rates),
                         redlines: try UsageLimitsStore.readRedlines(db), sessions: sessions)
        }
    }

    /// Tightest current Codex scope per window, across providers. No project
    /// attribution is inferred from quota data. Expired and stale observations are ignored.
    func codexHeadroom(now: Int64) throws -> [UsageHeadroom] {
        try databasePool.read { try UsageLimitsStore.codexHeadroom($0, now: now) }
    }

    func firstUsageTimestamp(_ filter: UsageFilter = .init()) throws -> Int64? {
        try databasePool.read { db in
            let predicate = UsagePredicate(filter)
            return try UsageCoverage.firstTimestamp(db, predicate: predicate)
        }
    }

    /// Full minutes use the durable rollup; raw events are consulted only for
    /// partial boundary minutes and distinct-session counts. One read snapshot
    /// supplies current/previous totals, peaks and timeline data.
    func usage(window: UsageWindow, filter: UsageFilter = .init(), metric: UsageMetric = .tokens,
               grouping: UsageGrouping = .agent, reusing chartBase: UsageChartSnapshot? = nil,
               liveAt: Int64? = nil) throws -> UsageReport {
        try databasePool.read { db in
            let hourly = grouping == .agent && Self.chartUsesHourRollup(window, filter: filter)
            let current = UsageCoverage(window.range, filter: filter, hourly: hourly)
            let totals = try current.totals(db)
            let previous = try window.previous.map { try UsageCoverage($0, filter: filter, hourly: hourly).totals(db) }
            let chart = try buildUsageChart(db, window: window, filter: filter, hourly: hourly, reusing: chartBase, liveAt: liveAt)
            guard totals.records > 0 else {
                return UsageReport(window: window, totals: totals, previous: previous, peak: nil, chart: chart,
                                   breakdown: [], sessionCount: 0, cacheSavings: nil)
            }
            let amount = UsageCoverage.amount(metric)
            let costPeaks = hourly && metric == .cost ? try current.fullCostPeaks(db, agent: filter.agent) : nil
            let peak: UsagePeak?
            if hourly { peak = try current.scopePeak(db, agent: filter.agent, metric: metric, costPeaks: costPeaks) }
            else {
                let peakRow = try Row.fetchOne(db, sql: """
                    \(current.cte) SELECT bucket,sum(\(amount)) AS peak FROM covered
                    WHERE precision='call' \(UsageCoverage.pricingPeakFilter(metric))
                    GROUP BY bucket ORDER BY peak DESC,bucket LIMIT 1
                    """, arguments: current.arguments)
                peak = try peakRow.map { UsagePeak(timestamp: try UsageCoverage.timestamp($0["bucket"]), value: $0["peak"]) }
            }
            let breakdown = try current.breakdown(db, grouping: grouping, metric: metric, costPeaks: costPeaks)
            let sessionCount = grouping == .model ? try current.distinctSessions(db) : breakdown.reduce(0) { $0 + $1.sessions }
            return UsageReport(window: window, totals: totals, previous: previous, peak: peak, chart: chart,
                               breakdown: breakdown, sessionCount: sessionCount,
                               cacheSavings: totals.counts.cacheRead > 0 ? try current.cacheSavings(db) : nil)
        }
    }

    /// Refresh the timeline only. Headline totals and previous-period
    /// comparisons remain tied to the last full UsageReport.
    func usageChart(period: UsagePeriod, now: Int64, timeZone: TimeZone,
                    filter: UsageFilter = .init(), custom: UsageRange? = nil,
                    reusing base: UsageChartSnapshot? = nil) throws -> UsageChartSnapshot {
        try databasePool.read { db in
            let predicate = UsagePredicate(filter)
            let first = period == .all ? try UsageCoverage.firstTimestamp(db, predicate: predicate).map { min($0, now) } : nil
            let window = try UsageWindow.make(period, now: now, firstTimestamp: first, custom: custom, timeZone: timeZone)
            return try buildUsageChart(db, window: window, filter: filter,
                                       hourly: Self.chartUsesHourRollup(window, filter: filter), reusing: base,
                                       liveAt: period == .custom ? nil : now)
        }
    }

    private static func chartUsesHourRollup(_ window: UsageWindow, filter: UsageFilter) -> Bool {
        guard filter.projectID == nil else { return false }
        switch window.bucket {
        case .fixed(let width): return width >= 3_600_000 && width % 3_600_000 == 0
        case .localDay: return true
        }
    }

    private func buildUsageChart(_ db: Database, window: UsageWindow, filter: UsageFilter, hourly: Bool,
                                 reusing base: UsageChartSnapshot?, liveAt: Int64? = nil) throws -> UsageChartSnapshot {
        let revision = try UsageChartChanges.revision(db)
        let recent = try liveAt.flatMap { observed -> UsageTotals? in
            let earliest = observed.subtractingReportingOverflow(60_000)
            let start = max(window.range.lowerBound, earliest.overflow ? Int64.min : earliest.partialValue)
            let end = min(observed, window.range.upperBound)
            guard start < end else { return nil }
            let predicate = UsagePredicate(filter)
            let row = try Row.fetchOne(db, sql: """
                WITH recent AS (\(UsageCoverage.rawFacts(predicate, precise: true)))
                SELECT \(UsageCoverage.sums) FROM recent
                """, arguments: UsageCoverage.rawArguments(start, end, predicate: predicate))
            return row.map(UsageCoverage.readTotals)
        }
        func snapshot(_ points: [UsagePoint], reused: Set<Int64> = [], from baseID: UUID? = nil) -> UsageChartSnapshot {
            UsageChartSnapshot(id: UUID(), window: window, points: points, reusedBuckets: reused, reusedFrom: baseID, recent: recent,
                               filter: filter, origin: usageChartIdentity, revision: revision)
        }
        func read(_ range: UsageRange) throws -> [UsagePoint] {
            try UsageCoverage(range, filter: filter, hourly: hourly).points(db, window: window, filter: filter)
        }
        guard window.range.lowerBound < window.range.upperBound else { return snapshot([]) }
        guard let base, base.origin == usageChartIdentity, base.filter == filter,
              base.window.bucket == window.bucket else { return try snapshot(read(window.range)) }
        let delta = try UsageChartChanges.delta(db, after: base.revision, through: revision)
        let modified: ClosedRange<Int64>?
        switch delta {
        case .reload: return try snapshot(read(window.range))
        case .none: modified = nil
        case .changed(let range): modified = range
        }

        var reused: Set<Int64> = []
        var dirty: [UsageRange] = []
        for bucket in try window.chartBuckets() {
            let lower = max(bucket.lowerBound, window.range.lowerBound)
            let upper = min(bucket.upperBound, window.range.upperBound)
            let sameClip = lower == max(bucket.lowerBound, base.window.range.lowerBound)
                && upper == min(bucket.upperBound, base.window.range.upperBound)
            let touchesChange = modified.map { $0.lowerBound < upper && $0.upperBound >= lower } == true
            if sameClip && !touchesChange {
                reused.insert(bucket.lowerBound)
            } else if let last = dirty.last, last.upperBound == lower {
                dirty[dirty.count - 1] = try UsageRange(lowerBound: last.lowerBound, upperBound: upper)
            } else {
                dirty.append(try UsageRange(lowerBound: lower, upperBound: upper))
            }
        }
        var points = base.points.filter { reused.contains($0.timestamp) }
        for range in dirty { points.append(contentsOf: try read(range)) }
        if !dirty.isEmpty {
            points.sort {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if $0.agent != $1.agent { return $0.agent.rawValue < $1.agent.rawValue }
                return !$0.coarse && $1.coarse
            }
        }
        return snapshot(points, reused: reused, from: base.id)
    }
}

private struct UsagePredicate {
    let sql: String
    let arguments: StatementArguments

    init(_ filter: UsageFilter) {
        var terms: [String] = []
        var args = StatementArguments()
        if let agent = filter.agent { terms.append("agent=?"); args += [agent.rawValue] }
        if let id = filter.projectID { terms.append(id == 0 ? "coalesce(project_id,0)=?" : "project_id=?"); args += [id] }
        sql = terms.isEmpty ? "" : "AND " + terms.joined(separator: " AND ")
        arguments = args
    }
}

private struct UsageCoverage {
    let range: UsageRange
    let predicate: UsagePredicate
    let cte: String
    let arguments: StatementArguments
    let hourly: Bool

    static let sums = UsageTotals.aggregateColumns

    static func firstTimestamp(_ db: Database, predicate: UsagePredicate) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT min(first) FROM (
                SELECT min(ts) AS first FROM token_events WHERE 1=1 \(predicate.sql)
                UNION ALL
                SELECT min(ts) FROM retained_archive_usage WHERE 1=1 \(predicate.sql)
            )
            """, arguments: predicate.arguments + predicate.arguments)
    }

    static func rawFacts(_ predicate: UsagePredicate, precise: Bool = false) -> String {
        let precision = precise ? "AND precision='call'" : ""
        return """
            SELECT ts,agent,coalesce(project_id,0) AS project_id,coalesce(model,'') AS model,precision,
                input_fresh,cache_read,cache_write,cache_write_1h,output,reasoning,cost_micro_usd,
                CASE WHEN price_status='unpriced' THEN input_fresh+cache_read+cache_write+cache_write_1h+output ELSE 0 END AS unpriced_tokens,
                1 AS records
            FROM token_events WHERE ts>=? AND ts<? \(precision) \(predicate.sql)
            UNION ALL
            SELECT ts,agent,project_id,model,precision,input_fresh,cache_read,cache_write,cache_write_1h,
                output,reasoning,cost_micro_usd,unpriced_tokens,records
            FROM retained_archive_usage WHERE ts>=? AND ts<? \(precision) \(predicate.sql)
            """
    }

    static func rawArguments(_ lower: Int64, _ upper: Int64, predicate: UsagePredicate) -> StatementArguments {
        let once = StatementArguments([lower, upper]) + predicate.arguments
        return once + once
    }

    init(_ range: UsageRange, filter: UsageFilter, hourly: Bool = false) {
        self.range = range
        let predicate = UsagePredicate(filter)
        self.predicate = predicate
        self.hourly = hourly
        var parts: [String] = []
        var args = StatementArguments()
        func raw(_ lower: Int64, _ upper: Int64) {
            parts.append("""
                SELECT ts/60000-(ts%60000<0) AS bucket,agent,project_id,model,precision,
                    input_fresh,cache_read,cache_write,cache_write_1h,output,reasoning,cost_micro_usd,unpriced_tokens,records
                FROM (\(Self.rawFacts(predicate)))
                """)
            args += Self.rawArguments(lower, upper, predicate: predicate)
        }
        func minutes(_ lower: Int64, _ upper: Int64) {
            guard lower < upper else { return }
            let (start, end) = Self.fullSlots(lower, upper, width: 60_000)
            if start < end {
                parts.append("SELECT * FROM token_minute WHERE bucket>=? AND bucket<? \(predicate.sql)")
                args += [start, end]; args += predicate.arguments
                let from = start * 60_000, upto = end * 60_000
                if lower < from { raw(lower, from) }
                if upto < upper { raw(upto, upper) }
            } else { raw(lower, upper) }
        }
        let (firstHour, lastHour) = Self.fullSlots(range.lowerBound, range.upperBound, width: 3_600_000)
        if hourly && firstHour < lastHour {
            parts.append("""
                SELECT bucket*60 AS bucket,agent,0 AS project_id,'' AS model,precision,input_fresh,cache_read,
                       cache_write,cache_write_1h,output,reasoning,cost_micro_usd,unpriced_tokens,records
                FROM token_usage_scope WHERE grain=60 AND agent<>'' AND bucket>=? AND bucket<? \(predicate.sql)
                """)
            args += [firstHour, lastHour]; args += predicate.arguments
            minutes(range.lowerBound, firstHour * 3_600_000)
            minutes(lastHour * 3_600_000, range.upperBound)
        } else if range.lowerBound < range.upperBound { minutes(range.lowerBound, range.upperBound) }
        else { raw(range.lowerBound, range.upperBound) }
        cte = "WITH covered AS (\(parts.joined(separator: " UNION ALL ")))"
        arguments = args
    }

    func totals(_ db: Database) throws -> UsageTotals {
        try Row.fetchOne(db, sql: "\(cte) SELECT \(Self.sums) FROM covered", arguments: arguments).map(Self.readTotals) ?? .empty
    }

    func cacheSavings(_ db: Database) throws -> UsageCacheSavings {
        let (start, end) = Self.fullSlots(range.lowerBound, range.upperBound, width: 3_600_000)
        var sections: [String] = []
        var args = StatementArguments()
        func raw(_ lower: Int64, _ upper: Int64) {
            guard lower < upper else { return }
            sections.append("""
                SELECT cache_savings_micro_usd AS amount,cache_read AS measured FROM token_events
                WHERE ts>=? AND ts<? AND cache_savings_micro_usd IS NOT NULL AND cache_read>0 \(predicate.sql)
                UNION ALL
                SELECT savings_micro_usd AS amount,measured_cache_read AS measured FROM retained_archive_usage
                WHERE ts>=? AND ts<? AND measured_cache_read>0 \(predicate.sql)
                """)
            args += Self.rawArguments(lower, upper, predicate: predicate)
        }
        if start < end {
            sections.append("""
                SELECT savings_micro_usd AS amount,measured_cache_read AS measured FROM cache_savings_hour
                WHERE bucket>=? AND bucket<? \(predicate.sql)
                """)
            args += [start, end]; args += predicate.arguments
            raw(range.lowerBound, start * 3_600_000)
            raw(end * 3_600_000, range.upperBound)
        } else { raw(range.lowerBound, range.upperBound) }
        guard !sections.isEmpty else { return UsageCacheSavings(microUSD: 0, measuredCacheReadTokens: 0) }
        let row = try Row.fetchOne(db, sql: """
            SELECT coalesce(sum(amount),0) AS savings,coalesce(sum(measured),0) AS coverage
            FROM (\(sections.joined(separator: " UNION ALL ")))
            """, arguments: args)
        return UsageCacheSavings(microUSD: row?["savings"] ?? 0, measuredCacheReadTokens: row?["coverage"] ?? 0)
    }

    func points(_ db: Database, window: UsageWindow, filter: UsageFilter) throws -> [UsagePoint] {
        switch window.bucket {
        case .fixed(let width): return try fixedPoints(db, widthMS: width)
        case .localDay:
            var points: [UsagePoint] = []
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                let bucket = try window.bucketRange(containing: cursor)
                let clip = try UsageRange(lowerBound: max(bucket.lowerBound, range.lowerBound),
                                          upperBound: min(bucket.upperBound, range.upperBound))
                // Reuse the exact coverage at both report and local-day edges.
                // A local midnight need not align to a UTC hour or minute.
                let day = UsageCoverage(clip, filter: filter, hourly: hourly)
                try points.append(contentsOf: day.dayPoints(db, at: bucket.lowerBound))
                cursor = clip.upperBound
            }
            return points
        }
    }

    private func fixedPoints(_ db: Database, widthMS: Int64) throws -> [UsagePoint] {
        let width = max(Int64(1), widthMS / 60_000)
        return try Row.fetchAll(db, sql: """
            \(cte) SELECT (bucket/\(width)-(bucket%\(width)<0))*\(width) AS chart_bucket,
                agent,precision<>'call' AS coarse,\(Self.sums)
            FROM covered GROUP BY chart_bucket,agent,coarse ORDER BY chart_bucket,agent,coarse
            """, arguments: arguments).map { row in
                guard let agent = AgentKind(rawValue: row["agent"]) else { throw StoreError.invalidStoredValue }
                return UsagePoint(timestamp: try Self.timestamp(row["chart_bucket"]), agent: agent,
                                  coarse: row["coarse"], totals: Self.readTotals(row))
            }
    }

    private func dayPoints(_ db: Database, at start: Int64) throws -> [UsagePoint] {
        try Row.fetchAll(db, sql: """
            \(cte) SELECT agent,precision<>'call' AS coarse,\(Self.sums)
            FROM covered GROUP BY agent,coarse ORDER BY agent,coarse
            """, arguments: arguments).map { row in
                guard let agent = AgentKind(rawValue: row["agent"]) else { throw StoreError.invalidStoredValue }
                return UsagePoint(timestamp: start, agent: agent, coarse: row["coarse"], totals: Self.readTotals(row))
            }
    }

    func breakdown(_ db: Database, grouping: UsageGrouping, metric: UsageMetric,
                   costPeaks: CostScopePeaks?) throws -> [UsageBreakdown] {
        let key = Self.groupKey(grouping)
        let sessionSQL: String
        if grouping == .model {
            sessionSQL = """
                SELECT \(key) AS group_key,count(DISTINCT session_id) AS sessions FROM token_events
                WHERE ts>=? AND ts<? \(predicate.sql) GROUP BY group_key
                """
        } else {
            sessionSQL = """
                SELECT \(key) AS group_key,count(*) AS sessions FROM sessions s
                WHERE EXISTS(SELECT 1 FROM token_events INDEXED BY token_events_session_time
                             WHERE session_id=s.id AND ts>=? AND ts<? \(predicate.sql)) GROUP BY group_key
                """
        }
        let distinct = try Row.fetchAll(db, sql: sessionSQL,
                                        arguments: StatementArguments([range.lowerBound, range.upperBound]) + predicate.arguments)
        var sessionCounts: [String: Int] = [:]
        for row in distinct { sessionCounts[row["group_key"]] = row["sessions"] }
        let amount = Self.amount(metric)
        var peaks: [String: UsagePeak] = [:]
        if !hourly {
        let peakRows = try Row.fetchAll(db, sql: """
            \(cte), per_minute AS (
                SELECT \(key) AS group_key,bucket,sum(\(amount)) AS amount FROM covered
                WHERE precision='call' \(Self.pricingPeakFilter(metric)) GROUP BY group_key,bucket
            ) SELECT group_key,bucket,max(amount) AS peak FROM per_minute GROUP BY group_key
            """, arguments: arguments)
        for row in peakRows {
            peaks[row["group_key"]] = UsagePeak(timestamp: try Self.timestamp(row["bucket"]), value: row["peak"])
        }
        }
        return try Row.fetchAll(db, sql: "\(cte) SELECT \(key) AS group_key,\(Self.sums) FROM covered GROUP BY group_key ORDER BY group_key",
                                arguments: arguments).map { row in
            let id: String = row["group_key"]
            let label: String?
            let agent = grouping == .agent ? AgentKind(rawValue: id) : nil
            switch grouping {
            case .agent: label = nil
            case .model: label = id.isEmpty ? nil : id
            case .project:
                label = try String.fetchOne(db, sql: "SELECT display_name FROM projects WHERE id=?", arguments: [Int64(id)])
            }
            let peak = hourly ? try scopePeak(db, agent: agent, metric: metric, costPeaks: costPeaks) : peaks[id]
            return UsageBreakdown(id: id, label: label, agent: agent, totals: Self.readTotals(row),
                                  sessions: sessionCounts[id, default: 0], peak: peak)
        }.sorted { lhs, rhs in
            let left = lhs.totals.value(metric), right = rhs.totals.value(metric)
            return left == right ? lhs.id < rhs.id : left > right
        }
    }

    func distinctSessions(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM sessions s WHERE EXISTS(
                SELECT 1 FROM token_events INDEXED BY token_events_session_time
                WHERE session_id=s.id AND ts>=? AND ts<? \(predicate.sql)
            )
            """, arguments: StatementArguments([range.lowerBound, range.upperBound]) + predicate.arguments) ?? 0
    }

    struct CostScopePeaks {
        var peaks: [String: UsagePeak] = [:]
        var overflow: Set<String> = []
    }

    /// Scan full minutes once for the combined and per-agent peaks. Rank a
    /// fitting amount together with its minute offset using integer arithmetic
    /// so equal costs choose the earlier minute. Very large costs fall back to
    /// the exact unencoded SQL order for that agent.
    func fullCostPeaks(_ db: Database, agent: AgentKind?) throws -> CostScopePeaks {
        let (start, end) = Self.fullSlots(range.lowerBound, range.upperBound, width: 60_000)
        guard start < end else { return CostScopePeaks() }
        let span = end - start
        let overflowMarker = Int64.max
        let cap = (overflowMarker - 1 - (span - 1)) / span
        let last = end - 1
        let scopes = agent.map { [$0.rawValue] } ?? ([""] + AgentKind.allCases.map(\.rawValue))
        var arguments: StatementArguments = [cap, overflowMarker, span, last, start, end]
        if let agent { arguments += [agent.rawValue] }
        arguments += StatementArguments(scopes)
        // Fixed scope keys let SQLite accumulate maxima without sorting a
        // temporary GROUP BY table over the whole selected minute range.
        let aggregates = scopes.map { _ in "max(ranked) FILTER (WHERE agent=?)" }.joined(separator: ",")
        let row = try Row.fetchOne(db, sql: """
            WITH minutes AS (
                SELECT agent,CASE WHEN cost_micro_usd>? THEN ? ELSE cost_micro_usd*?+(?-bucket) END AS ranked
                FROM token_usage_scope
                WHERE grain=1 AND precision='call' AND bucket>=? AND bucket<? AND volume>unpriced_tokens
                  \(agent == nil ? "" : "AND agent=?")
            )
            SELECT \(aggregates) FROM minutes
            """, arguments: arguments)
        var result = CostScopePeaks()
        guard let row else { return result }
        for (index, key) in scopes.enumerated() {
            guard let packed: Int64 = row[index] else { continue }
            if packed == overflowMarker { result.overflow.insert(key); continue }
            result.peaks[key] = UsagePeak(timestamp: try Self.timestamp(last - packed % span), value: packed / span)
        }
        return result
    }

    /// Full precise minutes use indexed token peaks or the bounded scope rollup
    /// range for costs. A cost index would add write overhead to price backfill.
    func scopePeak(_ db: Database, agent: AgentKind?, metric: UsageMetric, costPeaks: CostScopePeaks?) throws -> UsagePeak? {
        let (start, end) = Self.fullSlots(range.lowerBound, range.upperBound, width: 60_000)
        var candidates: [UsagePeak] = []
        var edges: [(Int64, Int64)] = []
        let key = agent?.rawValue ?? ""
        if start < end {
            if let costPeaks, !costPeaks.overflow.contains(key) {
                if let peak = costPeaks.peaks[key] { candidates.append(peak) }
            } else {
                let index: String
                let amount: String
                switch metric {
                case .tokens: index = "INDEXED BY token_usage_scope_peak_tokens"; amount = "volume"
                case .output: index = "INDEXED BY token_usage_scope_peak_output"; amount = "output"
                case .cost: index = ""; amount = "cost_micro_usd"
                }
                let row = try Row.fetchOne(db, sql: """
                    SELECT bucket,\(amount) AS peak FROM token_usage_scope \(index)
                    WHERE grain=1 AND precision='call' AND agent=? AND bucket>=? AND bucket<?
                      \(metric == .cost ? "AND volume>unpriced_tokens" : "")
                    ORDER BY \(amount) DESC,bucket LIMIT 1
                    """, arguments: [key, start, end])
                if let row { candidates.append(try UsagePeak(timestamp: Self.timestamp(row["bucket"]), value: row["peak"])) }
            }
            if range.lowerBound < start * 60_000 { edges.append((range.lowerBound, start * 60_000)) }
            if end * 60_000 < range.upperBound { edges.append((end * 60_000, range.upperBound)) }
        } else { edges.append((range.lowerBound, range.upperBound)) }
        let predicate = UsagePredicate(.init(agent: agent))
        for (lower, upper) in edges {
            let row = try Row.fetchOne(db, sql: """
                SELECT ts/60000-(ts%60000<0) AS bucket,sum(\(Self.amount(metric))) AS peak
                FROM (\(Self.rawFacts(predicate, precise: true))) WHERE 1=1 \(Self.pricingPeakFilter(metric))
                GROUP BY bucket ORDER BY peak DESC,bucket LIMIT 1
                """, arguments: Self.rawArguments(lower, upper, predicate: predicate))
            if let row { candidates.append(try UsagePeak(timestamp: Self.timestamp(row["bucket"]), value: row["peak"])) }
        }
        return candidates.sorted { lhs, rhs in lhs.value == rhs.value ? lhs.timestamp < rhs.timestamp : lhs.value > rhs.value }.first
    }

    private static func fullSlots(_ lower: Int64, _ upper: Int64, width: Int64) -> (Int64, Int64) {
        (lower / width + (lower % width > 0 ? 1 : 0), upper / width - (upper % width < 0 ? 1 : 0))
    }

    private static func groupKey(_ grouping: UsageGrouping) -> String {
        switch grouping {
        case .agent: "agent"
        case .project: "CAST(coalesce(project_id,0) AS TEXT)"
        case .model: "coalesce(model,'')"
        }
    }

    static func amount(_ metric: UsageMetric) -> String {
        switch metric {
        case .tokens: "input_fresh+cache_read+cache_write+cache_write_1h+output"
        case .output: "output"
        case .cost: "cost_micro_usd"
        }
    }

    static func pricingPeakFilter(_ metric: UsageMetric, raw: Bool = false) -> String {
        guard metric == .cost else { return "" }
        return raw ? "AND price_status<>'unpriced' AND (\(amount(.tokens)))>0"
                   : "AND (\(amount(.tokens)))>unpriced_tokens"
    }

    static func readTotals(_ row: Row) -> UsageTotals { .fromAggregate(row) }

    static func timestamp(_ minute: Int64) throws -> Int64 {
        let result = minute.multipliedReportingOverflow(by: 60_000)
        guard !result.overflow else { throw StoreError.invalidStoredValue }
        return result.partialValue
    }
}


extension UsageTotals {
    static let aggregateColumns = """
        coalesce(sum(input_fresh),0) AS fresh,coalesce(sum(cache_read),0) AS read_cache,
        coalesce(sum(cache_write),0) AS write_cache,coalesce(sum(cache_write_1h),0) AS write_hour,
        coalesce(sum(output),0) AS output,coalesce(sum(reasoning),0) AS reasoning,
        coalesce(sum(cost_micro_usd),0) AS cost,coalesce(sum(unpriced_tokens),0) AS unpriced,coalesce(sum(records),0) AS records
        """

    static func fromAggregate(_ row: Row) -> UsageTotals {
        UsageTotals(counts: TokenCounts(inputFresh: row["fresh"], cacheRead: row["read_cache"], cacheWrite: row["write_cache"],
                                        cacheWrite1h: row["write_hour"], output: row["output"], reasoning: row["reasoning"]),
                    costMicroUSD: row["cost"], unpricedTokens: row["unpriced"], records: row["records"])
    }
}

extension UsageChartSnapshot {
    /// Identifiers for workspace charts never match a broad or catalog cache.
    static func project(window: UsageWindow, points: [UsagePoint]) -> Self {
        .init(id: UUID(), window: window, points: points, reusedBuckets: [], reusedFrom: nil,
              recent: nil, filter: .init(), origin: UUID(), revision: nil)
    }
}
