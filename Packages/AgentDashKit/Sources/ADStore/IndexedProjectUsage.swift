import ADCore
import Foundation
import GRDB

/// The catalog, selected interval and project-scoped numbers come from one
/// owned-index snapshot. Published APIs never accept guessed workspace paths
/// or session row IDs as usage filters.
public struct IndexedProjectUsageSnapshot: Equatable, Sendable {
    public let projects: [IndexedProject]
    public let window: UsageWindow?
    public let totals: [IndexedProject.ID: UsageTotals]
    public let chartProject: IndexedProject.ID?
    public let chart: UsageChartSnapshot?
}

public extension AgentStore {
    func indexedProjectUsageUpdates(
        hostHome: String? = nil, period: UsagePeriod, custom: UsageRange? = nil,
        timeZone: TimeZone, chartFor projectID: IndexedProject.ID? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) -> some AsyncSequence<IndexedProjectUsageSnapshot, any Error> & Sendable {
        ValueObservation.tracking { db in
            try ProjectUsageRead.snapshot(db, hostHome: hostHome, period: period, custom: custom,
                                          timeZone: timeZone, chartFor: projectID, now: now())
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }
}

enum ProjectUsageRead {
    static func snapshot(_ db: Database, hostHome: String?, period: UsagePeriod, custom: UsageRange?,
                         timeZone: TimeZone, chartFor projectID: IndexedProject.ID?, now: Int64)
        throws -> IndexedProjectUsageSnapshot {
        let projects = try catalog(db, hostHome: hostHome)
        let membership = try Membership(projects)
        let first = period == .all ? try membership.firstDatedTimestamp(db, before: now) : nil
        guard let window = try? UsageWindow.make(period, now: now, firstTimestamp: first, custom: custom,
                                                 timeZone: timeZone) else {
            return .init(projects: projects, window: nil, totals: [:], chartProject: nil, chart: nil)
        }

        var coverage = Bounds.clip(window.range, to: window.range).map { [$0] } ?? []
        // All includes unknown timestamp counts, but a chart never plots them
        // at the Unix epoch (whether the report range spans it or not).
        if period == .all && !(window.range.lowerBound <= 0 && 0 < window.range.upperBound) {
            coverage.append(.init(bucket: 0, lower: 0, upper: 1))
        }
        let totals = try membership.totals(db, coverage: coverage, projects: projects)
        guard let selected = projects.first(where: { $0.id == projectID }) else {
            return .init(projects: projects, window: window, totals: totals, chartProject: nil, chart: nil)
        }
        let edges = try window.chartBuckets().compactMap { Bounds.clip($0, to: window.range) }
        let points = try Membership([selected]).points(db, coverage: edges)
        return .init(projects: projects, window: window, totals: totals, chartProject: selected.id,
                     chart: .project(window: window, points: points))
    }

    private struct RetainedProject {
        let name: String
        let location: String?
        var agents: Set<AgentKind> = []
    }

    static func catalog(_ db: Database, hostHome: String?) throws -> [IndexedProject] {
        let live = try AgentStore.projectCatalog(db, hostHome: hostHome)
        return try ProjectPinPreferences.ordered(live + archivedOnlyProjects(db, live: live))
    }

    private static func archivedOnlyProjects(_ db: Database, live: [IndexedProject]) throws -> [IndexedProject] {
        let active = Set(live.map(\.id.retentionKey))
        let rows = try Row.fetchCursor(db, sql: """
            SELECT r.project_key,r.label,r.location,s.agent
            FROM retained_archive_scopes r JOIN sources s ON s.id=r.source_id
            WHERE length(r.project_key)=32 AND r.label IS NOT NULL
                AND EXISTS (SELECT 1 FROM retained_archive_usage u WHERE u.scope_id=r.id)
            ORDER BY r.id
            """)
        var old: [Data: RetainedProject] = [:]
        var order: [Data] = []
        try rows.forEach { row in
            let key: Data = row["project_key"]
            guard !active.contains(key), let agent = AgentKind(rawValue: row["agent"]) else { return }
            if old[key] == nil { order.append(key) }
            old[key, default: .init(name: row["label"], location: row["location"])].agents.insert(agent)
        }
        guard !order.isEmpty else { return [] }
        let pins = try ProjectPinPreferences.keys(db)
        let catalogKeys = try ProjectPinPreferences.catalogKeysForArchives(db)
        return order.compactMap { key in
            old[key].map { info in
                let id = IndexedProject.ID.retained(key)
                let pinKey = catalogKeys[key] ?? key
                return IndexedProject(id: id, name: info.name, path: nil, repositoryURL: nil, location: info.location,
                                      agents: AgentKind.allCases.filter(info.agents.contains), branches: [],
                                      sessions: [], activityScope: .init(sessionIDs: []), pinTarget: .init(id: id, key: pinKey),
                                      pinned: pins.contains(pinKey), revealPath: nil)
            }
        }
    }

    private struct Bounds: Encodable {
        let bucket: Int64
        let lower: Int64
        let upper: Int64

        static func clip(_ bucket: UsageRange, to report: UsageRange) -> Self? {
            let lower = max(bucket.lowerBound, report.lowerBound)
            let upper = min(bucket.upperBound, report.upperBound)
            return lower < upper ? .init(bucket: bucket.lowerBound, lower: lower, upper: upper) : nil
        }
    }

    private struct Membership {
        private struct Member: Encodable { let slot: Int; let session: Int64 }
        private struct Archive: Encodable { let slot: Int; let hex: String }

        private let members: String
        private let archives: String

        init(_ projects: [IndexedProject]) throws {
            let members = projects.enumerated().flatMap { slot, project in
                project.activityScope.sessionIDs.map { Member(slot: slot, session: $0) }
            }
            let archives = projects.enumerated().map { slot, project in
                Archive(slot: slot, hex: project.id.retentionKey.map { String(format: "%02x", $0) }.joined())
            }
            self.members = try Self.encode(members)
            self.archives = try Self.encode(archives)
        }

        private static func encode<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }

        private static let membership = """
            members AS (SELECT value ->> '$.slot' AS slot,value ->> '$.session' AS sid FROM json_each(?)),
            archives AS (SELECT value ->> '$.slot' AS slot,unhex(value ->> '$.hex') AS project_key FROM json_each(?)),
            retained AS (
                SELECT a.slot,r.id AS sid FROM archives a
                CROSS JOIN retained_archive_scopes r WHERE r.project_key=a.project_key
            )
            """

        func firstDatedTimestamp(_ db: Database, before now: Int64) throws -> Int64? {
            try Int64.fetchOne(db, sql: """
                WITH \(Self.membership)
                SELECT min(first) FROM (
                    SELECT (
                        SELECT ts FROM token_events t INDEXED BY token_events_session_time
                        WHERE t.session_id=m.sid AND ts<>0 AND ts<? ORDER BY ts LIMIT 1
                    ) AS first FROM members m
                    UNION ALL
                    SELECT (
                        SELECT ts FROM retained_archive_usage u INDEXED BY retained_archive_usage_scope_time
                        WHERE u.scope_id=r.sid AND ts<>0 AND ts<? ORDER BY ts LIMIT 1
                    ) FROM retained r
                )
                """, arguments: [members, archives, now, now])
        }

        private static let facts = """
            WITH \(membership),
            ranges AS (
                SELECT value ->> '$.bucket' AS bucket,value ->> '$.lower' AS lo,value ->> '$.upper' AS hi FROM json_each(?)
            ),
            facts AS (
                SELECT m.slot,r.bucket,t.ts,t.agent,t.precision,input_fresh,cache_read,cache_write,cache_write_1h,
                    output,reasoning,cost_micro_usd,
                    CASE WHEN price_status='unpriced' THEN input_fresh+cache_read+cache_write+cache_write_1h+output ELSE 0 END AS unpriced_tokens,
                    1 AS records
                FROM ranges r CROSS JOIN members m CROSS JOIN token_events t INDEXED BY token_events_session_time
                WHERE t.session_id=m.sid AND t.ts>=r.lo AND t.ts<r.hi
                UNION ALL
                SELECT m.slot,r.bucket,u.ts,u.agent,u.precision,input_fresh,cache_read,cache_write,cache_write_1h,
                    output,reasoning,cost_micro_usd,unpriced_tokens,records
                FROM ranges r CROSS JOIN retained m CROSS JOIN retained_archive_usage u INDEXED BY retained_archive_usage_scope_time
                WHERE u.scope_id=m.sid AND u.ts>=r.lo AND u.ts<r.hi
            )
            """

        func totals(_ db: Database, coverage: [Bounds], projects: [IndexedProject]) throws -> [IndexedProject.ID: UsageTotals] {
            let rows = try Row.fetchAll(db, sql: """
                \(Self.facts)
                SELECT slot,\(UsageTotals.aggregateColumns) FROM facts GROUP BY slot
                """, arguments: [members, archives, try Self.encode(coverage)])
            var result: [IndexedProject.ID: UsageTotals] = [:]
            for row in rows {
                let slot: Int = row["slot"]
                guard projects.indices.contains(slot) else { throw StoreError.invalidStoredValue }
                result[projects[slot].id] = .fromAggregate(row)
            }
            return result
        }

        func points(_ db: Database, coverage: [Bounds]) throws -> [UsagePoint] {
            try Row.fetchAll(db, sql: """
                \(Self.facts)
                SELECT bucket,agent,precision<>'call' AS coarse,\(UsageTotals.aggregateColumns)
                FROM facts WHERE ts<>0 GROUP BY bucket,agent,coarse ORDER BY bucket,agent,coarse
                """, arguments: [members, archives, try Self.encode(coverage)]).map {
                    guard let agent = AgentKind(rawValue: $0["agent"]) else { throw StoreError.invalidStoredValue }
                    return UsagePoint(timestamp: $0["bucket"], agent: agent, coarse: $0["coarse"],
                                      totals: .fromAggregate($0))
                }
        }
    }
}
