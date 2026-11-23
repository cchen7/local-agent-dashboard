import ADCore
import Foundation
import GRDB

public extension AgentStore {
    /// Re-resolve the original project selection in the same snapshot as its
    /// term counts and search proof. Never match a masked display path.
    func indexedProjectTopicUpdates(_ target: IndexedProjectPinTarget, hostHome: String? = nil)
        -> some AsyncSequence<[String], any Error> & Sendable {
        ValueObservation.tracking { db in
            guard let project = try Self.projectCatalog(db, hostHome: hostHome)
                .first(where: { $0.pinTarget == target }) else { return [] }
            return try TopicRanking.projectTopics(project.activityScope.sessionIDs, db: db)
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }
}

enum TopicRanking {
    private static let corpus = """
        SELECT count(*) AS n FROM sessions s LEFT JOIN source_files f ON f.id=s.file_id
        WHERE f.role IS NOT 'prompt_history'
        """

    /// nil means legacy labels have not yet been replaced. A pending refresh
    /// of a computed document is different: hide stale labels until ready.
    static func sessionTopics(_ id: Int64, db: Database) throws -> [String]? {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM topic_documents WHERE session_id=?)",
                               arguments: [id]) == true else { return nil }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM topic_jobs WHERE session_id=?)",
                             arguments: [id]) == true { return [] }
        let candidates = try String.fetchAll(db, sql: """
            WITH corpus AS (\(corpus))
            SELECT t.term FROM topic_term_counts t JOIN term_df d ON d.term=t.term CROSS JOIN corpus
            WHERE t.session_id=? AND corpus.n>0 AND d.df BETWEEN 1 AND corpus.n
            ORDER BY ln(1.0+t.count)*ln(1.0*corpus.n/(1+d.df)) DESC,t.term COLLATE BINARY LIMIT 64
            """, arguments: [id])
        return try AgentStore.overviewSearchableTopics(candidates, in: id, db: db, distinctLimit: 5)
    }

    static func projectTopics(_ memberIDs: [Int64], db: Database) throws -> [String] {
        guard !memberIDs.isEmpty else { return [] }
        let members = String(decoding: try JSONEncoder().encode(memberIDs), as: UTF8.self)
        let candidates = try String.fetchAll(db, sql: """
            WITH corpus AS (\(corpus)), project_counts AS (
                SELECT t.term,sum(t.count) AS weighted FROM json_each(?) member
                JOIN topic_term_counts t ON t.session_id=member.value
                WHERE NOT EXISTS (SELECT 1 FROM topic_jobs j WHERE j.session_id=t.session_id)
                GROUP BY t.term
            )
            SELECT p.term FROM project_counts p JOIN term_df d ON d.term=p.term CROSS JOIN corpus
            WHERE corpus.n>0 AND d.df BETWEEN 1 AND corpus.n
            ORDER BY ln(1.0+p.weighted)*ln(1.0*corpus.n/(1+d.df)) DESC,p.term COLLATE BINARY LIMIT 64
            """, arguments: [members])
        var result: [String] = []
        for term in candidates {
            if result.contains(where: { $0.contains(term) }) { continue }
            if try AgentStore.projectSearchableTopic(term, membership: members, db: db) {
                result.append(term)
                if result.count == 5 { break }
            }
        }
        return result
    }
}
