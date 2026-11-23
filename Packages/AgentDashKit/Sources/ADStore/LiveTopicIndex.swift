import ADCore
import Foundation
import GRDB

public struct PreparedTopicUpdate: Sendable {
    public let sessionID: Int64
    let revision: Data
    let terms: [String: Double]
}

public extension AgentStore {
    func topicWorkUpdates() -> some AsyncSequence<Data?, any Error> & Sendable {
        ValueObservation.tracking { db in
            // A different revision wakes the worker even if SQLite observers
            // coalesce an empty-queue transition with the next incoming job.
            try Data.fetchOne(db, sql: "SELECT revision FROM topic_jobs ORDER BY session_id LIMIT 1")
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    /// Collect a few documents from a consistent read snapshot. The scorer
    /// only sees whole indexed fields, not files or retained aggregates.
    func prepareTopicUpdates(scoring: IndexTopicScoring, afterID: Int64) throws -> [PreparedTopicUpdate] {
        try databasePool.read { db in
            let jobs = try Row.fetchAll(db, sql: """
                SELECT j.session_id,j.revision,s.agent,f.role FROM topic_jobs j
                JOIN sessions s ON s.id=j.session_id LEFT JOIN source_files f ON f.id=s.file_id
                WHERE j.session_id>? ORDER BY j.session_id LIMIT 4
                """, arguments: [afterID])
            return try jobs.map { job in
                try Task.checkCancellation()
                let id: Int64 = job["session_id"]
                let counts: [String: Double]
                if (job["role"] as String?) == SourceFile.Role.promptHistory.rawValue {
                    counts = [:]
                } else {
                    counts = try TopicCorpus.counts(db, session: id,
                        claude: (job["agent"] as String) == AgentKind.claudeCode.rawValue, scoring: scoring)
                }
                return .init(sessionID: id, revision: job["revision"], terms: counts)
            }
        }
    }

    @discardableResult
    func applyTopicUpdates(_ updates: [PreparedTopicUpdate]) throws -> Int {
        guard !updates.isEmpty else { return 0 }
        return try databasePool.write { db in
            var applied = 0
            for update in updates {
                try Task.checkCancellation()
                let current = try Data.fetchOne(db, sql: "SELECT revision FROM topic_jobs WHERE session_id=?",
                                                arguments: [update.sessionID])
                guard current == update.revision else { continue }
                try TopicLedger.replace(update.terms, sessionID: update.sessionID, db: db)
                try db.execute(sql: "DELETE FROM topic_jobs WHERE session_id=?", arguments: [update.sessionID])
                applied += 1
            }
            return applied
        }
    }
}

enum TopicLedger {
    static func replace(_ terms: [String: Double], sessionID: Int64, db: Database) throws {
        try db.cachedStatement(sql: "DELETE FROM topic_term_counts WHERE session_id=?").execute(arguments: [sessionID])
        try db.cachedStatement(sql: "DELETE FROM session_keywords WHERE session_id=?").execute(arguments: [sessionID])
        let insert = try db.cachedStatement(sql: "INSERT INTO topic_term_counts(session_id,term,count) VALUES(?,?,?)")
        for (term, count) in terms {
            try Task.checkCancellation()
            try insert.execute(arguments: [sessionID, term, count])
        }
        try db.cachedStatement(sql: "INSERT OR IGNORE INTO topic_documents VALUES(?)").execute(arguments: [sessionID])
    }

    static func invalidateAll(_ db: Database) throws {
        try clear(db)
        try db.execute(sql: """
            INSERT INTO topic_jobs SELECT id,randomblob(16) FROM sessions WHERE 1
            ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision
            """)
    }

    static func rebuild(_ db: Database, scoring: IndexTopicScoring) throws {
        try clear(db)
        let sessions = try Row.fetchCursor(db, sql: """
            SELECT s.id,s.agent FROM sessions s LEFT JOIN source_files f ON f.id=s.file_id
            WHERE f.role IS NOT 'prompt_history' ORDER BY s.id
            """)
        while let row = try sessions.next() {
            try Task.checkCancellation()
            let id: Int64 = row["id"]
            let claude = (row["agent"] as String) == AgentKind.claudeCode.rawValue
            try replace(TopicCorpus.counts(db, session: id, claude: claude, scoring: scoring), sessionID: id, db: db)
        }
        // Prepared work from before the rebuild can no longer be applied.
        try db.execute(sql: "DELETE FROM topic_jobs")
    }

    private static func clear(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM session_keywords; DELETE FROM topic_term_counts; DELETE FROM topic_documents; DELETE FROM term_df;")
    }
}
