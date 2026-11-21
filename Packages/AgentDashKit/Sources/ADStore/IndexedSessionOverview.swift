import ADCore
import GRDB

/// A bounded snapshot of the app index for one session. Full transcript reads
/// and any filesystem access are outside the overview.
public struct IndexedSessionOverview: Equatable, Sendable {
    public let summary: String?
    public let lastPrompt: String?
    public let lastReply: String?
    public let topics: [String]
    public let recentActions: [IndexedOverviewAction]
    public let files: [IndexedOverviewFile]
    public let commands: [IndexedOverviewCommand]
}

public struct IndexedOverviewFile: Equatable, Sendable {
    public let path: String
    public let operation: String
    public let count: Int64
    public let added: Int64?
    public let removed: Int64?
    public let timestamp: Int64
}

public struct IndexedOverviewCommand: Equatable, Sendable {
    public let text: String
    public let timestamp: Int64
    public let exitCode: Int64?
    public let durationMS: Int64?
}

public enum IndexedOverviewAction: Equatable, Sendable {
    case file(IndexedOverviewFile)
    case command(IndexedOverviewCommand)
    case tool(kind: EventKind, name: String?, text: String?, timestamp: Int64)

    var time: Int64 {
        switch self {
        case .file(let row): row.timestamp
        case .command(let row): row.timestamp
        case let .tool(_, _, _, timestamp): timestamp
        }
    }
}

public extension AgentStore {
    /// Observe stored details and normalized events together, including event-only edits.
    func sessionOverviewUpdates(in session: SessionKey)
    -> some AsyncSequence<IndexedSessionOverview?, any Error> & Sendable {
        ValueObservation.tracking { db in
            try Self.overview(in: session, db: db)
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    private static func overview(in session: SessionKey, db: Database) throws -> IndexedSessionOverview? {
        // Do not truncate before masking. Oversize stored values are omitted
        // rather than exposing the unrecognizable prefix of a credential.
        guard let header = try Row.fetchOne(db, sql: """
            SELECT id,CASE WHEN length(CAST(latest_summary AS BLOB))<=1048576 THEN latest_summary END AS summary
            FROM sessions WHERE agent=? AND native_id=?
            """, arguments: [session.agent.rawValue, session.nativeID]) else { return nil }
        let id: Int64 = header["id"]
        func latestText(_ kind: EventKind) throws -> String? {
            try String.fetchOne(db, sql: """
                SELECT CASE WHEN length(CAST(text AS BLOB))<=1048576 THEN text END
                FROM events WHERE session_id=? AND kind=? AND text IS NOT NULL AND text<>''
                ORDER BY seq DESC,id DESC LIMIT 1
                """, arguments: [id, kind.rawValue])
        }
        let summary: String? = header["summary"]
        let files = try overviewFiles(in: id, order: "count DESC,last_ts DESC,path,op", limit: 10, db: db)
        let commands = try Row.fetchAll(db, sql: """
            SELECT command,ts,exit_code,duration_ms FROM commands
            WHERE session_id=? AND length(CAST(command AS BLOB))<=1048576
            ORDER BY ts DESC,id DESC LIMIT 10
            """, arguments: [id]).map { row in
                IndexedOverviewCommand(text: row["command"], timestamp: row["ts"],
                                       exitCode: row["exit_code"], durationMS: row["duration_ms"])
            }
        let recentFiles = try overviewFiles(in: id, order: "last_ts DESC,path,op", limit: 5, db: db)
        let structured = recentFiles.map(IndexedOverviewAction.file) + commands.prefix(5).map(IndexedOverviewAction.command)
        let actions: [IndexedOverviewAction]
        if structured.isEmpty {
            actions = try Row.fetchAll(db, sql: """
                SELECT kind,ts,CASE WHEN length(CAST(tool_name AS BLOB))<=16384 THEN tool_name END AS tool_name,
                       CASE WHEN length(CAST(text AS BLOB))<=1048576 THEN text END AS preview
                FROM events WHERE session_id=? AND kind IN ('tool_call','tool_result')
                ORDER BY seq DESC,id DESC LIMIT 5
                """, arguments: [id]).map { row in
                    guard let kind = EventKind(rawValue: row["kind"]) else { throw StoreError.invalidStoredValue }
                    return .tool(kind: kind, name: row["tool_name"], text: row["preview"], timestamp: row["ts"])
                }
        } else {
            actions = structured.enumerated().sorted {
                $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time > $1.element.time
            }.prefix(5).map(\.element)
        }
        let topics = try String.fetchAll(db, sql: """
            SELECT term FROM session_keywords WHERE session_id=? AND length(CAST(term AS BLOB))<=512
            ORDER BY weight DESC,term LIMIT 20
            """, arguments: [id])

        return try .init(summary: summary.flatMap { $0.isEmpty ? nil : $0 } ?? latestText(.summary),
                         lastPrompt: latestText(.user), lastReply: latestText(.assistant),
                         topics: topics, recentActions: actions, files: files, commands: commands)
    }

    private static func overviewFiles(in id: Int64, order: String, limit: Int, db: Database) throws -> [IndexedOverviewFile] {
        try Row.fetchAll(db, sql: """
            SELECT path,op,count,lines_added,lines_removed,last_ts FROM file_touches
            WHERE session_id=? AND length(CAST(path AS BLOB))<=16384
            ORDER BY \(order) LIMIT ?
            """, arguments: [id, limit]).map { row in
                .init(path: row["path"], operation: row["op"], count: row["count"],
                      added: row["lines_added"], removed: row["lines_removed"], timestamp: row["last_ts"])
            }
    }
}
