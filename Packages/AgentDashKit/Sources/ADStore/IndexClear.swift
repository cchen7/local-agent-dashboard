import ADCore
import Foundation
import GRDB

public enum IndexClearScope: Hashable, Sendable {
    case project(IndexedProject.ID)
    case source(Int64)
    case everything
}

public struct IndexClearChoice: Identifiable, Equatable, Sendable {
    public let id: IndexClearScope
    public let label: String
    public let location: String?
    public let removedSource: Bool
}

public enum IndexClearError: Error, Equatable, Sendable {
    case selectionMissing, selectionChanged, indexingActive
}

/// An immutable view of what the user reviewed. IDs alone do not identify a
/// stable selection: SQLite may reuse IDs and mapped project membership can move.
public struct IndexClearPlan: Sendable {
    public let scope: IndexClearScope
    public let label: String?
    public var sessionCount: Int { selection.sessions.count }
    public var fileCount: Int { selection.files.count }
    fileprivate let owner: ObjectIdentifier
    fileprivate let selection: ClearSelection
}

public struct IndexClearResult: Sendable {
    public let removedSessions: Int
    public let resetFiles: Int
}

public extension AgentStore {
    func indexClearChoices(hostHome: String?) -> some AsyncSequence<[IndexClearChoice], any Error> & Sendable {
        ValueObservation.tracking { db in
            let projects = try Self.projectCatalog(db, hostHome: hostHome).map {
                IndexClearChoice(id: .project($0.id), label: $0.name,
                                 location: [$0.path, $0.location].compactMap(\.self).joined(separator: " · "), removedSource: false)
            }
            let sources = try Row.fetchAll(db, sql: """
                SELECT s.id,s.label,s.root_path,s.removed FROM sources s
                WHERE s.removed=0 OR EXISTS(SELECT 1 FROM sessions WHERE source_id=s.id)
                      OR EXISTS(SELECT 1 FROM source_files WHERE source_id=s.id AND size IS NOT NULL)
                ORDER BY s.id
                """).map {
                    IndexClearChoice(id: .source($0["id"]), label: $0["label"], location: $0["root_path"], removedSource: $0["removed"])
                }
            return projects + sources
        }.removeDuplicates().values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    func prepareIndexClear(_ scope: IndexClearScope, hostHome: String?) throws -> IndexClearPlan {
        try databasePool.read { db in
            let selected = try ClearSelection.resolve(scope, hostHome: hostHome, db: db)
            return IndexClearPlan(scope: scope, label: selected.label, owner: ObjectIdentifier(self), selection: selected)
        }
    }

    /// Source files and preferences are outside the clear operation. Recheck
    /// membership in the same transaction that removes index-owned data.
    func clearIndex(_ plan: IndexClearPlan, hostHome: String?) throws -> IndexClearResult {
        guard plan.owner == ObjectIdentifier(self) else { throw IndexClearError.selectionChanged }
        return try databasePool.write { db in
            let selected: ClearSelection
            do { selected = try ClearSelection.resolve(plan.scope, hostHome: hostHome, db: db) }
            catch IndexClearError.selectionMissing { throw IndexClearError.selectionChanged }
            guard selected.sessions == plan.selection.sessions, selected.files == plan.selection.files,
                  (selected.label ?? "").utf8.elementsEqual((plan.label ?? "").utf8) else {
                throw IndexClearError.selectionChanged
            }
            try selected.stageTargets(db)
            try db.execute(sql: """
                INSERT OR IGNORE INTO temp.clear_index_refs(kind,id)
                    SELECT 'blob',blob_id FROM events
                    WHERE blob_id IS NOT NULL AND session_id IN (SELECT id FROM temp.clear_index_sessions);
                INSERT OR IGNORE INTO temp.clear_index_refs(kind,id)
                    SELECT 'basis',rate_basis_id FROM token_events
                    WHERE rate_basis_id IS NOT NULL AND session_id IN (SELECT id FROM temp.clear_index_sessions);
                INSERT OR IGNORE INTO temp.clear_index_refs(kind,id)
                    SELECT 'project',project_id FROM sessions
                    WHERE project_id IS NOT NULL AND id IN (SELECT id FROM temp.clear_index_sessions);
                UPDATE sessions SET parent_session_id=NULL WHERE parent_session_id IN (SELECT id FROM temp.clear_index_sessions);
                UPDATE sessions SET resumed_from_session_id=NULL WHERE resumed_from_session_id IN (SELECT id FROM temp.clear_index_sessions);
                DELETE FROM sessions WHERE id IN (SELECT id FROM temp.clear_index_sessions);
                """)
            let removed = db.changesCount
            guard removed == selected.sessions.count else { throw IndexClearError.selectionChanged }
            try db.execute(sql: """
                DELETE FROM blobs WHERE id IN (SELECT id FROM temp.clear_index_refs WHERE kind='blob')
                    AND NOT EXISTS(SELECT 1 FROM events WHERE blob_id=blobs.id);
                DELETE FROM token_rate_bases WHERE id IN (SELECT id FROM temp.clear_index_refs WHERE kind='basis')
                    AND NOT EXISTS(SELECT 1 FROM token_events WHERE rate_basis_id=token_rate_bases.id);
                DELETE FROM projects WHERE id IN (SELECT id FROM temp.clear_index_refs WHERE kind='project') AND pinned=0
                    AND NOT EXISTS(SELECT 1 FROM sessions WHERE project_id=projects.id);
                DELETE FROM term_df WHERE term NOT IN (SELECT term FROM session_keywords);
                UPDATE source_files SET device=NULL,inode=NULL,size=NULL,mtime_ns=NULL,read_offset=0,parser_version=0,
                    last_seq=-1,previous_ts=NULL,decoder_state=NULL,unknown_records=0,last_error=NULL,
                    state=CASE WHEN state='gone' THEN 'gone' ELSE 'ok' END
                    WHERE id IN (SELECT id FROM temp.clear_index_files);
                """)
            let reset = db.changesCount
            switch plan.scope {
            case .everything:
                // Include aggregate-only legacy data whose original rows no
                // longer exist. Scoped clears only remove attributed usage.
                try db.execute(sql: """
                    DELETE FROM token_minute;
                    DELETE FROM token_usage_scope;
                    DELETE FROM cache_savings_hour;
                    DELETE FROM rate_limit_snapshots;
                    DELETE FROM token_rate_bases;
                    DELETE FROM blobs;
                    DELETE FROM projects;
                    DELETE FROM app_meta WHERE key='cache_savings_legacy_through';
                    UPDATE sources SET last_scan_at=NULL,status=NULL,last_error=NULL;
                    """)
                try UsageChartChanges.invalidateAll(db)
            case .source(let sourceID):
                try db.execute(sql: "UPDATE sources SET last_scan_at=NULL,status=NULL,last_error=NULL WHERE id=?",
                               arguments: [sourceID])
                try UsageChartChanges.publish(db)
            case .project:
                try UsageChartChanges.publish(db)
            }
            try db.execute(sql: "DELETE FROM temp.clear_index_sessions; DELETE FROM temp.clear_index_files; DELETE FROM temp.clear_index_refs;")
            return .init(removedSessions: removed, resetFiles: reset)
        }
    }
}

fileprivate struct ClearSelection: Sendable {
    struct Session: Equatable, Sendable {
        let id: Int64
        let agent: String
        let nativeID: Data
        let fileID: Int64?

        init(_ row: Row) {
            id = row["id"]
            agent = row["agent"]
            let key: String = row["native_id"]
            nativeID = Data(key.utf8)
            fileID = row["file_id"]
        }
    }

    struct File: Equatable, Sendable {
        let id: Int64
        let sourceID: Int64
        let path: Data

        init(_ row: Row) {
            id = row["id"]
            sourceID = row["source_id"]
            let spelling: String = row["rel_path"]
            path = Data(spelling.utf8)
        }
    }

    let label: String?
    let sessions: [Session]
    let files: [File]

    static func resolve(_ scope: IndexClearScope, hostHome: String?, db: Database) throws -> Self {
        let sessionSQL = "SELECT id,agent,native_id,file_id FROM sessions"
        let fileSQL = "SELECT id,source_id,rel_path FROM source_files"
        switch scope {
        case .everything:
            return .init(label: nil, sessions: try Row.fetchAll(db, sql: sessionSQL + " ORDER BY id").map(Session.init),
                         files: try Row.fetchAll(db, sql: fileSQL + " ORDER BY id").map(File.init))
        case .source(let id):
            guard let row = try Row.fetchOne(db, sql: "SELECT label,root_path FROM sources WHERE id=?", arguments: [id])
            else { throw IndexClearError.selectionMissing }
            let name: String = row["label"]
            let path: String = row["root_path"]
            return .init(label: [name, path].joined(separator: " · "),
                         sessions: try Row.fetchAll(db, sql: sessionSQL + " WHERE source_id=? ORDER BY id", arguments: [id]).map(Session.init),
                         files: try Row.fetchAll(db, sql: fileSQL + " WHERE source_id=? ORDER BY id", arguments: [id]).map(File.init))
        case .project(let id):
            guard let project = try AgentStore.projectCatalog(db, hostHome: hostHome).first(where: { $0.id == id })
            else { throw IndexClearError.selectionMissing }
            let selected = try readRows(db, ids: project.activityScope.sessionIDs, base: sessionSQL).map(Session.init)
            let files = try readRows(db, ids: Array(Set(selected.compactMap(\.fileID))), base: fileSQL).map(File.init)
            let label = [project.name, project.path, project.location].compactMap { $0 }.joined(separator: " · ")
            return .init(label: label, sessions: selected, files: files)
        }
    }

    private static func readRows(_ db: Database, ids: [Int64], base: String) throws -> [Row] {
        let ordered = ids.sorted()
        var rows: [Row] = []
        for start in stride(from: 0, to: ordered.count, by: 400) {
            let slice = ordered[start..<min(start + 400, ordered.count)]
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            rows += try Row.fetchAll(db, sql: base + " WHERE id IN (\(placeholders)) ORDER BY id",
                                     arguments: StatementArguments(slice))
        }
        return rows
    }

    func stageTargets(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS clear_index_sessions(id INTEGER PRIMARY KEY);
            CREATE TEMP TABLE IF NOT EXISTS clear_index_files(id INTEGER PRIMARY KEY);
            CREATE TEMP TABLE IF NOT EXISTS clear_index_refs(kind TEXT NOT NULL,id INTEGER NOT NULL,PRIMARY KEY(kind,id)) WITHOUT ROWID;
            DELETE FROM temp.clear_index_sessions;
            DELETE FROM temp.clear_index_files;
            DELETE FROM temp.clear_index_refs;
            """)
        let insertSession = try db.cachedStatement(sql: "INSERT INTO temp.clear_index_sessions VALUES(?)")
        for session in sessions { try insertSession.execute(arguments: [session.id]) }
        let insertFile = try db.cachedStatement(sql: "INSERT INTO temp.clear_index_files VALUES(?)")
        for file in files { try insertFile.execute(arguments: [file.id]) }
    }
}
