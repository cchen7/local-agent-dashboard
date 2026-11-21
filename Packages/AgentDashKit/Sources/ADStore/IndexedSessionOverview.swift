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
            try Self.overviewMessage(in: id, agent: session.agent, kind: kind, db: db)
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
        let actions = try overviewActions(in: id, structured: structured, db: db)
        let candidates = try String.fetchAll(db, sql: """
            SELECT term FROM session_keywords WHERE session_id=? AND length(CAST(term AS BLOB))<=512
            ORDER BY weight DESC,term LIMIT 20
            """, arguments: [id])
        let topics = try overviewSearchableTopics(candidates, in: id, db: db)

        return try .init(summary: summary.flatMap { $0.isEmpty ? nil : $0 } ?? latestText(.summary),
                         lastPrompt: latestText(.user), lastReply: latestText(.assistant),
                         topics: topics, recentActions: actions, files: files, commands: commands)
    }

    private static func overviewActions(in id: Int64, structured: [IndexedOverviewAction], db: Database)
    throws -> [IndexedOverviewAction] {
        // Each candidate structured row can replace at most one call. After
        // those matches there are still enough rows to choose the newest five.
        let rows = try Row.fetchCursor(db, sql: """
            SELECT kind,ts,CASE WHEN length(CAST(tool_name AS BLOB))<=16384 THEN tool_name END AS tool_name,
                   CASE WHEN length(CAST(text AS BLOB))<=1048576 THEN text END AS preview
            FROM events WHERE session_id=? AND kind IN ('tool_call','tool_result')
            ORDER BY ts DESC,seq DESC,id DESC LIMIT ?
            """, arguments: [id, 5 + structured.count])
        var unpaired = structured
        var tools: [IndexedOverviewAction] = []
        while tools.count < 5, let row = try rows.next() {
            guard let kind = EventKind(rawValue: row["kind"]) else { throw StoreError.invalidStoredValue }
            let name: String? = row["tool_name"]
            let text: String? = row["preview"]
            let time: Int64 = row["ts"]
            if kind == .toolCall, time > 0, let name, let text,
               let match = unpaired.firstIndex(where: { $0.time == time && represents($0, tool: name, text: text) }) {
                unpaired.remove(at: match)
            } else {
                tools.append(.tool(kind: kind, name: name, text: text, timestamp: time))
            }
        }
        return (structured + tools).enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time > $1.element.time
        }.prefix(5).map(\.element)
    }

    private static func represents(_ action: IndexedOverviewAction, tool: String, text: String) -> Bool {
        let name = tool.lowercased()
        switch action {
        case .file(let row):
            let operation = name == "multiedit" ? "edit" : name
            return ["read", "edit", "write", "delete"].contains(operation) &&
                operation == row.operation && row.path.utf8.elementsEqual(text.utf8)
        case .command(let row):
            return ["bash", "exec_command", "shell", "run_command"].contains(name) &&
                row.text.utf8.elementsEqual(text.utf8)
        case .tool:
            return false
        }
    }

    private static func overviewMessage(in id: Int64, agent: AgentKind, kind: EventKind, db: Database) throws -> String? {
        // Legacy/non-Claude rows can contain other metadata or invalid JSON.
        let assistantID = """
            CASE WHEN kind='assistant' AND length(CAST(meta_json AS BLOB))<=4096 AND json_valid(meta_json)
                 THEN json_extract(meta_json,'$.claude_message_id') END
            """
        guard let latest = try Row.fetchOne(db, sql: """
            SELECT seq,dedupe_key,\(assistantID) AS message_id,
                   CASE WHEN length(CAST(text AS BLOB))<=1048576 THEN text END AS preview
            FROM events WHERE session_id=? AND kind=? AND text IS NOT NULL AND text<>''
            ORDER BY seq DESC,id DESC LIMIT 1
            """, arguments: [id, kind.rawValue]) else { return nil }
        let body: String? = latest["preview"]
        guard body != nil, agent == .claudeCode, kind == .user || kind == .assistant,
              let record = claudeBlock(latest["dedupe_key"]) else { return body }

        let selection: String
        let selectionArgs: StatementArguments
        if kind == .assistant, let messageID: String = latest["message_id"] {
            selection = "(\(assistantID))=? COLLATE BINARY"
            selectionArgs = [messageID]
        } else {
            // Old indexes and user prompts have only physical record identity.
            selection = """
                seq=? AND substr(dedupe_key,1,length(?))=? COLLATE BINARY
                      AND instr(substr(dedupe_key,length(?) + 1),':')=0
                """
            selectionArgs = [latest["seq"] as Int64, record.prefix, record.prefix, record.prefix]
        }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT seq,dedupe_key,CASE WHEN length(CAST(text AS BLOB))<=1048576 THEN text END AS preview
            FROM events WHERE session_id=? AND kind=? AND text IS NOT NULL AND \(selection)
            ORDER BY seq,id
            LIMIT 241
            """, arguments: [id, kind.rawValue] + selectionArgs)
        var records: [PhysicalBlockRecord: Int] = [:]
        var pieces: [(record: Int, index: Int, text: String)] = []
        var bytes = 0
        while let row = try rows.next() {
            guard let block = claudeBlock(row["dedupe_key"]), let text: String = row["preview"], pieces.count < 240,
                  text.utf8.count <= 1_048_576 - bytes else { return nil }
            bytes += text.utf8.count
            let physical = PhysicalBlockRecord(sequence: row["seq"], key: Array(block.prefix.utf8))
            let order = records[physical, default: records.count]
            records[physical] = order
            pieces.append((order, block.index, text))
        }
        // Do not insert delimiters before masking; a credential can straddle blocks.
        return pieces.sorted { ($0.record, $0.index) < ($1.record, $1.index) }.map(\.text).joined()
    }

    private struct PhysicalBlockRecord: Hashable {
        let sequence: Int64
        let key: [UInt8]
    }

    private static func claudeBlock(_ key: String) -> (prefix: String, index: Int)? {
        guard key.hasPrefix("claude:event:"), let colon = key.lastIndex(of: ":") else { return nil }
        let suffix = key[key.index(after: colon)...]
        guard let index = Int(suffix), (0..<240).contains(index), String(index) == suffix else { return nil }
        return (String(key[...colon]), index)
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
