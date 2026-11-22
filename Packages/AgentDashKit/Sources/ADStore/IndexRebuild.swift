import ADCore
import Foundation
import GRDB

public enum IndexRebuildError: Error, Equatable, Sendable {
    /// At least one rollup holds data the current source rows cannot reproduce.
    case unbackedUsage
}

public struct IndexRebuildResult: Equatable, Sendable {
    public let indexedEvents: Int
    public let usageRows: Int
}

/// Bounded input from one complete indexed field.
public enum IndexTopicInput: Sendable {
    case prompt(String), reply(String), path(String)
}

/// The store owns the transaction; ADInsights supplies deterministic scoring.
public struct IndexTopicScoring: Sendable {
    let counts: @Sendable (IndexTopicInput) -> [String: Double]
    let top: @Sendable ([String: Double], Int, [String: Int]) -> [(term: String, weight: Double)]

    public init(counts: @escaping @Sendable (IndexTopicInput) -> [String: Double],
                top: @escaping @Sendable ([String: Double], Int, [String: Int]) -> [(term: String, weight: Double)]) {
        self.counts = counts
        self.top = top
    }
}

public extension AgentStore {
    /// Logical bytes used by the index and its own SQLite sidecars.
    func indexStorageBytes() throws -> Int64 {
        var total: Int64 = 0
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            do {
                let attributes = try manager.attributesOfItem(atPath: databasePool.path + suffix)
                guard let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else {
                    throw StoreError.invalidStoredValue
                }
                let (next, overflow) = total.addingReportingOverflow(size)
                guard !overflow else { throw StoreError.invalidStoredValue }
                total = next
            } catch let error as CocoaError where !suffix.isEmpty &&
                (error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile) {
                continue
            }
        }
        return total
    }

    /// Repair app-owned projections transactionally, without rescanning the
    /// agents, touching checkpoints, changing quotes, or expiring sessions.
    func rebuildIndex(scoring: IndexTopicScoring) throws -> IndexRebuildResult {
        try databasePool.write { db in
            try Task.checkCancellation()
            try IndexRebuild.prepareUsage(db)
            try IndexRebuild.validateCoverage(db)
            try Task.checkCancellation()
            let result = IndexRebuildResult(
                indexedEvents: try Int.fetchOne(db, sql: "SELECT count(*) FROM main.events") ?? 0,
                usageRows: try Int.fetchOne(db, sql: "SELECT count(*) FROM temp.rebuild_minute") ?? 0)
            try IndexRebuild.replaceUsage(db)
            try db.execute(sql: "INSERT INTO events_fts(events_fts) VALUES('rebuild')")
            try IndexRebuild.replaceTopics(db, scoring: scoring)
            try UsageChartChanges.invalidateAll(db)
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('search_rebuild_revision','1')
                ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1
                """)
            return result
        }
    }
}

private enum IndexRebuild {
    private static let measures = [
        "input_fresh", "cache_read", "cache_write", "cache_write_1h", "output", "reasoning",
        "cost_micro_usd", "unpriced_tokens", "records",
    ]
    private static let measureList = measures.joined(separator: ",")
    private static let sums = measures.map { "sum(\($0)) AS \($0)" }.joined(separator: ",")

    static func replaceTopics(_ db: Database, scoring: IndexTopicScoring) throws {
        try TopicLedger.rebuild(db, scoring: scoring)
    }

    static func prepareUsage(_ db: Database) throws {
        // Candidate rows are isolated from the active projections until all
        // coverage checks pass. Use the same keys and floor division as v9-v12.
        try db.execute(sql: """
            CREATE TEMP TABLE rebuild_minute AS
            SELECT ts/60000-(ts%60000<0) AS bucket,agent,project_id,model,precision,\(sums)
            FROM (
                SELECT ts,agent,coalesce(project_id,0) AS project_id,coalesce(model,'') AS model,precision,
                    input_fresh,cache_read,cache_write,cache_write_1h,output,reasoning,cost_micro_usd,
                    CASE WHEN price_status='unpriced' THEN input_fresh+cache_read+cache_write+cache_write_1h+output ELSE 0 END AS unpriced_tokens,
                    1 AS records
                FROM main.token_events
                UNION ALL
                SELECT ts,agent,project_id,model,precision,\(measureList) FROM main.retained_archive_usage
            ) GROUP BY 1,2,3,4,5;
            CREATE UNIQUE INDEX temp.rebuild_minute_key ON rebuild_minute(bucket,agent,project_id,model,precision);

            CREATE TEMP TABLE rebuild_scope AS
            SELECT 1 AS grain,bucket,agent,precision,\(sums)
            FROM temp.rebuild_minute GROUP BY bucket,agent,precision
            UNION ALL
            SELECT 1,bucket,'',precision,\(sums)
            FROM temp.rebuild_minute GROUP BY bucket,precision
            UNION ALL
            SELECT 60,bucket/60-(bucket%60<0),agent,precision,\(sums)
            FROM temp.rebuild_minute GROUP BY 2,agent,precision;
            CREATE UNIQUE INDEX temp.rebuild_scope_key ON rebuild_scope(grain,bucket,agent,precision);

            CREATE TEMP TABLE rebuild_savings AS
            SELECT ts/3600000-(ts%3600000<0) AS bucket,agent,project_id,
                sum(savings_micro_usd) AS savings_micro_usd,sum(measured_cache_read) AS measured_cache_read
            FROM (
                SELECT ts,agent,coalesce(project_id,0) AS project_id,cache_savings_micro_usd AS savings_micro_usd,
                    cache_read AS measured_cache_read FROM main.token_events
                WHERE cache_savings_micro_usd IS NOT NULL AND cache_read>0
                UNION ALL
                SELECT ts,agent,project_id,savings_micro_usd,measured_cache_read FROM main.retained_archive_usage
                WHERE measured_cache_read>0
            ) GROUP BY 1,2,3;
            CREATE UNIQUE INDEX temp.rebuild_savings_key ON rebuild_savings(bucket,agent,project_id);
            """)
    }

    static func validateCoverage(_ db: Database) throws {
        try requireCovered(db, existing: "token_minute", candidate: "rebuild_minute",
                           keys: ["bucket", "agent", "project_id", "model", "precision"])
        try requireCovered(db, existing: "token_usage_scope", candidate: "rebuild_scope",
                           keys: ["grain", "bucket", "agent", "precision"])
        // Savings can be signed. Guard coverage and conflicting totals at
        // equal coverage rather than comparing signed amounts by magnitude.
        let unmatched = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM main.cache_savings_hour old
                WHERE NOT EXISTS(
                    SELECT 1 FROM temp.rebuild_savings candidate
                    WHERE candidate.bucket=old.bucket AND candidate.agent=old.agent AND candidate.project_id=old.project_id
                        AND (candidate.measured_cache_read>old.measured_cache_read OR
                             (candidate.measured_cache_read=old.measured_cache_read
                              AND candidate.savings_micro_usd=old.savings_micro_usd))
                )
            )
            """) ?? true
        guard !unmatched else { throw IndexRebuildError.unbackedUsage }
    }

    private static func requireCovered(_ db: Database, existing: String, candidate: String, keys: [String]) throws {
        let match = keys.map { "new.\($0)=old.\($0)" }.joined(separator: " AND ")
        let coverage = measures.map { "new.\($0)>=old.\($0)" }.joined(separator: " AND ")
        let unmatched = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM main.\(existing) old
                WHERE NOT EXISTS(SELECT 1 FROM temp.\(candidate) new WHERE \(match) AND \(coverage))
            )
            """) ?? true
        guard !unmatched else { throw IndexRebuildError.unbackedUsage }
    }

    static func replaceUsage(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM main.token_minute;
            INSERT INTO main.token_minute(bucket,agent,project_id,model,precision,\(measureList))
                SELECT bucket,agent,project_id,model,precision,\(measureList) FROM temp.rebuild_minute;
            DELETE FROM main.token_usage_scope;
            INSERT INTO main.token_usage_scope(grain,bucket,agent,precision,\(measureList))
                SELECT grain,bucket,agent,precision,\(measureList) FROM temp.rebuild_scope;
            DELETE FROM main.cache_savings_hour;
            INSERT INTO main.cache_savings_hour(bucket,agent,project_id,savings_micro_usd,measured_cache_read)
                SELECT bucket,agent,project_id,savings_micro_usd,measured_cache_read FROM temp.rebuild_savings;
            DROP TABLE temp.rebuild_minute;
            DROP TABLE temp.rebuild_scope;
            DROP TABLE temp.rebuild_savings;
            """)
    }
}
