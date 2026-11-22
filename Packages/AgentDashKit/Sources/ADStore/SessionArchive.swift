import ADCore
import GRDB

/// An indexed file observed before the reader checks the filesystem.
public struct SourceArchiveCandidate: Sendable {
    public let id: Int64
    public let relativePath: String
    let checkpoint: Checkpoint
}

public extension AgentStore {
    /// Record a completed discovery pass, separately from verifying access.
    func recordSourceScan(sourceID: Int64, at timestamp: Int64) throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE sources SET last_scan_at=? WHERE id=? AND enabled=1",
                           arguments: [timestamp, sourceID])
        }
    }

    /// The full scan compares only path keys, without reading decoder state.
    func unarchivedTranscriptPaths(sourceID: Int64) throws -> [String] {
        try databasePool.read { db in
            try String.fetchAll(db, sql: """
                SELECT rel_path FROM source_files WHERE source_id=? AND state<>'gone'
                    AND size IS NOT NULL AND role IN ('session','subagent')
                """, arguments: [sourceID])
        }
    }

    /// Only previously indexed transcript files can become archived.
    func sourceArchiveCandidate(sourceID: Int64, relativePath: String) throws -> SourceArchiveCandidate? {
        try databasePool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM source_files WHERE source_id=? AND state<>'gone'
                    AND size IS NOT NULL AND role IN ('session','subagent') AND rel_path=? COLLATE BINARY
                """, arguments: [sourceID, relativePath]).map { row in
                    .init(id: row["id"], relativePath: row["rel_path"], checkpoint: Self.decodeCheckpoint(row))
                }
        }
    }

    /// Record absences previously confirmed under the authorized root. A
    /// newer ingest checkpoint wins; this write never deletes indexed data.
    func archiveMissingSourceFiles(_ files: [SourceArchiveCandidate], sourceID: Int64,
                                   at timestamp: Int64) throws {
        guard !files.isEmpty else { return }
        try databasePool.write { db in
            for file in files {
                guard try Self.readCheckpoint(file.id, db: db) == file.checkpoint else { continue }
                try db.execute(sql: """
                    UPDATE source_files SET state='gone',last_error=NULL
                    WHERE id=? AND source_id=? AND rel_path=? COLLATE BINARY
                      AND EXISTS(SELECT 1 FROM sources WHERE id=? AND enabled=1)
                    """, arguments: [file.id, sourceID, file.relativePath, sourceID])
                guard db.changesCount == 1 else { continue }
                try db.execute(sql: """
                    UPDATE sessions SET source_deleted_at=?
                    WHERE source_id=? AND file_id=? AND source_deleted_at IS NULL
                    """, arguments: [timestamp, sourceID, file.id])
            }
        }
    }
}
