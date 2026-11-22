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
        try db.execute(sql: """
            CREATE TEMP TABLE rebuild_topic_counts(
                session_id INTEGER, term TEXT, weight REAL,
                PRIMARY KEY(session_id,term)
            ) WITHOUT ROWID;
            """)
        let sessions = try Row.fetchCursor(db, sql: """
            SELECT s.id,s.agent FROM sessions s LEFT JOIN source_files f ON f.id=s.file_id
            WHERE f.role IS NOT 'prompt_history'
            """)
        var documentCount = 0
        while let row = try sessions.next() {
            try Task.checkCancellation()
            documentCount += 1
            let session: Int64 = row["id"]
            let claude = (row["agent"] as String) == AgentKind.claudeCode.rawValue
            let rows = try Row.fetchCursor(db, sql: """
                SELECT kind,CASE WHEN length(CAST(text AS BLOB))<=1048576 THEN text END AS preview,
                  CASE WHEN ? AND substr(dedupe_key,1,13)='claude:event:'
                    THEN CASE WHEN kind='assistant' AND length(CAST(meta_json AS BLOB))<=4096
                                  AND json_valid(meta_json) AND json_extract(meta_json,'$.claude_message_id') IS NOT NULL
                         THEN 'm:' || json_extract(meta_json,'$.claude_message_id')
                         ELSE 'p:' || seq || ':' || rtrim(dedupe_key,'0123456789') END
                    ELSE 'e:' || id END AS message
                FROM events WHERE session_id=? AND kind IN ('user','assistant') AND text IS NOT NULL
                  AND (transcript_channel IS NOT 'fallback' OR NOT EXISTS(
                      SELECT 1 FROM events preferred
                      WHERE preferred.session_id=? AND preferred.transcript_channel='preferred'))
                ORDER BY kind,message COLLATE BINARY,seq,rtrim(dedupe_key,'0123456789'),
                    CAST(substr(dedupe_key,length(rtrim(dedupe_key,'0123456789'))+1) AS INTEGER),id
                """, arguments: [claude, session, session])
            var counts: [String: Double] = [:]
            var message: String?
            var role = ""
            var text = ""
            var bytes = 0
            var blocks = 0
            var oversized = false
            func countMessage() {
                guard message != nil, !oversized else { return }
                let input: IndexTopicInput = role == "user" ? .prompt(text) : .reply(text)
                for (term, count) in scoring.counts(input) { counts[term, default: 0] += count }
            }
            while let row = try rows.next() {
                try Task.checkCancellation()
                let next: String = row["message"]
                let kind: String = row["kind"]
                if role != kind || message?.utf8.elementsEqual(next.utf8) != true {
                    countMessage()
                    role = kind
                    message = next
                    text = ""
                    bytes = 0
                    blocks = 0
                    oversized = false
                }
                guard !oversized, let piece: String = row["preview"], blocks < 240,
                      piece.utf8.count <= 1_048_576 - bytes else {
                    oversized = true
                    continue
                }
                // Mask the reconstructed message, including secrets split across blocks.
                text.append(piece)
                bytes += piece.utf8.count
                blocks += 1
            }
            countMessage()
            let paths = try String.fetchCursor(db, sql: """
                SELECT DISTINCT path FROM file_touches WHERE session_id=? AND length(CAST(path AS BLOB))<=16384
                """, arguments: [session])
            while let path = try paths.next() {
                try Task.checkCancellation()
                for (term, count) in scoring.counts(.path(path)) { counts[term, default: 0] += count }
            }
            for (term, count) in counts where !term.isEmpty && term.utf8.count <= 512 && count.isFinite && count > 0 {
                try db.cachedStatement(sql: """
                    INSERT INTO temp.rebuild_topic_counts(session_id,term,weight) VALUES(?,?,?)
                    """).execute(arguments: [session, term, count])
            }
        }
        try db.execute(sql: """
            DELETE FROM main.session_keywords;
            DELETE FROM main.term_df;
            INSERT INTO main.term_df(term,df)
                SELECT term,count(*) FROM temp.rebuild_topic_counts GROUP BY term;
            """)
        let terms = try Row.fetchCursor(db, sql: """
            SELECT t.session_id,t.term,t.weight,f.df FROM temp.rebuild_topic_counts t
            JOIN main.term_df f ON f.term=t.term ORDER BY t.session_id
            """)
        var session: Int64?
        var counts: [String: Double] = [:]
        var frequencies: [String: Int] = [:]
        func save() throws {
            guard let session else { return }
            try Task.checkCancellation()
            for item in scoring.top(counts, documentCount, frequencies) {
                try db.cachedStatement(sql: """
                    INSERT INTO main.session_keywords(session_id,term,weight) VALUES(?,?,?)
                    """).execute(arguments: [session, item.term, item.weight])
            }
        }
        while let row = try terms.next() {
            let id: Int64 = row["session_id"]
            if id != session {
                try save()
                session = id
                counts.removeAll(keepingCapacity: true)
                frequencies.removeAll(keepingCapacity: true)
            }
            let term: String = row["term"]
            counts[term] = row["weight"]
            frequencies[term] = row["df"]
        }
        try save()
        try db.execute(sql: "DROP TABLE temp.rebuild_topic_counts")
    }

    static func prepareUsage(_ db: Database) throws {
        // Candidate rows are isolated from the active projections until all
        // coverage checks pass. Use the same keys and floor division as v9-v12.
        try db.execute(sql: """
            CREATE TEMP TABLE rebuild_minute AS
            SELECT ts/60000-(ts%60000<0) AS bucket,agent,coalesce(project_id,0) AS project_id,
                coalesce(model,'') AS model,precision,
                sum(input_fresh) AS input_fresh,sum(cache_read) AS cache_read,
                sum(cache_write) AS cache_write,sum(cache_write_1h) AS cache_write_1h,
                sum(output) AS output,sum(reasoning) AS reasoning,sum(cost_micro_usd) AS cost_micro_usd,
                sum(CASE WHEN price_status='unpriced' THEN input_fresh+cache_read+cache_write+cache_write_1h+output ELSE 0 END)
                    AS unpriced_tokens,count(*) AS records
            FROM main.token_events GROUP BY 1,2,3,4,5;
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
            SELECT ts/3600000-(ts%3600000<0) AS bucket,agent,coalesce(project_id,0) AS project_id,
                sum(cache_savings_micro_usd) AS savings_micro_usd,sum(cache_read) AS measured_cache_read
            FROM main.token_events
            WHERE cache_savings_micro_usd IS NOT NULL AND cache_read>0 GROUP BY 1,2,3;
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
