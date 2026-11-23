import ADCore
import GRDB

/// Recorded facts from the app index. Does not report live directory access
/// or expose the raw error fields.
public struct IndexedSourceStatus: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let trackedFiles: Int64
    public let indexedFiles: Int64
    public let partialFiles: Int64
    public let failedFiles: Int64
    public let goneFiles: Int64
    public let sessions: Int64
    public let archivedSessions: Int64
    public let unknownRecords: Int64
    public let lastScanAt: Int64?
    public let hasRecordedSourceError: Bool
}

public extension AgentStore {
    /// Observe checkpoint and session counts without opening a configured root.
    func indexedSourceStatusUpdates()
    -> some AsyncSequence<[IndexedSourceStatus], any Error> & Sendable {
        ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: """
                WITH file_stats AS (
                    SELECT source_id,count(*) AS tracked,count(size) AS indexed,
                           sum(state='partial') AS partial,sum(state='error' OR last_error IS NOT NULL) AS failed,sum(state='gone') AS gone,
                           sum(unknown_records) AS unknown
                    FROM source_files GROUP BY source_id
                ), session_stats AS (
                    SELECT s.source_id,count(*) AS sessions,sum(s.source_deleted_at IS NOT NULL) AS archived
                    FROM sessions s LEFT JOIN source_files f ON f.id=s.file_id
                    WHERE f.role IS NULL OR f.role<>?
                    GROUP BY s.source_id
                )
                SELECT s.id,s.last_scan_at,(s.last_error IS NOT NULL AND s.last_error<>'') AS has_error,
                       coalesce(f.tracked,0) AS tracked,coalesce(f.indexed,0) AS indexed,
                       coalesce(f.partial,0) AS partial,coalesce(f.failed,0) AS failed,coalesce(f.gone,0) AS gone,
                       coalesce(f.unknown,0) AS unknown,
                       coalesce(t.sessions,0) AS sessions,coalesce(t.archived,0) AS archived
                FROM sources s LEFT JOIN file_stats f ON f.source_id=s.id
                LEFT JOIN session_stats t ON t.source_id=s.id WHERE s.removed=0 ORDER BY s.id
                """, arguments: [SourceFile.Role.promptHistory.rawValue]).map { row in
                    IndexedSourceStatus(id: row["id"], trackedFiles: row["tracked"], indexedFiles: row["indexed"],
                                        partialFiles: row["partial"], failedFiles: row["failed"], goneFiles: row["gone"],
                                        sessions: row["sessions"], archivedSessions: row["archived"],
                                        unknownRecords: row["unknown"], lastScanAt: row["last_scan_at"],
                                        hasRecordedSourceError: row["has_error"])
                }
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }
}
